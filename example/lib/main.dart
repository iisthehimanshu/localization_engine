import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'LocationTracker.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  LocationTracker locationTracker = LocationTracker();

  Future<void> _requestBluetoothPermission() async {
    // Request permissions required for BLE scanning
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> _startTracking() async {
    await _requestBluetoothPermission();
    if (await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted &&
        await Permission.locationWhenInUse.isGranted) {
      locationTracker.start();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth permission denied')),
      );
    }
  }

  Future<void> _startGPSStream() async {
    await _requestBluetoothPermission();
    if (await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted &&
        await Permission.locationWhenInUse.isGranted) {
      locationTracker.startGpsStream();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth permission denied')),
      );
    }
  }

  Future<void> _startPeakValley() async {
    await _requestBluetoothPermission();
    if (await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted &&
        await Permission.locationWhenInUse.isGranted) {
      locationTracker.peakValley();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth permission denied')),
      );
    }
  }

  Future<Pt?> _getCurrentLocation() async {
    await _requestBluetoothPermission();
    if (await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted &&
        await Permission.locationWhenInUse.isGranted) {
      try{
        var location = await locationTracker.getCurrentLocation();
        print("_getCurrentLocation $location");
        return location;
      }catch(e){
        print("_getCurrentLocation $e");
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth permission denied')),
      );
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: _startTracking,
                icon: const Icon(Icons.bluetooth),
              ),
              SizedBox(height: 12,),
              IconButton(
                onPressed: _startGPSStream,
                icon: const Icon(Icons.location_on),
              ),
              SizedBox(height: 12,),
              IconButton(
                onPressed: _getCurrentLocation,
                icon: const Icon(Icons.my_location),
              ),
              SizedBox(height: 12,),
              IconButton(
                onPressed: _startPeakValley,
                icon: const Icon(Icons.auto_graph),
              ),
              SizedBox(height: 12,),
              IconButton(
                onPressed: (){
                  locationTracker.stop();
                },
                icon: const Icon(Icons.cancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
