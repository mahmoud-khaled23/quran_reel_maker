#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get --enforce-lockfile
# Keep the build's pub/tooling phase: Flutter uses it to regenerate the Android
# plugin registrant without dev-only plugins such as integration_test.
flutter build apk --release --split-per-abi
mkdir -p output/android
cp build/app/outputs/flutter-apk/app-*-release.apk output/android/
echo "Development-signed APKs copied to output/android. Configure production signing before publishing."
