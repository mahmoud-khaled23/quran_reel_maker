#!/usr/bin/env bash
set -euo pipefail
flutter pub get --enforce-lockfile
flutter build linux --release --no-pub
destination="${1:-output/linux}"
mkdir -p "$destination"
cp -a build/linux/x64/release/bundle/. "$destination/"
