package com.greinchville.backgroundlocation

import android.content.Context
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

object NativeHttpSync {
  private val TOKEN = Regex("<%=\\s*(\\w+)\\s*%>")

  // A JS sync() and the WorkManager job could otherwise both peek the same head batch and send it twice.
  @Synchronized fun sync(context: Context): Pair<Int,Int> {
    val cfg = ConfigStore.json(context).optJSONObject("http") ?: return 0 to LocationQueue.get(context).count()
    val url = cfg.optString("url"); if (url.isBlank()) return 0 to LocationQueue.get(context).count()
    val q = LocationQueue.get(context)
    return if (cfg.optBoolean("single", false)) syncSingle(cfg, url, q) else syncBatch(cfg, url, q)
  }

  private fun client(cfg: JSONObject) =
    OkHttpClient.Builder().callTimeout(cfg.optLong("timeoutMs", 15000), TimeUnit.MILLISECONDS).build()

  private fun request(cfg: JSONObject, url: String, bodyStr: String): Request {
    val body = bodyStr.toRequestBody("application/json".toMediaType())
    val rb = Request.Builder().url(url).method(cfg.optString("method", "POST"), body)
    cfg.optJSONObject("headers")?.let { h -> h.keys().forEach { k -> rb.header(k, h.optString(k)) } }
    return rb.build()
  }

  private fun syncBatch(cfg: JSONObject, url: String, q: LocationQueue): Pair<Int,Int> {
    val batch = q.peek(cfg.optInt("batchSize", 50)); if (batch.isEmpty()) return 0 to 0
    val arr = JSONArray(); batch.forEach { arr.put(JSONObject(it.second)) }
    val root = cfg.optString("rootProperty", "locations")
    val bodyStr = if (root == ".") arr.toString() else JSONObject().put(root, arr).toString()
    client(cfg).newCall(request(cfg, url, bodyStr)).execute().use { r -> if (!r.isSuccessful) throw IllegalStateException("HTTP ${r.code}") }
    q.deleteThrough(batch.last().first)
    return batch.size to q.count()
  }

  private fun syncSingle(cfg: JSONObject, url: String, q: LocationQueue): Pair<Int,Int> {
    var sent = 0
    val c = client(cfg)
    val max = cfg.optInt("batchSize", 50).coerceAtLeast(1)
    while (sent < max) {
      val rows = q.peek(1); if (rows.isEmpty()) break
      val (id, payload) = rows[0]
      val bodyStr = buildSingleBody(JSONObject(payload), cfg)
      c.newCall(request(cfg, url, bodyStr)).execute().use { r -> if (!r.isSuccessful) throw IllegalStateException("HTTP ${r.code}") }
      q.deleteThrough(id); sent++
    }
    return sent to q.count()
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
