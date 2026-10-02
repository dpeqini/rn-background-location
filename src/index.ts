import { NativeEventEmitter, NativeModules, Platform, PermissionsAndroid } from 'react-native';
import type { TrackingConfig, LocationRecord, Geofence, GeofenceEvent, HeartbeatEvent, ProviderState, BackgroundLocationError, SyncEvent } from './types';
export * from './types';

const LINKING_ERROR = `The package '@greinchville/react-native-background-location' is not linked. Rebuild the native app after installing it.`;
const Native = NativeModules.NativeBackgroundLocation ?? new Proxy({}, { get() { throw new Error(LINKING_ERROR); } });
const emitter = new NativeEventEmitter(Native);

export const BackgroundLocation = {
  configure(config: TrackingConfig): Promise<ProviderState> { return Native.configure(config); },
  start(): Promise<void> { return Native.start(); },
  stop(): Promise<void> { return Native.stop(); },
  getState(): Promise<ProviderState> { return Native.getState(); },
  getCurrentLocation(options: { timeoutMs?: number; highAccuracy?: boolean } = {}): Promise<LocationRecord> { return Native.getCurrentLocation(options); },
  getQueuedLocations(limit = 1000): Promise<LocationRecord[]> { return Native.getQueuedLocations(limit); },
  clearQueue(): Promise<void> { return Native.clearQueue(); },
  sync(): Promise<{sent: number; remaining: number}> { return Native.sync(); },
  addGeofence(geofence: Geofence): Promise<void> { return Native.addGeofence(geofence); },
  removeGeofence(id: string): Promise<void> { return Native.removeGeofence(id); },
  removeAllGeofences(): Promise<void> { return Native.removeAllGeofences(); },
  async requestPermissions(): Promise<string> {
    if (Platform.OS === 'android') {
      await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION);
      if (Platform.Version >= 29) await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.ACCESS_BACKGROUND_LOCATION);
      if (Platform.Version >= 33) await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS);
      if (Platform.Version >= 29) await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.ACTIVITY_RECOGNITION);
    }
    return Native.requestPermissions();
  },
  onLocation(cb: (e: LocationRecord) => void) { return emitter.addListener('backgroundLocation:location', cb); },
  onMotionChange(cb: (e: {motion: string; timestamp: number}) => void) { return emitter.addListener('backgroundLocation:motion', cb); },
  onGeofence(cb: (e: GeofenceEvent) => void) { return emitter.addListener('backgroundLocation:geofence', cb); },
  onHeartbeat(cb: (e: HeartbeatEvent) => void) { return emitter.addListener('backgroundLocation:heartbeat', cb); },
  onSync(cb: (e: SyncEvent) => void) { return emitter.addListener('backgroundLocation:sync', cb); },
  onError(cb: (e: BackgroundLocationError) => void) { return emitter.addListener('backgroundLocation:error', cb); },
};
