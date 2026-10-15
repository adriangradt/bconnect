// Starts a transfer-mode bridge on the homelab for tests with real clients.
// Usage: dart run tool/interop/serve_bridge.dart <remote host> <remote port>
//          [listen port] [stage] [assets/spawn_templates.json.gz]
// stage: afterLogin | afterPacks | afterStartGame | afterInitialized
import 'dart:io';

import 'package:bedrockbridge/src/bridge/bridge.dart';
import 'package:bedrockbridge/src/bridge/transfer.dart';

Future<void> main(List<String> args) async {
  final stage = args.length > 3 ? TransferStage.values.byName(args[3]) : TransferStage.afterLogin;
  final store = args.length > 4 ? SpawnTemplateStore.fromGzip(File(args[4]).readAsBytesSync()) : null;
  final bridge = BedrockBridge(BridgeConfig(
    remoteHost: args[0],
    remotePort: int.parse(args[1]),
    proxyPort: args.length > 2 ? int.parse(args[2]) : 0,
    discoveryPort: 0,
    transferStage: stage,
    spawnTemplates: store?.forProtocol,
  ));
  bridge.log.listen((e) => stderr.writeln('${DateTime.now().toIso8601String().substring(11, 23)} ${e.message}'));
  await bridge.start();
  stdout.writeln('PORT ${bridge.proxyPort} stage ${stage.name}');
}
