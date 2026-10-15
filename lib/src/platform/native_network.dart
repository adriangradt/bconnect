import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native networking helpers that Dart sockets cannot do alone.
///
/// Android: Wi-Fi multicast lock (many devices drop broadcast datagrams
/// without it), Wi-Fi lock and a foreground service that keeps the relay
/// alive while the game is in front, and directed broadcast addresses.
/// iOS: directed broadcast addresses via getifaddrs.
class NativeNetwork {
  static const _channel = MethodChannel('de.stalincraft.bedrockbridge/network');

  static bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<void> acquireMulticastLock() => _call('acquireMulticastLock');
  static Future<void> releaseMulticastLock() => _call('releaseMulticastLock');

  /// Shows the persistent notification and keeps the process in the foreground.
  static Future<void> startBridgeService({required String title, required String text}) =>
      _call('startBridgeService', {'title': title, 'text': text});

  static Future<void> stopBridgeService() => _call('stopBridgeService');

  /// Directed broadcast addresses of all active IPv4 interfaces.
  static Future<List<InternetAddress>> broadcastAddresses() async {
    if (!_supported) return _fallbackBroadcasts();
    try {
      final list = await _channel.invokeListMethod<String>('getBroadcastAddresses') ?? const [];
      final parsed = list.map(InternetAddress.tryParse).whereType<InternetAddress>().toList();
      return parsed.isEmpty ? await _fallbackBroadcasts() : parsed;
    } on PlatformException {
      return _fallbackBroadcasts();
    } on MissingPluginException {
      return _fallbackBroadcasts();
    }
  }

  /// IPv4 addresses of this device on the LAN, for display.
  static Future<List<InternetAddress>> localAddresses() async {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    return [
      for (final i in ifs)
        for (final a in i.addresses)
          if (!a.isLinkLocal) a,
    ];
  }

  /// Without a netmask from the OS, assume /24, the common home network size.
  static Future<List<InternetAddress>> _fallbackBroadcasts() async {
    final out = <InternetAddress>[];
    for (final a in await localAddresses()) {
      final b = a.rawAddress;
      out.add(InternetAddress.fromRawAddress(Uint8List.fromList([b[0], b[1], b[2], 255])));
    }
    return out;
  }

  static Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Platform without native support: the Dart sockets still work.
    }
  }
}
