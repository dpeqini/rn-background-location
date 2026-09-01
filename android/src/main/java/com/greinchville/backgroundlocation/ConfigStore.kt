package com.greinchville.backgroundlocation

import android.content.Context
import org.json.JSONObject

object ConfigStore {
  private const val PREFS = "rn_bg_location"
  fun save(context: Context, json: String) = context.getSharedPreferences(PREFS, 0).edit().putString("config", json).apply()
  fun json(context: Context): JSONObject = JSONObject(context.getSharedPreferences(PREFS, 0).getString("config", "{}") ?: "{}")
  fun tracking(context: Context): Boolean = context.getSharedPreferences(PREFS, 0).getBoolean("tracking", false)
  fun setTracking(context: Context, v: Boolean) = context.getSharedPreferences(PREFS, 0).edit().putBoolean("tracking", v).apply()
  fun setMotion(context: Context, m: String) = context.getSharedPreferences(PREFS, 0).edit().putString("motion", m).apply()
  fun motion(context: Context): String = context.getSharedPreferences(PREFS, 0).getString("motion", "unknown") ?: "unknown"
}
