// Network tests on real UDP sockets over loopback. No mocks: the bridge,
// pinger and scanner talk to TestBedrockServer through the OS stack.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bedrockbridge/src/bridge/bridge.dart';
import 'package:bedrockbridge/src/raknet/lan_discovery.dart';
import 'package:bedrockbridge/src/raknet/motd.dart';
import 'package:bedrockbridge/src/raknet/packets.dart';
import 'package:bedrockbridge/src/raknet/ping.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_server.dart';

/// A UDP client that collects every datagram it receives.
class Client {
  Client._(this.socket);
  final RawDatagramSocket socket;
  final _rx = StreamController<Datagram>.broadcast();

  static Future<Client> open() async {
    final c = Client._(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
    c.socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = c.socket.receive()) != null) {
        c._rx.add(dg!);
      }
    });
    return c;
  }

  void send(List<int> data, int port) => socket.send(data, InternetAddress.loopbackIPv4, port);

  Future<Datagram> next(bool Function(Uint8List d) where) =>
      _rx.stream.firstWhere((d) => where(d.data)).timeout(const Duration(seconds: 3));

  void close() {
    socket.close();
    _rx.close();
  }
}

void main() {
  late TestBedrockServer server;

  setUp(() async => server = await TestBedrockServer.start());
  tearDown(() => server.close());

  group('BedrockPinger', () {
    test('reads MOTD and latency from a live socket', () async {
      final r = await BedrockPinger.ping('127.0.0.1', server.port);
      expect(r.motd!.line1, 'Test Server');
      expect(r.motd!.players, 3);
      expect(r.pong.serverGuid, server.guid);
      expect(r.latency, lessThan(const Duration(seconds: 1)));
    });

    test('resolves host names', () async {
      final r = await BedrockPinger.ping('localhost', server.port);
      expect(r.motd!.line1, 'Test Server');
    });

    test('times out on a silent port', () async {
      final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      await expectLater(
        BedrockPinger.ping('127.0.0.1', silent.port, timeout: const Duration(milliseconds: 600)),
        throwsA(isA<PingException>()),
      );
    });

    test('fails clearly for unknown hosts', () async {
      await expectLater(
        BedrockPinger.ping('does-not-exist.invalid', 19132),
        throwsA(isA<PingException>()),
      );
    });
  });

  group('LanScanner', () {
    test('subnet sweep covers the /24 without the own address', () {
      final hosts = subnetHosts(InternetAddress('192.168.1.42'));
      expect(hosts, hasLength(253));
      expect(hosts.first.address, '192.168.1.1');
      expect(hosts.last.address, '192.168.1.254');
      expect(hosts.map((h) => h.address), isNot(contains('192.168.1.42')));
      expect(subnetHosts(InternetAddress('::1')), isEmpty);
    });

    test('unicast sweep finds a server among many silent targets', () async {
      final list = await LanScanner(
        ports: const [],
        extraTargets: [
          // Own address 127.0.0.2, so the sweep includes the server on 127.0.0.1.
          for (final h in subnetHosts(InternetAddress('127.0.0.2'))) (address: h, port: server.port),
        ],
      ).scan(duration: const Duration(milliseconds: 900));
      expect(list.map((s) => s.name), contains('Test Server'));
    });

    test('finds a server through a directed target', () async {
      final found = <DiscoveredServer>[];
      final list = await LanScanner(
        ports: const [],
        extraTargets: [(address: InternetAddress.loopbackIPv4, port: server.port)],
      ).scan(duration: const Duration(milliseconds: 900), onFound: found.add);
      expect(list, hasLength(1));
      expect(found, hasLength(1), reason: 'onFound fires once per server');
      expect(list.single.name, 'Test Server');
      expect(list.single.port, server.port);
      expect(list.single.serverGuid, server.guid);
    });
  });

  group('BedrockBridge', () {
    late BedrockBridge bridge;

    // These tests cover relay mode; transfer mode is in transfer_test.dart.
    Future<BedrockBridge> startBridge({String? displayName, Duration idle = const Duration(seconds: 30)}) async {
      bridge = BedrockBridge(BridgeConfig(
        remoteHost: '127.0.0.1',
        mode: BridgeMode.relay,
        remotePort: server.port,
        proxyPort: 0,
        discoveryPort: 0,
        displayName: displayName,
        sessionIdleTimeout: idle,
        pongRefreshInterval: const Duration(milliseconds: 300),
      ));
      await bridge.start();
      addTearDown(bridge.dispose);
      return bridge;
    }

    test('answers discovery pings with the remote MOTD and its own relay port', () async {
      await startBridge();
      final c = await Client.open();
      addTearDown(c.close);

      c.send(UnconnectedPing(time: 4711, clientGuid: 1).encode(), bridge.discoveryPort!);
      final dg = await c.next((d) => d[0] == RakNetId.unconnectedPong);
      final pong = UnconnectedPong.tryDecode(dg.data)!;
      final motd = BedrockMotd.tryParse(pong.serverId)!;

      expect(pong.time, 4711, reason: 'clients match pongs by echoed time');
      expect(pong.serverGuid, bridge.guid);
      expect(pong.serverGuid, isNot(server.guid));
      expect(motd.line1, 'Test Server');
      expect(motd.protocol, 800);
      expect(motd.portV4, bridge.proxyPort);
      expect(motd.portV6, bridge.proxyPort);
      expect(motd.serverGuid, '${bridge.guid}');
    });

    test('relay port answers pings too', () async {
      await startBridge(displayName: 'Bei Adrian');
      final c = await Client.open();
      addTearDown(c.close);
      c.send(UnconnectedPing(time: 1, clientGuid: 1, openConnectionsOnly: true).encode(), bridge.proxyPort!);
      final dg = await c.next((d) => d[0] == RakNetId.unconnectedPong);
      expect(BedrockMotd.tryParse(UnconnectedPong.tryDecode(dg.data)!.serverId)!.line1, 'Bei Adrian');
    });

    test('relays the RakNet handshake and game data both ways', () async {
      await startBridge();
      final c = await Client.open();
      addTearDown(c.close);

      c.send(encodeOpenConnectionRequest1(protocolVersion: 11, mtu: 1400), bridge.proxyPort!);
      final reply = await c.next((d) => d[0] == RakNetId.openConnectionReply1);
      final r1 = OpenConnectionReply1.tryDecode(reply.data)!;
      expect(r1.serverGuid, server.guid, reason: 'handshake reaches the real server');
      expect(r1.mtu, 1400);
      expect(reply.port, bridge.proxyPort, reason: 'answers come from the relay port');

      // A connected-data frame set (0x84) travels unchanged.
      final frame = Uint8List.fromList([0x84, 1, 2, 3, 4, 5]);
      c.send(frame, bridge.proxyPort!);
      final echo = await c.next((d) => d[0] == 0xee);
      expect(echo.data.sublist(1), frame);

      expect(bridge.stats.activeSessions, 1);
      expect(bridge.stats.packetsToRemote, 2);
      expect(bridge.stats.packetsToClients, 2);
      expect(bridge.stats.bytesToRemote, 1372 + 6);
    });

    test('keeps clients apart with one upstream socket each', () async {
      await startBridge();
      final a = await Client.open();
      final b = await Client.open();
      addTearDown(a.close);
      addTearDown(b.close);

      a.send([0x84, 0xaa], bridge.proxyPort!);
      b.send([0x84, 0xbb], bridge.proxyPort!);
      final ra = await a.next((d) => d[0] == 0xee);
      final rb = await b.next((d) => d[0] == 0xee);
      expect(ra.data, [0xee, 0x84, 0xaa]);
      expect(rb.data, [0xee, 0x84, 0xbb]);
      expect(bridge.stats.activeSessions, 2);

      final upstreamPorts = server.seenSourcePorts.toSet();
      expect(upstreamPorts.length, greaterThanOrEqualTo(2));
    });

    test('closes idle sessions', () async {
      await startBridge(idle: const Duration(milliseconds: 200));
      final c = await Client.open();
      addTearDown(c.close);
      c.send([0x84, 1], bridge.proxyPort!);
      await c.next((d) => d[0] == 0xee);
      expect(bridge.stats.activeSessions, 1);
      // The reaper runs every 5 s.
      await Future<void>.delayed(const Duration(milliseconds: 5600));
      expect(bridge.stats.activeSessions, 0);
      expect(bridge.stats.totalSessions, 1);
    });

    test('refuses to start when the remote is down', () async {
      final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      final b = BedrockBridge(BridgeConfig(
        remoteHost: '127.0.0.1',
        remotePort: silent.port,
        proxyPort: 0,
        discoveryPort: 0,
        remotePingTimeout: const Duration(milliseconds: 600),
      ));
      addTearDown(b.dispose);
      await expectLater(b.start(), throwsA(isA<BridgeException>()));
      expect(b.isRunning, isFalse);
    });

    test('stops answering LAN pings while the remote is down', () async {
      await startBridge();
      server.close();
      // Two missed refreshes mark the remote unreachable.
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(bridge.stats.remoteReachable, isFalse);

      final c = await Client.open();
      addTearDown(c.close);
      c.send(UnconnectedPing(time: 1, clientGuid: 1).encode(), bridge.discoveryPort!);
      await expectLater(
        c.next((d) => d[0] == RakNetId.unconnectedPong),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('stop releases the ports', () async {
      await startBridge();
      final port = bridge.proxyPort!;
      await bridge.stop();
      final again = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      again.close();
    });
  });
}
