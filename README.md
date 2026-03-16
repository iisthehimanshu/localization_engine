# LocalizationEngine Plugin
A Flutter plugin for indoor localization using BLE (Bluetooth Low Energy) beacon scanning. This plugin enables real-time position tracking within configured venues.
## Installation
Add this to your package's pubspec.yaml file:
```dart
dependencies: 
  localization_engine: 
    git: 
      url: https://github.com/iisthehimanshu/localization_engine.git
      ref: v2
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

    await LocalizationEngine.startScanning(
      immediateEmit: true,
      venueName: 'IITDelhi', // Required
    );

    _subscription = LocalizationEngine.scanResultsForAllBeacons.listen(
          (event) {
        print("ble scan result $event \n");
        if(event != null){
          print(Map<String, dynamic>.from(event));
        }
      },
      onError: (error) {
        print('Localization error: $error');
      },
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
