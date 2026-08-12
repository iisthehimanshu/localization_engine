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

  /// Source the engine currently considers the most trustworthy.
  final String? primarySource;

  /// Overall quality label for [primarySource]: high, medium, or low.
  final String? confidence;

  LocalizationEngineLocation({
    required this.beaconLocation,
    required this.gpsLocation,
    this.msg,
    this.primarySource,
    this.confidence,
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
      primarySource: json['primarySource'],
      confidence: json['confidence'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'beaconLocation': beaconLocation?.toJson(),
      'gpsLocation': gpsLocation?.toJson(),
      'message': msg,
      'primarySource': primarySource,
      'confidence': confidence,
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

  /// Floor that is currently accumulating evidence to replace [floor], or
  /// `null` when the floor is settled.
  ///
  /// The engine deliberately holds [floor] for a few seconds after a rival
  /// floor takes the lead, so that beacons from the floor below — which come
  /// into view well before the user does on a ramp or stairwell — can't flip
  /// the map underneath them. A non-null value means "a change is in
  /// progress": pre-load this floor's plan if you like, but keep rendering
  /// against [floor] until it commits.
  final int? pendingFloor;

  /// Overall estimator quality and the evidence behind it.
  final String? confidence;
  final String? floorConfidence;
  final double? floorMargin;
  final double? rank1Weight;
  final int? beaconCount;
  final String? motionState;
  final double? rawX;
  final double? rawY;
  final double? jumpPixels;

  DateTime timeStamp;

  BeaconPointLocation({
    required this.x,
    required this.y,
    required this.bid,
    required this.floor,
    required this.latitude,
    required this.longitude,
    required this.beacons,
    required this.rssi,
    required this.bestFloor,
    required this.timeStamp,
    this.pendingFloor,
    this.confidence,
    this.floorConfidence,
    this.floorMargin,
    this.rank1Weight,
    this.beaconCount,
    this.motionState,
    this.rawX,
    this.rawY,
    this.jumpPixels,
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
        bestFloor: json['bestFloor'],
        pendingFloor: json['pendingFloor'],
        confidence: json['confidence'],
        floorConfidence: json['floorConfidence'],
        floorMargin: (json['floorMargin'] as num?)?.toDouble(),
        rank1Weight: (json['rank1Weight'] as num?)?.toDouble(),
        beaconCount: json['beaconCount'],
        motionState: json['motionState'],
        rawX: (json['rawX'] as num?)?.toDouble(),
        rawY: (json['rawY'] as num?)?.toDouble(),
        jumpPixels: (json['jumpPixels'] as num?)?.toDouble(),
        timeStamp: DateTime.now());
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
      'bestFloor': bestFloor,
      'pendingFloor': pendingFloor,
      'confidence': confidence,
      'floorConfidence': floorConfidence,
      'floorMargin': floorMargin,
      'rank1Weight': rank1Weight,
      'beaconCount': beaconCount,
      'motionState': motionState,
      'rawX': rawX,
      'rawY': rawY,
      'jumpPixels': jumpPixels,
    };
  }
}

/// An outdoor position from the robust GPS buffer.
class GPSLocation {
  /// GPS latitude and longitude.
  final double latitude, longitude;
  final double? accuracy;
  final int? sampleCount;
  final String? confidence;
  final DateTime? timeStamp;

  GPSLocation({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.sampleCount,
    this.confidence,
    this.timeStamp,
  });

  factory GPSLocation.fromJson(Map<String, dynamic> json) {
    return GPSLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      sampleCount: json['sampleCount'],
      confidence: json['confidence'],
      timeStamp: json['timestamp'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'sampleCount': sampleCount,
      'confidence': confidence,
      'timestamp': timeStamp?.millisecondsSinceEpoch,
    };
  }
}
