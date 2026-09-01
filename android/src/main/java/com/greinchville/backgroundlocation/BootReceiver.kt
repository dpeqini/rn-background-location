package com.greinchville.backgroundlocation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
class BootReceiver:BroadcastReceiver(){override fun onReceive(c:Context,i:Intent){ val cfg=ConfigStore.json(c); if(cfg.optBoolean("startOnBoot",false)&&ConfigStore.tracking(c)) try{c.startForegroundService(Intent(c,LocationTrackingService::class.java))}catch(_:Exception){} }}
