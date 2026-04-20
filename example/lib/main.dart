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

  LocationTracker locationTracker = LocationTracker("TestLocation");

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
              ElevatedButton(
                onPressed: (){
                  locationTracker.startTracking();
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.start),
                    Text("Start Scanning for saving Data"),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: (){
                  locationTracker.saveBleDataToCsv();
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.file_copy),
                  Text("Stop Scanning and Save Data")
                ],
              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}