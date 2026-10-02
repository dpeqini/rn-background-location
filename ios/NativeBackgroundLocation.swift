import Foundation
import CoreLocation
import CoreMotion
import UIKit
import React

// Engine state is confined to the main thread: Core Location delivers there, the RN module hops there,
// and the uploader hands its callbacks there. Trap in debug builds if that ever stops being true.
@inline(__always) private func assertMain(){
  #if DEBUG
  dispatchPrecondition(condition:.onQueue(.main))
  #endif
}

final class BackgroundLocationEngine: NSObject, CLLocationManagerDelegate {
  static let shared = BackgroundLocationEngine()
  var emit: ((String, Any) -> Void)?
  private let manager = CLLocationManager()
  private let motionManager = CMMotionActivityManager()
  private let queue = IOSLocationQueue.shared
  private var config:[String:Any] = [:]
  private(set) var tracking=false
  private(set) var motion="unknown"
  private var heartbeatTimer:Timer?
  // Each pending getCurrentLocation owns its own box, so a timeout settles only its own promise
  // and a second call can no longer overwrite (and strand) the first.
  private final class OneShot {
    let completion:(Result<[String:Any],Error>)->Void
    var settled=false
    init(_ c:@escaping(Result<[String:Any],Error>)->Void){completion=c}
    func settle(_ r:Result<[String:Any],Error>){guard !settled else{return};settled=true;completion(r)}
  }
  private var oneShots:[OneShot]=[]
  private var lastFix:CLLocation?
  private var primarySource="gps"
  private var systemPaused=false
  private var safetyNet=false
  private var warnedAboutAuthorization=false
  private var warnedAboutBackgroundMode=false
  // Setting allowsBackgroundLocationUpdates without the Info.plist entry raises an
  // ObjC exception, so check once and report it as an error the host can see instead.
  private lazy var backgroundModeDeclared:Bool={(Bundle.main.object(forInfoDictionaryKey:"UIBackgroundModes") as? [String])?.contains("location") ?? false}()
  // Callers that asked for a sync while an upload was already in flight; settled with its result.
  private var syncWaiters:[(Int,Int,Error?)->Void]=[]
  // Queue overflow and storage failures are reported at most once a minute, with drops summed.
  private var unreportedDrops=0
  private var unreportedStorageFailure=false
  private var lastStorageReport=Date.distantPast
  private var storageReportScheduled=false
  // One upload at a time; see sync().
  private var uploading=false
  // Exit-only region kept around the last good fix. Region monitoring relaunches a terminated app, including
  // after a swipe-kill from the app switcher, and a region this small fires within a couple of hundred metres.
  // Significant-change monitoring alone waits for roughly 500 m and a cell-tower change.
  private static let relaunchFenceId="rn_bg_location_relaunch"
  private var relaunchFenceCenter:CLLocation?

  // Core Location calls the delegate on the thread that created the manager, so this must be main.
  override init(){
    super.init(); assertMain(); manager.delegate=self; loadConfig(); observeAppState()
    // Regions outlive the process, so a fence armed by a previous launch is still registered.
    relaunchFenceCenter=(manager.monitoredRegions.first{$0.identifier==Self.relaunchFenceId} as? CLCircularRegion).map{CLLocation(latitude:$0.center.latitude,longitude:$0.center.longitude)}
    BackgroundUploader.shared.onOrphanFinished={[weak self]outcome,_ in self?.orphanFinished(outcome)}
  }

  // Core Location must be driven from the main thread: the bridge calls these methods on the
  // module queue, which has no run loop, so timers never fire and start/stop is racy there.
  private func onMain(_ work:@escaping()->Void){ if Thread.isMainThread {work()} else {DispatchQueue.main.async(execute:work)} }

  func loadConfig(){ config=UserDefaults.standard.dictionary(forKey:"rn_bg_location_config") ?? [:]; tracking=UserDefaults.standard.bool(forKey:"rn_bg_location_tracking") }
  // Reconfiguring while tracking has to swap the primitive too, not just the accuracy: the modes
  // map onto different Core Location services, and applyMode alone cannot move between them.
  func configure(_ c:[String:Any]){ onMain{[weak self] in guard let self else{return};self.config=c;UserDefaults.standard.set(c,forKey:"rn_bg_location_config");self.applyMode();if self.stopOnTerminate{self.disarmRelaunchFence()};if self.tracking{self.stopPrimitives();self.startLocationPrimitive()}} }
  private var stopOnTerminate:Bool{config["stopOnTerminate"] as? Bool ?? false}
  private func stopPrimitives(){manager.stopUpdatingLocation();manager.stopMonitoringSignificantLocationChanges();manager.stopMonitoringVisits();safetyNet=false}
  func requestAlways(){ onMain{[weak self] in self?.manager.requestAlwaysAuthorization()} }
  func start(){ onMain{[weak self] in guard let self else{return};self.tracking=true;UserDefaults.standard.set(true,forKey:"rn_bg_location_tracking");self.applyMode();self.startLocationPrimitive();self.startMotion();self.startHeartbeat()} }
  // Runs on every launch, including the background relaunches iOS grants after the process dies.
  func bootstrap(){ onMain{[weak self] in guard let self else{return}
    self.loadConfig()
    guard self.tracking else{return}
    // stopOnTerminate: the process died and the host asked not to resume. Default is to resume.
    if self.stopOnTerminate {self.tracking=false;UserDefaults.standard.set(false,forKey:"rn_bg_location_tracking");self.disarmRelaunchFence();return}
    self.applyMode();self.startLocationPrimitive();self.startMotion();self.startHeartbeat();self.sync()
  }}
  func stop(){ onMain{[weak self] in guard let self else{return};self.tracking=false;UserDefaults.standard.set(false,forKey:"rn_bg_location_tracking");self.stopPrimitives();self.motionManager.stopActivityUpdates();self.heartbeatTimer?.invalidate();self.heartbeatTimer=nil;self.systemPaused=false;self.safetyNet=false;self.disarmRelaunchFence()} }

  func state()->[String:Any]{["enabled":CLLocationManager.locationServicesEnabled(),"authorization":authorization(),"tracking":tracking,"mode":config["mode"] as? String ?? "adaptive","queueSize":queue.count(),"motion":motion]}
  func queued(_ limit:Int)->[[String:Any]]{queue.peek(limit:limit).map{$0.payload}}
  func clear(){queue.clear()}
  func current(timeoutMs:Double,completion:@escaping(Result<[String:Any],Error>)->Void){
    onMain{[weak self] in guard let self else{return}
      if let l=self.lastFix,Date().timeIntervalSince(l.timestamp)<30 {completion(.success(self.record(l,"gps")));return}
      let shot=OneShot(completion)
      self.oneShots.append(shot)
      // requestLocation() errors while continuous updates are active; the stream delivers instead.
      if !self.tracking {self.manager.requestLocation()}
      DispatchQueue.main.asyncAfter(deadline:.now()+max(timeoutMs,1000)/1000){[weak self] in
        shot.settle(.failure(NSError(domain:"BackgroundLocation",code:2,userInfo:[NSLocalizedDescriptionKey:"Timed out waiting for a location fix"])))
        self?.oneShots.removeAll{$0.settled}
      }
    }
  }
  private func authorization()->String{switch manager.authorizationStatus{case .authorizedAlways:return "always";case .authorizedWhenInUse:return "whenInUse";case .denied:return "denied";case .restricted:return "restricted";default:return "notDetermined"}}

  private func startLocationPrimitive(){
    let m=config["mode"] as? String ?? "adaptive"
    systemPaused=false
    primarySource = (m=="significant"||m=="lowPower") ? "significant" : "gps"
    if m=="significant"||m=="lowPower" {manager.startMonitoringSignificantLocationChanges();safetyNet=false}
    else if m=="visits" {manager.startMonitoringVisits();safetyNet=false}
    else {
      manager.startUpdatingLocation()
      // Continuous updates die with the process and do not come back on their own. Significant-change
      // monitoring is the only primitive that relaunches the app, so keep it armed alongside.
      if manager.authorizationStatus == .authorizedAlways {manager.startMonitoringSignificantLocationChanges();safetyNet=true}
      else {safetyNet=false;warnAboutAuthorization()}
    }
  }
  private func warnAboutBackgroundMode(){guard !warnedAboutBackgroundMode else{return};warnedAboutBackgroundMode=true;emit?("backgroundLocation:error",["code":"backgroundMode","message":"Info.plist UIBackgroundModes is missing \"location\". Enable Background Modes > Location updates; without it iOS stops location the moment the app leaves the foreground."])}
  private func warnAboutAuthorization(){guard !warnedAboutAuthorization else{return};warnedAboutAuthorization=true;emit?("backgroundLocation:error",["code":"authorization","message":"Background tracking needs Always authorization. With When In Use, updates stop once the app is suspended and cannot be resumed."])}

  private func applyMode(){
    let ios=config["ios"] as? [String:Any]
    if backgroundModeDeclared {manager.allowsBackgroundLocationUpdates=true} else {warnAboutBackgroundMode()}
    manager.showsBackgroundLocationIndicator=ios?["showsBackgroundLocationIndicator"] as? Bool ?? false
    manager.activityType=activityType(ios?["activityType"] as? String)
    // Off by default: once iOS pauses updates it decides if and when they resume, and in the
    // background that regularly means never. Hosts opt back in with pausesAutomatically.
    manager.pausesLocationUpdatesAutomatically=config["pausesAutomatically"] as? Bool ?? false
    switch profile(){
    case "navigation":manager.desiredAccuracy=kCLLocationAccuracyBestForNavigation;manager.distanceFilter=10;manager.pausesLocationUpdatesAutomatically=false
    case "active":manager.desiredAccuracy=kCLLocationAccuracyBest;manager.distanceFilter=config["motionDistanceMeters"] as? Double ?? 10
    case "balanced":manager.desiredAccuracy=kCLLocationAccuracyHundredMeters;manager.distanceFilter=config["distanceFilterMeters"] as? Double ?? 50
    default:manager.desiredAccuracy=kCLLocationAccuracyKilometer;manager.distanceFilter=100
    }
  }
  // Only adaptive follows Core Motion; an explicit mode stays where the host put it.
  private func profile()->String{
    let m=config["mode"] as? String ?? "adaptive"
    guard m=="adaptive" else{return m}
    switch motion{
    case "automotive":return "navigation"
    case "walking","running","cycling":return "active"
    default:return "balanced" // stationary and unknown: coarse, but never the kilometer floor
    }
  }
  private func activityType(_ s:String?)->CLActivityType{switch s{case "automotiveNavigation":return .automotiveNavigation;case "fitness":return .fitness;case "otherNavigation":return .otherNavigation;case "airborne":return .airborne;default:return .other}}
  private func observeAppState(){
    // allowsBackgroundLocationUpdates has to be true before the app leaves the foreground,
    // otherwise updates are dropped when it suspends.
    NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main){[weak self]_ in
      guard let self,self.tracking else{return};self.applyMode();if !self.systemPaused{self.startLocationPrimitive()};self.sync()
    }
  }
  // Delivered on main: motion is read on every fix, and a String written from another thread races that read.
  private func startMotion(){guard config["motionDetection"] as? Bool ?? true,CMMotionActivityManager.isActivityAvailable() else{return};motionManager.stopActivityUpdates();motionManager.startActivityUpdates(to:.main){[weak self]a in guard let self,let a else{return};let n=a.automotive ? "automotive":a.cycling ? "cycling":a.running ? "running":a.walking ? "walking":a.stationary ? "stationary":"unknown";guard n != self.motion else{return};self.motion=n;self.applyMode();self.emit?("backgroundLocation:motion",["motion":n,"timestamp":Date().timeIntervalSince1970*1000])}}
  private func startHeartbeat(){onMain{[weak self] in guard let self else{return};self.heartbeatTimer?.invalidate();let sec=max(self.config["heartbeatIntervalSeconds"] as? Double ?? 60,15);let t=Timer(timeInterval:sec,repeats:true){[weak self]_ in guard let self,self.tracking else{return};self.emit?("backgroundLocation:heartbeat",["timestamp":Date().timeIntervalSince1970*1000,"queueSize":self.queue.count(),"motion":self.motion])};RunLoop.main.add(t,forMode:.common);self.heartbeatTimer=t}}

  func locationManager(_ manager:CLLocationManager,didUpdateLocations ls:[CLLocation]){
    assertMain()
    if systemPaused&&tracking{startLocationPrimitive()}
    store(ls,primarySource)
    guard let l=ls.last else{return}
    lastFix=l
    armRelaunchFence(l)
    let r=record(l,primarySource);let pending=oneShots;oneShots=[];pending.forEach{$0.settle(.success(r))}
  }

  // Re-registered only once the device has moved half a radius from the current center, not on every fix.
  private func armRelaunchFence(_ l:CLLocation){
    guard tracking,!stopOnTerminate,manager.authorizationStatus == .authorizedAlways,CLLocationManager.isMonitoringAvailable(for:CLCircularRegion.self),l.horizontalAccuracy>=0,l.horizontalAccuracy<=200 else{return}
    let configured=(config["ios"] as? [String:Any])?["relaunchRadiusMeters"] as? Double ?? 150
    let radius=min(max(configured,100),manager.maximumRegionMonitoringDistance)
    if let c=relaunchFenceCenter,l.distance(from:c)<radius/2 {return}
    let r=CLCircularRegion(center:l.coordinate,radius:radius,identifier:Self.relaunchFenceId)
    r.notifyOnEntry=false;r.notifyOnExit=true
    // Same identifier, so this replaces the previous fence rather than adding one.
    manager.startMonitoring(for:r)
    relaunchFenceCenter=l
  }
  private func disarmRelaunchFence(){
    manager.monitoredRegions.filter{$0.identifier==Self.relaunchFenceId}.forEach{manager.stopMonitoring(for:$0)}
    relaunchFenceCenter=nil
  }
  func locationManagerDidPauseLocationUpdates(_ manager:CLLocationManager){
    // iOS alone decides whether paused updates ever resume. Arm significant-change monitoring so
    // real movement wakes us, and restart continuous updates on the next fix that arrives.
    systemPaused=true
    if manager.authorizationStatus == .authorizedAlways && !safetyNet {manager.startMonitoringSignificantLocationChanges();safetyNet=true}
    emit?("backgroundLocation:error",["code":"paused","message":"System paused location updates"])
  }
  func locationManagerDidResumeLocationUpdates(_ manager:CLLocationManager){systemPaused=false}
  func locationManagerDidChangeAuthorization(_ manager:CLLocationManager){guard tracking,manager.authorizationStatus == .authorizedAlways else{return};warnedAboutAuthorization=false;onMain{[weak self] in guard let self else{return};self.applyMode();self.startLocationPrimitive()}}
  func locationManager(_ manager:CLLocationManager,didVisit v:CLVisit){store([CLLocation(latitude:v.coordinate.latitude,longitude:v.coordinate.longitude)],"visit")}
  func locationManager(_ manager:CLLocationManager,didEnterRegion r:CLRegion){handleRegion(r,"enter")}
  func locationManager(_ manager:CLLocationManager,didExitRegion r:CLRegion){handleRegion(r,"exit")}
  // A region event can wake a process where JS is not running, so emit is a no-op and the fix
  // would be lost. Persist it to the queue as well.
  private func handleRegion(_ r:CLRegion,_ transition:String){
    // The relaunch fence exists only to wake the app; bootstrap() has already restarted updates by now.
    // Its center is where the device was, not where it is, so it is never stored as a fix. Clearing the
    // center lets the next fix re-arm it around the new position.
    if r.identifier==Self.relaunchFenceId {
      relaunchFenceCenter=nil
      if tracking&&systemPaused {startLocationPrimitive()}
      return
    }
    emit?("backgroundLocation:geofence",["id":r.identifier,"transition":transition,"timestamp":Date().timeIntervalSince1970*1000])
    if let c=r as? CLCircularRegion {store([CLLocation(latitude:c.center.latitude,longitude:c.center.longitude)],"geofence")}
  }
  func locationManager(_ manager:CLLocationManager,didFailWithError e:Error){
    // kCLErrorLocationUnknown means "no fix yet", not failure: Core Location keeps trying and
    // surfacing it turns a normal cold start into a stream of error events.
    let code=(e as NSError).code
    guard code != CLError.locationUnknown.rawValue else{return}
    let pending=oneShots;oneShots=[];pending.forEach{$0.settle(.failure(e))}
    emit?("backgroundLocation:error",["code":code==CLError.denied.rawValue ? "authorization":"location","message":e.localizedDescription])
  }
  private func record(_ l:CLLocation,_ source:String)->[String:Any]{["id":UUID().uuidString,"latitude":l.coordinate.latitude,"longitude":l.coordinate.longitude,"accuracy":l.horizontalAccuracy,"altitude":l.altitude,"altitudeAccuracy":l.verticalAccuracy,"heading":l.course,"speed":l.speed,"timestamp":l.timestamp.timeIntervalSince1970*1000,"motion":motion,"source":source]}
  // One transaction per delivery rather than per fix; Core Location often hands over several at once.
  private func store(_ ls:[CLLocation],_ source:String){
    assertMain()
    guard !ls.isEmpty else{return}
    let rs=ls.map{record($0,source)}
    reportStorage(queue.enqueue(rs,max:config["maxQueueSize"] as? Int ?? 10000))
    rs.forEach{emit?("backgroundLocation:location",$0)}
    let th=(config["http"] as? [String:Any])?["syncThreshold"] as? Int ?? 10
    if queue.count()>=th{sync()}
  }
  private func reportStorage(_ r:EnqueueResult){
    unreportedDrops+=r.dropped
    if r.failed{unreportedStorageFailure=true}
    flushStorageReports()
  }
  private func flushStorageReports(){
    guard unreportedDrops>0||unreportedStorageFailure else{return}
    let wait=60-Date().timeIntervalSince(lastStorageReport)
    if wait>0 {
      guard !storageReportScheduled else{return}
      storageReportScheduled=true
      DispatchQueue.main.asyncAfter(deadline:.now()+wait){[weak self] in self?.storageReportScheduled=false;self?.flushStorageReports()}
      return
    }
    lastStorageReport=Date()
    if unreportedDrops>0 {emit?("backgroundLocation:error",["code":"queueOverflow","message":"Discarded \(unreportedDrops) oldest queued location(s): the queue reached maxQueueSize, or storage was unavailable, before they could be uploaded"]);unreportedDrops=0}
    if unreportedStorageFailure {emit?("backgroundLocation:error",["code":"storage","message":"Could not write locations to the on-device queue; recent fixes are held in memory until storage is available"]);unreportedStorageFailure=false}
  }

  func addGeofence(_ g:[String:Any]) throws {
    // iOS caps monitored regions at 20 per app and silently drops the rest, so a geofence added
    // past the cap would simply never fire. Fail loudly instead. One slot stays reserved for the relaunch fence.
    let requested=g["id"] as? String ?? ""
    guard requested != Self.relaunchFenceId else{throw NSError(domain:"BackgroundLocation",code:1,userInfo:[NSLocalizedDescriptionKey:"\(requested) is reserved"])}
    let user=manager.monitoredRegions.filter{$0.identifier != Self.relaunchFenceId}
    guard user.count < 19 || user.contains(where:{$0.identifier==requested}) else{
      throw NSError(domain:"BackgroundLocation",code:3,userInfo:[NSLocalizedDescriptionKey:"At most 19 geofences can be monitored on iOS (20 regions per app, one reserved); remove one before adding another"])
    }
    guard let id=g["id"] as? String,let lat=g["latitude"] as? Double,let lon=g["longitude"] as? Double,let radius=g["radius"] as? Double else{throw NSError(domain:"BackgroundLocation",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid geofence"])};let r=CLCircularRegion(center:.init(latitude:lat,longitude:lon),radius:min(radius,manager.maximumRegionMonitoringDistance),identifier:id);r.notifyOnEntry=g["notifyOnEntry"] as? Bool ?? true;r.notifyOnExit=g["notifyOnExit"] as? Bool ?? true;manager.startMonitoring(for:r)}
  func removeGeofence(_ id:String){guard id != Self.relaunchFenceId else{return};if let r=manager.monitoredRegions.first(where:{$0.identifier==id}){manager.stopMonitoring(for:r)}}
  func removeAllGeofences(){manager.monitoredRegions.filter{$0.identifier != Self.relaunchFenceId}.forEach{manager.stopMonitoring(for:$0)}}

  // completion is nil for internal triggers (each fix, draining, backgrounding): they need no answer and
  // must not pile up as waiters while one upload sits waiting for connectivity.
  func sync(completion:((Int,Int,Error?)->Void)?=nil){
    assertMain()
    let uploader=BackgroundUploader.shared
    // Decide nothing until the uploader has cancelled whatever a previous process left in flight.
    guard uploader.isReady else{uploader.whenReady{[weak self] in self?.sync(completion:completion)};return}
    // One upload at a time. Rows are deleted only on acknowledgement, so a request started while another
    // is pending would carry the same head of the queue.
    guard !uploading else{if let completion{syncWaiters.append(completion)};return}
    // Backoff state is persisted, so an outage does not restart it from zero on every relaunch, and a
    // doomed request per location fix is what drains the battery.
    guard !SyncBackoff.isBlocked else{completion?(0,queue.count(),nil);return}
    guard let h=config["http"] as? [String:Any],let us=h["url"] as? String,let url=URL(string:us),let next=nextUpload(h) else{completion?(0,queue.count(),nil);return}
    uploading=true
    upload(h,url,next.body,next.receipt){[weak self]outcome,status,error in guard let self else{return}
      self.uploading=false
      let sent = outcome == .delivered ? next.count : 0
      let remaining=self.queue.count();let err = outcome == .retry ? error : nil
      // A failed upload says why, so a stalled queue can be diagnosed from JS.
      var event:[String:Any]=["sent":sent,"remaining":remaining]
      if outcome != .delivered {event["status"]=status;event["error"]=error?.localizedDescription ?? "HTTP \(status)"}
      self.emit?("backgroundLocation:sync",event)
      if outcome == .dropped {self.emitDrop(next.count,error)}
      let waiters=self.syncWaiters;self.syncWaiters=[]
      completion?(sent,remaining,err);waiters.forEach{$0(sent,remaining,err)}
      self.drainIfNeeded(outcome)
    }
  }

  // The next request body: one row in single mode, otherwise the head batch. The receipt is the last
  // row id it carries; acknowledging deletes through it.
  private func nextUpload(_ h:[String:Any])->(body:Data,receipt:Int64,count:Int)?{
    if h["single"] as? Bool ?? false {
      guard let row=queue.peek(limit:1).first,let body=try? JSONSerialization.data(withJSONObject:buildSingleBody(row.payload,h)) else{return nil}
      return (body,row.id,1)
    }
    let batch=queue.peek(limit:h["batchSize"] as? Int ?? 50);guard let last=batch.last else{return nil}
    let root=h["rootProperty"] as? String ?? "locations"
    let payload:Any = root=="." ? batch.map{$0.payload} : [root:batch.map{$0.payload}]
    guard let body=try? JSONSerialization.data(withJSONObject:payload) else{return nil}
    return (body,last.id,batch.count)
  }

  // Keeps a backlog moving, one request at a time. Only a delivery chains: a drop also frees the queue,
  // but chaining on it would burn through thousands of records against an endpoint rejecting everything.
  private func drainIfNeeded(_ outcome:SyncOutcome){
    guard outcome == .delivered,tracking,let h=config["http"] as? [String:Any] else{return}
    let single=h["single"] as? Bool ?? false
    let n=queue.count()
    let due = single ? n>0 : n>=(h["syncThreshold"] as? Int ?? 10)
    if due {sync()}
  }

  // An upload left over from a previous process finished. Nobody here waits on it specifically, but
  // callers queued behind it do, and a delivery may leave a backlog to drain.
  private func orphanFinished(_ outcome:SyncOutcome){
    guard !uploading else{return}
    let waiters=syncWaiters;syncWaiters=[]
    if waiters.isEmpty {drainIfNeeded(outcome)} else {sync{s,r,e in waiters.forEach{$0(s,r,e)}}}
  }

  private func emitDrop(_ count:Int,_ error:Error?){
    emit?("backgroundLocation:error",["code":"syncDropped","message":"Discarded \(count) location(s) the server rejected permanently: \(error?.localizedDescription ?? "client error")"])
  }

  private func upload(_ h:[String:Any],_ url:URL,_ body:Data,_ receipt:Int64,_ completion:@escaping(SyncOutcome,Int,Error?)->Void){
    var req=URLRequest(url:url);req.httpMethod=h["method"] as? String ?? "POST";req.setValue("application/json",forHTTPHeaderField:"Content-Type")
    req.timeoutInterval=(h["timeoutMs"] as? Double ?? 15000)/1000
    (h["headers"] as? [String:String])?.forEach{req.setValue($1,forHTTPHeaderField:$0)}
    DirectUploader.shared.send(req,body:body,receipt:receipt,maxRetries:h["maxRetries"] as? Int ?? 10,completion:completion)
  }
  private func buildSingleBody(_ record:[String:Any],_ h:[String:Any])->[String:Any]{
    var obj:[String:Any]
    if let t=h["locationTemplate"] as? String,!t.isEmpty,let d=renderTemplate(t,record).data(using:.utf8),let parsed=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any]{obj=parsed}
    else{obj=record}
    if let params=h["params"] as? [String:Any]{for (k,v) in params{obj[k]=v}}
    return obj
  }

  private func renderTemplate(_ template:String,_ record:[String:Any])->String{
    var out=template
    for (k,v) in record{
      let s:String
      if let d=v as? Double{s=String(d)}else if let i=v as? Int{s=String(i)}else if let b=v as? Bool{s=b ? "true":"false"}else{s=String(describing:v)}
      out=out.replacingOccurrences(of:"<%= \(k) %>",with:s).replacingOccurrences(of:"<%=\(k)%>",with:s)
    }
    return out
  }
}

// cancelled: the uploader withdrew a redundant task. Its rows are still queued and nothing failed.
enum SyncOutcome { case delivered, dropped, retry, cancelled }

// Persisted, so an outage does not restart the backoff from zero every time the process is
// relaunched, and so a queue that cannot be delivered stops costing a request per location fix.
enum SyncBackoff {
  private static let failuresKey="rn_bg_location_sync_failures"
  private static let nextKey="rn_bg_location_sync_next"
  static var failures:Int{UserDefaults.standard.integer(forKey:failuresKey)}
  static var isBlocked:Bool{Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey:nextKey)}
  static func reset(){UserDefaults.standard.removeObject(forKey:failuresKey);UserDefaults.standard.removeObject(forKey:nextKey)}
  static func fail(){
    let n=failures+1
    UserDefaults.standard.set(n,forKey:failuresKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970+min(pow(2.0,Double(min(n,6)))*5,300),forKey:nextKey)
  }
}

// Uploads from memory on an ordinary session. A fix is only delivered while the process is running, and a
// running process gets its answer in one round trip. The background session used before handed every request
// to nsurlsessiond, which treats tasks created while the app is in the background as discretionary and may
// hold one for up to its resource timeout, keeping the single upload slot while the queue grew. It also
// wrote each body to disk first, so a full disk stopped all uploads.
final class DirectUploader {
  static let shared=DirectUploader()
  private let session:URLSession={
    let c=URLSessionConfiguration.ephemeral;c.waitsForConnectivity=false;c.urlCache=nil
    return URLSession(configuration:c)
  }()

  // completion runs on main with the outcome, the HTTP status (0 without a response) and the error.
  func send(_ req:URLRequest,body:Data,receipt:Int64,maxRetries:Int,completion:@escaping(SyncOutcome,Int,Error?)->Void){
    // Lets a request started just before suspension finish instead of being frozen mid-flight.
    var bg=UIBackgroundTaskIdentifier.invalid
    let end={ if bg != .invalid {UIApplication.shared.endBackgroundTask(bg);bg = .invalid} }
    bg=UIApplication.shared.beginBackgroundTask(withName:"rn-bg-location-upload"){DispatchQueue.main.async(execute:end)}
    session.uploadTask(with:req,from:body){_,response,error in
      let status=(response as? HTTPURLResponse)?.statusCode ?? 0
      let outcome=BackgroundUploader.classify(code:status,error:error,failures:SyncBackoff.failures,maxRetries:maxRetries)
      BackgroundUploader.acknowledge(outcome,receipt:receipt)
      DispatchQueue.main.async{completion(outcome,status,error);end()}
    }.resume()
  }
}

// Since DirectUploader took over, this only finishes off upload tasks an earlier version left with
// nsurlsessiond: it cancels them on launch, and acknowledges any that complete before the cancel lands.
final class BackgroundUploader:NSObject,URLSessionTaskDelegate,URLSessionDelegate{
  static let shared=BackgroundUploader()
  var backgroundCompletion:(()->Void)?
  // Main thread. Called for a finished task with no completion in this process: one started by a
  // previous launch, including the backlog 1.1.9 left behind.
  var onOrphanFinished:((SyncOutcome,Error?)->Void)?
  // Guarded by lock.
  private var ready=false
  private var readyWaiters:[()->Void]=[]
  private let lock=NSLock()
  // Where earlier versions wrote upload bodies.
  private static let uploadsDir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("rn-bg-uploads",isDirectory:true)
  // Prefix of task descriptions that carry a version; tasks from 1.1.9 and earlier lack it.
  private static let descriptionVersion="v2"
  // Touched only from main (lazy initialisation is not thread-safe): by the engine and by reattach.
  private lazy var session:URLSession={
    let c=URLSessionConfiguration.background(withIdentifier:"com.greinchville.rn-background-location.http");c.sessionSendsLaunchEvents=true;c.isDiscretionary=false
    c.timeoutIntervalForResource=3600
    let s=URLSession(configuration:c,delegate:self,delegateQueue:nil)
    s.getAllTasks{[weak self] in self?.adopt($0)}
    return s
  }()

  var isReady:Bool{_ = session;lock.lock();defer{lock.unlock()};return ready}
  func whenReady(_ work:@escaping()->Void){
    _ = session
    lock.lock()
    if ready {lock.unlock();DispatchQueue.main.async(execute:work);return}
    readyWaiters.append(work);lock.unlock()
  }

  // Shared with DirectUploader: what an upload outcome does to the queue and the backoff.
  static func acknowledge(_ outcome:SyncOutcome,receipt:Int64?){
    switch outcome{
    case .delivered,.dropped: if let receipt {IOSLocationQueue.shared.deleteThrough(receipt)};SyncBackoff.reset()
    case .retry: SyncBackoff.fail()
    case .cancelled: break
    }
  }

  func urlSession(_ s:URLSession,task:URLSessionTask,didCompleteWithError e:Error?){
    let d=Self.parse(task.taskDescription)
    let outcome:SyncOutcome
    if let ns=e as NSError?,ns.domain==NSURLErrorDomain,ns.code==NSURLErrorCancelled {outcome = .cancelled}
    else{
      let code=(task.response as? HTTPURLResponse)?.statusCode ?? 0
      outcome=Self.classify(code:code,error:e,failures:SyncBackoff.failures,maxRetries:d.maxRetries)
      Self.acknowledge(outcome,receipt:d.receipt)
    }
    if let path=d.path {try? FileManager.default.removeItem(atPath:path)}
    // This runs on the session's background delegate queue. The callback re-enters the engine, whose
    // state is confined to main.
    DispatchQueue.main.async{[weak self] in self?.onOrphanFinished?(outcome,e)}
  }

  // A 4xx other than 408/429 will not start succeeding on repeat, so that batch is discarded rather
  // than blocking the queue behind it forever. A transport failure is always retried: no network is
  // not a reason to lose data. Only a server that keeps failing past maxRetries gives up.
  static func classify(code:Int,error:Error?,failures:Int,maxRetries:Int)->SyncOutcome{
    if error==nil,(200..<300).contains(code){return .delivered}
    if (400..<500).contains(code),code != 408,code != 429{return .dropped}
    if code >= 500,failures+1 >= maxRetries{return .dropped}
    return .retry
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session:URLSession){DispatchQueue.main.async{self.backgroundCompletion?();self.backgroundCompletion=nil}}
  func reattach(completion:@escaping()->Void){_ = session;backgroundCompletion=completion}

  // Runs once per process with the tasks nsurlsessiond still holds, all left by an earlier version. Each
  // carries the head of the queue, which DirectUploader will send anyway, and any of them could hold the
  // upload slot for an hour or more, so all are cancelled. Their rows are still queued.
  private func adopt(_ tasks:[URLSessionTask]){
    let live=tasks.filter{$0.state == .running || $0.state == .suspended}
    for t in live {t.cancel()}
    removeStaleFiles()
    lock.lock()
    ready=true
    let waiters=readyWaiters;readyWaiters=[]
    lock.unlock()
    DispatchQueue.main.async{waiters.forEach{$0()}}
  }

  // Body files of the tasks cancelled above, and 1.1.9's files in tmp/.
  private func removeStaleFiles(){
    let fm=FileManager.default
    for dir in [Self.uploadsDir,fm.temporaryDirectory] {
      for f in (try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? [] where f.lastPathComponent.hasPrefix("rn-bg-") {try? fm.removeItem(at:f)}
    }
  }

  // taskDescription is "v2|receipt|maxRetries|path"; tasks from 1.1.9 and earlier lack the version.
  private static func parse(_ description:String?)->(current:Bool,receipt:Int64?,maxRetries:Int,path:String?){
    guard var s=description else{return (false,nil,10,nil)}
    let current=s.hasPrefix(descriptionVersion+"|")
    if current {s.removeFirst(descriptionVersion.count+1)}
    let parts=s.split(separator:"|",maxSplits:2,omittingEmptySubsequences:false)
    guard parts.count==3 else{return (current,nil,10,nil)}
    return (current,Int64(parts[0]),Int(parts[1]) ?? 10,String(parts[2]))
  }
}

@objc(NativeBackgroundLocation)
final class NativeBackgroundLocation:RCTEventEmitter{
  private let engine=BackgroundLocationEngine.shared
  // Restoration belongs in the AppDelegate via NativeBackgroundLocationBootstrap, which runs before
  // JS. This is the fallback for hosts that skipped it: later, but better than never resuming.
  override init(){super.init();engine.emit={[weak self]n,b in self?.sendEvent(withName:n,body:b)};engine.bootstrap()}
  @objc override static func requiresMainQueueSetup()->Bool{true}
  override func supportedEvents()->[String]! { ["backgroundLocation:location","backgroundLocation:motion","backgroundLocation:geofence","backgroundLocation:heartbeat","backgroundLocation:sync","backgroundLocation:error"] }
  // The bridge calls these on the module's own queue, but engine state lives on main, so hop there.
  // Queue reads and clears go straight to storage, which is thread-safe, keeping a large read off main.
  private func onMain(_ work:@escaping()->Void){DispatchQueue.main.async(execute:work)}
  private func offMain(_ work:@escaping()->Void){DispatchQueue.global(qos:.userInitiated).async(execute:work)}
  @objc(configure:resolver:rejecter:) func configure(_ c:NSDictionary,resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){let c=c as? [String:Any] ?? [:];onMain{[engine] in engine.configure(c);resolve(engine.state())}}
  @objc(start:rejecter:) func start(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){onMain{[engine] in engine.start();resolve(nil)}}
  @objc(stop:rejecter:) func stop(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){onMain{[engine] in engine.stop();resolve(nil)}}
  @objc(getState:rejecter:) func getState(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){onMain{[engine] in resolve(engine.state())}}
  @objc(requestPermissions:rejecter:) func requestPermissions(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){onMain{[engine] in engine.requestAlways();resolve("requested")}}
  @objc(getCurrentLocation:resolver:rejecter:) func getCurrentLocation(_ o:NSDictionary,resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){let t=(o["timeoutMs"] as? Double) ?? 15000;onMain{[engine] in engine.current(timeoutMs:t){r in switch r{case .success(let l):resolve(l);case .failure(let e):reject("location_failed",e.localizedDescription,e)}}}}
  @objc(getQueuedLocations:resolver:rejecter:) func getQueuedLocations(_ limit:NSNumber,resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){let n=limit.intValue;offMain{[engine] in resolve(engine.queued(n))}}
  @objc(clearQueue:rejecter:) func clearQueue(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){offMain{[engine] in engine.clear();resolve(nil)}}
  @objc(sync:rejecter:) func sync(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){onMain{[engine] in engine.sync{sent,remaining,e in if let e{reject("sync_failed",e.localizedDescription,e)}else{resolve(["sent":sent,"remaining":remaining])}}}}
  @objc(addGeofence:resolver:rejecter:) func addGeofence(_ g:NSDictionary,resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){let g=g as? [String:Any] ?? [:];onMain{[engine] in do{try engine.addGeofence(g);resolve(nil)}catch{reject("geofence",error.localizedDescription,error)}}}
  @objc(removeGeofence:resolver:rejecter:) func removeGeofence(_ id:String,resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){onMain{[engine] in engine.removeGeofence(id);resolve(nil)}}
  @objc(removeAllGeofences:rejecter:) func removeAllGeofences(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){onMain{[engine] in engine.removeAllGeofences();resolve(nil)}}
}
