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

    private var frequency: Int? = nil       // in ms (nil means no periodic emission)
    private var bufferSize: Int = 5000      // in ms
    private var timeout: Int? = nil
    private var immediateEmit: Bool = false // NEW: emit immediately on discovery

    private let restartInterval: TimeInterval = 60.0 // NEW: restart every 60 seconds

    private var scanBuffer: [(timestamp: TimeInterval, rssi: Int, peripheral: CBPeripheral, name: String)] = []
    private var scanTimer: Timer?
    private var timeoutTimer: Timer?
    private var restartTimer: Timer?       // NEW: periodic restart timer

    // GPS Related
    private var locationManager: CLLocationManager?

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

        instance.gpsEventChannel = FlutterEventChannel(
            name: "gps_scan_stream",
            binaryMessenger: registrar.messenger()
        )
        instance.gpsEventChannel?.setStreamHandler(GpsStreamHandler(plugin: instance))

        instance.centralManager = CBCentralManager(delegate: instance, queue: nil)
        instance.locationManager = CLLocationManager()
        instance.locationManager?.delegate = instance
    }

    // MARK: - Method Call Handling

    public func handle(_ call: FlutterMethodCall, result: FlutterResult) {
        switch call.method {

        case "initializeScan":
            let args = call.arguments as? [String: Any]
            // CHANGED: frequency is now optional (nil if not provided), matching Android behavior
            if let freq = args?["frequency"] as? Int {
                frequency = freq
            } else {
                frequency = nil
            }
            bufferSize = args?["bufferSize"] as? Int ?? 5000
            timeout = args?["timeout"] as? Int
            // NEW: read immediateEmit parameter
            immediateEmit = args?["immediateEmit"] as? Bool ?? false
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

        startBleScan()
        schedulePeriodicRestart() // NEW: schedule 60s restart
    }

    // NEW: extracted startBleScan so it can be called on restart too
    private func startBleScan() {
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true // Match Android MATCH_NUM_MAX_ADVERTISEMENT
            ])
            print("BLE: Started scanning")
        } else {
            print("BLE: Bluetooth not powered on")
        }

        // Only set up periodic emission timer if frequency is set
        if let frequency = frequency {
            scanTimer = Timer.scheduledTimer(timeInterval: Double(frequency) / 1000.0,
                                             target: self,
                                             selector: #selector(pushScanResults),
                                             userInfo: nil,
                                             repeats: true)
        }

        if let timeout = timeout {
            timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout) / 1000.0,
                                                repeats: false) { [weak self] _ in
                self?.stopScanning()
            }
        }
    }

    // NEW: periodic restart every 60 seconds, mirrors Android schedulePeriodicRestart()
    private func schedulePeriodicRestart() {
        restartTimer = Timer.scheduledTimer(timeInterval: restartInterval,
                                            target: self,
                                            selector: #selector(handlePeriodicRestart),
                                            userInfo: nil,
                                            repeats: true)
        print("BLE: Scheduled periodic BLE scan restart every \(restartInterval)s")
    }

    @objc private func handlePeriodicRestart() {
        guard isScanning else { return }

        print("BLE: Restarting BLE scan (periodic 60s restart)")

        // Stop current scan and timer
        centralManager.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil

        // Small delay before restarting
       DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
               guard let strongSelf = self else { return }
               guard strongSelf.isScanning else { return }
               strongSelf.startBleScan()
           }
    }

    private func stopScanning() {
        guard isScanning else { return }

        isScanning = false

        // Invalidate all timers first
        scanTimer?.invalidate()
        scanTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        restartTimer?.invalidate()   // NEW: cancel restart timer
        restartTimer = nil

        centralManager.stopScan()
        scanBuffer.removeAll()
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
            // NEW: stop scanning if bluetooth turns off mid-scan, mirrors Android bluetooth-off check
            if isScanning {
                print("BLE: Bluetooth turned off during scan - stopping")
                stopScanning()
            }
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
        guard name.lowercased().hasPrefix("iw") else { return }

        let timestamp = Date().timeIntervalSince1970 * 1000 // ms

        // NEW: immediateEmit - emit right away on discovery with formatted date string
        if immediateEmit {
            let dateTime = formattedDateTime(from: timestamp)
            let resultMap: [String: Any] = [
                "device": peripheral.identifier.uuidString,
                "name": name,
                "rssi": RSSI.intValue,
                "timestamp": dateTime
            ]
            eventSink?([resultMap])
        }

        // Buffer if frequency is set
        if frequency != nil {
            scanBuffer.append((timestamp, RSSI.intValue, peripheral, name))
            let minTimestamp = timestamp - Double(bufferSize)
            scanBuffer.removeAll { $0.timestamp < minTimestamp }
        } else if !immediateEmit {
            // NEW: legacy behavior - if no frequency and no immediateEmit, emit immediately
            let dateTime = formattedDateTime(from: timestamp)
            let resultMap: [String: Any] = [
                "device": peripheral.identifier.uuidString,
                "name": name,
                "rssi": RSSI.intValue,
                "timestamp": dateTime
            ]
            eventSink?([resultMap])
        }
    }

    // NEW: helper to format timestamp as "yyyy-MM-dd HH:mm:ss.SSS", matching Android
    private func formattedDateTime(from milliseconds: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }

    // MARK: - Push Buffer to Flutter

    @objc private func pushScanResults() {
        guard isScanning else { return }

        // NEW: check if Bluetooth is still on before emitting, mirrors Android bluetooth-off check
        guard centralManager.state == .poweredOn else {
            print("BLE: Bluetooth is OFF during periodic push - stopping scan")
            stopScanning()
            return
        }

        guard let sink = eventSink else { return }

        let mapped = scanBuffer.map {
            [
                "device": $0.peripheral.identifier.uuidString,
                "name": $0.name,
                "rssi": $0.rssi,
                "timestamp": Int($0.timestamp)
            ] as [String: Any]
        }

        print("BLE: Pushing \(mapped.count) results to stream")
        sink(mapped)
    }

    // MARK: - GPS Location Methods (unchanged)

    private func startLocationUpdates() {
        guard let locationManager = locationManager else { return }
        print("GPS: Initializing location updates")

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

        // AFTER (matches Android's 1000ms cadence)
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation  // forces ~1s GPS chipset rate
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.distanceFilter = kCLDistanceFilterNone                  // fire on any movement
        locationManager.activityType = .otherNavigation                         // disables iOS dead-reckoning / motion coalescing
        locationManager.startUpdatingLocation()
        print("GPS: Location updates started")
    }

    private func stopLocationUpdates() {
        print("GPS: Location updates stopped")

        print("----- CALL STACK -----")
        Thread.callStackSymbols.forEach { print($0) }
        print("----------------------")

        locationManager?.stopUpdatingLocation()
    }

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

    // MARK: - GPS Stream Handler

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
            return nil
        }
    }
}