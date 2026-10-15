import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'motd.dart';
import 'packets.dart';

class PingException implements Exception {
  PingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Answer of a Bedrock server to an unconnected ping.
class PingResult {
  PingResult({
    required this.address,
    required this.port,
    required this.latency,
    required this.pong,
    required this.motd,
  });

  final InternetAddress address;
  final int port;
  final Duration latency;
  final UnconnectedPong pong;

  /// Null when the server answered with a non-Bedrock server ID.
  final BedrockMotd? motd;
}

/// Resolves [host] to an address. IPv4 is preferred because most
/// Bedrock clients on consoles only speak IPv4 on the LAN.
Future<InternetAddress> resolveHost(String host) async {
  final literal = InternetAddress.tryParse(host.trim());
  if (literal != null) return literal;
  final List<InternetAddress> found;
  try {
    found = await InternetAddress.lookup(host.trim());
  } on SocketException catch (e) {
    throw PingException('Host "$host" not found: ${e.osError?.message ?? e.message}');
  }
  if (found.isEmpty) throw PingException('Host "$host" not found');
  return found.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => found.first);
}

/// Sends unconnected pings to a single Bedrock server.
class BedrockPinger {
  /// Pings [host]:[port]. The ping is repeated every [retryInterval]
  /// because single UDP datagrams get lost on mobile networks.
  static Future<PingResult> ping(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
    Duration retryInterval = const Duration(milliseconds: 700),
  }) async {
    final address = await resolveHost(host);
    return pingAddress(address, port, timeout: timeout, retryInterval: retryInterval);
  }

  static Future<PingResult> pingAddress(
    InternetAddress address,
    int port, {
    Duration timeout = const Duration(seconds: 3),
    Duration retryInterval = const Duration(milliseconds: 700),
  }) async {
    final socket = await RawDatagramSocket.bind(
      address.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
      0,
    );
    final guid = randomGuid();
    final done = Completer<PingResult>();
    final sent = <int, DateTime>{};
    var seq = 0;

    void send() {
      final t = DateTime.now();
      final time = ++seq;
      sent[time] = t;
      socket.send(UnconnectedPing(time: time, clientGuid: guid).encode(), address, port);
    }

    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = socket.receive()) != null) {
        final pong = UnconnectedPong.tryDecode(Uint8List.fromList(dg!.data));
        if (pong == null || done.isCompleted) continue;
        final start = sent[pong.time];
        if (start == null) continue;
        done.complete(PingResult(
          address: dg.address,
          port: dg.port,
          latency: DateTime.now().difference(start),
          pong: pong,
          motd: BedrockMotd.tryParse(pong.serverId),
        ));
      }
    });

    final retry = Timer.periodic(retryInterval, (_) => send());
    send();
    try {
      return await done.future.timeout(
        timeout,
        onTimeout: () => throw PingException('No answer from ${address.address}:$port'),
      );
    } finally {
      retry.cancel();
      await sub.cancel();
      socket.close();
    }
  }
}
