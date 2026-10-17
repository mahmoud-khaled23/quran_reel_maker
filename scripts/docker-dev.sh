#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p output
export DEV_UID="$(id -u)" DEV_GID="$(id -g)"
docker compose run --rm dev "${@:-bash}"
