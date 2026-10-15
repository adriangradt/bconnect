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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BedrockBridgeNetwork") {
      NetworkChannel.register(messenger: registrar.messenger())
    }
  }
}

/// Native side of `de.stalincraft.bedrockbridge/network`.
///
/// iOS has no multicast lock or foreground service; those calls succeed
/// without effect. Broadcast addresses come from getifaddrs.
enum NetworkChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "de.stalincraft.bedrockbridge/network", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getBroadcastAddresses":
        result(broadcastAddresses())
      case "acquireMulticastLock", "releaseMulticastLock", "startBridgeService", "stopBridgeService":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func broadcastAddresses() -> [String] {
    var out: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(ptr.pointee.ifa_flags)
      guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, (flags & IFF_BROADCAST) != 0,
            let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
            let bcast = ptr.pointee.ifa_dstaddr else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(bcast, socklen_t(bcast.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
        let s = String(cString: host)
        if !out.contains(s) { out.append(s) }
      }
    }
    return out
  }
}
