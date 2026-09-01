package com.greinchville.backgroundlocation

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import com.facebook.react.bridge.*
import com.google.android.gms.location.*
import org.json.JSONObject

class NativeBackgroundLocationModule(private val ctx:ReactApplicationContext): ReactContextBaseJavaModule(ctx){
  init { EventBus.reactContext=ctx }
  override fun getName()="NativeBackgroundLocation"
  @ReactMethod fun addListener(name:String){}; @ReactMethod fun removeListeners(count:Double){}
  @ReactMethod fun configure(config:ReadableMap,p:Promise){ ConfigStore.save(ctx,JSONObject(config.toHashMap()).toString()); p.resolve(stateMap()) }
  @ReactMethod fun start(p:Promise){ try{ val i=Intent(ctx,LocationTrackingService::class.java); if(Build.VERSION.SDK_INT>=26)ctx.startForegroundService(i) else ctx.startService(i); registerMotion(); p.resolve(null) }catch(e:Exception){p.reject("start_failed",e)} }
  @ReactMethod fun stop(p:Promise){ ConfigStore.setTracking(ctx,false);ctx.stopService(Intent(ctx,LocationTrackingService::class.java));unregisterMotion();p.resolve(null) }
  @ReactMethod fun getState(p:Promise)=p.resolve(stateMap())
  @ReactMethod fun requestPermissions(p:Promise){ p.resolve("Use the JS requestPermissions helper; iOS prompts natively.") }
  @ReactMethod fun getQueuedLocations(limit:Double,p:Promise){val a=Arguments.createArray();LocationQueue(ctx).peek(limit.toInt()).forEach{(_,s)->a.pushMap(jsonMap(JSONObject(s)))};p.resolve(a)}
  @ReactMethod fun clearQueue(p:Promise){LocationQueue(ctx).clear();p.resolve(null)}
  @ReactMethod fun sync(p:Promise){try{val(r,n)=NativeHttpSync.sync(ctx);val m=Arguments.createMap();m.putInt("sent",r);m.putInt("remaining",n);p.resolve(m)}catch(e:Exception){p.reject("sync_failed",e)}}
  @ReactMethod fun getCurrentLocation(options:ReadableMap,p:Promise){ try{ LocationServices.getFusedLocationProviderClient(ctx).getCurrentLocation(if(options.hasKey("highAccuracy")&&options.getBoolean("highAccuracy"))Priority.PRIORITY_HIGH_ACCURACY else Priority.PRIORITY_BALANCED_POWER_ACCURACY,null).addOnSuccessListener{l->if(l==null)p.reject("no_location","No location") else {val o=JSONObject().put("id",java.util.UUID.randomUUID().toString()).put("latitude",l.latitude).put("longitude",l.longitude).put("accuracy",l.accuracy).put("timestamp",l.time).put("source","fused");p.resolve(jsonMap(o))}}.addOnFailureListener{p.reject("location_failed",it)} }catch(e:SecurityException){p.reject("permission",e)} }
  @ReactMethod fun addGeofence(g:ReadableMap,p:Promise){try{val b=Geofence.Builder().setRequestId(g.getString("id")!!).setCircularRegion(g.getDouble("latitude"),g.getDouble("longitude"),g.getDouble("radius").toFloat()).setExpirationDuration(Geofence.NEVER_EXPIRE);var trans=0;if(!g.hasKey("notifyOnEntry")||g.getBoolean("notifyOnEntry"))trans=trans or Geofence.GEOFENCE_TRANSITION_ENTER;if(!g.hasKey("notifyOnExit")||g.getBoolean("notifyOnExit"))trans=trans or Geofence.GEOFENCE_TRANSITION_EXIT;b.setTransitionTypes(trans);val req=GeofencingRequest.Builder().setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER).addGeofence(b.build()).build();LocationServices.getGeofencingClient(ctx).addGeofences(req,geofencePi()).addOnSuccessListener{p.resolve(null)}.addOnFailureListener{p.reject("geofence",it)}}catch(e:SecurityException){p.reject("permission",e)}}
  @ReactMethod fun removeGeofence(id:String,p:Promise){LocationServices.getGeofencingClient(ctx).removeGeofences(listOf(id)).addOnCompleteListener{p.resolve(null)}}
  @ReactMethod fun removeAllGeofences(p:Promise){LocationServices.getGeofencingClient(ctx).removeGeofences(geofencePi()).addOnCompleteListener{p.resolve(null)}}
  private fun geofencePi()=PendingIntent.getBroadcast(ctx,1001,Intent(ctx,GeofenceReceiver::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
  private fun motionPi()=PendingIntent.getBroadcast(ctx,1002,Intent(ctx,ActivityTransitionReceiver::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
  private fun registerMotion(){if(!ConfigStore.json(ctx).optBoolean("motionDetection",true))return;val types=listOf(DetectedActivity.STILL,DetectedActivity.WALKING,DetectedActivity.RUNNING,DetectedActivity.ON_BICYCLE,DetectedActivity.IN_VEHICLE);val transitions=types.flatMap{t->listOf(ActivityTransition.Builder().setActivityType(t).setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER).build())};try{ActivityRecognition.getClient(ctx).requestActivityTransitionUpdates(ActivityTransitionRequest(transitions),motionPi())}catch(_:SecurityException){}}
  private fun unregisterMotion(){ActivityRecognition.getClient(ctx).removeActivityTransitionUpdates(motionPi())}
  private fun stateMap():WritableMap{val m=Arguments.createMap();m.putBoolean("enabled",true);m.putString("authorization","platform");m.putBoolean("tracking",ConfigStore.tracking(ctx));m.putString("mode",ConfigStore.json(ctx).optString("mode","adaptive"));m.putInt("queueSize",LocationQueue(ctx).count());m.putString("motion",ConfigStore.motion(ctx));return m}
  private fun jsonMap(o:JSONObject):WritableMap{val m=Arguments.createMap();o.keys().forEach{k->when(val v=o.get(k)){is String->m.putString(k,v);is Double->m.putDouble(k,v);is Int->m.putInt(k,v);is Long->m.putDouble(k,v.toDouble());is Boolean->m.putBoolean(k,v)}};return m}
}
