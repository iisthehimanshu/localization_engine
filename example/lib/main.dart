import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:localization_engine/localization_engine.dart';
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
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
  GlobalKey<ScaffoldMessengerState>();

  void _showPermissionDeniedSnackbar() {
    _scaffoldMessengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Bluetooth permission denied')),
    );
  }

  Future<void> _requestBluetoothPermission() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<bool> _hasPermissions() async {
    return true;
  }

  Future<void> _startTracking() async {
    await _requestBluetoothPermission();
    if (await _hasPermissions()) {
      locationTracker.startTracking();
    } else {
      _showPermissionDeniedSnackbar();
    }
  }

  Future<void> _startImmediateBeaconScan() async {
    await _requestBluetoothPermission();
    if (await _hasPermissions()) {
      locationTracker.scanForRawBluetooth();
    } else {
      _showPermissionDeniedSnackbar();
    }
  }

  Future<void> _startGPSStream() async {
    await _requestBluetoothPermission();
    if (await _hasPermissions()) {
      locationTracker.startGpsStream();
    } else {
      _showPermissionDeniedSnackbar();
    }
  }

  Future<void> _startPeakValley() async {
    await _requestBluetoothPermission();
    if (await _hasPermissions()) {
      locationTracker.peakValley();
    } else {
      _showPermissionDeniedSnackbar();
    }
  }

  Future<void> _trackUser() async {
      locationTracker.trackLocation();
  }

  StreamSubscription<Map<String, List<MapEntry<DateTime, int>>>?>?
  _allBeaconSubscription;

  final StreamController<Map<String, List<int>>> beaconStreamController =
  StreamController.broadcast();

  Future<Map<String, dynamic>?> _getCurrentLocation() async {
    await _requestBluetoothPermission();
    if (await _hasPermissions()) {
      try {
        var location = await locationTracker.getCurrentLocation();
        print("_getCurrentLocation $location");
        return location;
      } catch (e) {
        print("_getCurrentLocation $e");
      }
    } else {
      _showPermissionDeniedSnackbar();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
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
              const SizedBox(height: 12),
              IconButton(
                onPressed: _startGPSStream,
                icon: const Icon(Icons.location_on),
              ),
              const SizedBox(height: 12),
              IconButton(
                onPressed: _getCurrentLocation,
                icon: const Icon(Icons.my_location),
              ),
              const SizedBox(height: 12),
              IconButton(
                onPressed: _startPeakValley,
                icon: const Icon(Icons.auto_graph),
              ),
              const SizedBox(height: 12),
              IconButton(
                onPressed: _trackUser,
                icon: const Icon(Icons.interests),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _startImmediateBeaconScan,
                    icon: const Icon(Icons.bluetooth_searching_sharp),
                  ),
                  const SizedBox(width: 42),
                  IconButton(
                    onPressed: () {
                      locationTracker.crossedBeacon();
                    },
                    icon: const Icon(Icons.timer),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              IconButton(
                onPressed: () {
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