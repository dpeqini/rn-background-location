import React, {useEffect} from 'react';
import {Button, SafeAreaView, Text} from 'react-native';
import {BackgroundLocation} from '@greinchville/react-native-background-location';

export default function App(){
  useEffect(()=>{
    const l=BackgroundLocation.onLocation(x=>console.log('LOCATION',x));
    const m=BackgroundLocation.onMotionChange(x=>console.log('MOTION',x));
    const g=BackgroundLocation.onGeofence(x=>console.log('GEOFENCE',x));
    const h=BackgroundLocation.onHeartbeat(x=>console.log('HEARTBEAT',x));
    return()=>{l.remove();m.remove();g.remove();h.remove()};
  },[]);
  const enable=async()=>{
    await BackgroundLocation.requestPermissions();
    await BackgroundLocation.configure({
      mode:'adaptive', motionDetection:true, motionDistanceMeters:10,
      distanceFilterMeters:25, intervalMs:30000, fastestIntervalMs:5000,
      maxBatchDelayMs:60000, heartbeatIntervalSeconds:60, startOnBoot:true,
      maxQueueSize:10000,
      http:{url:'https://api.example.com/v1/locations/batch',method:'POST',headers:{Authorization:'Bearer TOKEN'},batchSize:50,syncThreshold:10},
      android:{notificationTitle:'Location sharing active',notificationText:'Your location is being recorded for this activity.'},
      ios:{activityType:'otherNavigation',showsBackgroundLocationIndicator:true}
    });
    await BackgroundLocation.start();
  };
  return <SafeAreaView><Text>Background Location Demo</Text><Button title="Enable tracking" onPress={enable}/><Button title="Stop" onPress={()=>BackgroundLocation.stop()}/></SafeAreaView>;
}
