import 'src/network/model/beaconData.dart';

class Pt {
  final double? x, y;
  final double? latitude, longitude;
  final Beacon? beacon;
  List<Beacon>? top3beacons;
  Map<Beacon, double>? beaconRadiusMap;
  Map<Beacon, double>? beaconRSSIMap;
  Pt({this.x, this.y, this.beacon, this.top3beacons, this.beaconRadiusMap, this.beaconRSSIMap, this.latitude, this.longitude});
  @override
  String toString() => '(${x?.toInt()}, ${y?.toInt()}) ($latitude, $longitude)';
}

class BeaconPosition{
  final double x, y;
  final Beacon beacon;
  List<Beacon>? top3beacons;
  Map<Beacon, double>? beaconRadiusMap;
  Map<Beacon, double>? beaconRSSIMap;
  BeaconPosition(this.x, this.y, this.beacon, {this.top3beacons, this.beaconRadiusMap, this.beaconRSSIMap});
  @override
  String toString() => '(${x?.toInt()}, ${y?.toInt()})';
}

class GPSPosition{
  final double latitude, longitude;
  GPSPosition(this.latitude, this.longitude);
  @override
  String toString() => '($latitude, $longitude)';
}