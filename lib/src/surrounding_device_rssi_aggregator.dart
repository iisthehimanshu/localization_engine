class SurroundingDeviceRssiAggregator {
  final Map<String, List<int>> _readings = <String, List<int>>{};

  void add(Map<String, dynamic> advertisement) {
    final device = advertisement['device'];
    final rawRssi = advertisement['rssi'];
    if (device is! String || device.isEmpty || rawRssi is! num) return;

    final rssi = rawRssi.round();
    if (rssi < -110 || rssi > -20) return;
    (_readings[device] ??= <int>[]).add(rssi);
  }

  Map<String, int> takeMedianSnapshot() {
    final snapshot = <String, int>{};
    _readings.forEach((device, values) {
      if (values.isEmpty) return;
      values.sort();
      final middle = values.length ~/ 2;
      snapshot[device] = values.length.isOdd
          ? values[middle]
          : ((values[middle - 1] + values[middle]) / 2).round();
    });
    _readings.clear();
    return snapshot;
  }

  void clear() => _readings.clear();
}
