import 'dart:convert';

import '../raknet/packets.dart';

/// A remote Bedrock server the user saved.
class SavedServer {
  SavedServer({
    required this.id,
    required this.name,
    required this.host,
    this.port = bedrockDefaultPort,
    this.lanName = '',
    this.relay = false,
  });

  final String id;
  final String name;
  final String host;
  final int port;

  /// Name shown in the console's LAN list. Empty keeps the server's MOTD.
  final String lanName;

  /// Relay all traffic through the phone instead of transferring the
  /// console to the server after login. Only for servers that block transfers.
  final bool relay;

  String get endpoint => '$host:$port';

  SavedServer copyWith({String? name, String? host, int? port, String? lanName, bool? relay}) => SavedServer(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        lanName: lanName ?? this.lanName,
        relay: relay ?? this.relay,
      );

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'host': host, 'port': port, 'lanName': lanName, 'relay': relay};

  factory SavedServer.fromJson(Map<String, Object?> j) => SavedServer(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        host: j['host'] as String,
        port: (j['port'] as num?)?.toInt() ?? bedrockDefaultPort,
        lanName: j['lanName'] as String? ?? '',
        relay: j['relay'] as bool? ?? false,
      );

  static String encodeList(List<SavedServer> list) => jsonEncode([for (final s in list) s.toJson()]);

  static List<SavedServer> decodeList(String raw) {
    final data = jsonDecode(raw);
    if (data is! List) return [];
    return [
      for (final e in data)
        if (e is Map) SavedServer.fromJson(e.cast<String, Object?>()),
    ];
  }
}

/// Validates host and port input. Returns an error text or null.
String? validateHost(String? v) {
  final s = v?.trim() ?? '';
  if (s.isEmpty) return 'Adresse fehlt';
  if (s.contains(' ') || s.contains('/')) return 'Nur Hostname oder IP eintragen';
  // Exactly one colon means "host:port"; IPv6 literals have several.
  if (':'.allMatches(s).length == 1) return 'Port bitte ins Port-Feld eintragen';
  return null;
}

String? validatePort(String? v) {
  final p = int.tryParse(v?.trim() ?? '');
  if (p == null || p < 1 || p > 65535) return 'Port 1–65535';
  return null;
}
