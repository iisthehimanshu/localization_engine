## 0.0.1

* Initial release.
* BLE beacon scanning with RSSI filtering and statistical smoothing.
* GPS fusion with robust-position fallback when no beacon is in range.
* Multi-floor resolution (RSSI dominance + circle-proximity heuristics).
* Peak/valley detection for strong transient beacon hits.
* Stream-based fused location updates via `userLocation`.
* Live tracking over WebSocket with offline queueing and auto-reconnect.
* Per-building/per-floor tuning via `floorConfig`.
