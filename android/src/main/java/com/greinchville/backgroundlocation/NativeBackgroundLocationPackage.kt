package com.greinchville.backgroundlocation
import com.facebook.react.*
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.ViewManager
class NativeBackgroundLocationPackage:ReactPackage{override fun createNativeModules(c:ReactApplicationContext):List<NativeModule> = listOf(NativeBackgroundLocationModule(c));override fun createViewManagers(c:ReactApplicationContext):List<ViewManager<*,*>> = emptyList()}
