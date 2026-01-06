import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
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

  Future<void> _startBluetoothScan() async {
    await _requestBluetoothPermission();
    if (await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted &&
        await Permission.locationWhenInUse.isGranted) {
      locationTracker.startBluetoothScanning();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bluetooth permission denied')),
      );
    }
  }

  Future<void> _localize() async {
    var result = await locationTracker.localize();
    showToast("$result");
  }

  void showToast(String mssg) {
    Fluttertoast.showToast(
      msg: mssg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.BOTTOM,
      timeInSecForIosWeb: 1,
      backgroundColor: Colors.grey,
      textColor: Colors.white,
      fontSize: 16.0,
    );
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
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _startBluetoothScan,
                    icon: const Icon(Icons.settings_bluetooth_sharp),
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
              SizedBox(height: 12,),
              IconButton(
                onPressed: _localize,
                icon: const Icon(Icons.my_location),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
