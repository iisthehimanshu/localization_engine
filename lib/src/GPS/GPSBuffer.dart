class GPSBuffer {
  final List<double> _latitudes = [];
  final List<double> _longitudes = [];
  final List<DateTime> _times = [];

  GPSBuffer();

  void add(double lat, double lon, [DateTime? ts]) {
    _latitudes.add(lat);
    _longitudes.add(lon);
    _times.add(ts ?? DateTime.now());
  }

  void Print(){
    print("_latitudes $_latitudes, _longitudes $_longitudes");
  }

  void clear(){
    _latitudes.clear();
    _longitudes.clear();
    _times.clear();
  }

  /// Robust position over all buffered samples. Clears the buffer afterwards.
  List<double>? getRobustPosition() {
    final result = _robustPosition(_latitudes, _longitudes);
    clear();
    return result;
  }

  /// Robust position over only the samples received within the last [window].
  ///
  /// Evicts samples older than the window, then computes the robust position
  /// over what remains. Does **not** clear the buffer, so the sliding window
  /// carries over to the next call.
  List<double>? getWindowedRobustPosition(Duration window) {
    final cutoff = DateTime.now().subtract(window);
    while (_times.isNotEmpty && _times.first.isBefore(cutoff)) {
      _times.removeAt(0);
      _latitudes.removeAt(0);
      _longitudes.removeAt(0);
    }
    return _robustPosition(_latitudes, _longitudes);
  }

  /// MAD-based outlier rejection + average over the given lat/lon lists.
  List<double>? _robustPosition(List<double> lats, List<double> lons) {
    List<double>? filterOutliers(List<double> values) {
      List<double> sorted = [...values]..sort();
      if(sorted.isEmpty) return null;
      double median = sorted[sorted.length ~/ 2];
      List<double> absDevs = values.map((v) => (v - median).abs()).toList();
      List<double> sortedDevs = [...absDevs]..sort();
      double mad = sortedDevs[sortedDevs.length ~/ 2];
      double threshold = 3 * mad;
      return values.where((v) => (v - median).abs() <= threshold).toList();
    }

    List<double>? filteredLat = filterOutliers(lats);
    List<double>? filteredLon = filterOutliers(lons);
    if(filteredLat == null || filteredLon == null){
      return null;
    }
    double avg(List<double> vals) => vals.reduce((a, b) => a + b) / vals.length;

    double initLat = filteredLat.isNotEmpty
        ? avg(filteredLat)
        : lats[lats.length ~/ 2];
    double initLon = filteredLon.isNotEmpty
        ? avg(filteredLon)
        : lons[lons.length ~/ 2];
    return [initLat, initLon];
  }
}
