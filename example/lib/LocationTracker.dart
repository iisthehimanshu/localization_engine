import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:localization_engine/localization_engine.dart';
import 'package:path_provider/path_provider.dart';

export 'package:localization_engine/Point.dart';


class LocationTracker {
  StreamSubscription<Pt?>? _subscription;
  StreamSubscription<Map<String, List<MapEntry<DateTime, int>>>?>? _allBeaconSubscription;
  StreamSubscription<Map<String, dynamic>?>? rawBluetoothScanResults;
  StreamSubscription<Map<String, dynamic>?>? _gpsSubscription;

  String venueName = "IITDelhi";

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
      venueName: venueName, // Required
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
      venueName: venueName, // Required
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
      venueName: venueName, // Required
    );
  }

  List<Map<String, dynamic>> bleDataList = [];
  Future<void> scanForRawBluetooth()async{
    rawBluetoothScanResults = LocalizationEngine.rawBluetoothScanResults.listen((event){
      print("ble scan result $event \n");
      if(event != null){
        bleDataList.add(Map<String, dynamic>.from(event));
      }
    });
    await LocalizationEngine.startScanning(
      immediateEmit: true,
      venueName: venueName, // Required
    );
  }

  List<DateTime> beaconCrossingTimes = [];
  void crossedBeacon(){
    beaconCrossingTimes.add(DateTime.now());
  }

  Future<void> saveBleDataToCsv() async {
    if (bleDataList.isEmpty) return;

    final headers = bleDataList.first.keys.toList();

    final rows = bleDataList.map((map) {
      return headers.map((key) => map[key]?.toString() ?? "").toList();
    }).toList();

    final csvData = [headers, ...rows];
    final csvString = const ListToCsvConverter().convert(csvData);

    Directory? directory;

    if (Platform.isAndroid) {
      directory = Directory('/storage/emulated/0/Download');
    } else if (Platform.isIOS) {
      directory = await getApplicationDocumentsDirectory(); // iOS has no Downloads folder
    }

    final file = File('${directory!.path}/ble_scan_data_${DateTime.now().millisecondsSinceEpoch}.csv');

    await file.writeAsString(csvString);

    print("✅ CSV saved in Downloads: ${file.path}");

    bleDataList.clear();
  }

  Future<void> saveDateTimeListToCsv() async {
    if (beaconCrossingTimes.isEmpty) return;

    // CSV header (single column)
    final headers = ['timestamp'];

    // Convert DateTime list to rows
    final rows = beaconCrossingTimes.map((dt) => [dt.toIso8601String()]).toList();

    final csvData = [headers, ...rows];
    final csvString = const ListToCsvConverter().convert(csvData);

    Directory? directory;

    if (Platform.isAndroid) {
      directory = Directory('/storage/emulated/0/Download');
    } else if (Platform.isIOS) {
      directory = await getApplicationDocumentsDirectory();
    }

    final file = File(
      '${directory!.path}/datetime_data_${DateTime.now().millisecondsSinceEpoch}.csv',
    );

    await file.writeAsString(csvString);

    print("✅ CSV saved: ${file.path}");

    beaconCrossingTimes.clear();
  }



  void startGpsStream(){
    _gpsSubscription = LocalizationEngine.gpsStreamRaw.listen((data){
      print("gpsStream $data");
    });
    
    LocalizationEngine.startScanning(venueName: venueName);
  }

  Future<Map<String, dynamic>?> getCurrentLocation() async {
    try{
      return await LocalizationEngine.getCurrentLocation(venueName: venueName);
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
    saveBleDataToCsv();
    saveDateTimeListToCsv();
    // Cleanup resources
    await LocalizationEngine.dispose();
  }
}