class LocalizationEngineLocation {
  final BeaconPointLocation? beaconLocation;
  final GPSLocation? gpsLocation;
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

class BeaconPointLocation {
  final int x, y;
  final String bid;
  final int floor;
  final double latitude, longitude;
  final List<String> beacons;
  int? tempX, tempY;

  BeaconPointLocation({
    required this.x,
    required this.y,
    required this.bid,
    required this.floor,
    required this.latitude,
    required this.longitude,
    required this.beacons,
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
    };
  }
}

class GPSLocation {
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
