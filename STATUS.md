# Status – 15.10.2026

## Live

| URL | State |
|-----|-------|
| https://stalincraft.de/bedrockbridge/ | Download page, 200 |
| https://stalincraft.de/bedrockbridge/downloads/BedrockBridge.apk | Release APK 1.0.1 (code 2, new icon), 50.0 MB, 200 |
| https://stalincraft.de/bedrockbridge/downloads/BedrockBridge.ipa | Unsigned IPA 1.0.1 (build 2) for AltStore Classic, 6.7 MB, 200 |
| https://stalincraft.de/bedrockbridge/altstore.json | AltStore Classic source with BedrockBridge 1.0.1, 200 |
| https://stalincraft.de/bedrockbridge/downloads/SHA256SUMS.txt | Checksums, 200 |

IPA SHA-256: `578b7ea49382782da2b9b7b19ef7f86d89041277a35e1e316f8a97daeaea0a7a`

APK SHA-256: `e03143190b1a59ecc01704c548b9b65de45a275ca312ed9fcae14056f12bfa83`

The existing site (`/`, `/spieler`, …) and all other vhosts are unchanged and
still answer.

## Verified

- `flutter analyze`: no issues.
- `flutter test`: 53 passed (including 4 interop runs with bedrock-protocol), 2 live tests skipped by default.
- Transfer mode (1.1.0): an independent Bedrock client (PrismarineJS
  bedrock-protocol, versions 1.19.20 to 1.26.51) joins the bridge and
  receives login success plus a Transfer packet to the configured server.
  Not yet tried with a real console.
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
