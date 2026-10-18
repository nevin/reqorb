import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ReqorbDevice") {
      DeviceChannel.register(with: registrar.messenger())
    }
  }
}

/// What the app asks of the device: how much memory it has, and how much
/// space is free where a file is to be written. Read by `lib/shared/device.dart`.
enum DeviceChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "reqorb/device", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "physicalMemory":
        result(Int(ProcessInfo.processInfo.physicalMemory))
      case "freeSpace":
        guard let path = call.arguments as? String else {
          result(nil)
          return
        }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
          .volumeAvailableCapacityForImportantUsageKey
        ])
        result(values?.volumeAvailableCapacityForImportantUsage.map { Int($0) })
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
