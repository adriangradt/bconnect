# Build, test and publish

Everything runs on the homelab server (`adriansserver`, Ubuntu 26.04, x86_64).
No GitHub, no hosted CI.

## Toolchain

Installed by `~/dev-tools/install-toolchain.sh`:

- OpenJDK 21 (apt, `/usr/lib/jvm/java-21-openjdk-amd64`)
- Flutter 3.47.7 stable in `~/dev-tools/flutter` (Dart 3.13.5)
- Android SDK in `~/dev-tools/android-sdk` (platform 36, build-tools 36.0.0, NDK pulled by Gradle)

Load it into a shell with:

    source ~/dev-tools/env.sh

## Tests

    flutter analyze
    flutter test                       # 32 tests: codecs, real UDP over loopback, UI
    BEDROCK_LIVE_HOST=stalincraft.de flutter test test/live_server_test.dart

The live test pings the real server and runs a RakNet Open Connection
Request 1 / Reply 1 handshake through a running bridge.

## Android release

    deploy/release-android.sh          # analyze, test, build, verify, publish
    deploy/release-android.sh --live   # plus the live server test

Before you build a new version, raise `version:` in `pubspec.yaml`
(for example `1.0.1+2`). Android refuses updates with the same version code.

### Signing key

- Keystore: `~/.bedrockbridge-signing/release.jks` (PKCS12, RSA 4096, alias `bedrockbridge`)
- Passwords: `~/.bedrockbridge-signing/key.properties` (mode 600)
- Certificate: `CN=BedrockBridge, O=stalincraft.de, C=DE`,
  SHA-256 `c18df033ddb0169c1aaf65fb2f7d33cc2feeac24cbd5674b4bd1c4f4ba51f234`

**Back up this directory.** Without this key, no future APK can update an
installed copy; users would have to uninstall first. Another path can be set
with `BEDROCKBRIDGE_KEY_PROPERTIES`. Without a key file the build falls back
to debug keys, and `publish.py` then refuses to publish.

## Publishing

`deploy/publish.py` checks the APK with `apksigner` (signature, release
signer, package name), copies it to
`/var/www/bedrockbridge/downloads/BedrockBridge.apk`, and regenerates
`index.html` and `SHA256SUMS.txt` from the files that are online.
The page only offers a download for a file that passed these checks.

An IPA is published with:

    deploy/publish.py --ipa /path/to/BedrockBridge.ipa

It must contain `Payload/*.app` with bundle ID `de.stalincraft.bedrockbridge`,
`embedded.mobileprovision` and `_CodeSignature`. The code signature itself can
only be checked on macOS.

## Web server

nginx serves the page from `/etc/nginx/conf.d/stalincraft.de.conf`
(source: `~/stalincraft-web/nginx/stalincraft.de.conf`):

- `location = /bedrockbridge` redirects to `/bedrockbridge/`
- `location ^~ /bedrockbridge/` uses alias `/var/www/bedrockbridge/`
- `location ^~ /bedrockbridge/downloads/` sets the APK MIME type, no listing

All locations allow only GET/HEAD and use the existing `sc_seiten` rate limit.
The server-wide security headers (CSP, HSTS, X-Frame-Options) apply.
The previous config is in `/etc/nginx/backup/`.

## iOS build for AltStore Classic (Codemagic, no Mac)

iOS apps are distributed via **AltStore Classic**. AltStore re-signs every
app with the user's own Apple ID, so the IPA is built **unsigned** and no
Apple Developer account is needed. Compiling still needs macOS and Xcode;
that runs on Codemagic (free plan: 500 macOS M2 minutes per month, one
build takes roughly 10–15 minutes).

Codemagic clones the code from the homelab, not from GitHub:

- Bare repository `/srv/git/bedrockbridge.git` (remote `homelab` of this checkout)
- Served read-only over HTTPS: `https://stalincraft.de/git/bedrockbridge.git`
  (nginx → fcgiwrap → `git-http-backend`, only `git-upload-pack`, push is refused)
- Basic auth user `codemagic`, password in `~/.bedrockbridge-codemagic/git-credentials`
  (hash in `/etc/nginx/bedrockbridge-git.htpasswd`)

### One-time setup in Codemagic

1. Sign up at https://codemagic.io (free personal account).
2. Add application → **Other** (Git repository URL) →
   URL `https://stalincraft.de/git/bedrockbridge.git`, private repository,
   username and password from `~/.bedrockbridge-codemagic/git-credentials`.
   Project type: Flutter App. Codemagic reads `codemagic.yaml`.
3. Team settings (Personal account) → Integrations → **Codemagic API** → Show,
   then on the server: `nano ~/.bedrockbridge-codemagic/api-token`
   (paste the token, save; `chmod 600` the file).

### Each iOS release

    git commit -am "…"            # the build uses the pushed commit
    deploy/codemagic-ios.py       # push, build on Codemagic, download, check, publish

The workflow `ios-altstore` in `codemagic.yaml` runs the tests, then
`deploy/build-ios-altstore.sh` (`flutter build ios --release --no-codesign`,
then packs `Payload/Runner.app` into `build/BedrockBridge.ipa`).
`deploy/publish.py --ipa-only` checks the IPA: bundle ID, arm64 Mach-O
executable, `Flutter.framework` and `App.framework`, and that it is **not**
signed. It then publishes, without touching the APK:

- `https://stalincraft.de/bedrockbridge/downloads/BedrockBridge.ipa`
- `https://stalincraft.de/bedrockbridge/altstore.json`, the AltStore source
- the iOS card on the page with an `altstore-classic://source?url=…` button

`deploy/build-ios-altstore.sh` also works on any Mac, if one is available.

Limits on iOS with AltStore (free Apple ID):

1. No multicast entitlement. Free Apple IDs cannot get
   `com.apple.developer.networking.multicast`, and iOS blocks UDP broadcast
   without it. So **LAN scan and the bridge's LAN discovery do not work on
   iOS**. The app replaces the LAN scan on iOS with unicast pings to every
   host of the own /24 network; that only needs the local network permission
   (`NSLocalNetworkUsageDescription`, asked on first use). Server status
   works. Consoles only find a bridge via broadcast, so the bridge must run on
   an Android phone in the same Wi-Fi.
   The unsigned build carries no entitlements, so `Runner.entitlements` has
   no effect here. It only matters for a later App Store or TestFlight build
   with an approved entitlement.
2. iOS suspends apps in the background, so a bridge only runs while the app
   is in the foreground.
3. Apps signed with a free Apple ID expire after 7 days. AltStore refreshes
   them automatically when AltServer is reachable.
