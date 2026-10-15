// Transfer mode: RakNet server layer, Bedrock login hand-off, and an interop
// run with an independent client implementation (PrismarineJS bedrock-protocol).
@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bedrockbridge/src/bridge/bridge.dart';
import 'package:bedrockbridge/src/bridge/transfer.dart';
import 'package:bedrockbridge/src/raknet/binary.dart';
import 'package:bedrockbridge/src/raknet/connection.dart';
import 'package:bedrockbridge/src/raknet/packets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_server.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

/// A RakNetConnection wired to lists instead of a socket.
class Harness {
  Harness() {
    conn = RakNetConnection(
      address: InternetAddress('192.168.1.20'),
      port: 50000,
      mtu: 1400,
      serverGuid: 42,
      serverAddress: InternetAddress('192.168.1.10'),
      serverPort: 19132,
      send: sent.add,
      onGamePacket: game.add,
      onClosed: (r) => closedReason = r,
    );
  }

  late final RakNetConnection conn;
  final sent = <Uint8List>[];
  final game = <Uint8List>[];
  String? closedReason;
  int _seq = 0;

  void receive(List<Frame> frames) => conn.handleDatagram(encodeFrameSet(_seq++, frames));

  /// Bodies of all frames the connection sent (ignoring ACKs).
  List<Uint8List> sentBodies() => [
        for (final d in sent)
          if (d[0] & DatagramFlag.ack == 0) ...decodeFrameSet(d).frames.map((f) => f.body),
      ];
}

Frame ordered(int index, List<int> body, {int reliable = -1}) => Frame(
      reliability: Reliability.reliableOrdered,
      body: bytes(body),
      reliableIndex: reliable < 0 ? index : reliable,
      orderIndex: index,
    );

void main() {
  group('RakNet frames', () {
    test('frame set round trip with split and ordered frames', () {
      final frames = [
        Frame(reliability: 0, body: bytes([1, 2, 3])),
        Frame(
          reliability: Reliability.reliableOrdered,
          body: bytes([9, 9]),
          reliableIndex: 70000,
          orderIndex: 5,
          orderChannel: 2,
          splitCount: 3,
          splitId: 7,
          splitIndex: 1,
        ),
      ];
      final d = decodeFrameSet(encodeFrameSet(0x123456, frames));
      expect(d.sequence, 0x123456);
      expect(d.frames, hasLength(2));
      final f = d.frames[1];
      expect(f.body, [9, 9]);
      expect([f.reliableIndex, f.orderIndex, f.orderChannel], [70000, 5, 2]);
      expect([f.splitCount, f.splitId, f.splitIndex], [3, 7, 1]);
    });

    test('ACK merges ranges and decodes back', () {
      final ack = encodeAck([5, 1, 2, 3, 9, 10]);
      expect(ack[0], DatagramFlag.valid | DatagramFlag.ack);
      expect(ByteData.sublistView(ack).getUint16(1), 3, reason: '1-3, 5, 9-10');
      expect(decodeAck(ack), [1, 2, 3, 5, 9, 10]);
    });

    test('system address round trip', () {
      final w = ByteWriter()
        ..address(InternetAddress('192.168.178.20'), 19132)
        ..address(InternetAddress('2001:db8::1'), 19133);
      final r = ByteReader(w.take());
      final a = r.address();
      final b = r.address();
      expect([a.address.address, a.port], ['192.168.178.20', 19132]);
      expect([b.address.address, b.port], ['2001:db8::1', 19133]);
      expect(r.done, isTrue);
    });
  });

  group('RakNetConnection', () {
    test('acknowledges and answers the connection request', () {
      final h = Harness();
      final req = ByteWriter()
        ..u8(RakNetOnlineId.connectionRequest)
        ..i64be(77)
        ..i64be(123456)
        ..boolean(false);
      h.receive([ordered(0, req.take())]);
      expect(h.sent.first[0] & DatagramFlag.ack, isNonZero);
      final reply = h.sentBodies().single;
      expect(reply[0], RakNetOnlineId.connectionRequestAccepted);
      final r = ByteReader(reply, 1);
      final client = r.address();
      expect([client.address.address, client.port], ['192.168.1.20', 50000]);
      r.u16be();
      for (var i = 0; i < 20; i++) {
        r.address();
      }
      expect(r.i64be(), 123456, reason: 'echoes the request time');
      r.i64be();
      expect(r.done, isTrue);
    });

    test('answers connected pings', () {
      final h = Harness();
      final ping = ByteWriter()
        ..u8(RakNetOnlineId.connectedPing)
        ..i64be(999);
      h.receive([Frame(reliability: 0, body: ping.take())]);
      final pong = h.sentBodies().single;
      expect(pong[0], RakNetOnlineId.connectedPong);
      expect(ByteReader(pong, 1).i64be(), 999);
    });

    test('delivers ordered frames in order and drops duplicates', () {
      final h = Harness();
      h.receive([ordered(1, [0xfe, 2])]);
      h.receive([ordered(2, [0xfe, 3])]);
      expect(h.game, isEmpty, reason: 'index 0 still missing');
      h.receive([ordered(0, [0xfe, 1])]);
      h.receive([ordered(0, [0xfe, 1])]); // duplicate
      expect(h.game.map((g) => g.first), [1, 2, 3]);
    });

    test('reassembles split packets', () {
      final h = Harness();
      Frame part(int i, List<int> b) => Frame(
            reliability: Reliability.reliableOrdered,
            body: bytes(b),
            reliableIndex: i,
            orderIndex: 0,
            splitCount: 3,
            splitId: 4,
            splitIndex: i,
          );
      h.receive([part(2, [5, 6])]);
      h.receive([part(0, [0xfe, 1, 2])]);
      expect(h.game, isEmpty);
      h.receive([part(1, [3, 4])]);
      expect(h.game.single, [1, 2, 3, 4, 5, 6]);
    });

    test('splits large outgoing packets below the MTU', () {
      final h = Harness();
      h.conn.sendGame(Uint8List(5000));
      final frames = [for (final d in h.sent) ...decodeFrameSet(d).frames];
      expect(frames.length, greaterThan(3));
      expect(h.sent.every((d) => d.length + 28 <= 1400), isTrue);
      expect(frames.map((f) => f.splitIndex), List.generate(frames.length, (i) => i));
      expect(frames.fold<int>(0, (n, f) => n + f.body.length), 5001);
    });

    test('retransmits until acknowledged', () async {
      final h = Harness();
      h.conn.sendReliableOrdered(bytes([1, 2, 3]));
      expect(h.sent, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      h.conn.tick();
      expect(h.sent, hasLength(2), reason: 'resent after 800 ms');
      final seq = ByteReader(h.sent.last, 1).u24le();
      h.conn.handleDatagram(encodeAck([seq]));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      h.conn.tick();
      expect(h.sent, hasLength(2), reason: 'acknowledged, no more resends');
    });

    test('client disconnect closes the session', () {
      final h = Harness();
      h.receive([ordered(0, [RakNetOnlineId.disconnect])]);
      expect(h.conn.closed, isTrue);
      expect(h.closedReason, 'client disconnected');
    });

    test('offline handshake replies', () {
      final r1 = RakNetHandshake.reply1(encodeOpenConnectionRequest1(protocolVersion: 11, mtu: 1400), 42);
      expect(OpenConnectionReply1.tryDecode(r1)!.mtu, 1400);
      final bad = RakNetHandshake.reply1(encodeOpenConnectionRequest1(protocolVersion: 3), 42);
      expect(bad[0], RakNetId.incompatibleProtocolVersion);

      final req2 = ByteWriter()
        ..u8(RakNetId.openConnectionRequest2)
        ..bytes(raknetMagic)
        ..address(InternetAddress('192.168.1.10'), 19132)
        ..u16be(1400)
        ..i64be(555);
      final parsed = RakNetHandshake.parseRequest2(req2.take());
      expect([parsed.mtu, parsed.clientGuid], [1400, 555]);
    });
  });

  group('BedrockTransferSession', () {
    final deflate = ZLibCodec(raw: true);

    Uint8List packet(int id, void Function(ByteWriter w) body) {
      final w = ByteWriter()..varuint(id);
      body(w);
      return w.take();
    }

    ({BedrockTransferSession session, List<Uint8List> out, List<int> transferred}) make() {
      final out = <Uint8List>[];
      final transferred = <int>[];
      final s = BedrockTransferSession(
        targetHost: 'stalincraft.de',
        targetPort: 19132,
        sendBatch: out.add,
        onTransferred: transferred.add,
      );
      return (session: s, out: out, transferred: transferred);
    }

    test('current clients: network settings, then login success and transfer', () {
      final t = make();
      t.session.handleBatch(joinBatch([packet(BedrockPacketId.requestNetworkSettings, (w) => w.i32be(2193))]));
      final settings = splitBatch(t.out.single).single;
      final sr = ByteReader(settings);
      expect(sr.varuint(), BedrockPacketId.networkSettings);

      final login = joinBatch([packet(BedrockPacketId.login, (w) => w..i32be(2193)..bytes(Uint8List(3000)))]);
      t.session.handleBatch(bytes([0x00, ...deflate.encode(login)]));
      expect(t.transferred, [2193]);
      final reply = t.out.last;
      expect(reply[0], 0xff, reason: 'uncompressed batch marker');
      final packets = splitBatch(Uint8List.sublistView(reply, 1));
      final status = ByteReader(packets[0]);
      expect(status.varuint(), BedrockPacketId.playStatus);
      expect(status.i32be(), 0);
      final tr = ByteReader(packets[1]);
      expect(tr.varuint(), BedrockPacketId.transfer);
      expect(utf8.decode(tr.bytes(tr.varuint())), 'stalincraft.de');
      expect(tr.bytes(2), [0xbc, 0x4a], reason: '19132 little endian');
      expect(tr.boolean(), isFalse, reason: 'reload_world');
      expect(tr.boolean(), isFalse, reason: 'no gatherings info');
      expect(tr.done, isTrue);
    });

    test('1.20.x clients get deflated batches without a header byte', () {
      final t = make();
      t.session.handleBatch(joinBatch([packet(BedrockPacketId.requestNetworkSettings, (w) => w.i32be(630))]));
      t.session.handleBatch(bytes(deflate.encode(joinBatch([packet(BedrockPacketId.login, (w) => w.i32be(630))]))));
      expect(t.transferred, [630]);
      final packets = splitBatch(Uint8List.fromList(deflate.decode(t.out.last)));
      final tr = ByteReader(packets[1])..varuint();
      tr.bytes(tr.varuint());
      tr.bytes(2);
      expect(tr.done, isTrue, reason: 'no reload_world before 1.21.30');
    });

    test('clients before 1.19.30 send Login first, deflated', () {
      final t = make();
      t.session.handleBatch(bytes(deflate.encode(joinBatch([packet(BedrockPacketId.login, (w) => w.i32be(544))]))));
      expect(t.transferred, [544]);
    });

    test('garbage does not crash the session', () {
      final t = make();
      t.session.handleBatch(bytes([1, 2, 3, 250, 251]));
      expect(t.transferred, isEmpty);
    });
  });

  group('SpawnTemplateStore', () {
    final store = SpawnTemplateStore.fromGzip(File('assets/spawn_templates.json.gz').readAsBytesSync());

    test('covers 1.19.30 up to the current release', () {
      expect(store.protocols.first, 554);
      expect(store.protocols, contains(2193));
      expect(store.protocols.length, greaterThanOrEqualTo(30));
    });

    test('picks exact, older or newest templates', () {
      expect(store.forProtocol(2193), same(store.forProtocol(2193)));
      expect(store.forProtocol(2200), same(store.forProtocol(2193)), reason: 'newer client gets newest');
      expect(store.forProtocol(553), isNull, reason: 'before 1.19.30 there are no templates');
      final older = store.protocols[store.protocols.length - 2];
      expect(store.forProtocol(older + 1), same(store.forProtocol(older)));
    });

    test('spawn sequences contain StartGame, 36 chunks and the spawn status', () {
      final t = store.forProtocol(2193)!;
      final ids = [for (final p in t.spawnSequence) ByteReader(p).varuint() & 0x3ff];
      expect(ids, contains(0x0b), reason: 'StartGame');
      expect(ids.where((i) => i == 0x3a), hasLength(36), reason: 'LevelChunk');
      expect(ids, contains(BedrockPacketId.playStatus));
    });
  });

  group('interop with bedrock-protocol', () {
    final nodePath = '${Platform.environment['HOME']}/bedrockbridge-testclient/node_modules';
    final skip = Directory('$nodePath/bedrock-protocol').existsSync() ? null : 'bedrock-protocol not installed';

    for (final version in ['1.26.51', '1.21.0', '1.20.50', '1.19.30']) {
      test('client $version is transferred to the remote server', () async {
        final server = await TestBedrockServer.start();
        addTearDown(server.close);
        final store = SpawnTemplateStore.fromGzip(File('assets/spawn_templates.json.gz').readAsBytesSync());
        final bridge = BedrockBridge(BridgeConfig(
          remoteHost: '127.0.0.1',
          remotePort: server.port,
          proxyPort: 0,
          discoveryPort: 0,
          spawnTemplates: store.forProtocol,
        ));
        addTearDown(bridge.dispose);
        await bridge.start();

        final r = await Process.run(
          'node',
          ['tool/interop/transfer_client.js', '127.0.0.1', '${bridge.proxyPort}', version],
          environment: {'NODE_PATH': nodePath},
        );
        final lines = LineSplitter.split('${r.stdout}')
            .where((l) => l.startsWith('{'))
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .toList();
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect(lines.any((l) => l['play_status'] == 'login_success'), isTrue);
        expect(lines.any((l) => l['play_status'] == 'player_spawn'), isTrue, reason: 'empty world before transfer');
        final transfer = lines.firstWhere((l) => l.containsKey('transfer'))['transfer'] as Map;
        expect(transfer['server_address'], '127.0.0.1');
        expect(transfer['port'], server.port);
        expect(bridge.stats.transfers, 1);
      }, skip: skip);
    }
  });
}
