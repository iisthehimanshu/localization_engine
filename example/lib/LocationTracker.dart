import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:localization_engine/localization_engine.dart';
import 'package:path_provider/path_provider.dart';

export 'package:localization_engine/Point.dart';


class LocationTracker {
  String venueName;
  late LocalizationEngine newLocalizationEngine;

  LocationTracker(this.venueName){
    newLocalizationEngine = LocalizationEngine(venueName);
  }

  Stream<Map<String, dynamic>?> get bluetoothScanResults => newLocalizationEngine.bluetoothScanResults;
  Stream<Map<String, dynamic>?> get gpsScanResults => newLocalizationEngine.gpsScanResults;

  Map<String, List<MapEntry<DateTime, int>>> beaconScan = {};

  List<Map<String, dynamic>> bleDataList = [];
  StreamSubscription? userLocationSubscription;

  void startTracking(){
    userLocationSubscription = newLocalizationEngine.bluetoothScanResults.listen((data){
      print("locationTracking $data");
      if(data != null){
        bleDataList.add(data);
      }
    });
  }

  Future<void> saveBleDataToCsv() async {
    if (bleDataList.isEmpty) return;
    userLocationSubscription?.cancel();
    List<int> _hexToBytes(String hex) {
      hex = hex.replaceAll("0x", "").replaceAll(" ", "");
      final result = <int>[];
      for (int i = 0; i < hex.length; i += 2) {
        result.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      return result;
    }

    List<Map<String, dynamic>> processedList = [];

    for (var item in bleDataList) {
      Map<String, dynamic> newItem = Map.from(item);

      final hex = item["manufacturerHex"];

      if (hex != null && hex.toString().isNotEmpty) {
        final bytes = _hexToBytes(hex);

        if (bytes.length >= 7) {
          final batteryVoltage = bytes[0] * 0.03125;
          final fwVersion = bytes[1] / 10.0;
          final txPower = bytes[2].toSigned(8);
          final advInterval = (bytes[3] << 8) | bytes[4];

          String? tag;
          if (bytes.length >= 3) {
            tag = String.fromCharCodes(bytes.sublist(bytes.length - 3));
          }

          newItem.addAll({
            "batteryVoltage": batteryVoltage,
            "fwVersion": fwVersion,
            "txPower": txPower,
            "advInterval": advInterval,
            "deviceTag": tag
          });
        }else{
          print("bytes is small $bytes");
        }
      }

      processedList.add(newItem);
    }

    final headers = processedList.first.keys.toList();

    final rows = processedList.map((map) {
      return headers.map((key) => map[key]?.toString() ?? "").toList();
    }).toList();

    final csvData = [headers, ...rows];
    final csvString = const ListToCsvConverter().convert(csvData);

    Directory? directory;

    if (Platform.isAndroid) {
      directory = Directory('/storage/emulated/0/Download');
    } else if (Platform.isIOS) {
      directory = await getApplicationDocumentsDirectory();
    }

    final file = File(
        '${directory!.path}/ble_scan_data_${DateTime.now().millisecondsSinceEpoch}.csv');

    await file.writeAsString(csvString);

    print("✅ CSV saved: ${file.path}");

    bleDataList.clear();
  }

}