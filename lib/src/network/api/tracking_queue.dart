import 'package:shared_preferences/shared_preferences.dart';

/// On-device FIFO of JSON-encoded tracking payloads awaiting delivery.
///
/// Stored as a string list under the same key earlier builds used, so points
/// queued before an app update are still delivered afterwards.
class TrackingQueue {
  static const _key = 'tracking_queue';

  /// Oldest points are dropped beyond this (~80 min at one point per second)
  /// so a long outage cannot grow the preferences file without bound.
  static const maxLength = 5000;

  static Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_key) ?? <String>[];
    } catch (e) {
      print('[TrackingQueue] ⚠️ Failed to load queue: $e');
      return <String>[];
    }
  }

  static Future<void> save(List<String> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (entries.isEmpty) {
        await prefs.remove(_key);
      } else {
        await prefs.setStringList(_key, entries);
      }
    } catch (e) {
      print('[TrackingQueue] ⚠️ Failed to save queue: $e');
    }
  }
}
