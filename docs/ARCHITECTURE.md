# Architecture

```text
React Native App / TypeScript API
        |
        v
NativeBackgroundLocation bridge
        |
        +-------------------------+
        |                         |
        v                         v
Configuration Store         JS Event Adapter
        |
        v
Native Tracking Engine
  |        |         |          |
  |        |         |          +--> Heartbeat scheduler
  |        |         +-------------> Geofence manager
  |        +-----------------------> Motion classifier
  +--------------------------------> Location provider
        |
        v
Normalizer / Adaptive state machine
        |
        v
SQLite durable queue
        |
        +--> JS event (best effort; optional)
        |
        v
Native sync engine
  iOS: in-process URLSession
  Android: OkHttp + WorkManager
        |
        v
HTTPS batch endpoint
```

## Adaptive state machine

| State | Typical trigger | iOS | Android | Distance | Typical cadence |
|---|---|---|---|---:|---:|
| stationary | Core Motion/Activity Recognition STILL | hundredMeters, 50 m filter | balanced priority | 50 m | event-driven |
| walking | walking | best | balanced/high as needed | 10 m | ~10 s |
| running | running | best | high/balanced | 10 m | 5-10 s |
| cycling | bicycle | best | high accuracy | 10 m | 5-10 s |
| automotive | vehicle | bestForNavigation | high accuracy | 10 m | ~5 s |
| significant | explicit low-power mode | significant-change | passive/low power | OS-controlled | event-driven |
| visits | explicit visits mode | CLVisit | geofence/activity approximation | OS-controlled | event-driven |

Only `adaptive` consults detected motion; an explicit mode keeps the profile the host selected. An
unknown motion state — which is what every cold start begins in — resolves to `balanced`, never to the
lowest-power profile.

The exact values are policy defaults, not guarantees. The OS ultimately controls hardware activation and callback timing.

## Event ordering
1. Native location callback arrives.
2. Normalize to `LocationRecord`.
3. Persist to SQLite.
4. Emit optional JS event if React Native is alive.
5. If queue threshold is reached, schedule native sync.
6. Delete only records acknowledged by a successful 2xx HTTP response.

## Killed-process restoration
### iOS
The host AppDelegate calls `NativeBackgroundLocationBootstrap.start()` at launch. Stored configuration is
loaded before JS is required, and the appropriate Core Location primitive is restarted. The React Native
module also calls the bootstrap from its initialiser, which covers hosts that skipped the AppDelegate
wiring, but only once the JS bundle has loaded — the AppDelegate call remains the correct path.

Continuous location updates never relaunch a terminated app. With Always authorization the engine keeps
an exit-only relaunch geofence (default 150 m) around the last good fix, re-registered once the device
has moved half its radius, and in continuous modes also arms significant-change monitoring as a second
net. Either one brings the process back after termination, including after the user swipes the app away in the app
switcher, and `bootstrap()` then restores continuous updates. Timing is OS-controlled. `stopOnTerminate`
opts out of resuming and removes the fence.

Uploads go through an ordinary URLSession with the body in memory, one at a time, wrapped in a UIKit
background task. A fix is only delivered while the process runs, so a request always has a live process
to finish in. A background URLSession was used before, but nsurlsessiond treats tasks created while the
app is in the background as discretionary and could hold the single upload slot for up to an hour, and
staging each body on disk meant a full disk stopped all uploads. Tasks such a version left behind are
cancelled on launch; their rows are still queued. Backoff state is persisted, so an outage does not
restart it from zero on every relaunch.

### Android
The tracking service uses a location foreground service and returns `START_STICKY`. A boot/package-replaced receiver can restart tracking when configured and allowed. WorkManager is used for resilient network draining. Android policy restrictions still apply to starts from the background.

## Battery strategy
- Prefer balanced/low-power providers unless active motion requires higher precision.
- Use minimum-distance filtering to avoid processing redundant samples.
- Batch delivery with `maxBatchDelayMs` on Android.
- Allow iOS automatic pausing except navigation mode.
- Switch stationary users to coarse/significant-change behavior.
- Trigger native sync by queue threshold instead of uploading every point.
- Bound the queue to prevent unbounded disk/memory use.
