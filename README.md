# @greinchville/react-native-background-location

Reference implementation of a native-first React Native background-location library for Android and iOS.

## What is included
- Native background tracking
- Adaptive battery strategy
- iOS standard, navigation, balanced, significant-change and visits modes
- Native motion detection
- Sub-10-meter *distance filtering* in active modes when the platform can provide it
- Geofencing
- Durable SQLite location queue
- Native batch HTTP synchronization
- Android foreground service + WorkManager retry
- iOS background URLSession upload
- Native heartbeat events
- Android boot recovery option
- TypeScript API and example app

## Installation
```bash
npm install @greinchville/react-native-background-location
cd ios && pod install
```
Rebuild both native apps after installation.

## iOS setup
Enable **Background Modes > Location updates**. Add:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Your explanation.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Your explanation of continuous/background use.</string>
<key>UIBackgroundModes</key>
<array><string>location</string></array>
```
Call the bootstrap in `didFinishLaunchingWithOptions` before React Native setup:
```swift
NativeBackgroundLocationBootstrap.start()
```
Forward background URLSession wakeups:
```swift
func application(_ application: UIApplication,
  handleEventsForBackgroundURLSession identifier: String,
  completionHandler: @escaping () -> Void) {
  NativeBackgroundLocationBootstrap.handleEventsForBackgroundURLSession(
    identifier,
    completionHandler: completionHandler
  )
}
```
Request **Always** location only after explaining the feature to the user.

## Android setup
The library manifest declares location, background-location, activity-recognition, notification, foreground-service, boot and internet permissions. Your app still must request dangerous permissions at runtime and satisfy Play policy.

Android 14+ requires the `location` foreground-service type and associated permission. Start tracking from a user-visible/eligible state whenever possible.

## API
```ts
await BackgroundLocation.requestPermissions();
await BackgroundLocation.configure({
  mode: 'adaptive',
  motionDetection: true,
  motionDistanceMeters: 10,
  intervalMs: 30_000,
  fastestIntervalMs: 5_000,
  maxBatchDelayMs: 60_000,
  heartbeatIntervalSeconds: 60,
  startOnBoot: true,
  maxQueueSize: 10_000,
  http: {
    url: 'https://api.example.com/v1/locations/batch',
    method: 'POST',
    headers: { Authorization: 'Bearer <short-lived-token>' },
    batchSize: 50,
    syncThreshold: 10
  }
});
await BackgroundLocation.start();
```

### Methods
- `configure(config)`
- `requestPermissions()`
- `start()` / `stop()`
- `getState()`
- `getCurrentLocation()`
- `getQueuedLocations(limit)`
- `clearQueue()`
- `sync()`
- `addGeofence()`
- `removeGeofence()`
- `removeAllGeofences()`

### Events
- `onLocation`
- `onMotionChange`
- `onGeofence`
- `onHeartbeat`
- `onSync`
- `onError`

## Recommended server contract
Request:
```json
{
  "locations": [
    {
      "id": "uuid",
      "latitude": 29.7,
      "longitude": -95.8,
      "accuracy": 8.2,
      "timestamp": 1786570000000,
      "motion": "walking",
      "source": "fused"
    }
  ]
}
```
Return any 2xx status only after the batch is durably accepted. For production, improve the protocol by returning accepted UUIDs so partial-batch acknowledgement is possible.

## Important production hardening
This repository is a comprehensive reference implementation, not a substitute for device-matrix validation. Before publishing an SDK, add automated native tests, partial-batch acknowledgements, encryption-at-rest if required by your threat model, token refresh hooks, telemetry, structured error codes, OEM-specific Android guidance, and a TurboModule/Codegen facade if you want New-Architecture-only packaging.
