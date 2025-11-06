import 'package:localization_engine/src/network/model/beaconData.dart';

class Pt {
  final double x, y;
  final Beacon beacon;
  List<Beacon>? top3beacons;
  Map<Beacon, double>? beaconRadiusMap;
  Map<Beacon, double>? beaconRSSIMap;
  Pt(this.x, this.y, this.beacon, {this.top3beacons, this.beaconRadiusMap, this.beaconRSSIMap});
  @override
  String toString() => '(${x.toInt()}, ${y.toInt()})';
}