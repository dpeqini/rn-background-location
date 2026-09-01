package com.greinchville.backgroundlocation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.facebook.react.bridge.Arguments
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import org.json.JSONObject
import java.util.UUID

class GeofenceReceiver: BroadcastReceiver() {
  override fun onReceive(c: Context, i: Intent) {
    val e = GeofencingEvent.fromIntent(i) ?: return
    if (e.hasError()) return
    val t = when (e.geofenceTransition) {
      Geofence.GEOFENCE_TRANSITION_ENTER -> "enter"
      Geofence.GEOFENCE_TRANSITION_EXIT -> "exit"
      Geofence.GEOFENCE_TRANSITION_DWELL -> "dwell"
      else -> return
    }
    // A geofence commonly wakes a process where React Native is not running, so EventBus.emit is a
    // no-op and the event would be lost entirely. Persisting the fix is what makes it survive.
    e.triggeringLocation?.let { l ->
      val o = JSONObject().put("id", UUID.randomUUID().toString()).put("latitude", l.latitude)
        .put("longitude", l.longitude).put("accuracy", l.accuracy).put("timestamp", l.time)
        .put("motion", ConfigStore.motion(c)).put("source", "geofence")
      LocationQueue.get(c).enqueue(o, ConfigStore.json(c).optInt("maxQueueSize", 10000))
    }
    e.triggeringGeofences?.forEach { g ->
      val m = Arguments.createMap()
      m.putString("id", g.requestId); m.putString("transition", t)
      m.putDouble("timestamp", System.currentTimeMillis().toDouble())
      EventBus.emit("backgroundLocation:geofence", m)
    }
  }
}
