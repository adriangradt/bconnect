#!/usr/bin/env bash
# Builds the unsigned IPA for AltStore Classic. Runs on macOS with Xcode and Flutter 3.47.7.
# AltStore re-signs the app with each user's Apple ID, so no Apple Developer account is needed.
#
# Usage: deploy/build-ios-altstore.sh [user@server]
#   With a server, the IPA is copied there and published with deploy/publish.py.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname)" == "Darwin" ]] || { echo "needs macOS with Xcode" >&2; exit 1; }

flutter pub get
flutter test
flutter build ios --release --no-codesign

rm -rf build/ipa-altstore && mkdir -p build/ipa-altstore/Payload
cp -R build/ios/iphoneos/Runner.app build/ipa-altstore/Payload/
(cd build/ipa-altstore && zip -qry ../BedrockBridge.ipa Payload)
echo "IPA: build/BedrockBridge.ipa ($(du -h build/BedrockBridge.ipa | cut -f1))"

if [[ $# -ge 1 ]]; then
  scp build/BedrockBridge.ipa "$1:bedrockbridge/build/BedrockBridge.ipa"
  ssh "$1" 'cd bedrockbridge && python3 deploy/publish.py --ipa build/BedrockBridge.ipa'
fi
