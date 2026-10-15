import 'dart:io';
import 'dart:typed_data';

import '../raknet/binary.dart';

/// Bedrock game packet ids used for the login hand-off.
abstract final class BedrockPacketId {
  static const int login = 0x01;
  static const int playStatus = 0x02;
  static const int disconnect = 0x05;
  static const int transfer = 0x55;
  static const int networkSettings = 0x8f;
  static const int requestNetworkSettings = 0xc1;
}

/// Protocol numbers where the wire format changed.
abstract final class BedrockProtocol {
  /// 1.19.30: client asks for network settings before Login.
  static const int networkSettings = 554;

  /// 1.20.60: every batch starts with a compression algorithm byte.
  static const int compressorInHeader = 649;

  /// 1.21.30: Transfer gained `reload_world`.
  static const int transferReloadWorld = 729;

  /// 1.26.40: Transfer gained an optional gatherings configuration.
  static const int transferGatherings = 2168;
}

/// Splits a decompressed batch into game packets.
List<Uint8List> splitBatch(Uint8List batch) {
  final r = ByteReader(batch);
  final out = <Uint8List>[];
  while (!r.done) {
    out.add(Uint8List.fromList(r.bytes(r.varuint())));
  }
  return out;
}

Uint8List joinBatch(List<Uint8List> packets) {
  final w = ByteWriter();
  for (final p in packets) {
    w.varuint(p.length);
    w.bytes(p);
  }
  return w.take();
}

/// Handles one console from RakNet connect until it is sent to the real server.
///
/// This is what lets the phone step away after joining: the console logs in
/// to the bridge, the bridge answers with "login ok" and a Transfer packet,
/// and the console reconnects straight to [targetHost]:[targetPort]. From then
/// on the game traffic no longer passes through the phone.
///
/// No encryption is negotiated (the bridge never sends a server-to-client
/// handshake), so packets stay readable for the short login phase.
class BedrockTransferSession {
  BedrockTransferSession({
    required this.targetHost,
    required this.targetPort,
    required this.sendBatch,
    required this.onTransferred,
    this.onLog,
  });

  final String targetHost;
  final int targetPort;

  /// Sends a game batch payload (without the 0xFE byte).
  final void Function(Uint8List payload) sendBatch;
  final void Function(int protocol) onTransferred;
  final void Function(String message)? onLog;

  static final _deflate = ZLibCodec(raw: true, level: 6);

  int? protocol;
  bool _compression = false;
  bool transferred = false;

  void handleBatch(Uint8List payload) {
    if (transferred || payload.isEmpty) return;
    final List<Uint8List> packets;
    try {
      packets = splitBatch(_decompress(payload));
    } on Object catch (e) {
      onLog?.call('Unreadable packet from console: $e');
      return;
    }
    for (final p in packets) {
      final r = ByteReader(p);
      final id = r.varuint() & 0x3ff;
      switch (id) {
        case BedrockPacketId.requestNetworkSettings:
          protocol = r.i32be();
          _send([_networkSettings()]);
          _compression = true;
        case BedrockPacketId.login:
          protocol ??= r.i32be();
          _transfer();
          return;
      }
    }
  }

  Uint8List _decompress(Uint8List p) {
    if (_compression && (protocol ?? 0) >= BedrockProtocol.compressorInHeader) {
      final rest = Uint8List.sublistView(p, 1);
      return switch (p[0]) {
        0x00 => Uint8List.fromList(_deflate.decode(rest)),
        0xff => rest,
        _ => throw PacketFormatException('compression ${p[0]} not supported'),
      };
    }
    if (_compression || protocol == null) {
      // Before 1.20.60, or before 1.19.30 (no network settings at all),
      // batches are deflated. The very first RequestNetworkSettings is not.
      try {
        return Uint8List.fromList(_deflate.decode(p));
      } on Object {
        return p;
      }
    }
    return p;
  }

  void _send(List<Uint8List> packets) {
    final batch = joinBatch(packets);
    if (!_compression) {
      sendBatch(batch);
    } else if ((protocol ?? 0) >= BedrockProtocol.compressorInHeader) {
      // 0xFF: this batch is not compressed.
      sendBatch(Uint8List.fromList([0xff, ...batch]));
    } else {
      sendBatch(Uint8List.fromList(_deflate.encode(batch)));
    }
  }

  Uint8List _networkSettings() {
    final w = ByteWriter()
      ..varuint(BedrockPacketId.networkSettings)
      ..u16le(1) // compression threshold
      ..u16le(0) // deflate
      ..boolean(false) // client throttle
      ..u8(0)
      ..f32le(0);
    return w.take();
  }

  void _transfer() {
    final p = protocol ?? 0;
    final status = ByteWriter()
      ..varuint(BedrockPacketId.playStatus)
      ..i32be(0); // login success
    final transfer = ByteWriter()
      ..varuint(BedrockPacketId.transfer)
      ..string(targetHost)
      ..u16le(targetPort);
    if (p >= BedrockProtocol.transferReloadWorld) transfer.boolean(true);
    if (p >= BedrockProtocol.transferGatherings) transfer.boolean(false); // no gatherings info
    _send([status.take(), transfer.take()]);
    transferred = true;
    onTransferred(p);
  }
}
