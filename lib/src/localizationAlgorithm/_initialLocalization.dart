import 'dart:collection';
import 'package:flutter_compass/flutter_compass.dart';
import '../../Point.dart';
import '../network/api/beaconapi.dart';
import '../network/model/beaconData.dart';
import '_directionalLocalisation.dart';

class InitialLocalization{

  final String _venueName;
  late HashMap<String, Beacon> _apibeaconmap;

  InitialLocalization({required String venueName}) : _venueName = venueName{
    _parseBeaconMap(_venueName);
  }

  Future<Pt?> findLocation(Map<String, List<MapEntry<DateTime, int>>> beaconData) async {
    double? compassDirection = await _getCurrentCompassHeading();
    return DirectionalLocalisation().estimateIntersectionCenter(beaconData, _apibeaconmap, compassDirection??0.0);
  }

  Future<HashMap<String, Beacon>> _parseBeaconMap(String venueName) async {
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
}