import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../config/config.dart';
import '../db/beaconCache.dart';
import '../model/beaconData.dart';


class beaconapi {
  final String baseUrl = "${AppConfig.baseUrl}/secured/venue/beacons?api_key=${AppConfig.apiKey}";

  final BeaconCache _cache = BeaconCache();

  /// Returns beacons for [venueName], cache-first.
  ///
  /// If Hive has data for the venue it is returned immediately and a background
  /// network refresh is fired to keep the cache fresh. On a cache miss the
  /// network is hit synchronously and the result is stored before returning.
  Future<List<Beacon>> fetchBeaconData(String venueName) async {
    final cached = await _cache.getBeacons(venueName);
    if (cached != null && cached.isNotEmpty) {
      // Stale-while-revalidate: serve cache now, refresh Hive in the background.
      _refreshInBackground(venueName);
      return cached;
    }

    // Nothing cached yet — fetch now and seed the cache.
    final beaconList = await _fetchFromApi(venueName);
    await _cache.saveBeacons(venueName, beaconList);
    return beaconList;
  }

  /// Fire-and-forget network fetch that updates the Hive cache.
  void _refreshInBackground(String venueName) {
    _fetchFromApi(venueName).then((fresh) {
      if (fresh.isNotEmpty) {
        _cache.saveBeacons(venueName, fresh);
      }
    }).catchError((e) {
      print("background beacon refresh failed for $venueName: $e");
    });
  }

  /// Raw network call. Throws on a non-200 response.
  Future<List<Beacon>> _fetchFromApi(String venueName) async {
    print("fetchBeaconData  $baseUrl");

    final Map<String, dynamic> data = {
      "venueName": venueName,
    };
    final response = await http.post(
      Uri.parse(baseUrl),
      body: jsonEncode(data),
      headers: {
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      List<dynamic> responseBody = json.decode(response.body);
      print("fetchBeaconData $responseBody");
      List<Beacon> beaconList = responseBody.map((data) => Beacon.fromJson(data)).toList();
        return beaconList;
    }else {
      print("response.statusCode : ${response.statusCode} - ${response.body}");
      throw Exception('Failed to load data');
    }
  }
}
