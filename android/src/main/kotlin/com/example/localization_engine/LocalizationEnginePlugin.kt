package com.example.localization_engine

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
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

  private var frequency: Long = 1000L // default 1 second
  private var bufferSize: Long = 5000L // default 5 seconds
  private var timeout: Long? = null

  private var scanBuffer = mutableListOf<Pair<Long, ScanResult>>()
  private var scanTimerRunnable: Runnable? = null
  private var timeoutRunnable: Runnable? = null
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
        frequency = call.argument<Int>("frequency")?.toLong() ?: 5000L
        bufferSize = call.argument<Int>("bufferSize")?.toLong() ?: 5000L
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
  private fun startScanning() {
    scanBuffer.clear()
    val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner

    scanCallback = object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult) {
        val deviceName =
          result.scanRecord?.deviceName
            ?: result.device.name
            ?: return   // ignore unnamed devices

        if (!deviceName.startsWith("IW", ignoreCase = true)) return

        val timestamp = System.currentTimeMillis()
        scanBuffer.add(Pair(timestamp, result))

        // keep only bufferSize window
        scanBuffer.removeAll { it.first < timestamp - bufferSize }
      }
    }

    bluetoothLeScanner?.startScan(scanCallback)

    scanTimerRunnable = object : Runnable {
      override fun run() {
        val resultsMap = scanBuffer.map {
          mapOf(
            "device" to it.second.device.address,
            "name" to (it.second.scanRecord?.deviceName ?: it.second.device.name ?: "Unknown"),
            "rssi" to it.second.rssi,
            "timestamp" to it.first
          )
        }

        eventSink?.success(resultsMap)
        mainHandler.postDelayed(this, frequency)
      }
    }

    mainHandler.post(scanTimerRunnable!!)

    timeout?.let {
      timeoutRunnable = Runnable { stopScanning() }
      mainHandler.postDelayed(timeoutRunnable!!, it)
    }
  }

  private fun stopScanning() {
    val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
    scanCallback?.let { bluetoothLeScanner?.stopScan(it) }

    scanTimerRunnable?.let { mainHandler.removeCallbacks(it) }
    timeoutRunnable?.let { mainHandler.removeCallbacks(it) }

    eventSink?.endOfStream()

    scanBuffer.clear()
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

    // Check if GPS or Network provider is enabled
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
        1000, // Time interval in milliseconds
        0f,  // Distance interval in meters
        locationListener
      )
      Log.d("GPS", "GPS location updates started")
    }

            if (isNetworkEnabled) {
            locationManager?.requestLocationUpdates(
                LocationManager.NETWORK_PROVIDER,
                1000,
                0f,
                locationListener
            )
        }
  }

  // Persistent LocationListener to prevent garbage collection
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
    }

    override fun onCancel(arguments: Any?) {
      gpsEventSink = null
      stopLocationUpdates()
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