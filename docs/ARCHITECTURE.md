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
  iOS: background URLSession
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

Continuous location updates never relaunch a terminated app. While tracking in a continuous mode with
Always authorization, significant-change monitoring is therefore armed alongside them purely as a
relaunch net: it is what brings the process back after termination, including after the user swipes the
app away in the app switcher. Timing is OS-controlled and each relaunch is a short window, so post-kill
tracking is event-driven and coarse until continuous updates are restored. `stopOnTerminate` opts out of
resuming. The host must also forward background URLSession completion callbacks.

Upload acknowledgement is carried on the URLSession task rather than in memory, because a background
upload routinely completes in a different process than the one that started it. Backoff state is
persisted for the same reason.

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
