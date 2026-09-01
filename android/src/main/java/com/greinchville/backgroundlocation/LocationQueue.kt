package com.greinchville.backgroundlocation

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONObject

class LocationQueue(context: Context): SQLiteOpenHelper(context, "rn_bg_location.db", null, 1) {
  override fun onCreate(db: SQLiteDatabase) { db.execSQL("CREATE TABLE queue(id INTEGER PRIMARY KEY AUTOINCREMENT, uuid TEXT UNIQUE, created INTEGER, payload TEXT NOT NULL)") }
  override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}
  @Synchronized fun enqueue(payload: JSONObject, max: Int) {
    writableDatabase.execSQL("INSERT OR IGNORE INTO queue(uuid,created,payload) VALUES(?,?,?)", arrayOf(payload.getString("id"), System.currentTimeMillis(), payload.toString()))
    writableDatabase.execSQL("DELETE FROM queue WHERE id IN (SELECT id FROM queue ORDER BY id ASC LIMIT MAX((SELECT COUNT(*) FROM queue)-?,0))", arrayOf(max))
  }
  @Synchronized fun peek(limit: Int): List<Pair<Long,String>> { val out= mutableListOf<Pair<Long,String>>(); readableDatabase.rawQuery("SELECT id,payload FROM queue ORDER BY id ASC LIMIT ?", arrayOf(limit.toString())).use { c -> while(c.moveToNext()) out += c.getLong(0) to c.getString(1) }; return out }
  @Synchronized fun deleteThrough(id: Long) { writableDatabase.delete("queue", "id<=?", arrayOf(id.toString())) }
  fun count(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM queue", null).use { c -> c.moveToFirst(); c.getInt(0) }
  fun clear() = writableDatabase.delete("queue", null, null)
}
