package com.example.localization_engine

import android.util.Log
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class LocalizationEnginePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  private lateinit var methodChannel: MethodChannel
  private lateinit var eventChannel: EventChannel
  private lateinit var context: Context

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

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel = MethodChannel(binding.binaryMessenger, "localization_engine")
    methodChannel.setMethodCallHandler(this)

    eventChannel = EventChannel(binding.binaryMessenger, "ble_scan_stream")
    eventChannel.setStreamHandler(this)

    context = binding.applicationContext
    bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "initializeScan" -> {
        frequency = call.argument<Int>("frequency")?.toLong() ?: 5000L
        bufferSize = call.argument<Int>("bufferSize")?.toLong() ?: 5000L
        timeout = call.argument<Int?>("timeout")?.toLong()
        Log.d("BluetoothScan","call ${call.argument<Int>("frequency")}");
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
      else -> result.notImplemented()
    }
  }

  private fun startScanning() {
    scanBuffer.clear()
    val bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner

    scanCallback = object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult) {
        val timestamp = System.currentTimeMillis()
        scanBuffer.add(Pair(timestamp, result))
        scanBuffer.removeAll { it.first < timestamp - bufferSize }
      }
    }

    bluetoothLeScanner?.startScan(scanCallback)

    scanTimerRunnable = object : Runnable {
      override fun run() {
        val resultsMap = scanBuffer.map {
          mapOf(
            "device" to it.second.device.address,
            "name" to it.second.device.name,
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

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
  }
}
