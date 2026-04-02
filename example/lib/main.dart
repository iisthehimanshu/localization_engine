import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:localization_engine/localization_engine.dart';

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
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  LocationTracker locationTracker = LocationTracker("NationalZoologicalPark");

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
                onPressed: (){
                  locationTracker.bluetoothScanResults.listen((data){
                    print("ble data $data");
                  });
                },
                icon: const Icon(Icons.bluetooth),
              ),
              const SizedBox(height: 12),
              IconButton(
                onPressed: (){
                  locationTracker.gpsScanResults.listen((data){
                    print("gps data $data");
                  });
                },
                icon: const Icon(Icons.my_location),
              ),
              const SizedBox(height: 12),
              IconButton(
                onPressed: (){
                  locationTracker.startTracking();
                },
                icon: const Icon(Icons.location_on),
              ),
              const SizedBox(height: 12),
              IconButton(
                onPressed: (){
                  locationTracker.saveBleDataToCsv();
                },
                icon: const Icon(Icons.file_copy),
              ),
            ],
          ),
        ),
      ),
    );
  }
}