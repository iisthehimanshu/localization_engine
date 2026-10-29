import 'package:data_repository/data_repository.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../data/data_repository_bridge.dart';
import 'model/beaconData.dart';

/// A venue's configured beacons (`/secured/venue/beacons`), through
/// Data_Repository. Main isolate only; see [dataRepository].
class VenueBeacons {
  /// Where this package cached beacons before Data_Repository, keyed by venue,
  /// as `Beacon.toJson()` maps. Read once into Data_Repository, then deleted.
  static const _oldCacheBox = 'beacon_cache';

  /// The beacons for [venueName], cache-first. A cached list is returned at
  /// once and refreshed behind it for the next run; with nothing cached the
  /// network is waited for. Throws when neither has them.
  Future<List<Beacon>> fetch(String venueName) async =>
      parse(await raw(venueName));

  /// The same, as the JSON list the backend sent, which is what
  /// LocalizationServiceConfiguration carries to the background isolate.
  Future<List<dynamic>> raw(String venueName) async {
    final venue = (await dataRepository()).venue;
    final cached = venue.cached(VenueData.venueBeacons, venueName) ??
        await _takeOldCache(venueName, venue);
    if (cached is List && cached.isNotEmpty) {
      // Stale-while-revalidate: serve the cache now, refresh it behind.
      venue.fetch(VenueData.venueBeacons, venueName).catchError((Object e) {
        print("background beacon refresh failed for $venueName: $e");
      });
      return cached;
    }
    final fresh = await venue.fetch(VenueData.venueBeacons, venueName);
    if (fresh is! List) {
      throw Exception('Failed to load beacons for $venueName');
    }
    return fresh;
  }

  static List<Beacon> parse(List<dynamic> json) => [
        for (final e in json) Beacon.fromJson(Map<dynamic, dynamic>.from(e as Map)),
      ];

  /// Moves [venueName]'s beacons out of the old `beacon_cache` box, so an
  /// install that was offline-capable stays so, and deletes that box.
  ///
  /// Not `Hive.boxExists` first: on web it opens the IndexedDB database and
  /// never closes that connection, so the delete below waited forever and
  /// the beacons were never returned. Opening an absent box just creates an
  /// empty one, which is deleted the same way. The delete isn't awaited: the
  /// beacons don't depend on it.
  static Future<List<dynamic>?> _takeOldCache(String venueName, VenueRepository venue) async {
    try {
      final box = Hive.isBoxOpen(_oldCacheBox)
          ? Hive.box(_oldCacheBox)
          : await Hive.openBox(_oldCacheBox);
      final old = box.get(venueName);
      final list = old is List && old.isNotEmpty
          ? [for (final e in old) Map<String, dynamic>.from(e as Map)]
          : null;
      if (list != null) await venue.put(VenueData.venueBeacons, venueName, list);
      box.deleteFromDisk().catchError((Object e) {
        print("old beacon cache not deleted: $e");
      });
      return list;
    } catch (e) {
      print("old beacon cache not read: $e");
      return null;
    }
  }
}
