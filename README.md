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
  (own GUID, relay port in the port fields) and relays every other datagram
  between each client and the remote server. Each client gets its own
  upstream UDP socket, so the RakNet handshake stays end to end and several
  players can join at once. Idle sessions close after 30 s.

## Layout

| Path | Content |
|------|---------|
| `lib/src/raknet/` | Packet codecs, MOTD parser, pinger, LAN scanner (pure Dart, `dart:io`) |
| `lib/src/bridge/bridge.dart` | UDP relay with discovery responder |
| `lib/src/platform/native_network.dart` | Method channel to native code |
| `lib/src/app/` | State (`AppController`) and persisted server list |
| `lib/src/ui/` | Material 3 UI: Server, LAN, Bridge tabs (German) |
| `android/app/src/main/kotlin/…/MainActivity.kt` | Multicast lock, broadcast addresses, service start |
| `android/app/src/main/kotlin/…/BridgeService.kt` | Foreground service with Wi-Fi lock |
| `ios/Runner/AppDelegate.swift` | Broadcast addresses via `getifaddrs` |
| `test/` | Codec tests, real-UDP network tests, live test, widget tests |
| `deploy/` | Download page template, `publish.py`, `release-android.sh` |

See [BUILD.md](BUILD.md) for building, testing and publishing, and
[STATUS.md](STATUS.md) for what is verified and what is blocked.
