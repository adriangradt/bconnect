// Runs against a real Bedrock server. Skipped unless BEDROCK_LIVE_HOST is set:
//   BEDROCK_LIVE_HOST=stalincraft.de flutter test test/live_server_test.dart
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:io';

import 'package:bedrockbridge/src/bridge/bridge.dart';
import 'package:bedrockbridge/src/raknet/motd.dart';
import 'package:bedrockbridge/src/raknet/packets.dart';
import 'package:bedrockbridge/src/raknet/ping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final host = Platform.environment['BEDROCK_LIVE_HOST'];
  final port = int.tryParse(Platform.environment['BEDROCK_LIVE_PORT'] ?? '') ?? bedrockDefaultPort;
  final skip = host == null ? 'BEDROCK_LIVE_HOST not set' : null;

  test('real server answers a ping', () async {
    final r = await BedrockPinger.ping(host!, port);
    expect(r.motd, isNotNull);
    // ignore: avoid_print
    print('live: ${r.motd!.plainName} ${r.motd!.version} ${r.motd!.players}/${r.motd!.maxPlayers} '
        '${r.latency.inMilliseconds} ms');
  }, skip: skip);

  test('RakNet handshake reaches the real server through the bridge', () async {
    final remote = await BedrockPinger.ping(host!, port);
    final bridge = BedrockBridge(
      BridgeConfig(remoteHost: host, remotePort: port, proxyPort: 0, discoveryPort: 0, mode: BridgeMode.relay),
    );
    addTearDown(bridge.dispose);
    await bridge.start();

    final client = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(client.close);
    final replies = StreamController<Datagram>();
    client.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = client.receive()) != null) {
        replies.add(dg!);
      }
    });
    final rx = StreamIterator(replies.stream);

    // LAN discovery through the bridge shows the remote MOTD.
    client.send(UnconnectedPing(time: 99, clientGuid: 5).encode(), InternetAddress.loopbackIPv4, bridge.discoveryPort!);
    expect(await rx.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final motd = BedrockMotd.tryParse(UnconnectedPong.tryDecode(rx.current.data)!.serverId)!;
    expect(motd.line1, remote.motd!.line1);
    expect(motd.portV4, bridge.proxyPort);

    // RakNet protocol 11 is what current Bedrock clients send.
    Future<OpenConnectionReply1?> handshake(int mtu) async {
      client.send(encodeOpenConnectionRequest1(protocolVersion: 11, mtu: mtu), InternetAddress.loopbackIPv4,
          bridge.proxyPort!);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        final ok = await rx.moveNext().timeout(deadline.difference(DateTime.now()), onTimeout: () => false);
        if (!ok) break;
        final r = OpenConnectionReply1.tryDecode(rx.current.data);
        if (r != null) return r;
      }
      return null;
    }

    // Like the game: probe large MTUs first, fall back to smaller ones.
    OpenConnectionReply1? reply;
    for (final mtu in [1492, 1200, 576]) {
      reply = await handshake(mtu);
      if (reply != null) break;
    }
    expect(reply, isNotNull, reason: 'no Open Connection Reply 1 through the bridge');
    expect(reply!.serverGuid, remote.pong.serverGuid);
    expect(bridge.stats.activeSessions, 1);
    // ignore: avoid_print
    print('live: handshake ok, server MTU ${reply.mtu}, guid ${reply.serverGuid}');
  }, skip: skip);
}
