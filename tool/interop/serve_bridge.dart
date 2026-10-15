// Starts a transfer-mode bridge for the interop client and prints its port.
// Usage: dart run tool/interop/serve_bridge.dart <remote host> <remote port>
import 'dart:io';

import 'package:bedrockbridge/src/bridge/bridge.dart';

Future<void> main(List<String> args) async {
  final bridge = BedrockBridge(BridgeConfig(
    remoteHost: args[0],
    remotePort: int.parse(args[1]),
    proxyPort: 0,
    discoveryPort: 0,
  ));
  bridge.log.listen((e) => stderr.writeln('[bridge] ${e.message}'));
  await bridge.start();
  stdout.writeln('PORT ${bridge.proxyPort}');
}
