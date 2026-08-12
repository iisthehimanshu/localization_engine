import CoreBluetooth
import CoreLocation
import Flutter
import Foundation
import UIKit

public final class LocalizationEnginePlugin: NSObject,
    FlutterPlugin,
    FlutterStreamHandler,
    CBCentralManagerDelegate,
    CLLocationManagerDelegate {

    private enum LocalizationMode: String {
        case onlyGps
        case onlyBle
        case bothGPSandBLE

        var usesGps: Bool { self != .onlyBle }
        var usesBle: Bool { self != .onlyGps }
    }

    private struct SessionConfiguration {
        var venueName: String
        var baseUrl: String?
        var mode: LocalizationMode
        var stopAt: Date?
        var gpsActive: Bool
        var bleActive: Bool

        var isActive: Bool { gpsActive || bleActive }

        init?(dictionary: [String: Any]) {
            guard
                let venueName = dictionary["venueName"] as? String,
                !venueName.isEmpty,
                let modeName = dictionary["mode"] as? String,
                let mode = LocalizationMode(rawValue: modeName)
            else { return nil }

            self.venueName = venueName
            self.baseUrl = dictionary["baseUrl"] as? String
            self.mode = mode
            if let milliseconds = dictionary["stopAt"] as? NSNumber {
                self.stopAt = Date(
                    timeIntervalSince1970: milliseconds.doubleValue / 1000.0
                )
            } else {
                self.stopAt = nil
            }
            self.gpsActive = dictionary["gpsActive"] as? Bool ?? false
            self.bleActive = dictionary["bleActive"] as? Bool ?? false
        }

        var dictionary: [String: Any] {
            var value: [String: Any] = [
                "venueName": venueName,
                "mode": mode.rawValue,
                "gpsActive": gpsActive,
                "bleActive": bleActive,
            ]
            if let baseUrl = baseUrl { value["baseUrl"] = baseUrl }
            if let stopAt = stopAt {
                value["stopAt"] = Int(stopAt.timeIntervalSince1970 * 1000)
            }
            return value
        }
    }

    private static let sessionDefaultsKey =
        "localization_engine.ios_background_session"
    private static let restorationIdentifier =
        "com.iwayplus.localization_engine.central"
    private static let iwayplusManufacturerIds: Set<UInt16> = [1285, 4336, 2202]

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var gpsEventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    private var gpsEventSink: FlutterEventSink?

    private var centralManager: CBCentralManager!
    private var locationManager: CLLocationManager!
    private var sessionConfiguration: SessionConfiguration?
    private var deadlineTimer: Timer?
    private var isScanning = false
    private var shouldStartGpsAfterAuthorization = false

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
        instance.gpsEventChannel?.setStreamHandler(
            GpsStreamHandler(plugin: instance)
        )

        instance.locationManager = CLLocationManager()
        instance.locationManager.delegate = instance
        instance.centralManager = CBCentralManager(
            delegate: instance,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey:
                    restorationIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
        instance.restorePersistedSession()
    }

    public func handle(_ call: FlutterMethodCall, result: FlutterResult) {
        switch call.method {
        case "initializeScan":
            result(nil)
        case "startScan":
            guard applyConfiguration(from: call.arguments, enablingBle: true) else {
                result(
                    FlutterError(
                        code: "INVALID_CONFIGURATION",
                        message: "Missing or invalid localization session configuration.",
                        details: nil
                    )
                )
                return
            }
            startScanning()
            result(nil)
        case "stopScan":
            stopScanning(updatePersistence: true)
            result(nil)
        case "startGpsScan":
            guard applyConfiguration(from: call.arguments, enablingGps: true) else {
                result(
                    FlutterError(
                        code: "INVALID_CONFIGURATION",
                        message: "Missing or invalid localization session configuration.",
                        details: nil
                    )
                )
                return
            }
            startLocationUpdates()
            result(nil)
        case "stopGpsScan":
            stopLocationUpdates(updatePersistence: true)
            result(nil)
        case "stopNativeSession":
            stopAllNativeSessions()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func applyConfiguration(
        from arguments: Any?,
        enablingGps: Bool = false,
        enablingBle: Bool = false
    ) -> Bool {
        var dictionary = sessionConfiguration?.dictionary ?? [:]
        if let arguments = arguments as? [String: Any] {
            dictionary.merge(arguments) { _, newValue in newValue }
        } else if dictionary.isEmpty {
            dictionary["venueName"] = "standalone"
            dictionary["mode"] = enablingGps
                ? LocalizationMode.onlyGps.rawValue
                : LocalizationMode.onlyBle.rawValue
        } else if ((enablingGps && sessionConfiguration?.mode == .onlyBle)
                    || (enablingBle && sessionConfiguration?.mode == .onlyGps)) {
            dictionary["mode"] = LocalizationMode.bothGPSandBLE.rawValue
        }
        dictionary["gpsActive"] =
            (sessionConfiguration?.gpsActive ?? false) || enablingGps
        dictionary["bleActive"] =
            (sessionConfiguration?.bleActive ?? false) || enablingBle

        guard let configuration = SessionConfiguration(dictionary: dictionary)
        else { return false }

        sessionConfiguration = configuration
        persistSession()
        scheduleDeadlineTimer()
        return !stopIfDeadlineExpired()
    }

    private func restorePersistedSession() {
        guard
            let dictionary = UserDefaults.standard.dictionary(
                forKey: Self.sessionDefaultsKey
            ),
            let configuration = SessionConfiguration(dictionary: dictionary)
        else { return }

        sessionConfiguration = configuration
        if stopIfDeadlineExpired() { return }
        scheduleDeadlineTimer()

        if configuration.gpsActive && configuration.mode.usesGps {
            startLocationUpdates()
        }
        if configuration.bleActive && configuration.mode.usesBle {
            isScanning = true
            startBleScanIfReady()
        }
    }

    private func persistSession() {
        guard let configuration = sessionConfiguration, configuration.isActive else {
            clearPersistedSession()
            return
        }
        UserDefaults.standard.set(
            configuration.dictionary,
            forKey: Self.sessionDefaultsKey
        )
    }

    private func clearPersistedSession() {
        UserDefaults.standard.removeObject(forKey: Self.sessionDefaultsKey)
        if sessionConfiguration?.isActive == false {
            sessionConfiguration = nil
        }
    }

    private func scheduleDeadlineTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let stopAt = sessionConfiguration?.stopAt else { return }

        let remaining = stopAt.timeIntervalSinceNow
        if remaining <= 0 {
            stopAllNativeSessions()
            return
        }
        deadlineTimer = Timer.scheduledTimer(
            withTimeInterval: remaining,
            repeats: false
        ) { [weak self] _ in
            self?.stopAllNativeSessions()
        }
    }

    @discardableResult
    private func stopIfDeadlineExpired() -> Bool {
        guard let stopAt = sessionConfiguration?.stopAt else { return false }
        guard stopAt <= Date() else { return false }
        stopAllNativeSessions()
        return true
    }

    private func stopAllNativeSessions() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        stopScanning(updatePersistence: false)
        stopLocationUpdates(updatePersistence: false)
        sessionConfiguration = nil
        clearPersistedSession()
    }

    // MARK: - BLE

    private func startScanning() {
        guard !stopIfDeadlineExpired() else { return }
        guard sessionConfiguration?.mode.usesBle == true else { return }
        isScanning = true
        startBleScanIfReady()
    }

    private func startBleScanIfReady() {
        guard isScanning, centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func stopScanning(updatePersistence: Bool) {
        isScanning = false
        centralManager?.stopScan()
        if updatePersistence, sessionConfiguration != nil {
            sessionConfiguration?.bleActive = false
            persistSession()
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startBleScanIfReady()
        } else if central.state == .poweredOff {
            central.stopScan()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        guard
            let configuration = sessionConfiguration,
            configuration.bleActive,
            configuration.mode.usesBle,
            !stopIfDeadlineExpired()
        else { return }

        isScanning = true
        startBleScanIfReady()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isScanning, !stopIfDeadlineExpired() else { return }
        guard
            let manufacturerData =
                advertisementData[CBAdvertisementDataManufacturerDataKey]
                    as? Data,
            let manufacturerId = manufacturerId(from: manufacturerData),
            Self.iwayplusManufacturerIds.contains(manufacturerId)
        else { return }

        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? ""
        guard name.lowercased().hasPrefix("iw") else { return }

        let payload = manufacturerData.dropFirst(2)
        let event: [String: Any] = [
            "device": peripheral.identifier.uuidString,
            "name": name,
            "rssi": RSSI.intValue,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "manufacturerHex": payload.map { String(format: "%02X", $0) }
                .joined(),
        ]
        eventSink?([event])
    }

    private func manufacturerId(from data: Data) -> UInt16? {
        guard data.count >= 2 else { return nil }
        return UInt16(data[data.startIndex])
            | (UInt16(data[data.index(after: data.startIndex)]) << 8)
    }

    // MARK: - Core Location

    private func startLocationUpdates() {
        guard !stopIfDeadlineExpired() else { return }
        guard sessionConfiguration?.mode.usesGps == true else { return }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            shouldStartGpsAfterAuthorization = true
            locationManager.requestWhenInUseAuthorization()
            return
        case .restricted, .denied:
            gpsEventSink?(
                FlutterError(
                    code: "PERMISSION_DENIED",
                    message: "Location permission not granted.",
                    details: nil
                )
            )
            return
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            return
        }

        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false

        let backgroundModes =
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")
                as? [String] ?? []
        if backgroundModes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }

        locationManager.startUpdatingLocation()
        if locationManager.authorizationStatus == .authorizedAlways,
           CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    private func stopLocationUpdates(updatePersistence: Bool) {
        shouldStartGpsAfterAuthorization = false
        locationManager?.stopUpdatingLocation()
        locationManager?.stopMonitoringSignificantLocationChanges()
        if updatePersistence, sessionConfiguration != nil {
            sessionConfiguration?.gpsActive = false
            persistSession()
        }
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard !stopIfDeadlineExpired(), let location = locations.last else {
            return
        }
        gpsEventSink?([
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "bearing": location.course,
            "altitude": location.altitude,
            "speed": location.speed,
            "timestamp": Int(location.timestamp.timeIntervalSince1970 * 1000),
        ])
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        gpsEventSink?(
            FlutterError(
                code: "LOCATION_ERROR",
                message: error.localizedDescription,
                details: nil
            )
        )
    }

    public func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        if shouldStartGpsAfterAuthorization,
           (manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways) {
            shouldStartGpsAfterAuthorization = false
            startLocationUpdates()
        }
    }

    // MARK: - Event channels

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private final class GpsStreamHandler: NSObject, FlutterStreamHandler {
        weak var plugin: LocalizationEnginePlugin?

        init(plugin: LocalizationEnginePlugin) {
            self.plugin = plugin
        }

        func onListen(
            withArguments arguments: Any?,
            eventSink events: @escaping FlutterEventSink
        ) -> FlutterError? {
            plugin?.gpsEventSink = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            plugin?.gpsEventSink = nil
            return nil
        }
    }
}
