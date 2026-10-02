# Technical Requirements

## Scope
A native-first React Native background-location SDK for iOS and Android. Tracking, persistence, motion classification, geofencing, heartbeat generation, and HTTP synchronization must execute in native code so JavaScript suspension does not stop the pipeline.

## Supported platforms
- React Native 0.79+ reference target; compatible bridge module design, suitable for migration to a TurboModule spec.
- iOS 15+; Swift, Core Location, Core Motion, SQLite3, URLSession.
- Android API 26+; Kotlin, Fused Location Provider, Activity Recognition Transition API, Geofencing API, SQLite, WorkManager, foreground service, OkHttp.
- Android target/compile SDK in the reference project: API 36.

## Functional requirements
1. Continuous/background location tracking.
2. Adaptive accuracy, distance filter, batching, and sampling based on motion state.
3. Native operation independent of JavaScript execution.
4. Recovery after OS process termination where the OS permits it.
5. iOS modes: adaptive, navigation, active, balanced, lowPower/significant-change, visits.
6. Durable offline SQLite queue with bounded capacity.
7. Native HTTP batch upload with retry behavior.
8. Motion detection and switching among stationary/walking/running/cycling/automotive/unknown.
9. Configurable ~10 m movement filter in active modes; this is a requested minimum displacement between delivered samples, not a guaranteed accuracy radius.
10. Circular geofences with enter/exit events.
11. Heartbeat events while native execution is available; heartbeat timing is best-effort on iOS because iOS does not permit arbitrary exact recurring background timers.
12. Start-on-boot option on Android, subject to modern foreground-service launch restrictions and user permissions.

## Non-functional requirements
- No dependency on the React Native JS thread for capture, queueing, or synchronization.
- At-least-once local persistence before upload acknowledgement.
- Queue records carry UUID, timestamp, coordinates, accuracy, altitude, heading, speed, source, and motion state.
- Bounded queue and batch upload to limit memory.
- Exponential retry on Android WorkManager.
- Native in-process URLSession uploads on iOS.
- HTTPS endpoints only in production; authentication headers supplied by the host app.
- Avoid storing long-lived credentials in plain AsyncStorage. Prefer Keychain/Keystore and inject short-lived tokens into native configuration.
- Explicit user consent and visible foreground-service notification on Android.
- App Store/Play policy justification for background location.

## OS limitations
- iOS can relaunch for certain Core Location services after normal system termination, but a deliberate user force-quit prevents relaunch until the app is opened again.
- Android foreground services improve continuity but do not bypass a user Force stop, revoked permissions, OEM power controls, or platform background-start restrictions.
- Significant-change and visit monitoring trade precision for battery life and do not provide sub-10-meter tracking.
- Geofence transition latency is controlled by the OS and can be delayed for battery optimization.
