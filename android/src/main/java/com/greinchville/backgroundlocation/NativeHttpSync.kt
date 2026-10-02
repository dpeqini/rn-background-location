package com.greinchville.backgroundlocation

import android.content.Context
import android.os.SystemClock
import com.facebook.react.bridge.Arguments
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

object NativeHttpSync {
  private val TOKEN = Regex("<%=\\s*(\\w+)\\s*%>")
  // One call drains the queue for at most this long, so a backlog goes out back to back instead of one
  // batch per scheduled job, while a JS sync() never blocks for minutes.
  private const val BUDGET_MS = 60_000L

  // A failure worth retrying: no network, a timeout, 408/429 or a 5xx. `sent` counts what was delivered
  // before it, so the sync event stays accurate.
  class SyncFailure(val sent: Int, val status: Int, message: String, cause: Throwable? = null): Exception(message, cause)

  // A JS sync() and the WorkManager job could otherwise both peek the same head batch and send it twice.
  @Synchronized fun sync(context: Context): Pair<Int,Int> {
    val q = LocationQueue.get(context)
    val cfg = ConfigStore.json(context).optJSONObject("http") ?: return 0 to q.count()
    val url = cfg.optString("url"); if (url.isBlank()) return 0 to q.count()
    val deadline = SystemClock.elapsedRealtime() + BUDGET_MS
    try {
      val sent = if (cfg.optBoolean("single", false)) syncSingle(cfg, url, q, deadline) else syncBatch(cfg, url, q, deadline)
      if (sent > 0) emitSync(sent, q.count(), 0, null)
      return sent to q.count()
    } catch (e: SyncFailure) {
      emitSync(e.sent, q.count(), e.status, e.message)
      throw e
    }
  }

  private fun client(cfg: JSONObject) =
    OkHttpClient.Builder().callTimeout(cfg.optLong("timeoutMs", 15000), TimeUnit.MILLISECONDS).build()

  private fun request(cfg: JSONObject, url: String, bodyStr: String): Request {
    val body = bodyStr.toRequestBody("application/json".toMediaType())
    val rb = Request.Builder().url(url).method(cfg.optString("method", "POST"), body)
    cfg.optJSONObject("headers")?.let { h -> h.keys().forEach { k -> rb.header(k, h.optString(k)) } }
    return rb.build()
  }

  private fun post(c: OkHttpClient, req: Request, sent: Int): Int =
    try { c.newCall(req).execute().use { it.code } }
    catch (e: IOException) { throw SyncFailure(sent, 0, e.message ?: "Network error", e) }

  // Mirrors iOS: a 4xx other than 408/429 will not start succeeding on repeat, so those rows are discarded
  // rather than blocking the queue behind them forever. Everything else is retried.
  private fun permanent(code: Int) = code in 400..499 && code != 408 && code != 429

  private fun syncBatch(cfg: JSONObject, url: String, q: LocationQueue, deadline: Long): Int {
    val c = client(cfg); var sent = 0; var dropped = 0; var dropCode = 0
    while (SystemClock.elapsedRealtime() < deadline) {
      val batch = q.peek(cfg.optInt("batchSize", 50)); if (batch.isEmpty()) break
      val arr = JSONArray(); batch.forEach { arr.put(JSONObject(it.second)) }
      val root = cfg.optString("rootProperty", "locations")
      val bodyStr = if (root == ".") arr.toString() else JSONObject().put(root, arr).toString()
      val code = post(c, request(cfg, url, bodyStr), sent)
      when {
        code in 200..299 -> { q.deleteThrough(batch.last().first); sent += batch.size }
        permanent(code) -> { q.deleteThrough(batch.last().first); dropped += batch.size; dropCode = code }
        else -> { emitDropped(dropped, dropCode); throw SyncFailure(sent, code, "HTTP $code") }
      }
    }
    emitDropped(dropped, dropCode)
    return sent
  }

  private fun syncSingle(cfg: JSONObject, url: String, q: LocationQueue, deadline: Long): Int {
    val c = client(cfg); var sent = 0; var dropped = 0; var dropCode = 0
    while (SystemClock.elapsedRealtime() < deadline) {
      val rows = q.peek(1); if (rows.isEmpty()) break
      val (id, payload) = rows[0]
      val code = post(c, request(cfg, url, buildSingleBody(JSONObject(payload), cfg)), sent)
      when {
        code in 200..299 -> { q.deleteThrough(id); sent++ }
        permanent(code) -> { q.deleteThrough(id); dropped++; dropCode = code }
        else -> { emitDropped(dropped, dropCode); throw SyncFailure(sent, code, "HTTP $code") }
      }
    }
    emitDropped(dropped, dropCode)
    return sent
  }

  private fun emitSync(sent: Int, remaining: Int, status: Int, error: String?) {
    val m = Arguments.createMap(); m.putInt("sent", sent); m.putInt("remaining", remaining)
    if (error != null) { m.putInt("status", status); m.putString("error", error) }
    EventBus.emit("backgroundLocation:sync", m)
  }

  private fun emitDropped(count: Int, code: Int) {
    if (count == 0) return
    val m = Arguments.createMap(); m.putString("code", "syncDropped")
    m.putString("message", "Discarded $count location(s) the server rejected permanently: HTTP $code")
    EventBus.emit("backgroundLocation:error", m)
  }

  private fun buildSingleBody(record: JSONObject, cfg: JSONObject): String {
    val template = cfg.optString("locationTemplate", "")
    val obj = if (template.isNotBlank()) JSONObject(renderTemplate(template, record)) else record
    cfg.optJSONObject("params")?.let { p -> p.keys().forEach { k -> obj.put(k, p.get(k)) } }
    return obj.toString()
  }

  private fun renderTemplate(template: String, record: JSONObject): String =
    TOKEN.replace(template) { m -> val k = m.groupValues[1]; if (record.has(k)) record.get(k).toString() else "" }
}
