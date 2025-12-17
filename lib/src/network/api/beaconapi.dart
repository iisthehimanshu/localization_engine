import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../config/config.dart';
import '../model/beaconData.dart';


class beaconapi {
  final String baseUrl = "${AppConfig.baseUrl}/secured/venue/beacons?api_key=${AppConfig.apiKey}";

  Future<List<Beacon>> fetchBeaconData(String venueName) async {

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
      List<Beacon> beaconList = responseBody.map((data) => Beacon.fromJson(data)).toList();
        return beaconList;
    }else {
      print("response.statusCode : ${response.statusCode} - ${response.body}");
      throw Exception('Failed to load data');
    }
  }
}