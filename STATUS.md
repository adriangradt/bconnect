# Status – 15.10.2026

## Live

| URL | State |
|-----|-------|
| https://stalincraft.de/bedrockbridge/ | Download page, 200 |
| https://stalincraft.de/bedrockbridge/downloads/BedrockBridge.apk | Release APK 1.2.0 (code 4, spawn + transfer), 50.5 MB, 200 |
| https://stalincraft.de/bedrockbridge/downloads/BedrockBridge.ipa | Unsigned IPA 1.2.0 (build 4) for AltStore Classic, 6.7 MB, 200 |
| https://stalincraft.de/bedrockbridge/altstore.json | AltStore Classic source with BedrockBridge 1.2.0, 200 |
| https://stalincraft.de/bedrockbridge/downloads/SHA256SUMS.txt | Checksums, 200 |

IPA SHA-256: `97d6b3b18d904a57f428663b0ec353a9c666950759666265aa41e964ed19a43b`

APK SHA-256: `0303469a0e0040976d31123f95ea77a774e98352c744c9e8680b407de2e76111`

The existing site (`/`, `/spieler`, …) and all other vhosts are unchanged and
still answer.

## Verified

- `flutter analyze`: no issues.
- `flutter test`: 56 passed (including 4 interop runs with bedrock-protocol), 2 live tests skipped by default.
- Transfer mode (1.2.0) works with a real client: Minecraft 26.3 (1.26.52,
  protocol 2193) on Windows joined a test bridge on the homelab, spawned in
  the empty world and was transferred to stalincraft.de. Earlier variants
  were checked on the same client and failed: Transfer right after login or
  after the resource packs is ignored, a spawn without structure data and
  registries is dropped, and `reload_world = true` keeps the player in the
  empty world.
- Interop: PrismarineJS bedrock-protocol clients (1.19.30, 1.20.50, 1.21.0,
  1.26.51) spawn in the empty world and receive the Transfer.
- iOS: Codemagic build 6ad0bdbdd0160b2eb0746a35 (Mac mini M2, commit c93ce56)
  passed tests and compiled the app including the Swift code. IPA checked:
  bundle ID, arm64 executable, Flutter and App frameworks, min iOS 15.0,
  no provisioning profile, no entitlements (frameworks carry the usual
  ad-hoc signature), local network usage text present. Online file matches
  the downloaded artifact byte for byte.
- Live test against the real stalincraft.de Geyser server (local and via the
  public domain): ping works; LAN discovery through the bridge shows the real
  MOTD with the relay port; RakNet Open Connection Request 1 → Reply 1
  through the bridge returns the real server GUID and MTU 1400.
- APK: v2 signature verifies with the release key; package
  `de.stalincraft.bedrockbridge`; minSdk 24 (Android 7.0), targetSdk 36;
  ABIs arm64-v8a, armeabi-v7a, x86_64.
- Download over HTTPS returns the same SHA-256 as the build output, with
  MIME type `application/vnd.android.package-archive`.

## Not verified yet

- **No test on a real Android device or emulator.** The server has no KVM
  (`/dev/kvm` missing), so an emulator cannot run here. Needed: install the
  APK on a phone, start the bridge for stalincraft.de, then join from a
  console or second device via the LAN tab.
- The download page was checked over HTTP only, not visually in a browser.
- IPA not yet installed on an iPhone via AltStore Classic.

## Blockers and limits

1. **Device tests pending.** APK and IPA are built and checked, but not yet
   run on a phone. Install, then test server status, LAN scan and bridge.
2. **iOS LAN limits with AltStore.** Free Apple IDs cannot get the multicast
   entitlement. LAN scan on iOS uses unicast pings across the /24 instead;
   a bridge on an iPhone cannot be found by consoles. Server status works.
3. **Original master prompt missing.** Features were derived from the
   change request. Send the master prompt to check for missing features.
