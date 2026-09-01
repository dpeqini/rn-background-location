export type TrackingMode = 'adaptive' | 'navigation' | 'active' | 'balanced' | 'lowPower' | 'significant' | 'visits';
export type MotionType = 'stationary' | 'walking' | 'running' | 'cycling' | 'automotive' | 'unknown';

export interface HttpConfig {
  url: string;
  method?: 'POST' | 'PUT';
  headers?: Record<string, string>;
  batchSize?: number;
  timeoutMs?: number;
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

export interface HeartbeatEvent { timestamp: number; queueSize: number; motion: MotionType; }
export interface ProviderState { enabled: boolean; authorization: string; tracking: boolean; mode: TrackingMode; queueSize: number; motion: MotionType; }
