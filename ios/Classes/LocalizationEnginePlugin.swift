import Flutter
import UIKit
import CoreBluetooth

public class LocalizationEnginePlugin: NSObject,
                                       FlutterPlugin,
                                       FlutterStreamHandler,
                                       CBCentralManagerDelegate {

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var centralManager: CBCentralManager!
    private var isScanning = false

    private var frequency: Int = 1000     // in ms
    private var bufferSize: Int = 5000    // in ms
    private var timeout: Int? = nil

    private var scanBuffer: [(timestamp: TimeInterval, rssi: Int, peripheral: CBPeripheral, name: String)] = []

    private var scanTimer: Timer?
    private var timeoutTimer: Timer?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LocalizationEnginePlugin()

        instance.methodChannel = FlutterMethodChannel(
            name: "localization_engine",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: instance.methodChannel!)

        instance.eventChannel = FlutterEventChannel(
            name: "ble_scan_stream",
            binaryMessenger: registrar.messenger()
        )
        instance.eventChannel?.setStreamHandler(instance)

        instance.centralManager = CBCentralManager(delegate: instance, queue: nil)
    }

    // MARK: - Method Call Handling

    public func handle(_ call: FlutterMethodCall, result: FlutterResult) {
        switch call.method {

        case "initializeScan":
            let args = call.arguments as? [String: Any]
            frequency = args?["frequency"] as? Int ?? 1000
            bufferSize = args?["bufferSize"] as? Int ?? 5000
            timeout = args?["timeout"] as? Int
            result(nil)

        case "startScan":
            startScanning()
            result(nil)

        case "stopScan":
            stopScanning()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - BLE Scan Logic

    private func startScanning() {
        scanBuffer.removeAll()

        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            isScanning = true
        }

        scanTimer = Timer.scheduledTimer(timeInterval: Double(frequency)/1000.0,
                                         target: self,
                                         selector: #selector(pushScanResults),
                                         userInfo: nil,
                                         repeats: true)

        if let timeout = timeout {
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout)/1000.0,
                                                repeats: false) { _ in
                self.stopScanning()
            }
        }
    }

    private func stopScanning() {
        if isScanning {
            centralManager.stopScan()
            isScanning = false
        }

        scanTimer?.invalidate()
        timeoutTimer?.invalidate()

        scanBuffer.removeAll()
        eventSink?(FlutterEndOfEventStream)
    }

    // MARK: - CBCentral Delegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Handle Bluetooth state changes if needed
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String : Any],
                               rssi RSSI: NSNumber) {

        let timestamp = Date().timeIntervalSince1970 * 1000
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown"

        scanBuffer.append((timestamp, RSSI.intValue, peripheral, name))

        let minTimestamp = timestamp - Double(bufferSize)
        scanBuffer.removeAll { $0.timestamp < minTimestamp }
    }

    // MARK: - Push Buffer to Flutter

    @objc private func pushScanResults() {
        guard let sink = eventSink else { return }

        let mapped = scanBuffer.map {
            [
                "device": $0.peripheral.identifier.uuidString,
                "name": $0.name,
                "rssi": $0.rssi,
                "timestamp": Int($0.timestamp)
            ]
        }

        sink(mapped)
    }

    // MARK: - Event Channel

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
