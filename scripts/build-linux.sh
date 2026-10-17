#!/usr/bin/env bash
set -euo pipefail
flutter pub get --enforce-lockfile
flutter build linux --release --no-pub
mkdir -p /output/linux
cp -a build/linux/x64/release/bundle/. /output/linux/
