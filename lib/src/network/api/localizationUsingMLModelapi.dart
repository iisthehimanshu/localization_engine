import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../config/config.dart';
import '../model/beaconData.dart';


class Localizationusingmlmodelapi {
  final String baseUrl = "http://10.194.174.248:8080/navigation/localize";

  Future<dynamic> localize(Map<String, double> values) async {

    final response = await http.post(
      Uri.parse(baseUrl),
      body: jsonEncode(values),
      headers: {
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      return response.body;
    }else {
      print("response.statusCode : ${response.statusCode} - ${response.body}");
      throw Exception('Failed to localize');
    }
  }
}