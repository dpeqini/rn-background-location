package com.greinchville.backgroundlocation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.facebook.react.bridge.Arguments
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
class GeofenceReceiver:BroadcastReceiver(){override fun onReceive(c:Context,i:Intent){val e=GeofencingEvent.fromIntent(i)?:return;if(e.hasError())return; val t=when(e.geofenceTransition){Geofence.GEOFENCE_TRANSITION_ENTER->"enter";Geofence.GEOFENCE_TRANSITION_EXIT->"exit";Geofence.GEOFENCE_TRANSITION_DWELL->"dwell";else->return};e.triggeringGeofences?.forEach{g->val m=Arguments.createMap();m.putString("id",g.requestId);m.putString("transition",t);m.putDouble("timestamp",System.currentTimeMillis().toDouble());EventBus.emit("backgroundLocation:geofence",m)}}}
