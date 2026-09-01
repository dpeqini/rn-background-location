import Foundation
import CoreLocation
import CoreMotion
import UIKit
import React

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

  override init(){ super.init(); manager.delegate=self; loadConfig(); observeAppState() }

  // Core Location must be driven from the main thread: the bridge calls these methods on the
  // module queue, which has no run loop, so timers never fire and start/stop is racy there.
  private func onMain(_ work:@escaping()->Void){ if Thread.isMainThread {work()} else {DispatchQueue.main.async(execute:work)} }

  func loadConfig(){ config=UserDefaults.standard.dictionary(forKey:"rn_bg_location_config") ?? [:]; tracking=UserDefaults.standard.bool(forKey:"rn_bg_location_tracking") }
  // Reconfiguring while tracking has to swap the primitive too, not just the accuracy: the modes
  // map onto different Core Location services, and applyMode alone cannot move between them.
  func configure(_ c:[String:Any]){ config=c;UserDefaults.standard.set(c,forKey:"rn_bg_location_config");onMain{[weak self] in guard let self else{return};self.applyMode();if self.tracking{self.stopPrimitives();self.startLocationPrimitive()}} }
  private func stopPrimitives(){manager.stopUpdatingLocation();manager.stopMonitoringSignificantLocationChanges();manager.stopMonitoringVisits();safetyNet=false}
  func requestAlways(){ onMain{[weak self] in self?.manager.requestAlwaysAuthorization()} }
  func start(){ tracking=true;UserDefaults.standard.set(true,forKey:"rn_bg_location_tracking");onMain{[weak self] in guard let self else{return};self.applyMode();self.startLocationPrimitive();self.startMotion();self.startHeartbeat()} }
  // Runs on every launch, including the background relaunches iOS grants after the process dies.
  func bootstrap(){
    loadConfig()
    guard tracking else{return}
    // stopOnTerminate: the process died and the host asked not to resume. Default is to resume.
    if config["stopOnTerminate"] as? Bool ?? false {tracking=false;UserDefaults.standard.set(false,forKey:"rn_bg_location_tracking");return}
    onMain{[weak self] in guard let self else{return};self.applyMode();self.startLocationPrimitive();self.startMotion();self.startHeartbeat();self.sync{_,_,_ in}}
  }
  func stop(){ tracking=false;UserDefaults.standard.set(false,forKey:"rn_bg_location_tracking");onMain{[weak self] in guard let self else{return};self.stopPrimitives();self.motionManager.stopActivityUpdates();self.heartbeatTimer?.invalidate();self.heartbeatTimer=nil;self.systemPaused=false;self.safetyNet=false} }

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
      guard let self,self.tracking else{return};self.applyMode();if !self.systemPaused{self.startLocationPrimitive()};self.sync{_,_,_ in}
    }
  }
  private func startMotion(){guard config["motionDetection"] as? Bool ?? true,CMMotionActivityManager.isActivityAvailable() else{return};motionManager.stopActivityUpdates();motionManager.startActivityUpdates(to:OperationQueue()){[weak self]a in guard let self,let a else{return};let n=a.automotive ? "automotive":a.cycling ? "cycling":a.running ? "running":a.walking ? "walking":a.stationary ? "stationary":"unknown";guard n != self.motion else{return};self.motion=n;self.onMain{self.applyMode();self.emit?("backgroundLocation:motion",["motion":n,"timestamp":Date().timeIntervalSince1970*1000])}}}
  private func startHeartbeat(){onMain{[weak self] in guard let self else{return};self.heartbeatTimer?.invalidate();let sec=max(self.config["heartbeatIntervalSeconds"] as? Double ?? 60,15);let t=Timer(timeInterval:sec,repeats:true){[weak self]_ in guard let self,self.tracking else{return};self.emit?("backgroundLocation:heartbeat",["timestamp":Date().timeIntervalSince1970*1000,"queueSize":self.queue.count(),"motion":self.motion])};RunLoop.main.add(t,forMode:.common);self.heartbeatTimer=t}}

  func locationManager(_ manager:CLLocationManager,didUpdateLocations ls:[CLLocation]){
    if systemPaused&&tracking{onMain{[weak self] in self?.startLocationPrimitive()}}
    ls.forEach{store($0,primarySource)}
    guard let l=ls.last else{return}
    lastFix=l
    let r=record(l,primarySource);let pending=oneShots;oneShots=[];pending.forEach{$0.settle(.success(r))}
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
  func locationManager(_ manager:CLLocationManager,didVisit v:CLVisit){store(CLLocation(latitude:v.coordinate.latitude,longitude:v.coordinate.longitude),"visit")}
  func locationManager(_ manager:CLLocationManager,didEnterRegion r:CLRegion){handleRegion(r,"enter")}
  func locationManager(_ manager:CLLocationManager,didExitRegion r:CLRegion){handleRegion(r,"exit")}
  // A region event can wake a process where JS is not running, so emit is a no-op and the fix
  // would be lost. Persist it to the queue as well.
  private func handleRegion(_ r:CLRegion,_ transition:String){
    emit?("backgroundLocation:geofence",["id":r.identifier,"transition":transition,"timestamp":Date().timeIntervalSince1970*1000])
    if let c=r as? CLCircularRegion {store(CLLocation(latitude:c.center.latitude,longitude:c.center.longitude),"geofence")}
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
  private func store(_ l:CLLocation,_ source:String){let r=record(l,source);queue.enqueue(r,max:config["maxQueueSize"] as? Int ?? 10000);emit?("backgroundLocation:location",r);let th=(config["http"] as? [String:Any])?["syncThreshold"] as? Int ?? 10;if queue.count()>=th{sync{_,_,_ in}}}

  func addGeofence(_ g:[String:Any]) throws {
    // iOS caps monitored regions at 20 per app and silently drops the rest, so a geofence added
    // past the cap would simply never fire. Fail loudly instead.
    guard manager.monitoredRegions.count < 20 || manager.monitoredRegions.contains(where:{$0.identifier==(g["id"] as? String ?? "")}) else{
      throw NSError(domain:"BackgroundLocation",code:3,userInfo:[NSLocalizedDescriptionKey:"iOS allows at most 20 monitored regions; remove one before adding another"])
    }
    guard let id=g["id"] as? String,let lat=g["latitude"] as? Double,let lon=g["longitude"] as? Double,let radius=g["radius"] as? Double else{throw NSError(domain:"BackgroundLocation",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid geofence"])};let r=CLCircularRegion(center:.init(latitude:lat,longitude:lon),radius:min(radius,manager.maximumRegionMonitoringDistance),identifier:id);r.notifyOnEntry=g["notifyOnEntry"] as? Bool ?? true;r.notifyOnExit=g["notifyOnExit"] as? Bool ?? true;manager.startMonitoring(for:r)}
  func removeGeofence(_ id:String){if let r=manager.monitoredRegions.first(where:{$0.identifier==id}){manager.stopMonitoring(for:r)}}
  func removeAllGeofences(){manager.monitoredRegions.forEach{manager.stopMonitoring(for:$0)}}

  func sync(completion:@escaping(Int,Int,Error?)->Void){
    // Backoff state is persisted, because the process this upload started in is often not the
    // process it finishes in, and a doomed request per location fix is what drains the battery.
    guard !SyncBackoff.isBlocked else{completion(0,queue.count(),nil);return}
    guard let h=config["http"] as? [String:Any],let us=h["url"] as? String,let url=URL(string:us) else{completion(0,queue.count(),nil);return}
    if h["single"] as? Bool ?? false { syncSingle(h,url,completion) } else { syncBatch(h,url,completion) }
  }

  private func syncBatch(_ h:[String:Any],_ url:URL,_ completion:@escaping(Int,Int,Error?)->Void){
    let batch=queue.peek(limit:h["batchSize"] as? Int ?? 50);guard !batch.isEmpty else{completion(0,0,nil);return}
    let root=h["rootProperty"] as? String ?? "locations"
    let payload:Any = root=="." ? batch.map{$0.payload} : [root:batch.map{$0.payload}]
    guard let body=try? JSONSerialization.data(withJSONObject:payload) else{completion(0,queue.count(),nil);return}
    upload(h,url,body,batch.last!.id){[weak self]outcome,error in guard let self else{return}
      let sent = outcome == .delivered ? batch.count : 0
      self.emit?("backgroundLocation:sync",["sent":sent,"remaining":self.queue.count()])
      if outcome == .dropped {self.emitDrop(batch.count,error)}
      completion(sent,self.queue.count(),outcome == .retry ? error : nil)
    }
  }

  private func syncSingle(_ h:[String:Any],_ url:URL,_ completion:@escaping(Int,Int,Error?)->Void){
    guard let row=queue.peek(limit:1).first else{completion(0,0,nil);return}
    guard let body=try? JSONSerialization.data(withJSONObject:buildSingleBody(row.payload,h)) else{completion(0,queue.count(),nil);return}
    upload(h,url,body,row.id){[weak self]outcome,error in guard let self else{return}
      let sent = outcome == .delivered ? 1 : 0
      self.emit?("backgroundLocation:sync",["sent":sent,"remaining":self.queue.count()])
      if outcome == .dropped {self.emitDrop(1,error)}
      completion(sent,self.queue.count(),outcome == .retry ? error : nil)
      // Only a delivery chains into the next record. A drop also frees the queue, but chaining on it
      // would burn through thousands of records in a burst against an endpoint rejecting everything.
      if outcome == .delivered, self.tracking, self.queue.count()>0 { self.syncSingle(h,url){_,_,_ in} }
    }
  }

  private func emitDrop(_ count:Int,_ error:Error?){
    emit?("backgroundLocation:error",["code":"syncDropped","message":"Discarded \(count) location(s) the server rejected permanently: \(error?.localizedDescription ?? "client error")"])
  }

  private func upload(_ h:[String:Any],_ url:URL,_ body:Data,_ receipt:Int64,_ completion:@escaping(SyncOutcome,Error?)->Void){
    do{
      let file=FileManager.default.temporaryDirectory.appendingPathComponent("rn-bg-\(UUID().uuidString).json")
      try body.write(to:file)
      var req=URLRequest(url:url);req.httpMethod=h["method"] as? String ?? "POST";req.setValue("application/json",forHTTPHeaderField:"Content-Type")
      req.timeoutInterval=(h["timeoutMs"] as? Double ?? 15000)/1000
      (h["headers"] as? [String:String])?.forEach{req.setValue($1,forHTTPHeaderField:$0)}
      BackgroundUploader.shared.upload(request:req,file:file,receipt:receipt,maxRetries:h["maxRetries"] as? Int ?? 10,completion:completion)
    }catch{SyncBackoff.fail();completion(.retry,error)}
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

enum SyncOutcome { case delivered, dropped, retry }

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

final class BackgroundUploader:NSObject,URLSessionTaskDelegate,URLSessionDelegate{
  static let shared=BackgroundUploader()
  var backgroundCompletion:(()->Void)?
  private var completions:[Int:(SyncOutcome,Error?)->Void]=[:]
  private let lock=NSLock()
  private lazy var session:URLSession={let c=URLSessionConfiguration.background(withIdentifier:"com.greinchville.rn-background-location.http");c.sessionSendsLaunchEvents=true;c.isDiscretionary=false;return URLSession(configuration:c,delegate:self,delegateQueue:nil)}()

  func upload(request:URLRequest,file:URL,receipt:Int64,maxRetries:Int,completion:@escaping(SyncOutcome,Error?)->Void){
    let t=session.uploadTask(with:request,fromFile:file)
    // A background upload routinely finishes in a later process, where no completion block exists.
    // Carrying everything the acknowledgement needs on the task is what makes it survive that.
    t.taskDescription="\(receipt)|\(maxRetries)|\(file.path)"
    lock.lock();completions[t.taskIdentifier]=completion;lock.unlock()
    t.resume()
  }

  func urlSession(_ s:URLSession,task:URLSessionTask,didCompleteWithError e:Error?){
    let code=(task.response as? HTTPURLResponse)?.statusCode ?? 0
    let parts=(task.taskDescription ?? "").split(separator:"|",maxSplits:2,omittingEmptySubsequences:false)
    let receipt:Int64? = parts.count==3 ? Int64(parts[0]) : nil
    let maxRetries:Int = parts.count==3 ? (Int(parts[1]) ?? 10) : 10
    let outcome=Self.classify(code:code,error:e,failures:SyncBackoff.failures,maxRetries:maxRetries)
    switch outcome{
    case .delivered,.dropped: if let receipt {IOSLocationQueue.shared.deleteThrough(receipt)};SyncBackoff.reset()
    case .retry: SyncBackoff.fail()
    }
    if parts.count==3 {try? FileManager.default.removeItem(atPath:String(parts[2]))}
    lock.lock();let cb=completions.removeValue(forKey:task.taskIdentifier);lock.unlock()
    cb?(outcome,e)
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
}

@objc(NativeBackgroundLocation)
final class NativeBackgroundLocation:RCTEventEmitter{
  private let engine=BackgroundLocationEngine.shared
  // Restoration belongs in the AppDelegate via NativeBackgroundLocationBootstrap, which runs before
  // JS. This is the fallback for hosts that skipped it: later, but better than never resuming.
  override init(){super.init();engine.emit={[weak self]n,b in self?.sendEvent(withName:n,body:b)};engine.bootstrap()}
  @objc override static func requiresMainQueueSetup()->Bool{true}
  override func supportedEvents()->[String]! { ["backgroundLocation:location","backgroundLocation:motion","backgroundLocation:geofence","backgroundLocation:heartbeat","backgroundLocation:sync","backgroundLocation:error"] }
  @objc(configure:resolver:rejecter:) func configure(_ c:NSDictionary,resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){engine.configure(c as? [String:Any] ?? [:]);resolve(engine.state())}
  @objc(start:rejecter:) func start(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){engine.start();resolve(nil)}
  @objc(stop:rejecter:) func stop(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){engine.stop();resolve(nil)}
  @objc(getState:rejecter:) func getState(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){resolve(engine.state())}
  @objc(requestPermissions:rejecter:) func requestPermissions(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){engine.requestAlways();resolve("requested")}
  @objc(getCurrentLocation:resolver:rejecter:) func getCurrentLocation(_ o:NSDictionary,resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){engine.current(timeoutMs:(o["timeoutMs"] as? Double) ?? 15000){r in switch r{case .success(let l):resolve(l);case .failure(let e):reject("location_failed",e.localizedDescription,e)}}}
  @objc(getQueuedLocations:resolver:rejecter:) func getQueuedLocations(_ limit:NSNumber,resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){resolve(engine.queued(limit.intValue))}
  @objc(clearQueue:rejecter:) func clearQueue(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){engine.clear();resolve(nil)}
  @objc(sync:rejecter:) func sync(_ resolve:@escaping RCTPromiseResolveBlock,reject:@escaping RCTPromiseRejectBlock){engine.sync{sent,remaining,e in if let e{reject("sync_failed",e.localizedDescription,e)}else{resolve(["sent":sent,"remaining":remaining])}}}
  @objc(addGeofence:resolver:rejecter:) func addGeofence(_ g:NSDictionary,resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){do{try engine.addGeofence(g as? [String:Any] ?? [:]);resolve(nil)}catch{reject("geofence",error.localizedDescription,error)}}
  @objc(removeGeofence:resolver:rejecter:) func removeGeofence(_ id:String,resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){engine.removeGeofence(id);resolve(nil)}
  @objc(removeAllGeofences:rejecter:) func removeAllGeofences(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock){engine.removeAllGeofences();resolve(nil)}
}
