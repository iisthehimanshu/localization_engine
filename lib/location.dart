/// A fused location result emitted by the engine.
///
/// Either [beaconLocation] (indoor) or [gpsLocation] (outdoor fallback) may be
/// present, both, or neither. When a beacon fix exists on a non-ground floor,
/// the GPS fallback is suppressed so indoor positions take priority.
class LocalizationEngineLocation {
  /// Indoor position resolved from the nearest beacon, or `null`.
  final BeaconPointLocation? beaconLocation;

  /// GPS fallback position, or `null`.
  final GPSLocation? gpsLocation;

  /// Optional status or diagnostic message.
  final String? msg;

  LocalizationEngineLocation({
    required this.beaconLocation,
    required this.gpsLocation,
    this.msg,
  });

  factory LocalizationEngineLocation.fromJson(Map<String, dynamic> json) {
    return LocalizationEngineLocation(
      beaconLocation: json['beaconLocation'] != null
          ? BeaconPointLocation.fromJson(json['beaconLocation'])
          : null,
      gpsLocation: json['gpsLocation'] != null
          ? GPSLocation.fromJson(json['gpsLocation'])
          : null,
      msg: json['message'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'beaconLocation': beaconLocation?.toJson(),
      'gpsLocation': gpsLocation?.toJson(),
      'message': msg,
    };
  }
}

/// An indoor position derived from the nearest resolved beacon.
class BeaconPointLocation {
  /// Beacon coordinates in the venue's map space.
  final int x, y;

  /// Building id the beacon belongs to.
  final String bid;

  /// Floor of the resolved beacon.
  final int floor;

  /// Beacon latitude and longitude.
  final double latitude, longitude;

  /// Names of the beacon(s) used for this fix.
  final List<String> beacons;

  /// Representative RSSI of the resolved beacon, or `null`.
  final double? rssi;

  /// Best-floor estimate, which may differ from [floor].
  final bestFloor;

  BeaconPointLocation({
    required this.x,
    required this.y,
    required this.bid,
    required this.floor,
    required this.latitude,
    required this.longitude,
    required this.beacons,
    required this.rssi,
    required this.bestFloor
  });

  factory BeaconPointLocation.fromJson(Map<String, dynamic> json) {
    return BeaconPointLocation(
      x: json['x'],
      y: json['y'],
      bid: json['bid'],
      floor: json['floor'],
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      beacons: List<String>.from(json['beacons'] ?? []),
      rssi: json['rssi'],
      bestFloor: json['bestFloor']
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'y': y,
      'bid': bid,
      'floor': floor,
      'latitude': latitude,
      'longitude': longitude,
      'beacons': beacons,
      'rssi': rssi,
      'bestFloor':bestFloor
    };
  }
}

/// An outdoor position from the robust GPS buffer.
class GPSLocation {
  /// GPS latitude and longitude.
  final double latitude, longitude;

  GPSLocation({
    required this.latitude,
    required this.longitude,
  });

  factory GPSLocation.fromJson(Map<String, dynamic> json) {
    return GPSLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
    };
  }
}
