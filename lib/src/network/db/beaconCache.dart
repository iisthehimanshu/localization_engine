import 'package:hive_flutter/hive_flutter.dart';
import '../model/beaconData.dart';

/// Local Hive-backed cache for beacon data, keyed by venue name.
///
/// `Beacon` already exposes `toJson()` / `fromJson()` over plain maps, so the
/// raw json is stored directly in Hive — no TypeAdapter is required.
class BeaconCache {
  static const String _boxName = 'beacon_cache';

  static bool _hiveInitialized = false;
  static Box? _box;

  /// Lazily initializes Hive and opens the box. Safe to call repeatedly.
  Future<Box> _openBox() async {
    if (!_hiveInitialized) {
      await Hive.initFlutter();
      _hiveInitialized = true;
    }
    _box ??= await Hive.openBox(_boxName);
    return _box!;
  }

  /// Returns the cached beacons for [venueName], or `null` if nothing is cached.
  Future<List<Beacon>?> getBeacons(String venueName) async {
    try {
      final box = await _openBox();
      final raw = box.get(venueName);
      if (raw is! List || raw.isEmpty) return null;
      return raw
          .map((e) => Beacon.fromJson(Map<dynamic, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      print("BeaconCache.getBeacons failed: $e");
      return null;
    }
  }

  /// Persists [beacons] for [venueName], overwriting any previous entry.
  Future<void> saveBeacons(String venueName, List<Beacon> beacons) async {
    try {
      final box = await _openBox();
      await box.put(venueName, beacons.map((b) => b.toJson()).toList());
    } catch (e) {
      print("BeaconCache.saveBeacons failed: $e");
    }
  }

  Future<void> clear(String venueName) async {
    final box = await _openBox();
    await box.delete(venueName);
  }
}
