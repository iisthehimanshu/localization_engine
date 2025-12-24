import Flutter
import UIKit
import CoreBluetooth
import CoreLocation

public class LocalizationEnginePlugin: NSObject,
                                       FlutterPlugin,
                                       FlutterStreamHandler,
                                       CBCentralManagerDelegate,
                                       CLLocationManagerDelegate {

    // Method and Event Channels
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var gpsEventChannel: FlutterEventChannel?

    private var eventSink: FlutterEventSink?
    private var gpsEventSink: FlutterEventSink?

    // BLE Related
    private var centralManager: CBCentralManager!
    private var isScanning = false

    private var frequency: Int = 1000     // in ms
    private var bufferSize: Int = 5000    // in ms
    private var timeout: Int? = nil

    private var scanBuffer: [(timestamp: TimeInterval, rssi: Int, peripheral: CBPeripheral, name: String)] = []
    private var scanTimer: Timer?
    private var timeoutTimer: Timer?

    // GPS Related
    private var locationManager: CLLocationManager?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LocalizationEnginePlugin()

        // Method Channel
        instance.methodChannel = FlutterMethodChannel(
            name: "localization_engine",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: instance.methodChannel!)

        // BLE Event Channel
        instance.eventChannel = FlutterEventChannel(
            name: "ble_scan_stream",
            binaryMessenger: registrar.messenger()
        )
        instance.eventChannel?.setStreamHandler(instance)

        // GPS Event Channel
        instance.gpsEventChannel = FlutterEventChannel(
            name: "gps_scan_stream",
            binaryMessenger: registrar.messenger()
        )
        instance.gpsEventChannel?.setStreamHandler(GpsStreamHandler(plugin: instance))

        // Initialize managers
        instance.centralManager = CBCentralManager(delegate: instance, queue: nil)
        instance.locationManager = CLLocationManager()
        instance.locationManager?.delegate = instance
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

        case "startGpsScan":
            startLocationUpdates()
            result(nil)

        case "stopGpsScan":
            stopLocationUpdates()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - BLE Scan Logic

    private func startScanning() {
        guard !isScanning else { return }

        isScanning = true
        scanBuffer.removeAll()

        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            print("BLE: Started scanning")
        } else {
            print("BLE: Bluetooth not powered on")
        }

        // Start timer to push results at specified frequency
        scanTimer = Timer.scheduledTimer(timeInterval: Double(frequency)/1000.0,
                                         target: self,
                                         selector: #selector(pushScanResults),
                                         userInfo: nil,
                                         repeats: true)

        // Set timeout if specified
        if let timeout = timeout {
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout)/1000.0,
                                                repeats: false) { [weak self] _ in
                self?.stopScanning()
            }
        }
    }

    private func stopScanning() {
        guard isScanning else { return }

        isScanning = false

        // Invalidate timers first
        scanTimer?.invalidate()
        scanTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        // Stop BLE scan
        centralManager.stopScan()

        // Clear buffer
        scanBuffer.removeAll()

        // End stream
        eventSink?(FlutterEndOfEventStream)

        print("BLE: Scanning stopped completely")
    }

    // MARK: - CBCentral Delegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("BLE: Bluetooth is powered on")
        case .poweredOff:
            print("BLE: Bluetooth is powered off")
        case .unauthorized:
            print("BLE: Bluetooth is unauthorized")
        case .unsupported:
            print("BLE: Bluetooth is unsupported")
        default:
            print("BLE: Bluetooth state changed")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String : Any],
                               rssi RSSI: NSNumber) {

        guard isScanning else { return }

        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""

        // Filter: Only include devices with names starting with "IW"
        guard name.lowercased().hasPrefix("iw") else { return }

        let timestamp = Date().timeIntervalSince1970 * 1000

        scanBuffer.append((timestamp, RSSI.intValue, peripheral, name))

        // Remove entries older than bufferSize
        let minTimestamp = timestamp - Double(bufferSize)
        scanBuffer.removeAll { $0.timestamp < minTimestamp }
    }

    // MARK: - Push Buffer to Flutter

    @objc private func pushScanResults() {
        guard let sink = eventSink, isScanning else { return }

        let mapped = scanBuffer.map {
            [
                "device": $0.peripheral.identifier.uuidString,
                "name": $0.name,
                "rssi": $0.rssi,
                "timestamp": Int($0.timestamp)
            ] as [String : Any]
        }

        print("BLE: Pushing \(mapped.count) results to stream")
        sink(mapped)
    }

    // MARK: - GPS Location Methods

    private func startLocationUpdates() {
        guard let locationManager = locationManager else { return }

        print("GPS: Initializing location updates")

        // Check authorization status
        let authStatus: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            authStatus = locationManager.authorizationStatus
        } else {
            authStatus = CLLocationManager.authorizationStatus()
        }

        switch authStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            return
        case .restricted, .denied:
            print("GPS: Permission denied")
            gpsEventSink?(FlutterError(code: "PERMISSION_DENIED",
                                       message: "Location permission not granted",
                                       details: nil))
            return
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            break
        }

        // Configure location manager
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 0 // Report all movements

        locationManager.startUpdatingLocation()
        print("GPS: Location updates started")
    }

    private func stopLocationUpdates() {
        locationManager?.stopUpdatingLocation()
        print("GPS: Location updates stopped")
    }

    // MARK: - CLLocationManager Delegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        let data: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "bearing": location.course,
            "altitude": location.altitude,
            "speed": location.speed,
            "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000)
        ]

        gpsEventSink?(data)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("GPS: Location error - \(error.localizedDescription)")
        gpsEventSink?(FlutterError(code: "LOCATION_ERROR",
                                   message: error.localizedDescription,
                                   details: nil))
    }

    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("GPS: Authorization status changed to \(status.rawValue)")

        if status == .authorizedWhenInUse || status == .authorizedAlways {
            // Permission granted, start updates if requested
            if locationManager?.location != nil {
                startLocationUpdates()
            }
        }
    }

    @available(iOS 14.0, *)
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationManager(manager, didChangeAuthorization: manager.authorizationStatus)
    }

    // MARK: - BLE Event Channel Stream Handler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        stopScanning()
        return nil
    }

    // MARK: - GPS Stream Handler (Nested Class)

    class GpsStreamHandler: NSObject, FlutterStreamHandler {
        weak var plugin: LocalizationEnginePlugin?

        init(plugin: LocalizationEnginePlugin) {
            self.plugin = plugin
        }

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            plugin?.gpsEventSink = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            plugin?.gpsEventSink = nil
            plugin?.stopLocationUpdates()
            return nil
        }
    }
}