# iOS host integration

Enable **Background Modes > Location updates** in Xcode and add these Info.plist descriptions:

- NSLocationWhenInUseUsageDescription
- NSLocationAlwaysAndWhenInUseUsageDescription
- NSMotionUsageDescription (required whenever `motionDetection` is on)

Both are load-bearing for background tracking:

- Without `UIBackgroundModes` containing `location`, iOS stops delivering updates as soon as the app
  leaves the foreground. The module emits a `backgroundMode` error event when the key is missing.
- Without **Always** authorization, continuous updates end when the app is suspended and cannot be
  restarted, and significant-change, visit, and region monitoring never start. `getState()` reports
  `authorization: "whenInUse"` in that case and the module emits an `authorization` error event.

For reliable native restoration before React Native/JavaScript is ready, call the bootstrap from application launch:

```swift
import react_native_background_location

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
  NativeBackgroundLocationBootstrap.start()
  // existing React Native setup...
  return true
}
```

If your AppDelegate is Objective-C++, expose/call the generated Swift header or add a tiny host Swift shim that invokes `NativeBackgroundLocationBootstrap.start()`.

Important: relaunch behaviour depends on which service is registered.

- Continuous location updates never relaunch a terminated app.
- Significant-change, region, and visit monitoring relaunch the app after termination, including
  after the user swipes it away in the app switcher (iOS 8 and later). Timing is OS-controlled and
  can be delayed, and each relaunch grants only a short background window, so treat post-kill
  tracking as event-driven and coarse rather than continuous.

Forward background URLSession completions as well, or uploads that finish while the app is
suspended will not be processed:

```swift
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
  NativeBackgroundLocationBootstrap.handleEventsForBackgroundURLSession(identifier,
                                                                       completionHandler: completionHandler)
}
```
