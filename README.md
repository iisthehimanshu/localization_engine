# LocalizationEngine Plugin
A Flutter plugin for indoor localization using BLE (Bluetooth Low Energy) beacon scanning. This plugin enables real-time position tracking within configured venues.
## Installation
Add this to your package's pubspec.yaml file:
```dart
dependencies: 
  localization_engine: 
    git: 
      url: https://github.com/iisthehimanshu/localization_engine.git
      ref: main
```

Then run:
```dart
flutter pub get
```

## Platform Setup
### Android
Add the following permissions to your AndroidManifest.xml:
```dart
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

### iOS
Add the following to your Info.plist:
```dart
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app needs Bluetooth to detect your location indoors</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access for indoor positioning</string>
```
## Usage
### Basic Implementation
```dart
import 'dart:async';
import 'package:localization_engine/localization_engine.dart';

class LocationTracker {
  StreamSubscription<Pt?>? _subscription;

  Future<void> start() async {
    // 1. Initialize the engine with your venue
     LocalizationEngine.setVenue(
      venueName: 'MyOffice'
    );

    // 2. Listen to position updates
    _subscription = LocalizationEngine.scanResults.listen(
      (position) {
        if (position != null) {
          print('Current position: $position');
          // Update UI with new position
        }
      },
      onError: (error) {
        print('Localization error: $error');
      },
    );

    // 3. Start scanning
    await LocalizationEngine.startScanning(
      frequency: const Duration(seconds: 6), // Optional (Default Duration(seconds: 6))
      bufferSize: const Duration(seconds: 6), // Optional (Default Duration(seconds: 6))
      timeout: const Duration(minutes: 5), // Optional
);
  }

  Future<void> stop() async {
    // Stop scanning
    await LocalizationEngine.stopScanning();
    
    // Cancel subscription
    await _subscription?.cancel();
    
    // Cleanup resources
    await LocalizationEngine.dispose();
  }
}
```
### Complete Example
```dart
import 'package:flutter/material.dart';
import 'package:localization_engine/localization_engine.dart';
import 'dart:async';

class IndoorLocationScreen extends StatefulWidget {
  @override
  _IndoorLocationScreenState createState() => _IndoorLocationScreenState();
}

class _IndoorLocationScreenState extends State<IndoorLocationScreen> {
  StreamSubscription<Pt?>? _subscription;
  Pt? _currentPosition;
  bool _isScanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeLocalization();
  }

  Future<void> _initializeLocalization() async {
    try {
      await LocalizationEngine.initialize(
        venueName: 'MyVenue',
        frequency: Duration(seconds: 5),
        bufferSize: Duration(seconds: 6),
      );

      _subscription = LocalizationEngine.scanResults.listen(
        (position) {
          setState(() {
            _currentPosition = position;
            _error = null;
          });
        },
        onError: (error) {
          setState(() {
            _error = error.toString();
          });
        },
      );
    } catch (e) {
      setState(() {
        _error = 'Initialization failed: $e';
      });
    }
  }

  Future<void> _toggleScanning() async {
    try {
      if (_isScanning) {
        await LocalizationEngine.stopScanning();
      } else {
        await LocalizationEngine.startScanning();
      }
      setState(() {
        _isScanning = !_isScanning;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to toggle scanning: $e';
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    LocalizationEngine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Indoor Location')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_error != null)
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Colors.red),
                ),
              ),
            Text(
              _currentPosition != null
                  ? 'Position: $_currentPosition'
                  : 'No position data',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _toggleScanning,
              child: Text(_isScanning ? 'Stop Scanning' : 'Start Scanning'),
            ),
            SizedBox(height: 10),
            Text(
              _isScanning ? 'Scanning...' : 'Not scanning',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
```
## API Reference
### Parameters:
venueName - Identifier for the venue/location
frequency - How often to scan for BLE devices (default: 6 seconds)
bufferSize - Size of the rolling buffer for measurements (default: 6 seconds)
timeout - Optional timeout for scanning operations (null = no timeout)
Throws: LocalizationException if initialization fails
### Start Scanning
```dart
Future<void> startScanning()
```
Starts BLE scanning. Requires setVenue() to be called first.
#### Throws:
StateError if not initialized
LocalizationException on platform errors
### Stop Scanning
```dart
Future<void> stopScanning()
```
Stops the BLE scanning process.
### Position Stream
```dart
Stream<Pt?> get scanResults
```
Stream that emits position updates. Returns null if position cannot be determined.
#### Usage:
```dart
LocalizationEngine.scanResults.listen(
  (position) {
    // Handle position update
  },
  onError: (error) {
    // Handle errors
  },
);
```
### Check Scanning State
```dart
bool get isScanning
```
- Returns true if currently scanning, false otherwise.
## Cleanup
```dart
Future<void> dispose()
```
Stops scanning and releases all resources. Should be called when done using the engine.
## Changelog
### 1.0.0
- Initial release
- BLE scanning with configurable parameters
- Stream-based position updates
- Multi-venue support
