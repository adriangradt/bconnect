import 'dart:typed_data';

import 'package:bedrockbridge/src/raknet/motd.dart';
import 'package:bedrockbridge/src/raknet/packets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Pong string captured from the stalincraft.de Geyser server.
  const geyser =
      'MCPE;Crossplay 26.3 | Java & Bedrock;2193;26.52;0;10;14514596338549154865;Java & Bedrock;Survival;1;19132;19132;';

  group('BedrockMotd', () {
    test('parses a real Geyser pong', () {
      final m = BedrockMotd.tryParse(geyser)!;
      expect(m.edition, 'MCPE');
      expect(m.line1, 'Crossplay 26.3 | Java & Bedrock');
      expect(m.protocol, 2193);
      expect(m.version, '26.52');
      expect(m.players, 0);
      expect(m.maxPlayers, 10);
      expect(m.serverGuid, '14514596338549154865');
      expect(m.line2, 'Java & Bedrock');
      expect(m.gameMode, 'Survival');
      expect(m.gameModeNumeric, 1);
      expect(m.portV4, 19132);
      expect(m.portV6, 19132);
    });

    test('round trip keeps the string identical', () {
      expect(BedrockMotd.tryParse(geyser)!.serialize(), geyser);
    });

    test('rewrites ports and name', () {
      final m = BedrockMotd.tryParse(geyser)!.copyWith(portV4: 40000, portV6: 40000, line1: 'Mein Server');
      final again = BedrockMotd.tryParse(m.serialize())!;
      expect(again.portV4, 40000);
      expect(again.portV6, 40000);
      expect(again.line1, 'Mein Server');
      expect(again.protocol, 2193);
    });

    test('semicolons in names cannot shift fields', () {
      final m = BedrockMotd.tryParse(geyser)!.copyWith(line1: 'a;b');
      expect(BedrockMotd.tryParse(m.serialize())!.protocol, 2193);
    });

    test('accepts short MOTDs from older servers', () {
      final m = BedrockMotd.tryParse('MCPE;Old;100;1.0;1;5')!;
      expect(m.maxPlayers, 5);
      expect(m.portV4, isNull);
    });

    test('rejects non-Bedrock strings', () {
      expect(BedrockMotd.tryParse('hello'), isNull);
      expect(BedrockMotd.tryParse(''), isNull);
    });

    test('strips formatting codes', () {
      expect(BedrockMotd.stripFormatting('§aGreen§r Text'), 'Green Text');
    });
  });

  group('packets', () {
    test('ping round trip', () {
      final p = UnconnectedPing(time: 123456789, clientGuid: -42);
      final d = UnconnectedPing.tryDecode(p.encode())!;
      expect(d.time, 123456789);
      expect(d.clientGuid, -42);
      expect(d.openConnectionsOnly, isFalse);
      expect(p.encode().length, UnconnectedPing.length);
    });

    test('open-connections ping keeps its id', () {
      final bytes = UnconnectedPing(time: 1, clientGuid: 2, openConnectionsOnly: true).encode();
      expect(bytes[0], RakNetId.unconnectedPingOpenConnections);
      expect(UnconnectedPing.tryDecode(bytes)!.openConnectionsOnly, isTrue);
    });

    test('ping matches the byte layout of the game', () {
      final bytes = UnconnectedPing(time: 1, clientGuid: 2).encode();
      expect(bytes.sublist(0, 9), [1, 0, 0, 0, 0, 0, 0, 0, 1]);
      expect(bytes.sublist(9, 25), raknetMagic);
      expect(bytes.sublist(25), [0, 0, 0, 0, 0, 0, 0, 2]);
    });

    test('pong round trip with UTF-8 name', () {
      final p = UnconnectedPong(time: 7, serverGuid: 99, serverId: 'MCPE;Grüße ✓;1;1;0;1;');
      final d = UnconnectedPong.tryDecode(p.encode())!;
      expect(d.time, 7);
      expect(d.serverGuid, 99);
      expect(d.serverId, 'MCPE;Grüße ✓;1;1;0;1;');
    });

    test('rejects packets without magic or truncated', () {
      final ping = UnconnectedPing(time: 1, clientGuid: 2).encode();
      final broken = Uint8List.fromList(ping)..[10] = 0;
      expect(UnconnectedPing.tryDecode(broken), isNull);
      expect(UnconnectedPing.tryDecode(ping.sublist(0, 20)), isNull);
      final pong = UnconnectedPong(time: 1, serverGuid: 2, serverId: 'MCPE;x;1;1;0;1;').encode();
      expect(UnconnectedPong.tryDecode(pong.sublist(0, pong.length - 1)), isNull);
      expect(UnconnectedPong.tryDecode(Uint8List(0)), isNull);
    });

    test('Open Connection Request 1 is padded to the MTU', () {
      final r = encodeOpenConnectionRequest1(protocolVersion: 11, mtu: 1400);
      expect(r.length, 1372);
      expect(r[0], RakNetId.openConnectionRequest1);
      expect(r.sublist(1, 17), raknetMagic);
      expect(r[17], 11);
    });

    test('random GUIDs differ', () {
      expect(randomGuid(), isNot(randomGuid()));
    });
  });
}
