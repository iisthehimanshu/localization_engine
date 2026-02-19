import 'dart:async';
import 'dart:developer';

import 'package:adapter_manager/adapter_manager.dart';
import 'package:flutter/services.dart';
import 'package:localization_engine/location.dart';
import 'package:localization_engine/src/GPS/GPSBuffer.dart';
import 'package:localization_engine/src/localizationAlgorithm/_triangulationlLocalisation.dart';
import 'package:localization_engine/src/network/api/localizationUsingMLModelapi.dart';

import 'LocalizationException.dart';
import 'Point.dart';
import 'initialLocalization.dart';

export 'Point.dart';
export 'LocalizationException.dart';

export 'package:adapter_manager/adapter_manager.dart';
export 'package:adapter_manager/AdapterException.dart';
export 'package:adapter_manager/UI/LocationServicesDialog.dart';

class LocalizationEngine {
  static const MethodChannel _methodChannel = MethodChannel('localization_engine');
  static const EventChannel _bleEventChannel = EventChannel('ble_scan_stream');
  static const EventChannel _gpsEventChannel = EventChannel('gps_scan_stream');
  static InitialLocalization? _localization;
  static StreamSubscription<dynamic>? _gpsSubscription;
  static final gpsBuffer = GPSBuffer();

  static Future<Map<String, dynamic>> _checkAllStatus() async {
    final result = await AdapterManager.setupAllPermissionsAndAdapters();
    return result;
    if (result['success']) {
      // _showSnackBar('All setup complete!');
    } else {
      // _showSnackBar('${result['errors']}');
    }
  }

  static Future<void> _setVenue({required String venueName})async{
    _localization = InitialLocalization(venueName);
    _localization?.parseBeaconMap(venueName);
  }

  /// Initialize scanning with custom params
  static Future<void> _initializeScanning({
    required Duration? frequency,
    required Duration? bufferSize,
    required Duration? timeout, // null means no timeout
    required bool immediateEmit,
  }) async {
    final params = {
      'frequency': frequency?.inMilliseconds,
      'bufferSize': bufferSize?.inMilliseconds,
      'timeout': timeout?.inMilliseconds,
      'immediateEmit': immediateEmit
    };
    await _methodChannel.invokeMethod('initializeScan', params);
  }

  static bool _isScanning = false;
  static bool get isScanning => _isScanning;

  static Future<void> startScanning({
     Duration? frequency,
     Duration? bufferSize,
     Duration? timeout, // null means no timeout
     bool immediateEmit = false, // null means no timeout
     required String venueName
  }) async {
    if (_isScanning) {
      throw StateError('Scanning is already in progress');
    }
    var adapterState = await _checkAllStatus();
    print("adapterState $adapterState");
    if(adapterState['success']){
      await _setVenue(venueName: venueName);
      _initializeScanning(frequency: frequency, bufferSize: bufferSize, timeout: timeout, immediateEmit: immediateEmit);
      await _methodChannel.invokeMethod('startGpsScan');
      await _methodChannel.invokeMethod('startScan');
      _isScanning = true;
    }else if(adapterState['PermanentlyDenied']){
      throw PermissionException(adapterState['errors'].first);
    }else{
      throw AdapterException(adapterState['errors'].first);
    }
  }

  static Future<void> stopScanning() async {
    await _methodChannel.invokeMethod('stopScan');
    await _methodChannel.invokeMethod('stopGpsScan');
    _isScanning = false;
  }

  /// Stream to listen to periodic scan results
  /// Listen to BLE scan results as a stream of list of devices
  static Stream<Pt?> get scanResults =>
      _bleEventChannel.receiveBroadcastStream().asyncMap((event) async {
        try {
        final List<dynamic> rawList = event as List;

        final Map<String, List<MapEntry<DateTime, int>>> formattedData = {};

        for (var entry in rawList) {
          final map = Map<String, dynamic>.from(entry);
          final device = map['name'] as String;
          if(!device.toLowerCase().contains("iw")) continue;
          final timestamp = DateTime.fromMillisecondsSinceEpoch(map['timestamp']);
          final rssi = map['rssi'] as int;
          // print("scanResults map $map");

          formattedData.putIfAbsent(device, () => []);
          formattedData[device]!.add(MapEntry(timestamp, rssi));
        }
          return await _localization?.findLocation(formattedData);
        } catch (e) {
          print('Error processing scan result: $e');
          return null; // or rethrow based on your needs
        }
      }).handleError((error) {
        print('Stream error: $error');
      });

  static Stream<Map<String, dynamic>?> get rawBluetoothScanResults =>
      _bleEventChannel.receiveBroadcastStream().asyncMap((event) async {
        try {
          final List<dynamic> rawList = event as List;
          for(var entry in rawList){
            final map = Map<String, dynamic>.from(entry);
            return map;
          }
        } catch (e) {
          print('Error processing rawBluetoothScanResults scan result: $e');
          return null; // or rethrow based on your needs
        }
      }).handleError((error) {
        print('Stream error: $error');
      });

  /// Stream to listen to periodic scan results
  /// Listen to BLE scan results as a stream of list of devices
  static Stream<Map<String, List<MapEntry<DateTime, int>>>?> get scanResultsForAllBeacons =>
      _bleEventChannel.receiveBroadcastStream().asyncMap((event) async {
        try {
          final List<dynamic> rawList = event as List;

          final Map<String, List<MapEntry<DateTime, int>>> formattedData = {};

          for (var entry in rawList) {
            final map = Map<String, dynamic>.from(entry);
            final device = map['name'] as String;
            if(!device.toLowerCase().contains("iw")) continue;
            final timestamp = DateTime.fromMillisecondsSinceEpoch(map['timestamp']);
            final rssi = map['rssi'] as int;
            // print("scanResults map $map");

            formattedData.putIfAbsent(device, () => []);
            formattedData[device]!.add(MapEntry(timestamp, rssi));
          }
          return formattedData;
          return _localization?.filterBeacons(formattedData);
        } catch (e) {
          print('Error processing scan result: $e');
          return null; // or rethrow based on your needs
        }
      }).handleError((error) {
        print('Stream error: $error');
      });

  static Future<dynamic> localizeUsingMLModelApiCall(Map<String, double> values) async {
    print("localizeUsingMLModel $values");
    dynamic result = await Localizationusingmlmodelapi().localize(values);
    return result;
  }

  static Stream<Map<String, dynamic>?> get gpsStreamRaw =>
      _gpsEventChannel.receiveBroadcastStream().asyncMap((event) async {
        return Map<String, dynamic>.from(event as Map);
      }).handleError((error) {
        print('gpsStreamRaw error: $error');
      });

  static Future<Map<String, dynamic>?> getCurrentLocation({required String venueName}) async {
    try {
      await startScanning(
        frequency: const Duration(seconds: 5),
        bufferSize: const Duration(seconds: 6),
        timeout: const Duration(seconds: 7),
        venueName: venueName,
      );

      await _gpsSubscription?.cancel();


      _gpsSubscription = _gpsEventChannel.receiveBroadcastStream().listen((data) {
        print("gpsSubscription $data");
        gpsBuffer.add(data['latitude'], data['longitude']);
      },
          onError: (error) {
            print('GPS stream error: $error');
          });

      print("gpsSubscription:${_gpsSubscription}");

      // Wait for BLE event
      final event = await _bleEventChannel
          .receiveBroadcastStream()
          .where((event) => event is List && event.isNotEmpty)
          .first;

      // log("getCurrentLocation event $event");

      final List<dynamic> rawList = event as List;
      Map<String, List<MapEntry<DateTime, int>>> formattedData = {};

      for (var entry in rawList) {
        final map = Map<String, dynamic>.from(entry);
        final device = map['name'] as String;

        if (!device.toLowerCase().contains("iw")) continue;

        final timestamp = DateTime.fromMillisecondsSinceEpoch(map['timestamp']);
        final rssi = map['rssi'] as int;

        formattedData.putIfAbsent(device, () => []);
        formattedData[device]!.add(MapEntry(timestamp, rssi));
      }

      if(_localization != null){
        formattedData = _localization!.filterBeacons(formattedData);
      }

      String? bestBeacon;
      double bestAvg = 90;
      BeaconPointLocation? beaconLocation;

      formattedData.forEach((beaconId, entries) {
        if (entries.isEmpty) return;

        var avg = entries
            .map((e) => e.value)
            .reduce((a, b) => a + b) /
            entries.length;

        avg = avg.abs();

        if (avg < bestAvg) {
          bestAvg = avg;
          bestBeacon = beaconId;
        }
      });

      log("nearestBeacon:${bestBeacon} ${bestAvg}");
      if(bestBeacon != null){
        var beacon = _localization?.getBeaconDetails(bestBeacon!);
        if(beacon != null){
          beaconLocation = BeaconPointLocation(x: beacon.coordinateX!, y: beacon.coordinateY!, bid: beacon.buildingID!, floor: beacon.floor!, latitude: double.parse(beacon.properties!.latitude!), longitude: double.parse(beacon.properties!.longitude!), beacons: [bestBeacon!]);
        }
      }
      // else{
      //   // Calculate avg RSSI per beacon
      //   final List<MapEntry<String, double>> avgList = [];
      //
      //   formattedData.forEach((beaconId, entries) {
      //     if (entries.isEmpty) return;
      //
      //     final avg = entries
      //         .map((e) => e.value)
      //         .reduce((a, b) => a + b) /
      //         entries.length;
      //
      //     avgList.add(MapEntry(beaconId, avg));
      //   });
      //
      //   // Sort by nearest (lowest avg RSSI)
      //   avgList.sort((a, b) => a.value.compareTo(b.value));
      //
      //   // Take top 3
      //   final top3 = avgList.take(3).toList();
      //   log("Top 3 beacons: $top3");
      //   var topBeacon = _localization?.getBeaconDetails(top3.first.key);
      //
      //   var list = top3.map((b)
      //   {
      //     var beaconDetails = _localization?.getBeaconDetails(b.key);
      //     return Beacon(id: b.key, location: Point2D(beaconDetails!.coordinateX!.toDouble(), beaconDetails.coordinateY!.toDouble()), rssi: b.value);
      //   }).toList();
      //
      //   list.forEach((item){
      //     print("beacon ${item.toString()}");
      //   });
      //
      //   TriangulationResult triangulationResult = triangulate(list);
      //   print(" triangulationResult.estimatedPosition.x ${ triangulationResult.estimatedPosition.x}");
      //   beaconLocation = BeaconPointLocation(x: triangulationResult.estimatedPosition.x.toInt(), y: triangulationResult.estimatedPosition.y.toInt(), bid: topBeacon!.buildingID!, floor: topBeacon.floor!, latitude: double.parse(topBeacon.properties!.latitude!), longitude: double.parse(topBeacon.properties!.longitude!), beacons: top3.map((b)=>b.key).toList());
      // }

      GPSLocation? gpsLocation;
      List<double>? gpsBufferLocation = gpsBuffer.getRobustPosition();
      print("gpsLocation $gpsBufferLocation");
      if(gpsBufferLocation != null && gpsBufferLocation.isNotEmpty){
        gpsLocation = GPSLocation(latitude: gpsBufferLocation[0], longitude: gpsBufferLocation[1]);
      }

      LocalizationEngineLocation location = LocalizationEngineLocation(beaconLocation: beaconLocation, gpsLocation: gpsLocation);

      return location.toJson();

    }on StateError{
      await stopScanning();
      GPSLocation? gpsLocation;
      List<double>? gpsBufferLocation = gpsBuffer.getRobustPosition();
      print("gpsLocation $gpsBufferLocation");
      if(gpsBufferLocation != null && gpsBufferLocation.isNotEmpty){
        gpsLocation = GPSLocation(latitude: gpsBufferLocation[0], longitude: gpsBufferLocation[1]);
      }

      LocalizationEngineLocation location = LocalizationEngineLocation(beaconLocation: null, gpsLocation: gpsLocation);
      return location.toJson();

    }on AdapterException{
      rethrow;
    }on PermissionException{
      rethrow;
    }catch (_){
      return null;
    }finally{
      await stopScanning();
    }
  }


  static Future<void> dispose() async {
    await stopScanning();
    _localization = null;
    _isScanning = false;
  }
}

