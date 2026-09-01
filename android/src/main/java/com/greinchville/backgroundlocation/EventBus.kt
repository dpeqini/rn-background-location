package com.greinchville.backgroundlocation
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
object EventBus {
  @Volatile var reactContext: ReactApplicationContext? = null
  fun emit(name:String, map:WritableMap) { reactContext?.takeIf { it.hasActiveReactInstance() }?.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)?.emit(name,map) }
}
