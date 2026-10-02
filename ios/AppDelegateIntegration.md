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
  after the user swipes it away in the app switcher (iOS 8 and later).

## After the app is killed

While tracking with Always authorization, the library keeps an exit-only **relaunch geofence** around
the last good fix (`ios.relaunchRadiusMeters`, default 150 m) and, in continuous modes, significant-change
monitoring as a second net. When the device leaves the fence, iOS relaunches the app in the background,
`NativeBackgroundLocationBootstrap.start()` restores continuous updates, and the fence is re-armed around
the new position. Expect a gap of roughly the fence radius after a kill. The relaunch timing is
OS-controlled, so confirm it on a real device.

To debug a relaunch in Xcode, set the scheme's Run > Info > Launch to **Wait for the executable to be
launched**, swipe the app away, and keep the simulated location moving (Features > Location > City Run or
Freeway Drive). The debugger attaches when iOS relaunches the app. Xcode's Stop button is not a swipe-kill.

Forwarding background URLSession completions is optional since uploads moved to an in-process session,
but keeps tasks left queued by an earlier version from lingering:

```swift
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
  NativeBackgroundLocationBootstrap.handleEventsForBackgroundURLSession(identifier,
                                                                       completionHandler: completionHandler)
}
```
