# localization_engine

A Flutter plugin for **real-time indoor + outdoor positioning**. It fuses BLE (Bluetooth Low Energy) beacon scanning with GPS to estimate a user's location inside configured venues, streams location updates to your app, and (optionally) reports the user's position to a backend over a WebSocket for live tracking.

The engine pulls a venue's beacon map from the iwayplus backend, scans for nearby beacons on a fixed cadence, resolves the nearest beacon / best floor, falls back to a robust GPS position when no beacon is in range, and emits a unified location object.

---

## Features

- 🔵 **BLE beacon scanning** with RSSI filtering and statistical smoothing.
- 🛰️ **GPS fusion** — falls back to a robust GPS position when no usable beacon is nearby (e.g. outdoors / ground floor).
- 🏢 **Multi-floor resolution** — picks the best floor using RSSI dominance and circle-proximity heuristics.
- 📈 **Peak/valley detection** to catch strong, transient beacon hits.
- 🔌 **Live tracking** — streams the resolved position to a backend WebSocket, with offline queueing and auto-reconnect.
- ♻️ **Restart support** to recover from permission/adapter changes.

---

## Installation

Add the package to your app's `pubspec.yaml`:

```yaml
dependencies:
  localization_engine:
    git:
      url: https://github.com/iisthehimanshu/localization_engine.git
      ref: main
```

Then:

```bash
flutter pub get
```

> **Note:** This plugin depends on [`adapter_manager`](https://github.com/iisthehimanshu/adaptermanager) (pulled in automatically), which handles Bluetooth/location permission and adapter setup.

---

## Platform Setup

### Android

Add these permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

> On Android 12+ (`BLUETOOTH_SCAN`), make sure you do **not** add `android:usesPermissionFlags="neverForLocation"` unless you intend to opt out of location derivation — this engine uses scan results for positioning.

### iOS

Add these keys to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app needs Bluetooth to detect your location indoors</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access for indoor positioning</string>
```

---

## Quick Start

Creating a `LocalizationEngine` **immediately starts** scanning, location resolution, and backend tracking — there is no separate `start()` call.

```dart
import 'dart:async';
import 'package:localization_engine/localization_engine.dart';

class LocationTracker {
  late final LocalizationEngine _engine;
  StreamSubscription<Map<String, dynamic>>? _sub;

  LocationTracker(String venueName) {
    // Construction kicks off permission checks, scanning, and tracking.
    _engine = LocalizationEngine(venueName);

    // Listen for fused location updates.
    _sub = _engine.userLocation.listen(
      (location) {
        final beacon = location['beaconLocation'];
        final gps = location['gpsLocation'];

        if (beacon != null) {
          print('Indoor → x:${beacon['x']} y:${beacon['y']} '
              'floor:${beacon['floor']} bid:${beacon['bid']}');
        } else if (gps != null) {
          print('Outdoor → ${gps['latitude']}, ${gps['longitude']}');
        }
      },
      onError: (e) => print('Localization error: $e'),
    );
  }

  Future<void> restart(String venueName) => _engine.restart(venueName: venueName);

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}
```

---

## Constructor

```dart
LocalizationEngine(
  String venueName, {
  String? baseURL,
  Map<String, Map<int, Map<String, dynamic>>>? floorConfig,
  bool skipAdapterSetup = false,
  LocalizationMode localizationMode = LocalizationMode.bothGPSandBLE,
})
```

| Parameter          | Type                                           | Description |
| ------------------ | ---------------------------------------------- | ----------- |
| `venueName`        | `String` (required)                            | Tracking context for every mode. The beacon map is fetched for this venue only when BLE is enabled. |
| `baseURL`          | `String?`                                      | Override the backend base URL. Defaults to `https://dev.iwayplus.in` in debug and `https://maps.iwayplus.in` in release. |
| `floorConfig`      | `Map<String, Map<int, Map<String, dynamic>>>?` | Per-building, per-floor tuning thresholds (see [Floor Config](#floor-config)). |
| `skipAdapterSetup` | `bool`                                         | Skip permission and adapter prompts when a foreground isolate has already completed setup. Native scans still follow `localizationMode`. |
| `localizationMode` | `LocalizationMode`                             | Select GPS only, BLE only, or both. Defaults to `bothGPSandBLE`. |

Constructing the engine triggers, in order:

1. Permission and adapter setup for the sensors selected by `localizationMode`.
2. Venue beacon-map fetch when BLE is selected.
3. Native scans and event streams for only the selected sensors.
4. The location resolution loop.
5. WebSocket connection for live tracking.

```dart
final gpsEngine = LocalizationEngine(
  'IITDelhi',
  localizationMode: LocalizationMode.onlyGps,
);

final bleEngine = LocalizationEngine(
  'IITDelhi',
  localizationMode: LocalizationMode.onlyBle,
);
```

---

## API Reference

### Streams

```dart
Stream<Map<String, dynamic>> get userLocation;
```
The primary output. Emits a fused location roughly every 3 seconds (the collection window). Each event is the JSON form of a [`LocalizationEngineLocation`](#location-models): a map with `beaconLocation`, `gpsLocation`, and `message` keys (any of which may be `null`).

```dart
Stream<Map<String, dynamic>?> get bluetoothScanResults;
```
Raw, filtered BLE scan results (RSSI magnitude kept within `55–110`). Useful for diagnostics, logging, or building a signal-strength UI.

```dart
Stream<Map<String, dynamic>?> get gpsScanResults;
```
Raw GPS samples coming from the native side.

### Properties

```dart
bool get isScanning;
```
`true` while the engine is actively scanning.

### Methods

```dart
Future<void> init({required String venueName});
```
Starts (or re-starts) scanning, the resolution loop, and tracking. Called automatically by the constructor — you normally don't invoke this yourself.

```dart
Future<void> restart({required String venueName});
```
Cleanly tears down the current run (cancels loops/subscriptions, clears the GPS buffer, reconnects the WebSocket) and re-initializes. Call this after the user grants previously-denied permissions, or to switch venues.

---

## Location Models

`userLocation` events are maps; if you want typed access, parse them with `LocalizationEngineLocation.fromJson`.

### `LocalizationEngineLocation`

| Field            | Type                    | Description                                       |
| ---------------- | ----------------------- | ------------------------------------------------- |
| `beaconLocation` | `BeaconPointLocation?`  | Indoor position from the nearest beacon, or null. |
| `gpsLocation`    | `GPSLocation?`          | GPS fallback position, or null.                   |
| `msg`            | `String?`               | Optional status/diagnostic message.               |

### `BeaconPointLocation`

| Field       | Type           | Description                                                  |
| ----------- | -------------- | ----------------------------------------------------------- |
| `x`, `y`    | `int`          | Beacon coordinates in the venue's map space.                |
| `bid`       | `String`       | Building id the beacon belongs to.                          |
| `floor`     | `int`          | Floor of the resolved beacon.                               |
| `latitude`  | `double`       | Beacon latitude.                                            |
| `longitude` | `double`       | Beacon longitude.                                           |
| `beacons`   | `List<String>` | Names of the beacon(s) used for this fix.                   |
| `rssi`      | `double?`      | Representative RSSI of the resolved beacon.                 |
| `bestFloor` | `int`          | Best-floor estimate (may differ from `floor`).             |

### `GPSLocation`

| Field       | Type     | Description     |
| ----------- | -------- | --------------- |
| `latitude`  | `double` | GPS latitude.   |
| `longitude` | `double` | GPS longitude.  |

> When a beacon fix exists on a non-ground floor, the GPS fallback is suppressed so indoor positions take priority.

---

## Floor Config

`floorConfig` lets you tune resolution thresholds per building and floor. Shape:

```
Map<BuildingId, Map<Floor, Map<SettingName, value>>>
```

```dart
final engine = LocalizationEngine(
  'IITDelhi',
  floorConfig: {
    'building_123': {
      0: {
        'initialLocalizationThreshold': 85, // min |RSSI| to accept a beacon fix
        'peakValley': -75,                  // min peak RSSI for a peak/valley hit
      },
      1: {
        'initialLocalizationThreshold': 80,
        'peakValley': -70,
      },
    },
  },
);
```

| Setting                        | Default | Meaning                                                                                         |
| ------------------------------ | ------- | ----------------------------------------------------------------------------------------------- |
| `initialLocalizationThreshold` | `85`    | A resolved beacon is discarded if its `|RSSI|` is weaker than this threshold.                    |
| `peakValley`                   | `-75`   | A peak/valley-detected beacon is only accepted if its peak RSSI exceeds this value.              |

---

## Live Tracking

Whenever a location is resolved, the engine builds a `TrackingPayload` (device id, timestamp, points, venue name) and emits it over a WebSocket (`send-tracking` event) to the configured backend. Key behaviors:

- **Device id** is derived per-platform (`device_info_plus`), with a secure random fallback.
- **Offline queueing** — payloads emitted while disconnected are stored and flushed on reconnect.
- **Auto-reconnect** — up to 5 attempts with a 2s delay.

Point vectors use short keys: `nb` (nearest beacon) and `gp` (GPS), each encoding `[x, y, lat, lng, floor, sourceType]`.

---

## Error Handling

The engine surfaces failures from `adapter_manager` during startup:

| Exception              | When                                                                  |
| ---------------------- | --------------------------------------------------------------------- |
| `PermissionException`  | Bluetooth/location permission is denied or permanently denied.        |
| `AdapterException`     | Bluetooth or location adapter is off/unavailable.                     |
| `LocalizationException`| General localization initialization failure.                          |

Listen on the `userLocation` stream's `onError` to handle these:

```dart
_engine.userLocation.listen(
  (loc) { /* ... */ },
  onError: (e) {
    if (e is PermissionException) {
      // prompt the user to grant permissions, then engine.restart(...)
    } else if (e is AdapterException) {
      // prompt the user to enable Bluetooth/Location
    }
  },
);
```

---

## Example

A runnable example lives in [`example/`](example/). It shows wiring up `LocalizationEngine`, listening to BLE/GPS streams, and exporting captured BLE data to CSV. Run it with:

```bash
cd example
flutter run
```

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
