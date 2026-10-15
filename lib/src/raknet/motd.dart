/// The semicolon-separated server ID string a Bedrock server sends in its pong.
///
/// ```text
/// MCPE;<line 1>;<protocol>;<version>;<players>;<max players>;<server GUID>;
/// <line 2>;<game mode>;<game mode numeric>;<IPv4 port>;<IPv6 port>;
/// ```
///
/// Unknown trailing fields are kept so a round trip does not lose data.
class BedrockMotd {
  BedrockMotd({
    this.edition = 'MCPE',
    required this.line1,
    required this.protocol,
    required this.version,
    required this.players,
    required this.maxPlayers,
    this.serverGuid = '',
    this.line2 = '',
    this.gameMode = 'Survival',
    this.gameModeNumeric = 1,
    this.portV4,
    this.portV6,
    this.extra = const [],
  });

  final String edition;
  final String line1;
  final int protocol;
  final String version;
  final int players;
  final int maxPlayers;
  final String serverGuid;
  final String line2;
  final String gameMode;
  final int gameModeNumeric;
  final int? portV4;
  final int? portV6;
  final List<String> extra;

  /// Parses a server ID string. Returns null if it is not a Bedrock MOTD.
  static BedrockMotd? tryParse(String raw) {
    final f = raw.split(';');
    // A trailing ';' yields an empty last element.
    if (f.isNotEmpty && f.last.isEmpty) f.removeLast();
    if (f.length < 6 || (f[0] != 'MCPE' && f[0] != 'MCEE')) return null;
    String at(int i) => i < f.length ? f[i] : '';
    int? intAt(int i) => int.tryParse(at(i).trim());
    return BedrockMotd(
      edition: f[0],
      line1: at(1),
      protocol: intAt(2) ?? 0,
      version: at(3),
      players: intAt(4) ?? 0,
      maxPlayers: intAt(5) ?? 0,
      serverGuid: at(6),
      line2: at(7),
      gameMode: at(8),
      gameModeNumeric: intAt(9) ?? 1,
      portV4: intAt(10),
      portV6: intAt(11),
      extra: f.length > 12 ? f.sublist(12) : const [],
    );
  }

  /// Line 1 with Minecraft formatting codes (§x) removed, for display.
  String get plainName => stripFormatting(line1);
  String get plainLine2 => stripFormatting(line2);

  static String stripFormatting(String s) => s.replaceAll(RegExp('§.'), '');

  BedrockMotd copyWith({
    String? line1,
    String? line2,
    String? serverGuid,
    int? portV4,
    int? portV6,
    int? players,
    int? maxPlayers,
  }) {
    return BedrockMotd(
      edition: edition,
      line1: line1 ?? this.line1,
      protocol: protocol,
      version: version,
      players: players ?? this.players,
      maxPlayers: maxPlayers ?? this.maxPlayers,
      serverGuid: serverGuid ?? this.serverGuid,
      line2: line2 ?? this.line2,
      gameMode: gameMode,
      gameModeNumeric: gameModeNumeric,
      portV4: portV4 ?? this.portV4,
      portV6: portV6 ?? this.portV6,
      extra: extra,
    );
  }

  String serialize() {
    // ';' inside a field would shift every following field for the client.
    String clean(String s) => s.replaceAll(';', ',');
    final fields = <String>[
      edition,
      clean(line1),
      '$protocol',
      clean(version),
      '$players',
      '$maxPlayers',
      serverGuid,
      clean(line2),
      clean(gameMode),
      '$gameModeNumeric',
      portV4?.toString() ?? '',
      portV6?.toString() ?? '',
      ...extra,
    ];
    return '${fields.join(';')};';
  }

  @override
  String toString() => serialize();
}
