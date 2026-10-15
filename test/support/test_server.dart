import 'dart:io';
import 'dart:typed_data';

import 'package:bedrockbridge/src/raknet/motd.dart';
import 'package:bedrockbridge/src/raknet/packets.dart';

/// Minimal Bedrock endpoint on a real UDP socket for tests.
///
/// Answers unconnected pings with a pong, Open Connection Request 1 with
/// a reply, and echoes every other datagram prefixed with 0xEE so tests
/// can check both relay directions.
class TestBedrockServer {
  TestBedrockServer._(this.socket, this.motd);

  final RawDatagramSocket socket;
  final BedrockMotd motd;
  final int guid = 0x1122334455667788;

  /// Source ports of every datagram, to check per-client upstream sockets.
  final List<int> seenSourcePorts = [];
  int pingCount = 0;

  int get port => socket.port;

  static Future<TestBedrockServer> start({String name = 'Test Server'}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final motd = BedrockMotd(
      line1: name,
      protocol: 800,
      version: '1.21.80',
      players: 3,
      maxPlayers: 20,
      serverGuid: '1234',
      line2: 'Welt',
      portV4: socket.port,
      portV6: socket.port,
    );
    final server = TestBedrockServer._(socket, motd);
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = socket.receive()) != null) {
        server._handle(dg!);
      }
    });
    return server;
  }

  void _handle(Datagram dg) {
    seenSourcePorts.add(dg.port);
    final ping = UnconnectedPing.tryDecode(dg.data);
    if (ping != null) {
      pingCount++;
      socket.send(
        UnconnectedPong(time: ping.time, serverGuid: guid, serverId: motd.serialize()).encode(),
        dg.address,
        dg.port,
      );
      return;
    }
    if (dg.data.isNotEmpty && dg.data[0] == RakNetId.openConnectionRequest1) {
      final b = ByteData(28);
      b.setUint8(0, RakNetId.openConnectionReply1);
      final out = b.buffer.asUint8List();
      out.setRange(1, 17, raknetMagic);
      b.setInt64(17, guid);
      b.setUint8(25, 0);
      b.setUint16(26, dg.data.length + 28);
      socket.send(out, dg.address, dg.port);
      return;
    }
    socket.send([0xee, ...dg.data], dg.address, dg.port);
  }

  void close() => socket.close();
}
