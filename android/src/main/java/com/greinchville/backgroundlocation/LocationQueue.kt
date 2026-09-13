package com.greinchville.backgroundlocation

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.facebook.react.bridge.Arguments
import org.json.JSONObject

class LocationQueue private constructor(context: Context): SQLiteOpenHelper(context, "rn_bg_location.db", null, 1) {
  // Writes from the service no longer block the sync worker's reads, and each fix costs one WAL append.
  init { setWriteAheadLoggingEnabled(true) }
  companion object {
    // One helper per process. It was previously constructed per call site, twice per location
    // fix, and never closed, so every fix leaked an open database connection.
    @Volatile private var instance: LocationQueue? = null
    fun get(context: Context): LocationQueue = instance ?: synchronized(this) {
      instance ?: LocationQueue(context.applicationContext).also { instance = it }
    }
  }
  override fun onCreate(db: SQLiteDatabase) { db.execSQL("CREATE TABLE queue(id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT UNIQUE, created INTEGER, payload TEXT NOT NULL)") }
  override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}
  // Returns how many of the oldest rows were discarded to stay within max.
  @Synchronized fun enqueue(payload: JSONObject, max: Int): Int {
    val db = writableDatabase
    db.execSQL("INSERT OR IGNORE INTO queue(uuid,created,payload) VALUES(?,?,?)", arrayOf(payload.getString("id"), System.currentTimeMillis(), payload.toString()))
    return db.compileStatement("DELETE FROM queue WHERE id IN (SELECT id FROM queue ORDER BY id ASC LIMIT MAX((SELECT COUNT(*) FROM queue)-?,0))").use { it.bindLong(1, max.toLong()); it.executeUpdateDelete() }
  }
  @Synchronized fun peek(limit: Int): List<Pair<Long,String>> { val out= mutableListOf<Pair<Long,String>>(); readableDatabase.rawQuery("SELECT id,payload FROM queue ORDER BY id ASC LIMIT ?", arrayOf(limit.toString())).use { c -> while(c.moveToNext()) out += c.getLong(0) to c.getString(1) }; return out }
  @Synchronized fun deleteThrough(id: Long) { writableDatabase.delete("queue", "id<=?", arrayOf(id.toString())) }
  fun count(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM queue", null).use { c -> c.moveToFirst(); c.getInt(0) }
  fun clear() = writableDatabase.delete("queue", null, null)
}

// Trimming used to discard the oldest fixes silently. Report it, at most once a minute with drops
// summed, matching the iOS queueOverflow event.
internal object OverflowReporter {
  private val handler = Handler(Looper.getMainLooper())
  private var pending = 0
  private var last = -60_000L
  private var scheduled = false
  @Synchronized fun add(dropped: Int) { if (dropped > 0) { pending += dropped; flush() } }
  @Synchronized private fun flush() {
    if (pending == 0) return
    val wait = 60_000L - (SystemClock.elapsedRealtime() - last)
    if (wait > 0) {
      if (!scheduled) { scheduled = true; handler.postDelayed({ synchronized(this) { scheduled = false; flush() } }, wait) }
      return
    }
    last = SystemClock.elapsedRealtime()
    val m = Arguments.createMap()
    m.putString("code", "queueOverflow")
    m.putString("message", "Discarded $pending oldest queued location(s): the queue reached maxQueueSize before they could be uploaded")
    pending = 0
    EventBus.emit("backgroundLocation:error", m)
  }
}
