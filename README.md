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
<key>NSMotionUsageDescription</key>
<string>Your explanation of motion-based battery optimisation.</string>
```
Both entries are load-bearing. Without `UIBackgroundModes` containing `location`, iOS stops delivering
updates the moment the app leaves the foreground; the library emits a `backgroundMode` error event when
the key is missing. `NSMotionUsageDescription` is required whenever `motionDetection` is on.
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
Request **Always** location only after explaining the feature to the user. Always is not optional for
background work: with When In Use, updates stop once the app is suspended and cannot be restarted, and
significant-change, visit, and region monitoring never start at all. `getState().authorization` reports
`always` / `whenInUse` / `denied` / `restricted` / `notDetermined`, and an `authorization` error event is
emitted when tracking starts without it.

## Background and termination behaviour

| Situation | What happens |
|---|---|
| App backgrounded | Continuous updates keep running. The process is not suspended while the `location` background mode is active. |
| System terminates the app | Significant-change monitoring relaunches it in the background and the stored configuration is restored. |
| User swipes the app away | Same relaunch path on iOS 8+. Timing is OS-controlled and can lag. |
| `stopOnTerminate: true` | Tracking stays stopped after the process dies. |
| Android swipe-away | The foreground service is restarted unless `stopOnTerminate` is set. |

After a kill, tracking is **event-driven and coarse** — significant-change is roughly 500 m — until a
relaunch restores continuous updates. Locations are persisted to SQLite before any upload is attempted,
so a gap in delivery is not a gap in data. Nothing recovers from a device-level Force Stop on Android or
from revoked permissions.

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

### Error codes
`onError` receives `{ code, message }`:

| code | Meaning |
|---|---|
| `authorization` | Background tracking needs Always authorization (iOS). |
| `backgroundMode` | Info.plist `UIBackgroundModes` is missing `location` (iOS). |
| `permission` | Location permission was denied when subscribing (Android). |
| `paused` | iOS paused location updates; significant-change monitoring is armed to resume them. |
| `location` | Core Location reported a failure. |
| `syncDropped` | The server rejected a batch permanently (4xx other than 408/429, or 5xx past `maxRetries`); it was discarded. |
| `queueOverflow` | The queue reached `maxQueueSize` (or, on iOS, storage was unavailable) and the oldest fixes were discarded. At most one event per minute, with counts summed. |
| `storage` | iOS could not write to the on-device queue; recent fixes are held in memory (up to 500) until storage is available. |

### Delivery guarantees
- **One upload in flight.** A new request starts only after the previous one finishes; a backlog
  drains one batch at a time. Calling `sync()` while an upload is pending resolves with that upload's
  result.
- **At least once.** A batch is removed from the queue only after a 2xx. A request can still be
  delivered twice (e.g. the app dies before the response is processed), so deduplicate on the
  server by the location `id`.
- **Bounded storage.** The queue is capped at `maxQueueSize` rows (default 10,000, a few MB); the
  oldest rows are discarded first and reported via `queueOverflow`.

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
