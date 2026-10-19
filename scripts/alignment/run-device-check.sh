#!/usr/bin/env bash
# Explicit --offline temporarily disables connectivity; always restores prior state.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
alignment_adb="${ADB:-adb}"
alignment_serial="$("$alignment_adb" get-serialno)"
mkdir -p output
alignment_wifi=unchanged
alignment_data=unchanged
restore_network() {
  if [[ "$alignment_wifi" == 1 ]]; then "$alignment_adb" shell svc wifi enable; fi
  if [[ "$alignment_data" == 1 ]]; then "$alignment_adb" shell svc data enable; fi
}
trap restore_network EXIT
trap 'exit 130' INT TERM
if [[ "${1:-}" == --offline ]]; then
  alignment_wifi="$("$alignment_adb" shell settings get global wifi_on | tr -d '\r')"
  alignment_data="$("$alignment_adb" shell settings get global mobile_data | tr -d '\r')"
  [[ "$alignment_wifi" =~ ^[01]$ && "$alignment_data" =~ ^[01]$ ]] || { echo 'Cannot determine network state; no connectivity changes made.' >&2; exit 1; }
  printf 'wifi=%s\nmobile_data=%s\n' "$alignment_wifi" "$alignment_data" > output/alignment-device-network-before.txt
  "$alignment_adb" shell svc wifi disable
  "$alignment_adb" shell svc data disable
  for alignment_attempt in $(seq 1 10); do
    "$alignment_adb" shell dumpsys connectivity | sed -n '/^Active default network:/p' > output/alignment-device-connectivity-offline.txt
    if rg -q '^Active default network: none' output/alignment-device-connectivity-offline.txt; then break; fi
    sleep 1
  done
  rg -q '^Active default network: none' output/alignment-device-connectivity-offline.txt || { echo 'Phone still has a default network; offline claim rejected.' >&2; exit 1; }
fi
# Preserve partial failure reports as well as successes. Never mask a test's exit
# status with a successful report copy, and never read a previous run's report.
"$alignment_adb" shell run-as com.example.quran_reel_maker.benchmark rm -f files/alignment-device-report.json
alignment_status=0
flutter test integration_test/android_alignment_test.dart -d "$alignment_serial" --no-pub --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true || alignment_status=$?
"$alignment_adb" exec-out run-as com.example.quran_reel_maker.benchmark cat files/alignment-device-report.json > output/alignment-device-report.json || true
exit "$alignment_status"
