import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../raknet/motd.dart';
import '../raknet/packets.dart';
import '../raknet/ping.dart';

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BridgeConfig {
  const BridgeConfig({
    required this.remoteHost,
    this.remotePort = bedrockDefaultPort,
    this.proxyPort = bedrockDefaultPort,
    this.discoveryPort = bedrockDefaultPort,
    this.bindAddress,
    this.displayName,
    this.sessionIdleTimeout = const Duration(seconds: 30),
    this.pongRefreshInterval = const Duration(seconds: 3),
    this.remotePingTimeout = const Duration(seconds: 4),
  });

  final String remoteHost;
  final int remotePort;

  /// Port that carries the game traffic. 0 picks a free port.
  final int proxyPort;

  /// Port that answers LAN discovery pings. Consoles only broadcast to
  /// 19132 and 19133, so this should stay 19132.
  final int discoveryPort;

  /// Local address to bind to. Defaults to all IPv4 interfaces.
  final InternetAddress? bindAddress;

  /// Replaces line 1 of the remote MOTD in the LAN list when set.
  final String? displayName;

  /// Sessions without traffic for this long are closed.
  final Duration sessionIdleTimeout;
  final Duration pongRefreshInterval;
  final Duration remotePingTimeout;
}

enum BridgeLogLevel { info, warning, error }

class BridgeLogEntry {
  BridgeLogEntry(this.level, this.message) : time = DateTime.now();
  final BridgeLogLevel level;
  final String message;
  final DateTime time;
}

/// Live counters of a running bridge.
class BridgeStats {
  int activeSessions = 0;
  int totalSessions = 0;
  int bytesToRemote = 0;
  int bytesToClients = 0;
  int packetsToRemote = 0;
  int packetsToClients = 0;
  int pingsAnswered = 0;
  Duration? remoteLatency;
  BedrockMotd? remoteMotd;
  DateTime? lastRemotePong;
  bool remoteReachable = false;
}

class _Session {
  _Session(this.clientAddress, this.clientPort, this.upstream) : lastActive = DateTime.now();

  final InternetAddress clientAddress;
  final int clientPort;
  final RawDatagramSocket upstream;
  StreamSubscription<RawSocketEvent>? subscription;
  DateTime lastActive;

  String get key => '${clientAddress.address}:$clientPort';
}

/// Makes a remote Bedrock server appear as a LAN world.
///
/// Consoles and phones only list servers they find on the LAN, so the
/// bridge answers their discovery pings with the remote server's MOTD
/// and relays every other datagram between each client and the remote
/// server. Each client gets its own upstream socket, so the remote server
/// sees separate RakNet connections and the handshake stays end to end.
class BedrockBridge {
  BedrockBridge(this.config) : guid = randomGuid();

  final BridgeConfig config;

  /// GUID this bridge advertises on the LAN. It differs from the remote
  /// server's GUID so clients do not merge the two entries.
  final int guid;

  final BridgeStats stats = BridgeStats();
  final _log = StreamController<BridgeLogEntry>.broadcast();
  final _changes = StreamController<void>.broadcast();

  RawDatagramSocket? _proxy;
  RawDatagramSocket? _discovery;
  final List<StreamSubscription<RawSocketEvent>> _subs = [];
  final Map<String, Future<_Session>> _sessions = {};
  Timer? _pongTimer;
  Timer? _reaper;
  InternetAddress? _remoteAddress;
  bool _running = false;
  bool _refreshing = false;

  Stream<BridgeLogEntry> get log => _log.stream;

  /// Fires whenever [stats] change in a way the UI should show.
  Stream<void> get changes => _changes.stream;

  bool get isRunning => _running;
  int? get proxyPort => _proxy?.port;
  /// Port answering LAN discovery, or null if discovery could not bind.
  int? get discoveryPort {
    if (_discovery != null) return _discovery!.port;
    final p = _proxy?.port;
    return p == config.discoveryPort ? p : null;
  }
  InternetAddress? get remoteAddress => _remoteAddress;

  void _emit(BridgeLogLevel level, String message) {
    if (!_log.isClosed) _log.add(BridgeLogEntry(level, message));
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> start() async {
    if (_running) return;
    final bind = config.bindAddress ?? InternetAddress.anyIPv4;

    _remoteAddress = await resolveHost(config.remoteHost);
    _emit(BridgeLogLevel.info, 'Remote ${config.remoteHost} resolved to ${_remoteAddress!.address}');

    // The remote server must answer before we advertise it on the LAN.
    await _refreshPong(throwOnError: true);

    try {
      _proxy = await _bindWithFallback(bind, config.proxyPort);
    } on SocketException catch (e) {
      throw BridgeException('Cannot open UDP port ${config.proxyPort}: ${e.osError?.message ?? e.message}');
    }
    _subs.add(_proxy!.listen((e) => _onProxyEvent(e)));
    _emit(BridgeLogLevel.info, 'Relay listening on UDP ${_proxy!.port}');

    if (_proxy!.port != config.discoveryPort) {
      try {
        _discovery = await RawDatagramSocket.bind(bind, config.discoveryPort, reuseAddress: true);
        _subs.add(_discovery!.listen((e) => _onDiscoveryEvent(e)));
        _emit(BridgeLogLevel.info, 'LAN discovery listening on UDP ${config.discoveryPort}');
      } on SocketException catch (e) {
        _emit(
          BridgeLogLevel.warning,
          'UDP ${config.discoveryPort} is busy (${e.osError?.message ?? e.message}). '
          'Consoles will not see the bridge in the LAN list. Close other Minecraft apps or servers on this device.',
        );
      }
    }

    _running = true;
    _pongTimer = Timer.periodic(config.pongRefreshInterval, (_) => _refreshPong());
    _reaper = Timer.periodic(const Duration(seconds: 5), (_) => _reapIdleSessions());
    _changed();
  }

  /// Binds [port]; if the default port is taken, falls back to a free one.
  /// The pong advertises the real port, so clients still connect.
  Future<RawDatagramSocket> _bindWithFallback(InternetAddress bind, int port) async {
    try {
      return await RawDatagramSocket.bind(bind, port, reuseAddress: true);
    } on SocketException {
      if (port == 0) rethrow;
      _emit(BridgeLogLevel.warning, 'UDP $port is busy, using a random relay port');
      return RawDatagramSocket.bind(bind, 0);
    }
  }

  Future<void> stop() async {
    if (!_running && _proxy == null) return;
    _running = false;
    _pongTimer?.cancel();
    _reaper?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final f in _sessions.values.toList()) {
      try {
        _closeSession(await f, reason: 'bridge stopped');
      } catch (_) {}
    }
    _sessions.clear();
    _proxy?.close();
    _discovery?.close();
    _proxy = null;
    _discovery = null;
    stats.activeSessions = 0;
    _emit(BridgeLogLevel.info, 'Bridge stopped');
    _changed();
  }

  Future<void> dispose() async {
    await stop();
    await _log.close();
    await _changes.close();
  }

  Future<void> _refreshPong({bool throwOnError = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final r = await BedrockPinger.pingAddress(
        _remoteAddress!,
        config.remotePort,
        timeout: config.remotePingTimeout,
      );
      if (r.motd == null) {
        throw PingException('Remote answered, but not as a Bedrock server');
      }
      final wasReachable = stats.remoteReachable;
      stats
        ..remoteMotd = r.motd
        ..remoteLatency = r.latency
        ..lastRemotePong = DateTime.now()
        ..remoteReachable = true;
      if (!wasReachable && _running) _emit(BridgeLogLevel.info, 'Remote server reachable again');
    } on PingException catch (e) {
      if (throwOnError) throw BridgeException('Remote server not reachable: $e');
      if (stats.remoteReachable) _emit(BridgeLogLevel.warning, 'Remote server stopped answering: $e');
      stats.remoteReachable = false;
    } finally {
      _refreshing = false;
      _changed();
    }
  }

  /// The pong the LAN sees: remote MOTD, our GUID, our relay port.
  Uint8List? _buildPong(int pingTime) {
    final motd = stats.remoteMotd;
    if (motd == null || !stats.remoteReachable) return null;
    final port = _proxy!.port;
    final advertised = motd.copyWith(
      line1: config.displayName?.isNotEmpty == true ? config.displayName : null,
      serverGuid: '$guid',
      portV4: port,
      portV6: port,
    );
    return UnconnectedPong(time: pingTime, serverGuid: guid, serverId: advertised.serialize()).encode();
  }

  bool _answerPing(RawDatagramSocket socket, Datagram dg) {
    final ping = UnconnectedPing.tryDecode(dg.data);
    if (ping == null) return false;
    final pong = _buildPong(ping.time);
    if (pong != null) {
      socket.send(pong, dg.address, dg.port);
      stats.pingsAnswered++;
    }
    return true;
  }

  void _onDiscoveryEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _discovery;
    if (socket == null) return;
    Datagram? dg;
    while ((dg = socket.receive()) != null) {
      // Only discovery happens here; game traffic goes to the relay port.
      _answerPing(socket, dg!);
    }
  }

  void _onProxyEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _proxy;
    if (socket == null) return;
    Datagram? dg;
    while ((dg = socket.receive()) != null) {
      final d = dg!;
      if (_answerPing(socket, d)) continue;
      _forwardToRemote(d);
    }
  }

  void _forwardToRemote(Datagram dg) {
    final key = '${dg.address.address}:${dg.port}';
    var future = _sessions[key];
    if (future == null) {
      future = _openSession(dg.address, dg.port);
      _sessions[key] = future;
      // A failed upstream bind must not leave a dead entry behind.
      future.catchError((Object e) {
        _sessions.remove(key);
        _emit(BridgeLogLevel.error, 'Cannot open upstream socket for $key: $e');
        _changed();
        throw e;
      }).ignore();
    }
    future.then((s) {
      if (!_running) return;
      s.lastActive = DateTime.now();
      final sent = s.upstream.send(dg.data, _remoteAddress!, config.remotePort);
      if (sent > 0) {
        stats.bytesToRemote += dg.data.length;
        stats.packetsToRemote++;
      }
    }).ignore();
  }

  Future<_Session> _openSession(InternetAddress clientAddress, int clientPort) async {
    final upstream = await RawDatagramSocket.bind(
      _remoteAddress!.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
      0,
    );
    final session = _Session(clientAddress, clientPort, upstream);
    session.subscription = upstream.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = upstream.receive()) != null) {
        final d = dg!;
        // Drop anything that does not come from the remote server.
        if (d.address.address != _remoteAddress!.address || d.port != config.remotePort) continue;
        final proxy = _proxy;
        if (proxy == null) return;
        session.lastActive = DateTime.now();
        if (proxy.send(d.data, clientAddress, clientPort) > 0) {
          stats.bytesToClients += d.data.length;
          stats.packetsToClients++;
        }
      }
    });
    stats.activeSessions++;
    stats.totalSessions++;
    _emit(BridgeLogLevel.info, 'Client ${session.key} connected');
    _changed();
    return session;
  }

  void _closeSession(_Session s, {required String reason}) {
    s.subscription?.cancel();
    s.upstream.close();
    stats.activeSessions = (stats.activeSessions - 1).clamp(0, 1 << 30);
    _emit(BridgeLogLevel.info, 'Client ${s.key} disconnected ($reason)');
  }

  Future<void> _reapIdleSessions() async {
    final now = DateTime.now();
    for (final entry in _sessions.entries.toList()) {
      final _Session s;
      try {
        s = await entry.value;
      } catch (_) {
        continue;
      }
      if (now.difference(s.lastActive) > config.sessionIdleTimeout) {
        _sessions.remove(entry.key);
        _closeSession(s, reason: 'idle');
        _changed();
      }
    }
  }
}
