# BedrockBridge

Flutter app for Android and iOS that makes remote Minecraft Bedrock servers
appear in the LAN tab of consoles, tablets and phones on the same Wi-Fi.

Download page: https://stalincraft.de/bedrockbridge/

## What it does

- **Server status**: pings saved Bedrock servers (RakNet unconnected ping) and
  shows MOTD, players, version and latency.
- **LAN discovery**: broadcasts unconnected pings to UDP 19132/19133 on the
  limited and directed broadcast addresses and lists every pong, like the
  in-game LAN tab.
- **Bridge**: answers LAN discovery pings with the remote server's MOTD
  (own GUID, bridge port in the port fields). Two modes:
  - *Transfer* (default, like BedrockTogether): the bridge runs a minimal
    RakNet server, lets the console log in (network settings, no
    encryption) and spawns it in an empty world, the way BedrockConnect
    does. Once the client reports itself initialised, the bridge sends a
    Transfer packet (`reload_world = false`) to the remote server. The
    console then connects directly; the phone is only needed while joining.
    Minecraft ignores a Transfer that arrives before the player is in a
    world, and stays in the empty world with `reload_world = true`.
    The spawn packets per version (1.19.30 up to 26.x) are generated with
    PrismarineJS bedrock-protocol: `tool/spawn/gen_templates.js` writes
    `assets/spawn_templates.json.gz`.
  - *Relay*: every datagram is relayed through the phone, with one upstream
    socket per client. Only for servers that refuse transferred players.

## Layout

| Path | Content |
|------|---------|
| `lib/src/raknet/` | Packet codecs, MOTD parser, pinger, LAN scanner (pure Dart, `dart:io`) |
| `lib/src/raknet/connection.dart` | RakNet server side: frames, ACK/NAK, splits, ordering, connection handshake |
| `lib/src/bridge/transfer.dart` | Bedrock login hand-off: network settings, PlayStatus, Transfer |
| `lib/src/bridge/bridge.dart` | Discovery responder, transfer and relay modes |
| `lib/src/platform/native_network.dart` | Method channel to native code |
| `lib/src/app/` | State (`AppController`) and persisted server list |
| `lib/src/ui/` | Material 3 UI: Server, LAN, Bridge tabs (German) |
| `android/app/src/main/kotlin/…/MainActivity.kt` | Multicast lock, broadcast addresses, service start |
| `android/app/src/main/kotlin/…/BridgeService.kt` | Foreground service with Wi-Fi lock |
| `ios/Runner/AppDelegate.swift` | Broadcast addresses via `getifaddrs` |
| `test/` | Codec tests, real-UDP network tests, transfer + interop tests, live test, widget tests |
| `tool/interop/` | Interop client using PrismarineJS bedrock-protocol |
| `deploy/` | Download page template, `publish.py`, `release-android.sh` |

See [BUILD.md](BUILD.md) for building, testing and publishing, and
[STATUS.md](STATUS.md) for what is verified and what is blocked.
