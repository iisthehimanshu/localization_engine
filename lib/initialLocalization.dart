import 'dart:collection';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:localization_engine/src/network/api/localizationUsingMLModelapi.dart';
import 'Point.dart';
import 'src/network/api/beaconapi.dart';
import 'src/network/model/beaconData.dart';
import 'src/localizationAlgorithm/_directionalLocalisation.dart';

class InitialLocalization{

  final String _venueName;
  HashMap<String, Beacon> _apibeaconmap = HashMap();

  InitialLocalization(this._venueName);

  Future<Pt?> findLocation(Map<String, List<MapEntry<DateTime, int>>> beaconData) async {
    double? compassDirection = await _getCurrentCompassHeading();
    return DirectionalLocalisation().estimateIntersectionCenter(beaconData, _apibeaconmap, compassDirection??0.0);
  }

  Pt bestBeacon(String beaconName){
    Beacon? beacon = _apibeaconmap![beaconName];
    print("beacon:${beacon}");
    return Pt(beacon: beacon!,x: beacon.coordinateX!.toDouble(),y: beacon.coordinateY!.toDouble());
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
    final compassEvent = await FlutterCompass.events!.first;
    return compassEvent.heading; // in degrees, 0-360
  }

  Future<dynamic> localizeUsingMLModel(Map<String, double> values) async {
    print("localizeUsingMLModel $values");
    dynamic result = await Localizationusingmlmodelapi().localize(values);
    return result;
  }
}