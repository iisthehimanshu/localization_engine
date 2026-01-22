import 'dart:async';
import 'dart:developer';
import 'package:localization_engine/localization_engine.dart';

export 'package:localization_engine/Point.dart';


class LocationTracker {
  StreamSubscription<Pt?>? _subscription;
  StreamSubscription<Map<String, List<MapEntry<DateTime, int>>>?>? _allBeaconSubscription;
  StreamSubscription<Map<String, dynamic>?>? _gpsSubscription;

  Map<String, List<MapEntry<DateTime, int>>> beaconScan = {};

  Future<void> startTracking() async {

    // 1. Listen to position updates
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

    // 2. Start scanning
    await LocalizationEngine.startScanning(
      frequency: const Duration(seconds: 6), // Optional (Default Duration(seconds: 6))
      bufferSize: const Duration(seconds: 6), // Optional (Default Duration(seconds: 6))
      timeout: const Duration(minutes: 5),
      venueName: 'IITDelhi', // Required
    );
  }

  Future<void> startBluetoothScanning() async {

    // 1. Listen to position updates
    _allBeaconSubscription = LocalizationEngine.scanResultsForAllBeacons.listen(
          (beacon) {
        if (beacon != null) {
          beacon.forEach((beaconName, list){
            beaconScan.putIfAbsent(beaconName, ()=>[]);
            beaconScan[beaconName]!.addAll(list);
          });
          log('beacon: $beacon \n\n\n\n');
          // Update UI with new position
        }
      },
      onError: (error) {
        print('beacon error: $error');
      },
    );

    // 2. Start scanning
    await LocalizationEngine.startScanning(
      venueName: 'IITDelhi', // Required
    );
  }

  Future<dynamic> localize() async {

    stop();

    double average(List<MapEntry<DateTime, int>> entries) {
      if (entries.isEmpty) return 0;

      final int sum = entries.fold(
        0,
            (total, entry) => total + entry.value,
      );

      return sum / entries.length;
    }

    Map<String, double> values = Map();
    beaconScan.forEach((beaconName, list){
      values[beaconName] = average(list);
    });
    log("localize values $values");
    beaconScan.clear();
    var result = await LocalizationEngine.localizeUsingMLModelApiCall(values);
    return result;
  }

  List<Map<String, List<int>>> peakValleyList = [];

  Future<void> peakValley() async {

    // 1. Listen to position updates
    _allBeaconSubscription = LocalizationEngine.scanResultsForAllBeacons.listen(
          (rawBeaconList) {
        if (rawBeaconList != null) {
          var beaconData = rawBeaconList.map(
                (key, value) => MapEntry(
              key,
              value.map((e) => e.value).toList(),
            ),
          );
          peakValleyList.add(beaconData);
          log('peakValley position: $rawBeaconList \n\n\n\n');
          // Update UI with new position
        }
      },
      onError: (error) {
        print('Localization error: $error');
      },
    );

    // 2. Start scanning
    await LocalizationEngine.startScanning(
      frequency: const Duration(seconds: 1), // Optional (Default Duration(seconds: 6))
      bufferSize: const Duration(seconds: 5), // Optional (Default Duration(seconds: 6))
      venueName: 'Mapmyindia', // Required
    );
  }

  void startGpsStream(){
    _gpsSubscription = LocalizationEngine.gpsStreamRaw.listen((data){
      print("gpsStream $data");
    });
    
    LocalizationEngine.startScanning(venueName: 'IITDelhi');
  }

  Future<Pt?> getCurrentLocation() async {
    try{
      return await LocalizationEngine.getCurrentLocation(venueName: 'IITDelhi');
    }catch (e){
      rethrow;
    }
  }

  Future<void> stop() async {
    // Stop scanning
    await LocalizationEngine.stopScanning();
    log(peakValleyList.toString());
    peakValleyList.clear();
    // Cancel subscription
    await _subscription?.cancel();
    await _allBeaconSubscription?.cancel();

    // Cleanup resources
    await LocalizationEngine.dispose();
  }
}