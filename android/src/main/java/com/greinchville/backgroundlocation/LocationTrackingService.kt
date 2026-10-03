package com.greinchville.backgroundlocation

import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.location.Location
import android.os.*
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import com.facebook.react.bridge.Arguments
import com.google.android.gms.location.*
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

class LocationTrackingService: Service() {
  companion object { const val ACTION_MOTION_CHANGED = "com.greinchville.backgroundlocation.MOTION_CHANGED" }

  private lateinit var fused: FusedLocationProviderClient
  private var callback: LocationCallback? = null
  private val handler = Handler(Looper.getMainLooper())
  // The speed band elasticity last applied; see Elasticity.
  private var speedSteps = 0
  // Motion changes used to be applied by restarting the service, which is a background
  // foreground-service start on Android 12+ and throws. A running service re-subscribes in place.
  private val motionReceiver = object: BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) { subscribe() }
  }

  override fun onCreate() {
    super.onCreate(); fused = LocationServices.getFusedLocationProviderClient(this); createChannel()
    ContextCompat.registerReceiver(this, motionReceiver, IntentFilter(ACTION_MOTION_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
  }
  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    ConfigStore.setTracking(this,true); speedSteps=0; startForegroundNow(); subscribe(); startHeartbeat()
    return if (stopOnTerminate()) START_NOT_STICKY else START_STICKY
  }
  // Swipe-away from recents. START_STICKY would restart the service regardless of config, so the
  // host's choice has to be honoured explicitly here.
  override fun onTaskRemoved(rootIntent: Intent?) {
    if (stopOnTerminate()) { ConfigStore.setTracking(this,false); stopSelf() }
    super.onTaskRemoved(rootIntent)
  }
  private fun stopOnTerminate() = ConfigStore.json(this).optBoolean("stopOnTerminate", false)
  override fun onDestroy() { callback?.let { fused.removeLocationUpdates(it) }; handler.removeCallbacksAndMessages(null); try { unregisterReceiver(motionReceiver) } catch (_: IllegalArgumentException) {}; super.onDestroy() }
  override fun onBind(intent: Intent?) = null

  private fun startForegroundNow() {
    val cfg=ConfigStore.json(this); val a=cfg.optJSONObject("android"); val channel=a?.optString("notificationChannelId","background-location") ?: "background-location"
    val n=NotificationCompat.Builder(this,channel).setSmallIcon(applicationInfo.icon).setContentTitle(a?.optString("notificationTitle","Location tracking active")).setContentText(a?.optString("notificationText","Tracking location in the background")).setOngoing(true).build()
    if (Build.VERSION.SDK_INT>=34) startForeground(a?.optInt("notificationId",9271)?:9271,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION) else startForeground(a?.optInt("notificationId",9271)?:9271,n)
  }
  private fun createChannel(){ if(Build.VERSION.SDK_INT>=26){ val id=ConfigStore.json(this).optJSONObject("android")?.optString("notificationChannelId","background-location")?:"background-location"; (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(NotificationChannel(id,"Background location",NotificationManager.IMPORTANCE_LOW)) } }

  private fun subscribe(){
    val cfg=ConfigStore.json(this)
    val profile = profile(cfg.optString("mode","adaptive"), ConfigStore.motion(this))
    val p = when (profile) { "navigation", "active" -> Priority.PRIORITY_HIGH_ACCURACY; "balanced" -> Priority.PRIORITY_BALANCED_POWER_ACCURACY; else -> Priority.PRIORITY_LOW_POWER }
    val interval = when (profile) { "navigation" -> 5000L; "active" -> 10000L; "balanced" -> cfg.optLong("intervalMs",30000); else -> 120000L }
    val base = when (profile) { "navigation" -> maxOf(cfg.optDouble("motionDistanceMeters",10.0),10.0); "active" -> cfg.optDouble("motionDistanceMeters",10.0); "balanced" -> cfg.optDouble("distanceFilterMeters",50.0); else -> 100.0 }
    val minDist = Elasticity.filter(base, speedSteps, cfg).toFloat()
    val req=LocationRequest.Builder(p,interval).setMinUpdateIntervalMillis(cfg.optLong("fastestIntervalMs",5000)).setMinUpdateDistanceMeters(minDist).setMaxUpdateDelayMillis(cfg.optLong("maxBatchDelayMs",60000)).build()
    callback?.let{fused.removeLocationUpdates(it)}
    callback=object:LocationCallback(){ override fun onLocationResult(r:LocationResult){ r.locations.forEach(::handleLocation); r.lastLocation?.let(::updateElasticity) } }
    try { fused.requestLocationUpdates(req, callback!!, Looper.getMainLooper()) } catch(e:SecurityException){ emitError("permission",e.message?:"Location permission denied") }
  }

  // A running request's minimum distance cannot be changed, so a new speed band means re-subscribing. The
  // bands and their hysteresis keep that to once per band change rather than once per fix.
  private fun updateElasticity(l:Location){
    if (!l.hasSpeed()) return
    val s = Elasticity.steps(l.speed.toDouble(), speedSteps)
    if (s == speedSteps) return
    speedSteps = s; subscribe()
  }

  // Mirrors the iOS profile(): only `adaptive` follows detected motion, an explicit mode stays put.
  // `significant` and `visits` have no Play Services equivalent, so they fall to the low-power,
  // long-interval request rather than silently behaving like `balanced`.
  private fun profile(mode:String, motion:String):String =
    if (mode != "adaptive") mode else when (motion) {
      "automotive" -> "navigation"
      "walking", "running", "cycling" -> "active"
      else -> "balanced"
    }

  private fun handleLocation(l:Location){
    val id=UUID.randomUUID().toString(); val o=JSONObject().put("id",id).put("latitude",l.latitude).put("longitude",l.longitude).put("accuracy",l.accuracy).put("altitude",l.altitude).put("heading",l.bearing).put("speed",l.speed).put("timestamp",l.time).put("mocked", if(Build.VERSION.SDK_INT>=31) l.isMock else l.isFromMockProvider).put("motion",ConfigStore.motion(this)).put("source","fused")
    val cfg=ConfigStore.json(this); val q=LocationQueue.get(this); OverflowReporter.add(q.enqueue(o,cfg.optInt("maxQueueSize",10000))); emitJson("backgroundLocation:location",o)
    val threshold=cfg.optJSONObject("http")?.optInt("syncThreshold",10)?:10; if(q.count()>=threshold) scheduleSync()
  }
  // Was driven off incoming fixes, so a stationary user got no heartbeat at all - the opposite of
  // what it is for, and of the iOS timer.
  private val heartbeat = object: Runnable {
    override fun run() {
      emitHeartbeat(LocationQueue.get(this@LocationTrackingService).count())
      handler.postDelayed(this, heartbeatMs())
    }
  }
  private fun heartbeatMs() = (ConfigStore.json(this).optInt("heartbeatIntervalSeconds",60)*1000L).coerceAtLeast(15000L)
  private fun startHeartbeat(){ handler.removeCallbacks(heartbeat); handler.postDelayed(heartbeat, heartbeatMs()) }

  // KEEP ignores new requests while a retry is pending, so the backoff bounds how long uploads can stall.
  // Exponential backoff reached hours within a few failures; linear caps at 30 s x maxRetries (5 min by
  // default), the same ceiling as the iOS SyncBackoff.
  private fun scheduleSync(){ val constraints=Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(); val req=OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(constraints).setBackoffCriteria(BackoffPolicy.LINEAR,30,TimeUnit.SECONDS).build(); WorkManager.getInstance(this).enqueueUniqueWork("rn-bg-location-sync",ExistingWorkPolicy.KEEP,req) }
  private fun emitHeartbeat(size:Int){ val m=Arguments.createMap();m.putDouble("timestamp",System.currentTimeMillis().toDouble());m.putInt("queueSize",size);m.putString("motion",ConfigStore.motion(this));EventBus.emit("backgroundLocation:heartbeat",m) }
  private fun emitJson(name:String,o:JSONObject){ val m=Arguments.createMap(); o.keys().forEach{ k-> when(val v=o.get(k)){ is String->m.putString(k,v); is Double->m.putDouble(k,v); is Int->m.putInt(k,v); is Long->m.putDouble(k,v.toDouble()); is Boolean->m.putBoolean(k,v) } }; EventBus.emit(name,m) }
  private fun emitError(code:String,message:String){ val m=Arguments.createMap();m.putString("code",code);m.putString("message",message);EventBus.emit("backgroundLocation:error",m) }
}

// Widens the distance filter with speed, as Transistorsoft's elasticity does: at speed the provider delivers
// a fix about every second whatever the filter, so a fixed small filter means one upload per second.
// Mirrors Elasticity in NativeBackgroundLocation.swift; keep the two in step.
internal object Elasticity {
  // One band per 5 m/s (18 km/h). Up as soon as speed crosses a threshold, down only 1 m/s below it, so a
  // speed hovering on a boundary does not flip the filter on every fix.
  fun steps(speed: Double, current: Int): Int {
    if (speed < 0) return current
    val raw = minOf((speed / 5).toInt(), 20)
    if (raw < current && speed > current * 5.0 - 1) return current
    return raw
  }
  // base x (1 + multiplier x steps), capped at maxDistanceFilterMeters (never below the base itself).
  fun filter(base: Double, steps: Int, cfg: JSONObject): Double {
    if (!cfg.optBoolean("elasticity", true)) return base
    val multiplier = cfg.optDouble("elasticityMultiplier", 1.0)
    val cap = maxOf(cfg.optDouble("maxDistanceFilterMeters", 100.0), base)
    return minOf(base * (1 + multiplier * steps), cap)
  }
}
