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
| stationary | Core Motion/Activity Recognition STILL | low accuracy or significant-change | low-power priority | 50-100 m | 2+ min / event-driven |
| walking | walking | best | balanced/high as needed | 10 m | ~10 s |
| running | running | best | high/balanced | 10 m | 5-10 s |
| cycling | bicycle | best | high | 10-20 m | 5-10 s |
| automotive | vehicle | bestForNavigation | high accuracy | 10 m | ~5 s |
| significant | explicit low-power mode | significant-change | passive/low power | OS-controlled | event-driven |
| visits | explicit visits mode | CLVisit | geofence/activity approximation | OS-controlled | event-driven |

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
The host AppDelegate calls `NativeBackgroundLocationBootstrap.start()` at launch. Stored configuration is loaded before JS is required, and the appropriate Core Location primitive is restarted. Significant-change/region services may cause an OS relaunch. Standard continuous tracking behavior after termination remains OS-controlled. The host must also forward background URLSession completion callbacks.

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
