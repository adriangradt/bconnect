import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'motd.dart';
import 'packets.dart';

/// A Bedrock world or server found on the local network.
class DiscoveredServer {
  DiscoveredServer({
    required this.address,
    required this.port,
    required this.latency,
    required this.serverGuid,
    required this.motd,
    required this.rawServerId,
  });

  final InternetAddress address;
  final int port;
  final Duration latency;
  final int serverGuid;
  final BedrockMotd? motd;
  final String rawServerId;

  String get key => '${address.address}:$port';
  String get name => motd?.plainName.isNotEmpty == true ? motd!.plainName : key;
}

/// Every other host address in the /24 network of [own].
///
/// iOS blocks broadcast datagrams without Apple's multicast entitlement,
/// which sideloaded apps cannot get. Unicast pings to each neighbour only
/// need the local network permission, so they replace the broadcast there.
List<InternetAddress> subnetHosts(InternetAddress own) {
  if (own.type != InternetAddressType.IPv4) return const [];
  final b = own.rawAddress;
  return [
    for (var i = 1; i < 255; i++)
      if (i != b[3]) InternetAddress.fromRawAddress(Uint8List.fromList([b[0], b[1], b[2], i])),
  ];
}

/// Finds Bedrock servers on the LAN the same way the game does:
/// it broadcasts unconnected pings to UDP 19132/19133 and collects pongs.
class LanScanner {
  LanScanner({
    this.ports = const [bedrockDefaultPort, bedrockDefaultPortV6],
    this.broadcastAddresses = const [],
    this.extraTargets = const [],
    this.resendInterval = const Duration(milliseconds: 800),
  });

  final List<int> ports;

  /// Directed broadcast addresses (e.g. 192.168.178.255). The limited
  /// broadcast 255.255.255.255 is always used in addition. On Android the
  /// native layer supplies these from the Wi-Fi link properties.
  final List<InternetAddress> broadcastAddresses;

  /// Unicast targets that are pinged as well, e.g. a known host.
  final List<({InternetAddress address, int port})> extraTargets;

  final Duration resendInterval;

  /// Scans for [duration]. [onFound] fires once per new server, as soon as it answers.
  Future<List<DiscoveredServer>> scan({
    Duration duration = const Duration(seconds: 3),
    void Function(DiscoveredServer server)? onFound,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final guid = randomGuid();
    final start = DateTime.now();
    final found = <String, DiscoveredServer>{};

    final targets = <({InternetAddress address, int port})>[
      for (final p in ports) (address: InternetAddress('255.255.255.255'), port: p),
      for (final b in broadcastAddresses)
        for (final p in ports) (address: b, port: p),
      ...extraTargets,
    ];

    void sendAll() {
      final ping = UnconnectedPing(
        time: DateTime.now().difference(start).inMilliseconds,
        clientGuid: guid,
      ).encode();
      for (final t in targets) {
        try {
          socket.send(ping, t.address, t.port);
        } on SocketException {
          // A missing route to one broadcast address must not stop the scan.
        }
      }
    }

    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = socket.receive()) != null) {
        final pong = UnconnectedPong.tryDecode(Uint8List.fromList(dg!.data));
        if (pong == null) continue;
        final server = DiscoveredServer(
          address: dg.address,
          port: dg.port,
          latency: Duration(
            milliseconds: (DateTime.now().difference(start).inMilliseconds - pong.time).clamp(0, 1 << 30),
          ),
          serverGuid: pong.serverGuid,
          motd: BedrockMotd.tryParse(pong.serverId),
          rawServerId: pong.serverId,
        );
        final isNew = !found.containsKey(server.key);
        found[server.key] = server;
        if (isNew) onFound?.call(server);
      }
    });

    final timer = Timer.periodic(resendInterval, (_) => sendAll());
    sendAll();
    await Future<void>.delayed(duration);
    timer.cancel();
    await sub.cancel();
    socket.close();

    final list = found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }
}
