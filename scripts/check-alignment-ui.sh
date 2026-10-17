#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get --enforce-lockfile
xvfb-run -a -s '-screen 0 1366x900x24' flutter test integration_test/alignment_flow_test.dart -d linux --dart-define=QRM_REAL_ALIGNMENT=true
