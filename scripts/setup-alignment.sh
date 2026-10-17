#!/usr/bin/env bash
set -euo pipefail
alignment_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$alignment_root"
python3 -c 'import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 13) else "Use Python 3.11–3.13 for the pinned alignment runtime.")'
if ! command -v ffmpeg >/dev/null; then
  printf '%s\n' 'Install FFmpeg and put ffmpeg on PATH before setting up alignment.' >&2
  exit 1
fi
python3 -m venv .alignment-venv
.alignment-venv/bin/python -m pip install --no-cache-dir --only-binary=:all: --require-hashes -r alignment_worker/requirements.lock
.alignment-venv/bin/python -m alignment_worker.model "$@"
printf '\nSelect this worker in the app: %s/scripts/alignment-worker.sh\n' "$alignment_root"
