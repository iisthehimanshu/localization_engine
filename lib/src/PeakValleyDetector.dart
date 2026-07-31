import 'dart:collection';

import 'package:http/http.dart';

/// Represents a single beacon reading

class PeakValleyResult {
  final String name;
  final int peakRssi;
  final DateTime timestamp;
  final int stepsToBeMoved;
  final List<BeaconReading> readings;

  PeakValleyResult({
    required this.name,
    required this.peakRssi,
    required this.timestamp,
    required this.stepsToBeMoved,
    required this.readings
  });

  @override
  String toString() {
    return 'BeaconReading(name: $name, rssi: $peakRssi, timestamp: $timestamp)';
  }
}

class BeaconReading {
  final String device;
  final String name;
  final int rssi;
  final DateTime timestamp;

  BeaconReading({
    required this.device,
    required this.name,
    required this.rssi,
    required this.timestamp,
  });

  factory BeaconReading.fromMap(Map<String, dynamic> map) {
    return BeaconReading(
      device: map['device'] as String,
      name: map['name'] as String,
      rssi: map['rssi'] as int,
      timestamp: map['timestamp'] is DateTime
          ? map['timestamp'] as DateTime
          : map['timestamp'] is int
              ? DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int)
              : DateTime.parse(map['timestamp'].toString()),
    );
  }

  @override
  String toString() {
    return 'BeaconReading(device: $device, name: $name, rssi: $rssi, timestamp: $timestamp)';
  }
}

/// Manages RSSI history for a single beacon
class BeaconHistory {
  final String name;
  final Queue<BeaconReading> readings = Queue<BeaconReading>();
  final int maxHistorySize;

  BeaconHistory({
    required this.name,
    this.maxHistorySize = 10,
  });

  void addReading(BeaconReading reading) {
    readings.addLast(reading);

    // Keep only the most recent readings
    while (readings.length > maxHistorySize) {
      readings.removeFirst();
    }
  }

  void removeOldReadings(){
    final cutoff = DateTime.now().subtract(const Duration(seconds: 7));
    while (readings.isNotEmpty && readings.first.timestamp.isBefore(cutoff)) {
      readings.removeFirst();
    }
  }

  /// Detects peak-valley pattern: low -> high -> low
  /// Returns the peak reading if pattern is found, null otherwise

  BeaconReading? detectPeakValley() {
    if (readings.length < 3) {
      return null;
    }

    final list = readings.toList();

    // Check recent readings (last few points only)
    for (int i = list.length - 3; i >= 0 && i >= list.length - 5; i--) {
          final valley1 = list[i];
          final peak = list[i + 1];
          final valley2 = list[i + 2];

          // Check if it matches the pattern: low -> high -> low
          if (valley1.rssi < peak.rssi && valley2.rssi < peak.rssi) {
            return peak;
          }
        }

    if(readings.length < 4) return null;
    for (int i = list.length - 4; i >= 0 && i >= list.length - 6; i--) {
      final a = list[i];
      final b = list[i + 1];
      final c = list[i + 2];
      final d = list[i + 3];

      // Pattern 2: low -> equal -> equal -> low
      if (a.rssi < b.rssi && b.rssi == c.rssi && c.rssi > d.rssi) {
        return c; // or return d depending on your logic
      }
    }

    return null;
  }

  BeaconReading? get latestReading => readings.isEmpty ? null : readings.last;
}

/// Main peak-valley detector that processes beacon scan results
class PeakValleyDetector {
  final Map<String, BeaconHistory> _beaconHistories = {};
  Map<String, int> _selectedBeaconPeaks = {};
  final int historySize;
  DateTime? _flagTime;


  PeakValleyDetector({
    this.historySize = 10,
  });

  /// Process a new scan event and detect peak-valley patterns
  PeakValleyResult? processEvent(Map<String, dynamic> event) {
    // try {
      final reading = BeaconReading.fromMap(event);

      if(reading.rssi >= -65){
        // print("bestrssi ${reading.name} ${reading.rssi}");
        if(_selectedBeaconPeaks[reading.name] == null || _selectedBeaconPeaks[reading.name]! < reading.rssi){
          _selectedBeaconPeaks[reading.name] = reading.rssi;
          return PeakValleyResult(name: reading.name, peakRssi: reading.rssi, timestamp: reading.timestamp, stepsToBeMoved: 0, readings: [reading]);
        }
      }

      // Get or create history for this beacon
      final history = _beaconHistories.putIfAbsent(
        reading.name,
            () => BeaconHistory(name: reading.name, maxHistorySize: historySize),
      );

      // Add the new reading to history
      history.addReading(reading);

      _beaconHistories.forEach((key, value){
        value.removeOldReadings();
      });

      // Find all beacons with peak-valley pattern
      final candidates = <String, BeaconReading>{};

      for (final entry in _beaconHistories.entries) {
        final peakReading = entry.value.detectPeakValley();
        if (peakReading != null) {
          if(_selectedBeaconPeaks[peakReading.name] == null || _selectedBeaconPeaks[peakReading.name]! < peakReading.rssi){
            // print("peakReading found for ${peakReading.name} with peak ${peakReading.rssi}");
            candidates[entry.key] = peakReading;
          }else{
            // print("peakReading found for ${peakReading.name} with peak ${peakReading.rssi} but rejected due to past peak being ${_selectedBeaconPeaks[peakReading.name]}");
          }
        }
      }

      // If no candidates found, return null
      if (candidates.isEmpty) {
        return null;
      }

      // Find the beacon with the highest peak
      String? bestBeacon;
      int highestRssi = -85;

      for (final entry in candidates.entries) {
        if (entry.value.rssi >= highestRssi) {
          highestRssi = entry.value.rssi;
          bestBeacon = entry.key;
        }
      }

      if (bestBeacon == null) {
        return null;
      }

      // Calculate steps to be moved
      final beaconHistory = _beaconHistories[bestBeacon]!;
      final beaconHistoryReadings = beaconHistory.readings.toList();
      final read = beaconHistoryReadings.firstWhere((r)=> r.rssi == highestRssi);

      if (beaconHistoryReadings.isEmpty) {
        return null;
      }
      _selectedBeaconPeaks[bestBeacon] = highestRssi;
      // Use current time as flag time if not set
      _flagTime ??= DateTime.now();

      final duration = beaconHistoryReadings[0].timestamp.difference(_flagTime!).abs();
      final roundedSeconds = (duration.inMilliseconds / 1000).round();
      final stepsToBeMoved = (roundedSeconds / 2).round();

      final q = _beaconHistories[bestBeacon]!.readings;
      while (q.length > 1) {
        q.removeFirst();
      }

      // Update flag time for next calculation
      _flagTime = DateTime.now();

      return PeakValleyResult(name: bestBeacon, peakRssi: highestRssi, timestamp: read.timestamp, readings: beaconHistoryReadings, stepsToBeMoved: stepsToBeMoved);
    // } catch (e) {
    //   print('Error processing event: $e');
    //   return null;
    // }
  }

  /// Reset the detector state
  void reset() {
    _beaconHistories.clear();
    _flagTime = null;
  }

  /// Get current beacon count being tracked
  int get beaconCount => _beaconHistories.length;

  /// Get history for a specific beacon
  BeaconHistory? getHistory(String beaconName) {
    return _beaconHistories[beaconName];
  }
}