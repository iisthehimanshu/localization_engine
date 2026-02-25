import 'dart:convert';

import 'package:flutter/foundation.dart';

class AppConfig {

  static String? url;

  static String get baseUrl {
    if(url != null){
      return url!;
    }

    if (kDebugMode) {
      return 'https://dev.iwayplus.in';
    } else {
      return 'https://dev.iwayplus.in';
    }
  }

  static String get encryptionKey {
    if (baseUrl == 'https://dev.iwayplus.in') {
      return 'rtyHuAxNZPIyx1YMCXQJcx6dX1ev0/svf79IWd1teX0=';
    } else {
      //this api key is for udit soni
      return 'TtcuUZ1JK26FJ7rxqp36OCQflajb1RYIIiv481l764k=';
    }
  }

  static String get Authorization {
    if (baseUrl == 'https://dev.iwayplus.in') {
      return 'd52f6110-c69a-11ef-aa4e-e7aa7912987a';
    } else {
      return '023357e0-cf4f-11ef-8c00-45832f202b2e';
    }
  }

  static String get apiKey {
    if (baseUrl == 'https://dev.iwayplus.in') {
      return '7cc62870-d67e-11f0-91ed-2f0eb903e7db';
    } else {
      //this api key is for udit soni
      return '63a0a740-cc23-11f0-b58c-17043284b6b2';
    }
  }

  static String appID = "com.iwayplus.rni";

}

String encryptDecrypt(String input) {
  String key = AppConfig.encryptionKey;
  StringBuffer result = StringBuffer();
  for (int i = 0; i < input.length; i++) {
// XOR each character of the input with the corresponding character of the key
    result.writeCharCode(input.codeUnitAt(i) ^ key.codeUnitAt(i % key.length));
  }
  return result.toString();
}

String EncryptedbodyForApi(Map<String, dynamic> data){
  final jsonEncoder = JsonEncoder();
  var finalData=jsonEncoder.convert(data);
  final encryptedData = encryptDecrypt(finalData);
  return json.encode({"encryptedData":encryptedData});
}

