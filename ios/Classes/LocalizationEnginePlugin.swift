import Flutter
import UIKit
import CoreBluetooth

public class LocalizationEnginePlugin: NSObject, FlutterPlugin, CBCentralManagerDelegate {
  var centralManager: CBCentralManager?
  var devices: [String] = []
  var result: FlutterResult?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "LocalizationEnginePlugin", binaryMessenger: registrar.messenger())
    let instance = YourPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "scanBluetooth":
      self.result = result
      startScan()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func startScan() {
    centralManager = CBCentralManager(delegate: self, queue: nil)
  }

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn {
      devices = []
      central.scanForPeripherals(withServices: nil, options: nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        central.stopScan()
        self.result?(self.devices)
      }
    } else {
      result?(FlutterError(code: "BT_OFF", message: "Bluetooth is off", details: nil))
    }
  }

  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                             advertisementData: [String : Any], rssi RSSI: NSNumber) {
    let name = peripheral.name ?? "Unknown"
    let identifier = peripheral.identifier.uuidString
    devices.append("\(name) - \(identifier)")
  }
}
