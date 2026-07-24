// tool/replay_estimator.dart
//
// Offline replay harness for [BLEPositionEstimator]. Reads a recorded BLE scan
// CSV, fetches the venue's beacon coordinate map from the backend, and feeds the
// readings through the REAL estimator exactly like the live engine does
// (1-second ticks, 6-second rolling window, walking:true). It then emits a
// self-contained HTML file you can open on your Mac to visualize the estimated
// path over the beacon layout.
//
// This mirrors LocalizationEngine.initEstimatorLocationStream(): every 1s the
// readings from the previous second are grouped and handed to estimator.update.
//
// Run:
//   dart run tool/replay_estimator.dart \
//       --venue "YOUR_VENUE" --env prod \
//       --csv ~/Desktop/DEPwd.csv --out ~/Desktop/estimator_replay.html
//
// Then just open the generated HTML file.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:localization_engine/src/localizationAlgorithm/ble_position_estimator.dart';
import 'package:localization_engine/src/network/model/beaconData.dart';


// cd /Users/himanshu/StudioProjects/localization_engine
//   dart run tool/replay_estimator.dart \
//       --venue "YOUR_VENUE_NAME" --env prod \
//       --csv ~/Desktop/DEPwd.csv \
//       --out ~/Desktop/estimator_replay.html
//   open ~/Desktop/estimator_replay.html

// ── Backend config (mirrors lib/src/config/config.dart) ──────────────────────
const _envConfig = {
  'prod': {
    'baseUrl': 'https://maps.iwayplus.in',
    'apiKey': '63a0a740-cc23-11f0-b58c-17043284b6b2',
  },
  'dev': {
    'baseUrl': 'https://dev.iwayplus.in',
    'apiKey': '7cc62870-d67e-11f0-91ed-2f0eb903e7db',
  },
};

Map<String, String> _parseArgs(List<String> args) {
  final m = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final key = a.substring(2);
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        m[key] = args[++i];
      } else {
        m[key] = 'true';
      }
    }
  }
  return m;
}

String _expandHome(String p) =>
    p.startsWith('~') ? p.replaceFirst('~', Platform.environment['HOME']!) : p;

Future<Map<String, Beacon>> _fetchBeaconMap(String baseUrl, String apiKey,
    String venue, String? beaconJsonPath) async {
  // Offline override: load beacons from a saved JSON array instead of the API.
  if (beaconJsonPath != null) {
    final raw = File(_expandHome(beaconJsonPath)).readAsStringSync();
    final List<dynamic> body = json.decode(raw);
    return _mapBeacons(body);
  }

  final url = '$baseUrl/secured/venue/beacons?api_key=$apiKey';
  stderr.writeln('Fetching beacon map: $url  (venueName="$venue")');
  final resp = await http.post(
    Uri.parse(url),
    body: jsonEncode({'venueName': venue}),
    headers: {'Content-Type': 'application/json'},
  );
  if (resp.statusCode != 200) {
    throw Exception(
        'Beacon fetch failed: HTTP ${resp.statusCode} — ${resp.body}');
  }
  final List<dynamic> body = json.decode(resp.body);
  return _mapBeacons(body);
}

Map<String, Beacon> _mapBeacons(List<dynamic> body) {
  final map = <String, Beacon>{};
  for (final b in body) {
    final beacon = Beacon.fromJson(b as Map<dynamic, dynamic>);
    if (beacon.name != null) map[beacon.name!] = beacon;
  }
  return map;
}

class _Reading {
  final String name;
  final int rssi;
  final DateTime ts;
  _Reading(this.name, this.rssi, this.ts);
}

List<_Reading> _parseCsv(String path) {
  // The recorder occasionally writes NUL bytes; strip them before decoding.
  final bytes = File(_expandHome(path)).readAsBytesSync();
  final text = utf8.decode(bytes.where((b) => b != 0).toList(),
      allowMalformed: true);
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty) return [];

  final header = lines.first.split(',');
  final iName = header.indexOf('name');
  final iRssi = header.indexOf('rssi');
  final iTs = header.indexOf('timestamp');
  if (iName < 0 || iRssi < 0 || iTs < 0) {
    throw Exception('CSV must have name,rssi,timestamp columns. Got: $header');
  }

  final readings = <_Reading>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final c = line.split(',');
    if (c.length <= iTs) continue;
    final name = c[iName].trim();
    final rssi = int.tryParse(c[iRssi].trim());
    final ts = DateTime.tryParse(c[iTs].trim());
    if (name.isEmpty || rssi == null || ts == null) continue;
    readings.add(_Reading(name, rssi, ts));
  }
  readings.sort((a, b) => a.ts.compareTo(b.ts));
  return readings;
}

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts.containsKey('help') || opts.isEmpty && !stdin.hasTerminal) {
    // fallthrough to defaults
  }

  final env = (opts['env'] ?? 'prod').toLowerCase();
  final cfg = _envConfig[env];
  if (cfg == null) {
    stderr.writeln('Unknown --env "$env" (use prod|dev)');
    exit(2);
  }
  final venue = opts['venue'];
  final beaconJson = opts['beacons']; // optional offline beacon JSON
  if (venue == null && beaconJson == null) {
    stderr.writeln('ERROR: pass --venue "<name>" (or --beacons <file.json>)');
    stderr.writeln(
        'Usage: dart run tool/replay_estimator.dart --venue "X" --env prod '
        '--csv ~/Desktop/DEPwd.csv --out ~/Desktop/estimator_replay.html');
    exit(2);
  }

  final csvPath = opts['csv'] ?? '${Platform.environment['HOME']}/Desktop/DEPwd.csv';
  final outPath =
      opts['out'] ?? '${Platform.environment['HOME']}/Desktop/estimator_replay.html';
  final realtime = opts['fast'] != 'true'; // real-time by default; --fast to skip sleeps

  // ── 1. Beacon coordinate DB ────────────────────────────────────────────────
  final beaconDb =
      await _fetchBeaconMap(cfg['baseUrl']!, cfg['apiKey']!, venue ?? '', beaconJson);
  stderr.writeln('Loaded ${beaconDb.length} beacons.');

  // ── 2. Recorded readings ───────────────────────────────────────────────────
  final readings = _parseCsv(csvPath);
  if (readings.isEmpty) {
    stderr.writeln('No usable readings in $csvPath');
    exit(1);
  }
  final t0 = readings.first.ts;
  final t1 = readings.last.ts;
  final totalTicks = (t1.difference(t0).inMilliseconds / 1000).ceil();
  stderr.writeln(
      '${readings.length} readings spanning ${t1.difference(t0).inSeconds}s '
      '→ $totalTicks ticks.');

  // Report beacons in the CSV that are missing from the map (they get dropped,
  // exactly as filterBeacons would drop them live).
  final csvNames = readings.map((r) => r.name).toSet();
  final missing = csvNames.where((n) => !beaconDb.containsKey(n)).toList();
  if (missing.isNotEmpty) {
    stderr.writeln('WARNING: ${missing.length} CSV beacon(s) not in venue map '
        '(ignored): ${missing.join(", ")}');
  }

  // Bucket readings by whole-second tick relative to t0.
  final buckets = <int, List<_Reading>>{};
  for (final r in readings) {
    final tick = (r.ts.difference(t0).inMilliseconds / 1000).floor();
    buckets.putIfAbsent(tick, () => []).add(r);
  }

  // ── 3. Drive the REAL estimator, one tick per second ───────────────────────
  final est = BLEPositionEstimator(beaconDb: beaconDb); // windowS=6, temp=5, topN=5
  final samples = <Map<String, dynamic>>[];

  for (var tick = 0; tick <= totalTicks; tick++) {
    final now = DateTime.now();
    final batch = buckets[tick] ?? const <_Reading>[];
    final bleReadings = batch
        .map((r) => BleReading(name: r.name, rssi: r.rssi, timestamp: now))
        .toList();

    final pos = est.update(bleReadings, walking: true);
    final rank1 = pos == null ? null : beaconDb[pos.rank1Beacon];

    samples.add({
      'tick': tick,
      'wallMs': batch.isEmpty ? null : batch.last.ts.millisecondsSinceEpoch,
      'nReadings': batch.length,
      if (pos != null) ...{
        'smoothX': pos.smoothX,
        'smoothY': pos.smoothY,
        'rawX': pos.rawX,
        'rawY': pos.rawY,
        'smoothLat': pos.smoothLat,
        'smoothLon': pos.smoothLon,
        'confidence': pos.confidence,
        'motion': pos.motionState,
        'rank1': pos.rank1Beacon,
        'rank1Rssi': pos.rank1Rssi,
        'rank1Weight': pos.rank1Weight,
        'jumpPx': pos.jumpPx,
        'nBeacons': pos.nBeacons,
        'floor': rank1?.floor,
      },
    });

    if (realtime) {
      // Sleep so the estimator's wall-clock 6s eviction window matches the live
      // engine's 1s tick cadence exactly.
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  final resolved = samples.where((s) => s.containsKey('smoothX')).length;
  stderr.writeln('Resolved $resolved / ${samples.length} ticks.');

  // ── 4. Beacon layout payload for the plot ──────────────────────────────────
  final beaconPayload = <Map<String, dynamic>>[];
  for (final entry in beaconDb.entries) {
    final b = entry.value;
    if (b.coordinateX == null || b.coordinateY == null) continue;
    beaconPayload.add({
      'name': entry.key,
      'x': b.coordinateX,
      'y': b.coordinateY,
      'floor': b.floor,
      'inCsv': csvNames.contains(entry.key),
    });
  }

  final html = _buildHtml(
    venue: venue ?? 'offline',
    env: env,
    csvPath: csvPath,
    beacons: beaconPayload,
    samples: samples,
  );
  File(_expandHome(outPath)).writeAsStringSync(html);
  stderr.writeln('\n✅ Wrote visualization → ${_expandHome(outPath)}');
  stderr.writeln('   open "${_expandHome(outPath)}"');
}

String _buildHtml({
  required String venue,
  required String env,
  required String csvPath,
  required List<Map<String, dynamic>> beacons,
  required List<Map<String, dynamic>> samples,
}) {
  final data = jsonEncode({
    'venue': venue,
    'env': env,
    'csv': csvPath,
    'beacons': beacons,
    'samples': samples,
  });
  // The visualization is a single self-contained HTML page (no external deps).
  return _htmlTemplate.replaceFirst('/*__DATA__*/', 'const DATA = $data;');
}

const _htmlTemplate = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>BLEPositionEstimator — replay</title>
<style>
  :root{
    --bg:#0f1115; --panel:#171a21; --fg:#e7eaf0; --muted:#8b93a7;
    --grid:#232833; --beacon:#3b465e; --beacon-active:#e0a63c;
    --raw:#5aa2ff; --smooth:#ff5a7a; --accent:#39d98a;
  }
  @media (prefers-color-scheme: light){
    :root{--bg:#f6f7f9;--panel:#fff;--fg:#12141a;--muted:#5a6072;
      --grid:#e3e6ec;--beacon:#c3c9d6;--beacon-active:#d18f18;
      --raw:#2563eb;--smooth:#e11d48;--accent:#0d9f6e;}
  }
  *{box-sizing:border-box}
  body{margin:0;font:14px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    background:var(--bg);color:var(--fg);}
  header{padding:14px 18px;border-bottom:1px solid var(--grid);display:flex;
    gap:16px;align-items:baseline;flex-wrap:wrap}
  header h1{font-size:15px;margin:0;font-weight:600}
  header .meta{color:var(--muted);font-size:12px}
  .wrap{display:flex;gap:16px;padding:16px;flex-wrap:wrap}
  .plot{background:var(--panel);border:1px solid var(--grid);border-radius:12px;
    padding:8px;flex:1 1 560px;min-width:320px}
  svg{width:100%;height:auto;display:block;touch-action:none}
  aside{flex:1 1 260px;min-width:240px;display:flex;flex-direction:column;gap:12px}
  .card{background:var(--panel);border:1px solid var(--grid);border-radius:12px;padding:14px}
  .card h2{margin:0 0 10px;font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
  .kv{display:flex;justify-content:space-between;padding:3px 0;font-variant-numeric:tabular-nums}
  .kv b{font-weight:600}
  .controls{display:flex;gap:10px;align-items:center;padding:10px 16px;flex-wrap:wrap}
  button{background:var(--accent);color:#04140d;border:0;border-radius:8px;
    padding:8px 16px;font-weight:600;cursor:pointer}
  input[type=range]{flex:1;min-width:200px;accent-color:var(--smooth)}
  .legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--muted);padding:0 18px 8px}
  .legend span{display:inline-flex;align-items:center;gap:6px}
  .dot{width:10px;height:10px;border-radius:50%;display:inline-block}
  .pill{padding:2px 8px;border-radius:999px;font-size:11px;font-weight:600}
  .conf-high{background:rgba(57,217,138,.18);color:var(--accent)}
  .conf-medium{background:rgba(224,166,60,.18);color:var(--beacon-active)}
  .conf-low{background:rgba(255,90,122,.18);color:var(--smooth)}
</style>
</head>
<body>
<header>
  <h1>BLEPositionEstimator · replay</h1>
  <span class="meta" id="hmeta"></span>
</header>
<div class="legend">
  <span><i class="dot" style="background:var(--beacon)"></i>beacon</span>
  <span><i class="dot" style="background:var(--beacon-active)"></i>beacon in scan</span>
  <span><i class="dot" style="background:var(--raw)"></i>raw softmax centroid</span>
  <span><i class="dot" style="background:var(--smooth)"></i>smoothed (EMA) position</span>
  <span><i class="dot" style="background:var(--accent)"></i>current</span>
</div>
<div class="controls">
  <button id="play">▶ Play</button>
  <input type="range" id="scrub" min="0" value="0"/>
  <span class="meta" id="tlabel"></span>
</div>
<div class="wrap">
  <div class="plot"><svg id="svg" viewBox="0 0 800 600" preserveAspectRatio="xMidYMid meet"></svg></div>
  <aside>
    <div class="card">
      <h2>Current tick</h2>
      <div id="stats"></div>
    </div>
    <div class="card">
      <h2>About</h2>
      <div class="meta">Positions come from the real <code>BLEPositionEstimator</code>
      (windowS=6, temp=5, topN=5, walking=true), replayed at 1&nbsp;tick/sec from the CSV —
      identical to the live engine's estimator stream. Y axis is floor-plan pixel space (flipped for display).</div>
    </div>
  </aside>
</div>
<script>
/*__DATA__*/

const svg = document.getElementById('svg');
const NS='http://www.w3.org/2000/svg';
const W=800,H=600,PAD=40;

// Bounds from beacons + resolved positions.
const xs=[], ys=[];
DATA.beacons.forEach(b=>{xs.push(b.x);ys.push(b.y);});
DATA.samples.forEach(s=>{ if(s.smoothX!=null){xs.push(s.smoothX,s.rawX);ys.push(s.smoothY,s.rawY);} });
const minX=Math.min(...xs),maxX=Math.max(...xs),minY=Math.min(...ys),maxY=Math.max(...ys);
const spanX=(maxX-minX)||1, spanY=(maxY-minY)||1;
const scale=Math.min((W-2*PAD)/spanX,(H-2*PAD)/spanY);
const offX=(W-spanX*scale)/2, offY=(H-spanY*scale)/2;
// Flip Y so it reads like a normal upward chart.
const sx=x=>offX+(x-minX)*scale;
const sy=y=>H-(offY+(y-minY)*scale);

function el(t,a){const e=document.createElementNS(NS,t);for(const k in a)e.setAttribute(k,a[k]);return e;}

// Static layer: beacons.
DATA.beacons.forEach(b=>{
  const active=b.inCsv;
  svg.appendChild(el('circle',{cx:sx(b.x),cy:sy(b.y),r:active?6:4,
    fill:active?'var(--beacon-active)':'var(--beacon)',
    stroke:'rgba(0,0,0,.25)','stroke-width':.5}));
  if(active){
    const t=el('text',{x:sx(b.x)+8,y:sy(b.y)+3,'font-size':10,fill:'var(--muted)'});
    t.textContent=b.name; svg.appendChild(t);
  }
});

// Dynamic layers.
const rawPath=el('polyline',{fill:'none',stroke:'var(--raw)','stroke-width':1.5,
  'stroke-opacity':.5,'stroke-dasharray':'3 3'});
const smoothPath=el('polyline',{fill:'none',stroke:'var(--smooth)','stroke-width':2.5,
  'stroke-linejoin':'round','stroke-linecap':'round'});
svg.appendChild(rawPath); svg.appendChild(smoothPath);
const cursor=el('circle',{r:8,fill:'var(--accent)',stroke:'#000','stroke-opacity':.3});
const rawCursor=el('circle',{r:4,fill:'var(--raw)'});
svg.appendChild(rawCursor); svg.appendChild(cursor);

const resolved=DATA.samples.filter(s=>s.smoothX!=null);
const scrub=document.getElementById('scrub');
scrub.max=DATA.samples.length-1;

function fmt(n,d=1){return n==null?'—':Number(n).toFixed(d);}

function render(i){
  // Build path up to tick i (only resolved samples).
  let rp='', spts='';
  for(let k=0;k<=i;k++){
    const s=DATA.samples[k];
    if(s.smoothX==null)continue;
    rp+=`${sx(s.rawX)},${sy(s.rawY)} `;
    spts+=`${sx(s.smoothX)},${sy(s.smoothY)} `;
  }
  rawPath.setAttribute('points',rp);
  smoothPath.setAttribute('points',spts);

  const cur=DATA.samples[i];
  const stats=document.getElementById('stats');
  if(cur.smoothX==null){
    cursor.setAttribute('opacity',0); rawCursor.setAttribute('opacity',0);
    stats.innerHTML=`<div class="kv"><span>tick</span><b>${cur.tick}</b></div>
      <div class="kv"><span>readings</span><b>${cur.nReadings}</b></div>
      <div class="kv"><span>status</span><b>no fix</b></div>`;
  }else{
    cursor.setAttribute('opacity',1); rawCursor.setAttribute('opacity',1);
    cursor.setAttribute('cx',sx(cur.smoothX)); cursor.setAttribute('cy',sy(cur.smoothY));
    rawCursor.setAttribute('cx',sx(cur.rawX)); rawCursor.setAttribute('cy',sy(cur.rawY));
    stats.innerHTML=`
      <div class="kv"><span>tick</span><b>${cur.tick}</b></div>
      <div class="kv"><span>readings</span><b>${cur.nReadings}</b></div>
      <div class="kv"><span>smoothed</span><b>${fmt(cur.smoothX)}, ${fmt(cur.smoothY)}</b></div>
      <div class="kv"><span>raw</span><b>${fmt(cur.rawX)}, ${fmt(cur.rawY)}</b></div>
      <div class="kv"><span>floor</span><b>${cur.floor??'—'}</b></div>
      <div class="kv"><span>rank-1</span><b>${cur.rank1}</b></div>
      <div class="kv"><span>rank-1 RSSI</span><b>${cur.rank1Rssi} dBm</b></div>
      <div class="kv"><span>weight</span><b>${fmt(cur.rank1Weight,2)}</b></div>
      <div class="kv"><span>jump</span><b>${fmt(cur.jumpPx)} px</b></div>
      <div class="kv"><span>#beacons</span><b>${cur.nBeacons}</b></div>
      <div class="kv"><span>motion</span><b>${cur.motion}</b></div>
      <div class="kv"><span>confidence</span><b class="pill conf-${cur.confidence}">${cur.confidence}</b></div>
      ${cur.smoothLat!=null?`<div class="kv"><span>lat/lon</span><b>${fmt(cur.smoothLat,6)}, ${fmt(cur.smoothLon,6)}</b></div>`:''}`;
  }
  document.getElementById('tlabel').textContent=`tick ${cur.tick} / ${DATA.samples[DATA.samples.length-1].tick}`;
}

document.getElementById('hmeta').textContent=
  `venue "${DATA.venue}" · ${DATA.env} · ${DATA.beacons.length} beacons · `+
  `${resolved.length}/${DATA.samples.length} ticks resolved · ${DATA.csv}`;

scrub.addEventListener('input',()=>render(+scrub.value));

let timer=null;
const playBtn=document.getElementById('play');
playBtn.addEventListener('click',()=>{
  if(timer){clearInterval(timer);timer=null;playBtn.textContent='▶ Play';return;}
  playBtn.textContent='⏸ Pause';
  timer=setInterval(()=>{
    let v=+scrub.value+1;
    if(v>+scrub.max){v=0;}
    scrub.value=v; render(v);
    if(v==+scrub.max){clearInterval(timer);timer=null;playBtn.textContent='▶ Play';}
  },250);
});

render(0);
</script>
</body>
</html>
''';
