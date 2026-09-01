package com.greinchville.backgroundlocation
import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
class SyncWorker(appContext: Context, params: WorkerParameters): CoroutineWorker(appContext, params) {
  override suspend fun doWork(): Result = try {
    NativeHttpSync.sync(applicationContext); Result.success()
  } catch (_: Exception) {
    // Previously retried without bound, so a permanently failing endpoint kept rescheduling a
    // worker forever. maxRetries was declared in the config and never read.
    val max = ConfigStore.json(applicationContext).optJSONObject("http")?.optInt("maxRetries", 10) ?: 10
    if (runAttemptCount + 1 >= max) Result.failure() else Result.retry()
  }
}
