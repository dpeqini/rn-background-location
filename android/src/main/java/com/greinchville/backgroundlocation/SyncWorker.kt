package com.greinchville.backgroundlocation
import android.content.Context
import android.os.SystemClock
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
class SyncWorker(appContext: Context, params: WorkerParameters): CoroutineWorker(appContext, params) {
  override suspend fun doWork(): Result = try {
    // Keep draining while each pass makes progress, so a backlog clears in one run rather than waiting
    // for the next fix to schedule another. Bounded well inside WorkManager's 10-minute limit.
    val deadline = SystemClock.elapsedRealtime() + 5 * 60_000L
    var before = Int.MAX_VALUE
    while (SystemClock.elapsedRealtime() < deadline) {
      val (_, remaining) = NativeHttpSync.sync(applicationContext)
      if (remaining == 0 || remaining >= before) break
      before = remaining
    }
    Result.success()
  } catch (_: Exception) {
    // Previously retried without bound, so a permanently failing endpoint kept rescheduling a
    // worker forever. maxRetries was declared in the config and never read.
    val max = ConfigStore.json(applicationContext).optJSONObject("http")?.optInt("maxRetries", 10) ?: 10
    if (runAttemptCount + 1 >= max) Result.failure() else Result.retry()
  }
}
