package com.greinchville.backgroundlocation
import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
class SyncWorker(appContext: Context, params: WorkerParameters): CoroutineWorker(appContext, params) {
  override suspend fun doWork(): Result = try { NativeHttpSync.sync(applicationContext); Result.success() } catch (_: Exception) { Result.retry() }
}
