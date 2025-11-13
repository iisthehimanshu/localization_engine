import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'll.dart';

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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: IconButton(
            onPressed: _startTracking,
            icon: const Icon(Icons.bluetooth),
          ),
        ),
      ),
    );
  }
}
