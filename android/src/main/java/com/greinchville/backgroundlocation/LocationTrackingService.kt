package com.greinchville.backgroundlocation

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.work.*
import com.facebook.react.bridge.Arguments
import com.google.android.gms.location.*
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

class LocationTrackingService: Service() {
  private lateinit var fused: FusedLocationProviderClient
  private var callback: LocationCallback? = null
  private val handler = Handler(Looper.getMainLooper())
  private var lastHeartbeat = 0L

  override fun onCreate() { super.onCreate(); fused = LocationServices.getFusedLocationProviderClient(this); createChannel() }
  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int { ConfigStore.setTracking(this,true); startForegroundNow(); subscribe(); return START_STICKY }
  override fun onDestroy() { callback?.let { fused.removeLocationUpdates(it) }; handler.removeCallbacksAndMessages(null); super.onDestroy() }
  override fun onBind(intent: Intent?) = null

  private fun startForegroundNow() {
    val cfg=ConfigStore.json(this); val a=cfg.optJSONObject("android"); val channel=a?.optString("notificationChannelId","background-location") ?: "background-location"
    val n=NotificationCompat.Builder(this,channel).setSmallIcon(applicationInfo.icon).setContentTitle(a?.optString("notificationTitle","Location tracking active")).setContentText(a?.optString("notificationText","Tracking location in the background")).setOngoing(true).build()
    if (Build.VERSION.SDK_INT>=34) startForeground(a?.optInt("notificationId",9271)?:9271,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION) else startForeground(a?.optInt("notificationId",9271)?:9271,n)
  }
  private fun createChannel(){ if(Build.VERSION.SDK_INT>=26){ val id=ConfigStore.json(this).optJSONObject("android")?.optString("notificationChannelId","background-location")?:"background-location"; (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(NotificationChannel(id,"Background location",NotificationManager.IMPORTANCE_LOW)) } }

  private fun subscribe(){
    val cfg=ConfigStore.json(this); val motion=ConfigStore.motion(this); val mode=cfg.optString("mode","adaptive")
    val p = when { mode=="navigation" || motion=="automotive" -> Priority.PRIORITY_HIGH_ACCURACY; mode=="lowPower" || motion=="stationary" -> Priority.PRIORITY_LOW_POWER; else -> Priority.PRIORITY_BALANCED_POWER_ACCURACY }
    val interval = when { motion=="automotive" -> 5000L; motion=="walking" -> 10000L; motion=="stationary" -> 120000L; else -> cfg.optLong("intervalMs",30000) }
    val minDist = when { motion=="automotive" -> 10f; motion=="walking" -> cfg.optDouble("motionDistanceMeters",10.0).toFloat(); motion=="stationary" -> 50f; else -> cfg.optDouble("distanceFilterMeters",25.0).toFloat() }
    val req=LocationRequest.Builder(p,interval).setMinUpdateIntervalMillis(cfg.optLong("fastestIntervalMs",5000)).setMinUpdateDistanceMeters(minDist).setMaxUpdateDelayMillis(cfg.optLong("maxBatchDelayMs",60000)).build()
    callback?.let{fused.removeLocationUpdates(it)}
    callback=object:LocationCallback(){ override fun onLocationResult(r:LocationResult){ r.locations.forEach(::handleLocation) } }
    try { fused.requestLocationUpdates(req, callback!!, Looper.getMainLooper()) } catch(e:SecurityException){ emitError("permission",e.message?:"Location permission denied") }
  }

  private fun handleLocation(l:Location){
    val id=UUID.randomUUID().toString(); val o=JSONObject().put("id",id).put("latitude",l.latitude).put("longitude",l.longitude).put("accuracy",l.accuracy).put("altitude",l.altitude).put("heading",l.bearing).put("speed",l.speed).put("timestamp",l.time).put("mocked", if(Build.VERSION.SDK_INT>=31) l.isMock else l.isFromMockProvider).put("motion",ConfigStore.motion(this)).put("source","fused")
    val cfg=ConfigStore.json(this); LocationQueue(this).enqueue(o,cfg.optInt("maxQueueSize",10000)); emitJson("backgroundLocation:location",o)
    val q=LocationQueue(this); val threshold=cfg.optJSONObject("http")?.optInt("syncThreshold",10)?:10; if(q.count()>=threshold) scheduleSync()
    val hb=cfg.optInt("heartbeatIntervalSeconds",60)*1000L; if(System.currentTimeMillis()-lastHeartbeat>=hb){ lastHeartbeat=System.currentTimeMillis(); emitHeartbeat(q.count()) }
  }
  private fun scheduleSync(){ val constraints=Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(); val req=OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(constraints).setBackoffCriteria(BackoffPolicy.EXPONENTIAL,30,TimeUnit.SECONDS).build(); WorkManager.getInstance(this).enqueueUniqueWork("rn-bg-location-sync",ExistingWorkPolicy.KEEP,req) }
  private fun emitHeartbeat(size:Int){ val m=Arguments.createMap();m.putDouble("timestamp",System.currentTimeMillis().toDouble());m.putInt("queueSize",size);m.putString("motion",ConfigStore.motion(this));EventBus.emit("backgroundLocation:heartbeat",m) }
  private fun emitJson(name:String,o:JSONObject){ val m=Arguments.createMap(); o.keys().forEach{ k-> when(val v=o.get(k)){ is String->m.putString(k,v); is Double->m.putDouble(k,v); is Int->m.putInt(k,v); is Long->m.putDouble(k,v.toDouble()); is Boolean->m.putBoolean(k,v) } }; EventBus.emit(name,m) }
  private fun emitError(code:String,message:String){ val m=Arguments.createMap();m.putString("code",code);m.putString("message",message);EventBus.emit("backgroundLocation:error",m) }
}
