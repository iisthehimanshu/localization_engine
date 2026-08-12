package com.example.localization_engine

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal val IWAYPLUS_MANUFACTURER_IDS = listOf(1285, 4336, 2202)

class LocalizationEnginePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private lateinit var gpsEventChannel: EventChannel
  private lateinit var context: Context

  // BLE related
  private var bluetoothAdapter: BluetoothAdapter? = null
  private var scanCallback: ScanCallback? = null
  private var mainHandler = Handler(Looper.getMainLooper())

  private var timeout: Long? = null
  private val restartInterval: Long = 60000L

  private var timeoutRunnable: Runnable? = null
  private var restartTimerRunnable: Runnable? = null
  private var eventSink: EventChannel.EventSink? = null

  // Scan results are batched instead of dispatched per advertisement.
  //
  // SCAN_MODE_LOW_LATENCY + CALLBACK_TYPE_ALL_MATCHES + reportDelay(0) delivers
  // ~230 callbacks/sec in a beacon-dense venue, and ScanCallback runs on the
  // main looper — so every packet used to serialize a message and dispatch it
  // over the EventChannel from the UI thread, starving the map of frames.
  // Buffering and flushing 4x/sec cuts that to ~4 dispatches/sec with no loss
  // of readings: the Dart side already groups by device over a 1-second window.
  private val scanBuffer = ArrayList<Map<String, Any?>>()
  private var flushRunnable: Runnable? = null
  private val flushInterval: Long = 250L

  // Both the ScanCallback and the flush Runnable run on the main looper, so the
  // buffer needs no synchronization.
  private fun scheduleFlush() {
    if (flushRunnable != null) return
    flushRunnable = object : Runnable {
      override fun run() {
        if (scanBuffer.isNotEmpty()) {
          eventSink?.success(ArrayList(scanBuffer))
          scanBuffer.clear()
        }
        if (isScanning) mainHandler.postDelayed(this, flushInterval)
      }
    }
    mainHandler.postDelayed(flushRunnable!!, flushInterval)
  }

  private fun stopFlush() {
    flushRunnable?.let { mainHandler.removeCallbacks(it) }
    flushRunnable = null
    scanBuffer.clear()
  }

  private val hexDigits = "0123456789ABCDEF".toCharArray()

  /// `"%02X".format(byte)` per byte built a Formatter and parsed the format
  /// string for every byte of every packet. This is the same output via a
  /// lookup table.
  private fun toHex(bytes: ByteArray): String {
    val out = CharArray(bytes.size * 2)
    for (i in bytes.indices) {
      val v = bytes[i].toInt() and 0xFF
      out[i * 2] = hexDigits[v ushr 4]
      out[i * 2 + 1] = hexDigits[v and 0x0F]
    }
    return String(out)
  }

  // GPS related
  private var locationManager: LocationManager? = null
  private var gpsEventSink: EventChannel.EventSink? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel = MethodChannel(binding.binaryMessenger, "localization_engine")
    methodChannel.setMethodCallHandler(this)

    eventChannel = EventChannel(binding.binaryMessenger, "ble_scan_stream")
    eventChannel.setStreamHandler(this)

    gpsEventChannel = EventChannel(binding.binaryMessenger, "gps_scan_stream")
    gpsEventChannel.setStreamHandler(GpsStreamHandler())

    context = binding.applicationContext
    bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "initializeScan" -> {
        timeout = call.argument<Int?>("timeout")?.toLong()
        result.success(null)
      }
      "startScan" -> {
        startScanning()
        result.success(null)
      }
      "stopScan" -> {
        stopScanning()
        result.success(null)
      }
      "startGpsScan" -> {
        startLocationUpdates()
        result.success(null)
      }
      "stopGpsScan" -> {
        stopLocationUpdates()
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  // BLE Scanning Methods
  private var isScanning = false

  private fun startScanning() {
    if (isScanning) stopScanning()
    isScanning = true
    startBleScan()
    schedulePeriodicRestart()
    scheduleFlush()
  }

  private fun startBleScan() {
    val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner

    scanCallback = object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult) {
        val deviceName =
          result.scanRecord?.deviceName
            ?: result.device.name
            ?: return

        if (!deviceName.startsWith("IW", ignoreCase = true)) return

        val manufacturerData = result.scanRecord?.manufacturerSpecificData
        var manufacturerHex: String? = null
        manufacturerData?.let { data ->
          if (data.size() > 0) {
            manufacturerHex = toHex(data.valueAt(0))
          }
        }

        // Epoch millis instead of a SimpleDateFormat string: constructing a
        // SimpleDateFormat per packet (locale lookup, pattern parse, Calendar +
        // NumberFormat allocation) was the single most expensive thing on this
        // callback, and Dart only re-parsed the string back into a DateTime.
        val resultMap = mapOf(
          "device" to result.device.address,
          "name" to deviceName,
          "rssi" to result.rssi,
          "timestamp" to System.currentTimeMillis(),
          "manufacturerHex" to manufacturerHex
        )
        scanBuffer.add(resultMap)
      }
    }

    val scanSettings = ScanSettings.Builder()
      .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
      .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
      .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
      .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
      .setReportDelay(0L)
      .build()

    val scanFilters = IWAYPLUS_MANUFACTURER_IDS.map { manufacturerId ->
      ScanFilter.Builder()
        .setManufacturerData(manufacturerId, byteArrayOf())
        .build()
    }

    bluetoothLeScanner?.startScan(scanFilters, scanSettings, scanCallback)
    Log.d("BLE", "BLE scan started")

    timeout?.let {
      timeoutRunnable = Runnable { stopScanning() }
      mainHandler.postDelayed(timeoutRunnable!!, it)
    }
  }

  private fun schedulePeriodicRestart() {
    restartTimerRunnable = object : Runnable {
      override fun run() {
        if (!isScanning) return

        Log.d("BLE", "Restarting BLE scan (periodic 1-minute restart)")

        val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
        scanCallback?.let { bluetoothLeScanner?.stopScan(it) }

        mainHandler.postDelayed({
          if (isScanning) {
            startBleScan()
          }
        }, 100)

        if (isScanning) {
          mainHandler.postDelayed(this, restartInterval)
        }
      }
    }

    mainHandler.postDelayed(restartTimerRunnable!!, restartInterval)
    Log.d("BLE", "Scheduled periodic BLE scan restart every ${restartInterval}ms")
  }

  private fun stopScanning() {
    val wasScanning = isScanning
    isScanning = false

    timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
    restartTimerRunnable?.let { mainHandler.removeCallbacks(it) }

    val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
    scanCallback?.let { bluetoothLeScanner?.stopScan(it) }
    scanCallback = null

    stopFlush()
    if (wasScanning) eventSink?.endOfStream()

    timeoutRunnable = null
    restartTimerRunnable = null

    Log.d("stopScanning", "Scanning stopped completely")
  }

  // GPS Methods
  @SuppressLint("MissingPermission")
  private fun startLocationUpdates() {
    locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    Log.d("GPS", "Initializing location updates")

    if (ActivityCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
      Log.d("GPS", "Permission denied for location updates")
      gpsEventSink?.error("PERMISSION_DENIED", "Location permission not granted", null)
      return
    }

    val isGpsEnabled = locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) ?: false
    val isNetworkEnabled = locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ?: false

    if (!isGpsEnabled && !isNetworkEnabled) {
      Log.d("GPS", "No location provider enabled")
      gpsEventSink?.error("NO_PROVIDER", "No location provider enabled", null)
      return
    }

    if (isGpsEnabled) {
      locationManager?.requestLocationUpdates(
        LocationManager.GPS_PROVIDER,
        1000,
        0f,
        locationListener
      )
      Log.d("GPS", "GPS location updates started")
    }
  }

  private val locationListener = object : LocationListener {
    override fun onLocationChanged(location: Location) {
      val data = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy" to location.accuracy,
        "bearing" to location.bearing,
        "altitude" to location.altitude,
        "speed" to location.speed,
        "timestamp" to location.time
      )
      gpsEventSink?.success(data)
    }

    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

    override fun onProviderEnabled(provider: String) {
      Log.d("GPS", "GPS Provider enabled")
    }

    override fun onProviderDisabled(provider: String) {
      Log.d("GPS", "GPS Provider disabled")
      gpsEventSink?.error("GPS_DISABLED", "GPS provider is disabled", null)
    }
  }

  private fun stopLocationUpdates() {
    try {
      locationManager?.removeUpdates(locationListener)
    } catch (error: SecurityException) {
      Log.w("GPS", "Unable to remove location updates", error)
    }
    locationManager = null
    Log.d("GPS", "Location updates stopped")
  }

  // BLE Stream Handler
  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  // GPS Stream Handler
  inner class GpsStreamHandler : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
      gpsEventSink = events
      Log.d("GPS", "Stream listener attached")
    }

    override fun onCancel(arguments: Any?) {
      gpsEventSink = null
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    stopScanning()
    stopLocationUpdates()

    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    gpsEventChannel.setStreamHandler(null)

    eventSink = null
    gpsEventSink = null
  }
}
