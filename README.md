# localization_engine

A Flutter plugin for **real-time indoor + outdoor positioning**. It calculates quality-scored BLE (Bluetooth Low Energy) and GPS estimates, selects the best available source, streams location updates to your app, and reports the user's position to a backend over a WebSocket for live tracking.

The engine pulls a venue's beacon map from the iwayplus backend, scans for nearby beacons, resolves a robust indoor position and floor, calculates an accuracy-weighted GPS position, and emits a unified location object with source and confidence diagnostics.

---

## Features

- 🔵 **BLE beacon scanning** with RSSI filtering and statistical smoothing.
- 🛰️ **Quality-aware GPS selection** — filters complete GPS samples by accuracy and geographic outliers, then prefers the stronger source.
- 🏢 **Multi-floor resolution** — selects building and floor with signal evidence, hysteresis, dwell time, and confidence reporting.
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
  DateTime? stopAt,
  Map<String, BeaconSignalCalibration> beaconCalibrations = const {},
  Map<String, double> pixelsPerMeterByFloor = const {},
  Map<String, FloorGeoTransform> geoTransformsByFloor = const {},
  LocalPositionConstraint? positionConstraint,
  Duration surroundingDeviceScanInterval = const Duration(seconds: 10),
})
```

| Parameter          | Type                                           | Description |
| ------------------ | ---------------------------------------------- | ----------- |
| `venueName`        | `String` (required)                            | Tracking context for every mode. The beacon map is fetched for this venue only when BLE is enabled. |
| `baseURL`          | `String?`                                      | Override the backend base URL. Defaults to `https://dev.iwayplus.in` in debug and `https://maps.iwayplus.in` in release. |
| `floorConfig`      | `Map<String, Map<int, Map<String, dynamic>>>?` | Per-building, per-floor tuning thresholds (see [Floor Config](#floor-config)). |
| `skipAdapterSetup` | `bool`                                         | Skip permission and adapter prompts when a foreground isolate has already completed setup. Native scans still follow `localizationMode`. |
| `localizationMode` | `LocalizationMode`                             | Select GPS only, BLE only, or both. Defaults to `bothGPSandBLE`. |
| `stopAt` | `DateTime?` | Optional absolute native-session deadline. |
| `beaconCalibrations` | `Map<String, BeaconSignalCalibration>` | Per-beacon RSSI offset and reliability, keyed by beacon name. |
| `pixelsPerMeterByFloor` | `Map<String, double>` | Physical map scale keyed as `buildingId:floor`; defaults to 4 pixels/metre. |
| `geoTransformsByFloor` | `Map<String, FloorGeoTransform>` | Surveyed affine pixel-to-geographic transform keyed as `buildingId:floor`. |
| `positionConstraint` | `LocalPositionConstraint?` | Optional projection onto the floor's walkable geometry. |
| `surroundingDeviceScanInterval` | `Duration` | Positive RSSI aggregation window for non-`IW` BLE advertisers. Defaults to 10 seconds. |

Constructing the engine triggers, in order:

1. Permission and adapter setup for the sensors selected by `localizationMode`.
2. Venue beacon-map fetch when BLE is selected.
3. Native scans and event streams for only the selected sensors.
4. The location resolution loop.
5. WebSocket connection for live tracking.

### Surrounding BLE devices

When BLE is enabled, `surroundingDeviceSnapshots` emits one map after every
`surroundingDeviceScanInterval`. Each map contains one median RSSI measurement
per non-`IW` BLE advertiser found during that window:

```dart
final engine = LocalizationEngine(
  'Iwayplus',
  surroundingDeviceScanInterval: const Duration(seconds: 20),
);

engine.surroundingDeviceSnapshots.listen((devices) {
  // Example: {'A1:B2:C3:D4:E5:F6': -63}
});
```

The completed map is attached once to the next existing `send-tracking`
payload as `devices: {deviceId: rssi}`. Tracking messages sent before the
window completes omit `devices`, so stale snapshots are not repeated. The
interval must be greater than zero and is persisted for background sessions.

These keys are platform BLE identifiers, not permanent IDs, and may rotate.
The generic scan also cannot prove an advertiser is a phone. Identifying only
other host-app installations requires a dedicated advertised BLE service UUID
and an application-controlled rotating token.

```dart
final gpsEngine = LocalizationEngine(
  'IITDelhi',
  localizationMode: LocalizationMode.onlyGps,
);

final bleEngine = LocalizationEngine(
  'IITDelhi',
  localizationMode: LocalizationMode.onlyBle,
  beaconCalibrations: const {
    'IW26020521': BeaconSignalCalibration(
      rssiOffset: 3.5,
      reliability: 0.9,
    ),
  },
  pixelsPerMeterByFloor: const {'building-id:0': 4.2},
);
```

Each `userLocation` event also includes `primarySource` and `confidence`.
BLE results expose `floorConfidence`, `floorMargin`, `rank1Weight`,
`beaconCount`, `motionState`, raw coordinates, final smoothed `jumpPixels`, and
`rawCandidateJumpPixels` for diagnosing RSSI noise. GPS results
expose estimated `accuracy`, accepted `sampleCount`, confidence, and timestamp.

## Background localization

Use `LocalizationBackgroundService` when localization must continue in an
Android foreground-service isolate. Permission and adapter prompts are handled
in the foreground before the service starts, while the background isolate
restores the persisted venue, mode, base URL, and absolute stop deadline.
Serializable beacon calibrations, floor scales, and geographic transforms are
also restored. A `positionConstraint` callback is host-isolate-only and cannot
be persisted across a background-isolate restart.

```dart
await LocalizationBackgroundService.start(
  venueName: 'Iwayplus',
  baseUrl: 'https://dev.iwayplus.in',
  mode: LocalizationMode.bothGPSandBLE,
  duration: const Duration(minutes: 30),
);

final running = await LocalizationBackgroundService.isRunning;
final configuration =
    await LocalizationBackgroundService.activeConfiguration;
final remaining = await LocalizationBackgroundService.remainingDuration;

await LocalizationBackgroundService.stop();
```

Omit `duration` to run indefinitely. Zero and negative durations are rejected.
Calling `stop()` repeatedly is safe, and a repeated `start()` replaces the
currently running service configuration.

### iOS host configuration

An iOS host must enable the **Location updates** and **Uses Bluetooth LE
accessories** background modes and provide location
and Bluetooth usage descriptions. The bundled example contains the required
`Info.plist` entries. GPS uses native Core Location background delivery; BLE
uses Core Bluetooth state restoration and best-effort background discovery.
iOS controls BLE discovery frequency and does not relaunch an app after the
user explicitly force-quits it.

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
