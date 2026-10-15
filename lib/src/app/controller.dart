import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bridge.dart';
import '../bridge/transfer.dart';
import '../platform/native_network.dart';
import '../raknet/lan_discovery.dart';
import '../raknet/packets.dart';
import '../raknet/ping.dart';
import 'models.dart';

/// Ping state of one saved server.
class ServerStatus {
  const ServerStatus({this.pinging = false, this.result, this.error, this.checkedAt});
  final bool pinging;
  final PingResult? result;
  final String? error;
  final DateTime? checkedAt;
}

/// App state: saved servers, LAN scan, and the running bridge.
class AppController extends ChangeNotifier {
  AppController({SharedPreferencesAsync? prefs}) : _prefs = prefs ?? SharedPreferencesAsync();

  static const _serversKey = 'servers.v1';
  static const maxLogEntries = 300;

  final SharedPreferencesAsync _prefs;

  List<SavedServer> servers = [];
  final Map<String, ServerStatus> status = {};

  List<DiscoveredServer> lanServers = [];
  bool scanning = false;
  String? scanError;
  DateTime? lastScan;

  BedrockBridge? bridge;
  SavedServer? bridgedServer;
  bool bridgeStarting = false;
  String? bridgeError;
  final List<BridgeLogEntry> bridgeLog = [];
  List<InternetAddress> localAddresses = [];

  SpawnTemplateStore? _spawnTemplates;

  StreamSubscription<BridgeLogEntry>? _logSub;
  StreamSubscription<void>? _changeSub;
  Timer? _notifyThrottle;

  bool get bridgeRunning => bridge?.isRunning == true;

  Future<void> load() async {
    final raw = await _prefs.getString(_serversKey);
    if (raw != null) {
      try {
        servers = SavedServer.decodeList(raw);
      } on FormatException {
        servers = [];
      }
    } else {
      // First start: preset with the home server of this app.
      servers = [SavedServer(id: _newId(), name: 'stalincraft.de', host: 'stalincraft.de')];
      await _save();
    }
    notifyListeners();
    unawaited(pingAll());
    unawaited(_refreshLocalAddresses());
  }

  Future<void> _save() => _prefs.setString(_serversKey, SavedServer.encodeList(servers));

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}';

  Future<void> addServer({
    required String name,
    required String host,
    required int port,
    String lanName = '',
    bool relay = false,
  }) async {
    final s = SavedServer(
      id: _newId(),
      name: name.trim().isEmpty ? host.trim() : name.trim(),
      host: host.trim(),
      port: port,
      lanName: lanName.trim(),
      relay: relay,
    );
    servers = [...servers, s];
    await _save();
    notifyListeners();
    unawaited(ping(s));
  }

  Future<void> updateServer(SavedServer s) async {
    servers = [for (final e in servers) e.id == s.id ? s : e];
    await _save();
    notifyListeners();
    unawaited(ping(s));
  }

  Future<void> removeServer(SavedServer s) async {
    if (bridgedServer?.id == s.id) await stopBridge();
    servers = servers.where((e) => e.id != s.id).toList();
    status.remove(s.id);
    await _save();
    notifyListeners();
  }

  Future<void> pingAll() => Future.wait(servers.map(ping));

  Future<void> ping(SavedServer s) async {
    status[s.id] = ServerStatus(pinging: true, result: status[s.id]?.result);
    notifyListeners();
    try {
      final r = await BedrockPinger.ping(s.host, s.port);
      status[s.id] = ServerStatus(result: r, checkedAt: DateTime.now());
    } on PingException catch (e) {
      status[s.id] = ServerStatus(error: e.message, checkedAt: DateTime.now());
    } on SocketException catch (e) {
      status[s.id] = ServerStatus(error: e.osError?.message ?? e.message, checkedAt: DateTime.now());
    }
    notifyListeners();
  }

  Future<void> scanLan() async {
    if (scanning) return;
    scanning = true;
    scanError = null;
    lanServers = [];
    notifyListeners();
    await NativeNetwork.acquireMulticastLock();
    try {
      final scanner = LanScanner(
        broadcastAddresses: await NativeNetwork.broadcastAddresses(),
        extraTargets: Platform.isIOS ? await _unicastSweepTargets() : const [],
      );
      lanServers = await scanner.scan(
        duration: const Duration(seconds: 4),
        onFound: (s) {
          lanServers = [...lanServers, s];
          notifyListeners();
        },
      );
      lastScan = DateTime.now();
    } on SocketException catch (e) {
      scanError = e.osError?.message ?? e.message;
    } finally {
      // The running bridge needs the lock for incoming broadcasts.
      if (!bridgeRunning) await NativeNetwork.releaseMulticastLock();
      scanning = false;
      notifyListeners();
    }
  }

  /// iOS fallback for the blocked broadcast: ping every host of the own /24.
  Future<List<({InternetAddress address, int port})>> _unicastSweepTargets() async {
    final own = await NativeNetwork.localAddresses();
    return [
      for (final a in own.where((a) => a.isLoopback == false).take(2))
        for (final h in subnetHosts(a)) (address: h, port: bedrockDefaultPort),
    ];
  }

  bool isOwnBridge(DiscoveredServer s) => bridge != null && s.serverGuid == bridge!.guid;

  Future<void> startBridge(SavedServer s) async {
    if (bridgeStarting) return;
    await stopBridge();
    bridgeStarting = true;
    bridgeError = null;
    bridgedServer = s;
    bridgeLog.clear();
    notifyListeners();

    _spawnTemplates ??= await _loadSpawnTemplates();
    final b = BedrockBridge(BridgeConfig(
      remoteHost: s.host,
      remotePort: s.port,
      displayName: s.lanName.isEmpty ? null : s.lanName,
      mode: s.relay ? BridgeMode.relay : BridgeMode.transfer,
      spawnTemplates: _spawnTemplates?.forProtocol,
    ));
    _logSub = b.log.listen((e) {
      bridgeLog.insert(0, e);
      if (bridgeLog.length > maxLogEntries) bridgeLog.removeLast();
      _throttledNotify();
    });
    _changeSub = b.changes.listen((_) => _throttledNotify());
    bridge = b;
    try {
      await NativeNetwork.acquireMulticastLock();
      await b.start();
      await NativeNetwork.startBridgeService(
        title: 'BedrockBridge aktiv',
        text: s.relay
            ? '${s.name} läuft über dieses Handy – App bitte offen lassen'
            : '${s.name} im LAN-Tab – nach dem Beitreten kannst du die App schließen',
      );
      unawaited(_refreshLocalAddresses());
    } catch (e) {
      bridgeError = e.toString();
      await _teardownBridge();
    } finally {
      bridgeStarting = false;
      notifyListeners();
    }
  }

  Future<SpawnTemplateStore?> _loadSpawnTemplates() async {
    try {
      final data = await rootBundle.load('assets/spawn_templates.json.gz');
      return SpawnTemplateStore.fromGzip(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    } on Object catch (e) {
      bridgeLog.insert(0, BridgeLogEntry(BridgeLogLevel.error, 'Spawn templates missing: $e'));
      return null;
    }
  }

  Future<void> stopBridge() async {
    if (bridge == null) return;
    await _teardownBridge();
    notifyListeners();
  }

  Future<void> _teardownBridge() async {
    final b = bridge;
    bridge = null;
    await _logSub?.cancel();
    await _changeSub?.cancel();
    _logSub = null;
    _changeSub = null;
    await b?.dispose();
    await NativeNetwork.stopBridgeService();
    await NativeNetwork.releaseMulticastLock();
  }

  Future<void> _refreshLocalAddresses() async {
    try {
      localAddresses = await NativeNetwork.localAddresses();
      notifyListeners();
    } on SocketException {
      // Interface listing is informational only.
    }
  }

  /// Socket traffic can produce hundreds of updates per second; the UI
  /// needs at most a few.
  void _throttledNotify() {
    if (_notifyThrottle?.isActive == true) return;
    _notifyThrottle = Timer(const Duration(milliseconds: 250), notifyListeners);
  }

  @override
  void dispose() {
    _notifyThrottle?.cancel();
    unawaited(_teardownBridge());
    super.dispose();
  }
}
