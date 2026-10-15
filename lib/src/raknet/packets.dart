import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// RakNet offline message magic. Every unconnected packet carries it.
final Uint8List raknetMagic = Uint8List.fromList(const [
  0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe, //
  0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78,
]);

/// RakNet packet identifiers used by the bridge.
abstract final class RakNetId {
  static const int unconnectedPing = 0x01;
  static const int unconnectedPingOpenConnections = 0x02;
  static const int unconnectedPong = 0x1c;
  static const int openConnectionRequest1 = 0x05;
  static const int openConnectionReply1 = 0x06;
  static const int openConnectionRequest2 = 0x07;
  static const int openConnectionReply2 = 0x08;
  static const int incompatibleProtocolVersion = 0x19;
}

/// Default Bedrock ports. Clients broadcast LAN discovery pings to both.
const int bedrockDefaultPort = 19132;
const int bedrockDefaultPortV6 = 19133;

bool _magicAt(Uint8List data, int offset) {
  if (data.length < offset + raknetMagic.length) return false;
  for (var i = 0; i < raknetMagic.length; i++) {
    if (data[offset + i] != raknetMagic[i]) return false;
  }
  return true;
}

/// Random 64-bit GUID, as RakNet peers use to identify themselves.
int randomGuid([Random? random]) {
  final r = random ?? Random.secure();
  return (r.nextInt(1 << 32) << 32) | r.nextInt(1 << 32);
}

/// Unconnected ping (0x01) or open-connections ping (0x02).
///
/// Layout: id | time (int64) | magic (16) | client GUID (int64).
class UnconnectedPing {
  UnconnectedPing({required this.time, required this.clientGuid, this.openConnectionsOnly = false});

  static const int length = 1 + 8 + 16 + 8;

  final int time;
  final int clientGuid;
  final bool openConnectionsOnly;

  Uint8List encode() {
    final b = ByteData(length);
    b.setUint8(0, openConnectionsOnly ? RakNetId.unconnectedPingOpenConnections : RakNetId.unconnectedPing);
    b.setInt64(1, time);
    final out = b.buffer.asUint8List();
    out.setRange(9, 25, raknetMagic);
    b.setInt64(25, clientGuid);
    return out;
  }

  /// Returns null when [data] is not a well-formed ping.
  static UnconnectedPing? tryDecode(Uint8List data) {
    if (data.length < length) return null;
    final id = data[0];
    if (id != RakNetId.unconnectedPing && id != RakNetId.unconnectedPingOpenConnections) return null;
    if (!_magicAt(data, 9)) return null;
    final b = ByteData.sublistView(data);
    return UnconnectedPing(
      time: b.getInt64(1),
      clientGuid: b.getInt64(25),
      openConnectionsOnly: id == RakNetId.unconnectedPingOpenConnections,
    );
  }
}

/// Unconnected pong (0x1c), the answer to a ping.
///
/// Layout: id | time (int64) | server GUID (int64) | magic (16) | uint16 length | server ID string.
class UnconnectedPong {
  UnconnectedPong({required this.time, required this.serverGuid, required this.serverId});

  final int time;
  final int serverGuid;

  /// Bedrock MOTD string, see [BedrockMotd].
  final String serverId;

  Uint8List encode() {
    final id = utf8.encode(serverId);
    if (id.length > 0xffff) throw ArgumentError('server ID too long');
    final b = ByteData(1 + 8 + 8 + 16 + 2 + id.length);
    b.setUint8(0, RakNetId.unconnectedPong);
    b.setInt64(1, time);
    b.setInt64(9, serverGuid);
    final out = b.buffer.asUint8List();
    out.setRange(17, 33, raknetMagic);
    b.setUint16(33, id.length);
    out.setRange(35, 35 + id.length, id);
    return out;
  }

  static UnconnectedPong? tryDecode(Uint8List data) {
    if (data.length < 35 || data[0] != RakNetId.unconnectedPong) return null;
    if (!_magicAt(data, 17)) return null;
    final b = ByteData.sublistView(data);
    final len = b.getUint16(33);
    if (data.length < 35 + len) return null;
    return UnconnectedPong(
      time: b.getInt64(1),
      serverGuid: b.getInt64(9),
      serverId: utf8.decode(data.sublist(35, 35 + len), allowMalformed: true),
    );
  }
}

/// Open Connection Request 1 (0x05): id | magic | protocol version | zero padding up to the MTU.
///
/// Only used by tests and diagnostics; the bridge forwards handshakes untouched.
Uint8List encodeOpenConnectionRequest1({required int protocolVersion, int mtu = 1400}) {
  // 28 bytes of IP + UDP header are part of the MTU the client probes.
  final size = mtu - 28;
  final out = Uint8List(size);
  out[0] = RakNetId.openConnectionRequest1;
  out.setRange(1, 17, raknetMagic);
  out[17] = protocolVersion;
  return out;
}

/// Parsed Open Connection Reply 1 (0x06): id | magic | server GUID | use security | MTU.
class OpenConnectionReply1 {
  OpenConnectionReply1({required this.serverGuid, required this.useSecurity, required this.mtu});

  final int serverGuid;
  final bool useSecurity;
  final int mtu;

  static OpenConnectionReply1? tryDecode(Uint8List data) {
    if (data.length < 28 || data[0] != RakNetId.openConnectionReply1) return null;
    if (!_magicAt(data, 1)) return null;
    final b = ByteData.sublistView(data);
    final secure = data[25] != 0;
    // With security enabled a 4-byte cookie sits before the MTU.
    final mtuOffset = secure ? 30 : 26;
    if (data.length < mtuOffset + 2) return null;
    return OpenConnectionReply1(serverGuid: b.getInt64(17), useSecurity: secure, mtu: b.getUint16(mtuOffset));
  }
}
