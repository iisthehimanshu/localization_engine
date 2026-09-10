import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:localization_engine/src/network/api/localizationUsingMLModelapi.dart';
import 'Point.dart';
import 'src/network/api/beaconapi.dart';
import 'src/network/model/beaconData.dart';
import 'src/localizationAlgorithm/_directionalLocalisation.dart';

class InitialLocalization{

  final String _venueName;
  HashMap<String, Beacon> _apibeaconmap = HashMap();

  HashMap<String, Beacon> get apibeaconmap => _apibeaconmap;

  /// [headingProvider] supplies the device heading in degrees.
  ///
  /// Defaults to `flutter_compass`, which has no web implementation — so a
  /// bundle running inside the host app's WebView passes a provider backed by
  /// the scan source's heading stream instead.
  InitialLocalization(this._venueName, {Future<double?> Function()? headingProvider})
      : _headingProvider = headingProvider;

  final Future<double?> Function()? _headingProvider;

  Future<Pt?> findLocation(Map<String, List<MapEntry<DateTime, int>>> beaconData) async {
    double? compassDirection = await _getCurrentCompassHeading();
    return DirectionalLocalisation().estimateIntersectionCenter(beaconData, _apibeaconmap, compassDirection??0.0);
  }

  Beacon? getBeaconDetails(String beaconName){
    Beacon? beacon = _apibeaconmap[beaconName];
    print("apibeaconMap $_apibeaconmap");
    return beacon;
  }

  Map<String, List<MapEntry<DateTime, int>>> filterBeacons(Map<String, List<MapEntry<DateTime, int>>> beaconList){
    if(_apibeaconmap.isEmpty) return beaconList;
    Map<String, List<MapEntry<DateTime, int>>> filteredList = Map();
    beaconList.forEach((beaconName, data){
      if(_apibeaconmap[beaconName] != null){
        filteredList[beaconName] = data;
      }
    });
    return filteredList;
  }

  Future<HashMap<String, Beacon>> parseBeaconMap(String venueName) async {
    if(_venueName == venueName && _apibeaconmap.isNotEmpty) return _apibeaconmap;
    List<dynamic> beaconList = await beaconapi().fetchBeaconData(venueName);
    for (var beacon in beaconList) {
      if (beacon.name != null) {
        _apibeaconmap[beacon.name!] = beacon;
      }
    }
    return _apibeaconmap;
  }

  Future<double?> _getCurrentCompassHeading() async {
    final provided = await _headingProvider?.call();
    if (provided != null) return provided;

    // Falls back to the sensor plugin on native hosts. Both guards matter:
    // `events` is null wherever the plugin has no implementation, and the
    // stream can simply never emit on a device with no usable magnetometer —
    // which used to hang findLocation forever rather than localise without a
    // heading.
    final events = FlutterCompass.events;
    if (events == null) return null;
    try {
      final compassEvent =
          await events.first.timeout(const Duration(seconds: 2));
      return compassEvent.heading; // in degrees, 0-360
    } on TimeoutException {
      debugPrint('No compass heading available within 2s; localising without one.');
      return null;
    }
  }

  Future<dynamic> localizeUsingMLModel(Map<String, double> values) async {
    print("localizeUsingMLModel $values");
    dynamic result = await Localizationusingmlmodelapi().localize(values);
    return result;
  }
}