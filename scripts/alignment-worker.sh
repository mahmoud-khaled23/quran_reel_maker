#!/usr/bin/env bash
set -euo pipefail
alignment_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$alignment_root"
alignment_python="${QRM_ALIGNMENT_PYTHON:-$alignment_root/.alignment-venv/bin/python}"
if [[ ! -x "$alignment_python" ]]; then
  printf '%s\n' '{"protocol":1,"type":"error","code":"setup","message":"Run ./scripts/setup-alignment.sh in the project folder to install the local worker and verified model. Manual timing remains available."}'
  exit 1
fi
exec "$alignment_python" -m alignment_worker.worker "$@"
