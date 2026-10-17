#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p output
export DEV_UID="$(id -u)" DEV_GID="$(id -g)"
docker compose run --rm dev bash -c 'flutter pub get --enforce-lockfile && xvfb-run -a -s "-screen 0 1366x900x24" flutter test integration_test/editor_flow_test.dart -d linux'
