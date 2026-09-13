export type TrackingMode = 'adaptive' | 'navigation' | 'active' | 'balanced' | 'lowPower' | 'significant' | 'visits';
export type MotionType = 'stationary' | 'walking' | 'running' | 'cycling' | 'automotive' | 'unknown';

export interface HttpConfig {
  url: string;
  method?: 'POST' | 'PUT';
  headers?: Record<string, string>;
  batchSize?: number;
  /** Per-request timeout. Defaults to 15000. */
  timeoutMs?: number;
  /**
   * Consecutive 5xx failures tolerated for one batch before it is discarded so it cannot block the
   * queue behind it. Defaults to 10. Transport failures (no network, timeout) are always retried and
   * never count against this. A 4xx other than 408/429 is treated as permanent and discards the batch
   * immediately, since it will not start succeeding on repeat. Retries use exponential backoff capped
   * at five minutes, persisted across process termination.
   */
  maxRetries?: number;
  syncThreshold?: number;
  /**
   * When true, each queued location is POSTed as its own request (one location
   * per HTTP call) instead of a single batched array. Mirrors transistorsoft's
   * `batchSync: false`.
   */
  single?: boolean;
  /**
   * Optional body template rendered per location in `single` mode. Supports
   * `<%= field %>` placeholders drawn from the LocationRecord (e.g. latitude,
   * longitude, accuracy, speed, timestamp). If omitted, the full record is sent.
   */
  locationTemplate?: string;
  /**
   * Extra key/values merged into every request body (e.g. `{ deviceId }`).
   * Mirrors transistorsoft's `params`.
   */
  params?: Record<string, string | number | boolean>;
  /**
   * Batch mode only. Key the locations array is nested under. Defaults to
   * `"locations"`; use `"."` to POST the bare array as the root body.
   */
  rootProperty?: string;
}

export interface TrackingConfig {
  /**
   * Selects the tracking profile. Defaults to `adaptive`, which is the only mode that follows detected
   * motion (automotive -> navigation, walking/running/cycling -> active, otherwise balanced); every
   * other mode keeps the profile you set. On iOS `significant`, `lowPower`, and `visits` register a
   * different Core Location service rather than continuous updates. Android has no equivalent of
   * `significant` or `visits` and maps both to a low-power, long-interval request.
   */
  mode?: TrackingMode;
  desiredAccuracyMeters?: number;
  distanceFilterMeters?: number;
  intervalMs?: number;
  fastestIntervalMs?: number;
  maxBatchDelayMs?: number;
  /**
   * When false (the default), tracking resumes after the process is terminated: iOS relaunches
   * the app in the background on a significant-change, region, or visit event and restores the
   * stored configuration. Set true to leave tracking stopped once the process dies.
   * Requires Always authorization. A deliberate user force-quit is not covered.
   */
  stopOnTerminate?: boolean;
  startOnBoot?: boolean;
  /**
   * iOS only. Maps to `pausesLocationUpdatesAutomatically`. Defaults to **false**: once iOS pauses
   * updates it decides whether they ever resume, and in the background that regularly means never.
   * Enable it only if you want that battery trade-off and can tolerate gaps.
   */
  pausesAutomatically?: boolean;
  heartbeatIntervalSeconds?: number;
  motionDetection?: boolean;
  motionDistanceMeters?: number;
  geofencing?: boolean;
  maxQueueSize?: number;
  http?: HttpConfig;
  android?: {
    notificationTitle?: string;
    notificationText?: string;
    notificationChannelId?: string;
    notificationId?: number;
  };
  ios?: {
    showsBackgroundLocationIndicator?: boolean;
    activityType?: 'other' | 'automotiveNavigation' | 'fitness' | 'otherNavigation' | 'airborne';
  };
}

export interface LocationRecord {
  id: string;
  latitude: number;
  longitude: number;
  accuracy: number;
  altitude?: number;
  altitudeAccuracy?: number;
  heading?: number;
  speed?: number;
  timestamp: number;
  mocked?: boolean;
  motion?: MotionType;
  batteryLevel?: number;
  isCharging?: boolean;
  source: 'gps' | 'network' | 'fused' | 'significant' | 'visit' | 'geofence' | 'unknown';
  extras?: Record<string, unknown>;
}

export interface Geofence {
  id: string;
  latitude: number;
  longitude: number;
  radius: number;
  notifyOnEntry?: boolean;
  notifyOnExit?: boolean;
  loiteringDelayMs?: number;
}

export interface GeofenceEvent {
  id: string;
  transition: 'enter' | 'exit' | 'dwell';
  timestamp: number;
  location?: LocationRecord;
}

/**
 * `code` values carried by `onError` events. New codes may be added in minor versions, so handle
 * unknown ones gracefully.
 */
export type BackgroundLocationErrorCode =
  | 'authorization'
  | 'backgroundMode'
  | 'permission'
  | 'paused'
  | 'location'
  | 'syncDropped'
  | 'queueOverflow'
  | 'storage';
export interface BackgroundLocationError { code: BackgroundLocationErrorCode | (string & {}); message: string; }

export interface HeartbeatEvent { timestamp: number; queueSize: number; motion: MotionType; }
export interface ProviderState { enabled: boolean; authorization: string; tracking: boolean; mode: TrackingMode; queueSize: number; motion: MotionType; }
