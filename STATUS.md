# Status – 15.10.2026

## Live

| URL | State |
|-----|-------|
| https://stalincraft.de/bedrockbridge/ | Download page, 200 |
| https://stalincraft.de/bedrockbridge/downloads/BedrockBridge.apk | Release APK 1.0.1 (code 2, new icon), 50.0 MB, 200 |
| https://stalincraft.de/bedrockbridge/downloads/BedrockBridge.ipa | 404 – no IPA built (see blockers) |
| https://stalincraft.de/bedrockbridge/altstore.json | AltStore Classic source, 200 (no app until an IPA exists) |
| https://stalincraft.de/bedrockbridge/downloads/SHA256SUMS.txt | Checksums, 200 |

APK SHA-256: `e03143190b1a59ecc01704c548b9b65de45a275ca312ed9fcae14056f12bfa83`

The existing site (`/`, `/spieler`, …) and all other vhosts are unchanged and
still answer.

## Verified

- `flutter analyze`: no issues.
- `flutter test`: 32 passed, 2 live tests skipped by default.
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
- Swift code in `ios/` was not compiled (needs Xcode).

## Blockers

1. **iOS IPA: waiting for Codemagic setup.** Everything on the homelab is
   ready: private Git endpoint `https://stalincraft.de/git/bedrockbridge.git`
   (clone tested from the internet, push refused), `codemagic.yaml`,
   `deploy/codemagic-ios.py`. Needed once from you: Codemagic account, app
   added with the Git URL and credentials, API token on the server
   (BUILD.md, "One-time setup in Codemagic"). The Swift code and the iOS
   build itself are unverified until the first Codemagic run.
2. **iOS LAN limits with AltStore.** Free Apple IDs cannot get the multicast
   entitlement. LAN scan on iOS uses unicast pings across the /24 instead;
   a bridge on an iPhone cannot be found by consoles. Server status works.
3. **Original master prompt missing.** Features were derived from the
   change request. Send the master prompt to check for missing features.
