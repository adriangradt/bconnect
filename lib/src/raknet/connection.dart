import 'dart:io';
import 'dart:typed_data';

import 'binary.dart';
import 'packets.dart';

/// Identifiers of RakNet packets inside a connected session.
abstract final class RakNetOnlineId {
  static const int connectedPing = 0x00;
  static const int connectedPong = 0x03;
  static const int connectionRequest = 0x09;
  static const int connectionRequestAccepted = 0x10;
  static const int newIncomingConnection = 0x13;
  static const int disconnect = 0x15;
  static const int game = 0xfe;
}

abstract final class Reliability {
  static const int unreliable = 0;
  static const int reliableOrdered = 3;

  static bool isReliable(int r) => r == 2 || r == 3 || r == 4 || r == 6 || r == 7;
  static bool isSequenced(int r) => r == 1 || r == 4;
  static bool hasOrderIndex(int r) => r == 1 || r == 3 || r == 4 || r == 7;
}

abstract final class DatagramFlag {
  static const int valid = 0x80;
  static const int ack = 0x40;
  static const int nak = 0x20;
}

/// One encapsulated message inside a RakNet datagram.
class Frame {
  Frame({
    required this.reliability,
    required this.body,
    this.reliableIndex = 0,
    this.sequenceIndex = 0,
    this.orderIndex = 0,
    this.orderChannel = 0,
    this.splitCount = 0,
    this.splitId = 0,
    this.splitIndex = 0,
  });

  final int reliability;
  final Uint8List body;
  final int reliableIndex;
  final int sequenceIndex;
  final int orderIndex;
  final int orderChannel;
  final int splitCount;
  final int splitId;
  final int splitIndex;

  bool get isSplit => splitCount > 0;

  /// Worst-case header size, used to size splits.
  static const int maxHeaderSize = 1 + 2 + 3 + 3 + 4 + 10;

  void write(ByteWriter w) {
    w.u8(reliability << 5 | (isSplit ? 0x10 : 0));
    w.u16be(body.length * 8);
    if (Reliability.isReliable(reliability)) w.u24le(reliableIndex);
    if (Reliability.isSequenced(reliability)) w.u24le(sequenceIndex);
    if (Reliability.hasOrderIndex(reliability)) {
      w.u24le(orderIndex);
      w.u8(orderChannel);
    }
    if (isSplit) {
      w.u32be(splitCount);
      w.u16be(splitId);
      w.u32be(splitIndex);
    }
    w.bytes(body);
  }

  static Frame read(ByteReader r) {
    final flags = r.u8();
    final reliability = flags >> 5;
    final split = flags & 0x10 != 0;
    final length = (r.u16be() + 7) >> 3;
    final reliableIndex = Reliability.isReliable(reliability) ? r.u24le() : 0;
    final sequenceIndex = Reliability.isSequenced(reliability) ? r.u24le() : 0;
    var orderIndex = 0, orderChannel = 0;
    if (Reliability.hasOrderIndex(reliability)) {
      orderIndex = r.u24le();
      orderChannel = r.u8();
    }
    var splitCount = 0, splitId = 0, splitIndex = 0;
    if (split) {
      splitCount = r.u32be();
      splitId = r.u16be();
      splitIndex = r.u32be();
      if (splitCount == 0 || splitCount > 4096 || splitIndex >= splitCount) {
        throw PacketFormatException('bad split $splitIndex/$splitCount');
      }
    }
    return Frame(
      reliability: reliability,
      body: Uint8List.fromList(r.bytes(length)),
      reliableIndex: reliableIndex,
      sequenceIndex: sequenceIndex,
      orderIndex: orderIndex,
      orderChannel: orderChannel,
      splitCount: splitCount,
      splitId: splitId,
      splitIndex: splitIndex,
    );
  }
}

/// Encodes a frame set datagram.
Uint8List encodeFrameSet(int sequence, List<Frame> frames) {
  final w = ByteWriter()
    ..u8(DatagramFlag.valid | 0x04) // 0x04: "needs B and AS", as RakNet sets it
    ..u24le(sequence);
  for (final f in frames) {
    f.write(w);
  }
  return w.take();
}

/// Decodes a frame set datagram into its sequence number and frames.
({int sequence, List<Frame> frames}) decodeFrameSet(Uint8List d) {
  final r = ByteReader(d);
  final flags = r.u8();
  if (flags & DatagramFlag.valid == 0 || flags & (DatagramFlag.ack | DatagramFlag.nak) != 0) {
    throw PacketFormatException('not a frame set');
  }
  final sequence = r.u24le();
  final frames = <Frame>[];
  while (!r.done) {
    frames.add(Frame.read(r));
  }
  return (sequence: sequence, frames: frames);
}

/// Encodes an ACK or NAK for [sequences], merging consecutive numbers into ranges.
Uint8List encodeAck(Iterable<int> sequences, {bool nak = false}) {
  final sorted = sequences.toSet().toList()..sort();
  final ranges = <(int, int)>[];
  for (final s in sorted) {
    if (ranges.isNotEmpty && ranges.last.$2 + 1 == s) {
      ranges[ranges.length - 1] = (ranges.last.$1, s);
    } else {
      ranges.add((s, s));
    }
  }
  final w = ByteWriter()
    ..u8(DatagramFlag.valid | (nak ? DatagramFlag.nak : DatagramFlag.ack))
    ..u16be(ranges.length);
  for (final (a, b) in ranges) {
    w.boolean(a == b);
    w.u24le(a);
    if (a != b) w.u24le(b);
  }
  return w.take();
}

List<int> decodeAck(Uint8List d) {
  final r = ByteReader(d, 1);
  final count = r.u16be();
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    final single = r.boolean();
    final a = r.u24le();
    final b = single ? a : r.u24le();
    // Guard against absurd ranges from broken peers.
    for (var s = a; s <= b && out.length < 8192; s++) {
      out.add(s);
    }
  }
  return out;
}

/// RakNet server side of one client, after the offline handshake.
///
/// Implements what a Bedrock client needs to log in: reliable and ordered
/// delivery, split reassembly, ACK/NAK with retransmission, the connection
/// request handshake and connected pings. Game packets (0xFE) are handed
/// to [onGamePacket] without the 0xFE byte.
class RakNetConnection {
  RakNetConnection({
    required this.address,
    required this.port,
    required int mtu,
    required this.serverGuid,
    required this.serverAddress,
    required this.serverPort,
    required this.send,
    required this.onGamePacket,
    this.onClosed,
  })  : mtu = mtu.clamp(576, 1492),
        lastActive = DateTime.now();

  final InternetAddress address;
  final int port;
  final int mtu;
  final int serverGuid;
  final InternetAddress serverAddress;
  final int serverPort;

  /// Sends a raw datagram to this client.
  final void Function(Uint8List datagram) send;
  final void Function(Uint8List payload) onGamePacket;
  final void Function(String reason)? onClosed;

  DateTime lastActive;
  bool connected = false;
  bool closed = false;

  // Receiving
  final Set<int> _seenReliable = {};
  int _seenReliableFloor = 0;
  final Map<int, List<Frame?>> _splits = {};
  final Map<int, int> _nextOrder = {};
  final Map<int, Map<int, Uint8List>> _orderQueue = {};

  // Sending
  int _sendSequence = 0;
  int _reliableIndex = 0;
  int _orderIndex = 0;
  int _splitId = 0;
  final Map<int, _Sent> _unacked = {};

  String get key => '${address.address}:$port';

  void handleDatagram(Uint8List d) {
    if (closed || d.isEmpty) return;
    lastActive = DateTime.now();
    final flags = d[0];
    if (flags & DatagramFlag.ack != 0) {
      for (final s in decodeAck(d)) {
        _unacked.remove(s);
      }
      return;
    }
    if (flags & DatagramFlag.nak != 0) {
      for (final s in decodeAck(d)) {
        final sent = _unacked.remove(s);
        if (sent != null) _transmit(sent.frames, retries: sent.retries + 1);
      }
      return;
    }
    if (flags & DatagramFlag.valid == 0) return;
    final set = decodeFrameSet(d);
    send(encodeAck([set.sequence]));
    for (final f in set.frames) {
      _handleFrame(f);
      if (closed) return;
    }
  }

  void _handleFrame(Frame f) {
    if (Reliability.isReliable(f.reliability) && !_markReliable(f.reliableIndex)) return;

    var frame = f;
    if (f.isSplit) {
      final parts = _splits.putIfAbsent(f.splitId, () => List<Frame?>.filled(f.splitCount, null));
      if (parts.length != f.splitCount) return;
      parts[f.splitIndex] = f;
      if (parts.any((p) => p == null)) return;
      _splits.remove(f.splitId);
      final b = BytesBuilder(copy: false);
      for (final p in parts) {
        b.add(p!.body);
      }
      frame = Frame(
        reliability: f.reliability,
        body: b.takeBytes(),
        orderIndex: f.orderIndex,
        orderChannel: f.orderChannel,
      );
    }

    if (frame.reliability == 3 || frame.reliability == 7) {
      final ch = frame.orderChannel;
      final expected = _nextOrder[ch] ?? 0;
      if (frame.orderIndex < expected) return;
      if (frame.orderIndex > expected) {
        _orderQueue.putIfAbsent(ch, () => {})[frame.orderIndex] = frame.body;
        return;
      }
      _deliver(frame.body);
      var next = expected + 1;
      final queue = _orderQueue[ch];
      while (queue != null && queue.containsKey(next) && !closed) {
        _deliver(queue.remove(next)!);
        next++;
      }
      _nextOrder[ch] = next;
      return;
    }
    _deliver(frame.body);
  }

  /// Returns false if this reliable index was already seen.
  bool _markReliable(int index) {
    if (index < _seenReliableFloor || !_seenReliable.add(index)) return false;
    if (_seenReliable.length > 4096) {
      _seenReliableFloor = index - 2048;
      _seenReliable.removeWhere((i) => i < _seenReliableFloor);
    }
    return true;
  }

  void _deliver(Uint8List body) {
    if (body.isEmpty) return;
    final r = ByteReader(body, 1);
    switch (body[0]) {
      case RakNetOnlineId.connectedPing:
        final time = r.i64be();
        final w = ByteWriter()
          ..u8(RakNetOnlineId.connectedPong)
          ..i64be(time)
          ..i64be(DateTime.now().millisecondsSinceEpoch);
        _sendFrames([Frame(reliability: Reliability.unreliable, body: w.take())]);
      case RakNetOnlineId.connectionRequest:
        r.i64be(); // client GUID
        final time = r.i64be();
        final w = ByteWriter()
          ..u8(RakNetOnlineId.connectionRequestAccepted)
          ..address(address, port)
          ..u16be(0); // system index
        // Bedrock's RakNet uses 20 internal addresses.
        w.address(serverAddress, serverPort);
        for (var i = 1; i < 20; i++) {
          w.address(InternetAddress('255.255.255.255'), 0);
        }
        w
          ..i64be(time)
          ..i64be(DateTime.now().millisecondsSinceEpoch);
        sendReliableOrdered(w.take());
      case RakNetOnlineId.newIncomingConnection:
        connected = true;
      case RakNetOnlineId.disconnect:
        _close('client disconnected');
      case RakNetOnlineId.game:
        onGamePacket(Uint8List.sublistView(body, 1));
    }
  }

  /// Sends a game batch (0xFE is added here).
  void sendGame(Uint8List payload) {
    final b = Uint8List(payload.length + 1)
      ..[0] = RakNetOnlineId.game
      ..setRange(1, payload.length + 1, payload);
    sendReliableOrdered(b);
  }

  void sendReliableOrdered(Uint8List body) {
    // 28 bytes IP/UDP header, 4 bytes datagram header.
    final maxBody = mtu - 28 - 4 - Frame.maxHeaderSize;
    final orderIndex = _orderIndex++;
    if (body.length <= maxBody) {
      _sendFrames([
        Frame(reliability: Reliability.reliableOrdered, body: body, reliableIndex: _reliableIndex++, orderIndex: orderIndex),
      ]);
      return;
    }
    final id = _splitId++ & 0xffff;
    final count = (body.length + maxBody - 1) ~/ maxBody;
    for (var i = 0; i < count; i++) {
      final part = Uint8List.sublistView(body, i * maxBody, ((i + 1) * maxBody).clamp(0, body.length));
      _sendFrames([
        Frame(
          reliability: Reliability.reliableOrdered,
          body: Uint8List.fromList(part),
          reliableIndex: _reliableIndex++,
          orderIndex: orderIndex,
          splitCount: count,
          splitId: id,
          splitIndex: i,
        ),
      ]);
    }
  }

  void _sendFrames(List<Frame> frames) => _transmit(frames);

  void _transmit(List<Frame> frames, {int retries = 0}) {
    if (closed) return;
    final seq = _sendSequence++ & 0xffffff;
    send(encodeFrameSet(seq, frames));
    if (frames.any((f) => Reliability.isReliable(f.reliability))) {
      _unacked[seq] = _Sent(frames, DateTime.now(), retries);
    }
  }

  /// Retransmits reliable datagrams that were not acknowledged in time.
  void tick() {
    if (closed) return;
    final now = DateTime.now();
    for (final e in _unacked.entries.toList()) {
      if (now.difference(e.value.sentAt) < const Duration(milliseconds: 800)) continue;
      _unacked.remove(e.key);
      if (e.value.retries >= 10) {
        _close('no acknowledgement');
        return;
      }
      _transmit(e.value.frames, retries: e.value.retries + 1);
    }
  }

  bool get hasPendingSends => _unacked.isNotEmpty;

  void disconnect() {
    if (closed) return;
    _transmit([Frame(reliability: Reliability.unreliable, body: Uint8List.fromList([RakNetOnlineId.disconnect]))]);
    _close('disconnected by bridge');
  }

  void _close(String reason) {
    if (closed) return;
    closed = true;
    _unacked.clear();
    onClosed?.call(reason);
  }
}

class _Sent {
  _Sent(this.frames, this.sentAt, this.retries);
  final List<Frame> frames;
  final DateTime sentAt;
  final int retries;
}

/// Offline handshake replies (server side).
abstract final class RakNetHandshake {
  /// RakNet protocol version spoken by current Bedrock clients.
  static const int protocolVersion = 11;

  /// Versions this server accepts. Older Bedrock releases and some
  /// libraries still speak 9 or 10; the handshake is the same.
  static bool accepts(int protocol) => protocol >= 9 && protocol <= 11;

  /// Answer to Open Connection Request 1, or an Incompatible Protocol reply.
  static Uint8List reply1(Uint8List request, int serverGuid) {
    final protocol = request.length > 17 ? request[17] : 0;
    final w = ByteWriter();
    if (!accepts(protocol)) {
      w
        ..u8(RakNetId.incompatibleProtocolVersion)
        ..u8(protocolVersion)
        ..bytes(raknetMagic)
        ..i64be(serverGuid);
      return w.take();
    }
    // The request is padded to the MTU the client probes; add IP/UDP headers.
    final mtu = (request.length + 28).clamp(576, 1492);
    w
      ..u8(RakNetId.openConnectionReply1)
      ..bytes(raknetMagic)
      ..i64be(serverGuid)
      ..boolean(false) // no security
      ..u16be(mtu);
    return w.take();
  }

  /// Parses Open Connection Request 2: returns MTU and client GUID.
  static ({int mtu, int clientGuid}) parseRequest2(Uint8List d) {
    final r = ByteReader(d, 17); // id + magic
    r.address(); // server address as the client sees it
    return (mtu: r.u16be(), clientGuid: r.i64be());
  }

  static Uint8List reply2({required int serverGuid, required InternetAddress client, required int clientPort, required int mtu}) {
    final w = ByteWriter()
      ..u8(RakNetId.openConnectionReply2)
      ..bytes(raknetMagic)
      ..i64be(serverGuid)
      ..address(client, clientPort)
      ..u16be(mtu)
      ..boolean(false); // no encryption
    return w.take();
  }
}
