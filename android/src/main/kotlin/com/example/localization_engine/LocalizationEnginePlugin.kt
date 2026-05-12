package com.example.localization_engine

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
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
    isScanning = true
    startBleScan()
    schedulePeriodicRestart()
  }

  private fun startBleScan() {
    val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner

    scanCallback = object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult) {
        val deviceName =
          result.scanRecord?.deviceName
            ?: result.device.name
            ?: return

        val manufacturerData = result.scanRecord?.manufacturerSpecificData
        var manufacturerHex: String? = null
        manufacturerData?.let { data ->
          if (data.size() > 0) {
            val bytes = data.valueAt(0)
            manufacturerHex = bytes.joinToString("") { "%02X".format(it) }
          }
        }

        val dateTime = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", java.util.Locale.getDefault())
          .format(java.util.Date(System.currentTimeMillis()))

        val resultMap = mapOf(
          "device" to result.device.address,
          "name" to deviceName,
          "rssi" to result.rssi,
          "timestamp" to dateTime,
          "manufacturerHex" to manufacturerHex
        )
        eventSink?.success(listOf(resultMap))
      }
    }

    val scanSettings = ScanSettings.Builder()
      .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
      .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
      .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
      .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
      .setReportDelay(0L)
      .build()

    bluetoothLeScanner?.startScan(null, scanSettings, scanCallback)
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
    if (!isScanning) return

    isScanning = false

    timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
    restartTimerRunnable?.let { mainHandler.removeCallbacks(it) }

    val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
    scanCallback?.let { bluetoothLeScanner?.stopScan(it) }

    eventSink?.endOfStream()

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
    locationManager?.removeUpdates(locationListener)
    Log.d("GPS", "Location updates stopped")
    Log.d("GPS", "Stack trace:", Exception())
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
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    gpsEventChannel.setStreamHandler(null)
    stopLocationUpdates()
    stopScanning()
  }
}