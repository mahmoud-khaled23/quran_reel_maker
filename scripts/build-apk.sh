#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get --enforce-lockfile
# Regenerate explicitly after tests/pub get. The pinned Flutter can otherwise
# leave integration_test in GeneratedPluginRegistrant for a release build.
# https://github.com/flutter/flutter/issues/169336
flutter build apk --release --config-only
flutter build apk --release --split-per-abi --no-pub
mkdir -p output/android
cp build/app/outputs/flutter-apk/app-*-release.apk output/android/
(cd output/android && sha256sum app-*-release.apk > SHA256SUMS)
echo "Development-signed APKs copied to output/android. Configure production signing before publishing."
