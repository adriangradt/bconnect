#!/usr/bin/env bash
# Full Android release on the homelab: analyze, test, build, verify, publish.
# Usage: deploy/release-android.sh [--live]   (--live also runs tests against stalincraft.de)
set -euo pipefail
cd "$(dirname "$0")/.."
source "$HOME/dev-tools/env.sh"
LOG_DIR="$HOME/bedrockbridge-build-logs"
mkdir -p "$LOG_DIR"
stamp=$(date +%F-%H%M%S)

flutter pub get
flutter analyze
flutter test
if [[ "${1:-}" == "--live" ]]; then
  BEDROCK_LIVE_HOST=stalincraft.de flutter test test/live_server_test.dart
fi
flutter build apk --release 2>&1 | tee "$LOG_DIR/apk-$stamp.log"
python3 deploy/publish.py
