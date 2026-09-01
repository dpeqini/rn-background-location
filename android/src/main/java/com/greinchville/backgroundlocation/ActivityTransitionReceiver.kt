package com.greinchville.backgroundlocation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.facebook.react.bridge.Arguments
import com.google.android.gms.location.*
class ActivityTransitionReceiver: BroadcastReceiver(){ override fun onReceive(c:Context,i:Intent){ if(!ActivityTransitionResult.hasResult(i)) return; val r=ActivityTransitionResult.extractResult(i)?:return; val e=r.transitionEvents.lastOrNull()?:return; val motion=when(e.activityType){DetectedActivity.STILL->"stationary";DetectedActivity.WALKING,DetectedActivity.ON_FOOT->"walking";DetectedActivity.RUNNING->"running";DetectedActivity.ON_BICYCLE->"cycling";DetectedActivity.IN_VEHICLE->"automotive";else->"unknown"}; ConfigStore.setMotion(c,motion); val m=Arguments.createMap();m.putString("motion",motion);m.putDouble("timestamp",System.currentTimeMillis().toDouble());EventBus.emit("backgroundLocation:motion",m); if(ConfigStore.tracking(c)) { c.startForegroundService(Intent(c,LocationTrackingService::class.java)) } } }
