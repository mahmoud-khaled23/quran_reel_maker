#!/usr/bin/env bash
# Real release/R8/JNI stress probe in the separately provisioned benchmark app.
# --offline is explicit authorization to temporarily disable/restore networking.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
alignment_adb="${ADB:-adb}"
alignment_package=com.example.quran_reel_maker.benchmark
mkdir -p output
flutter build apk --release --config-only --target integration_test/alignment_release_runner.dart --dart-define=QRM_ALIGNMENT_BENCHMARK=true
flutter build apk --release --split-per-abi --target-platform android-arm64 --no-pub --target integration_test/alignment_release_runner.dart --dart-define=QRM_ALIGNMENT_BENCHMARK=true
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk output/alignment-benchmark-release.apk
"$alignment_adb" install -r output/alignment-benchmark-release.apk
alignment_wifi=unchanged
alignment_data=unchanged
alignment_logcat_pid=
alignment_monitor_pid=
cleanup() {
  if [[ -n "$alignment_monitor_pid" ]]; then kill "$alignment_monitor_pid" 2>/dev/null || true; wait "$alignment_monitor_pid" 2>/dev/null || true; fi
  if [[ -n "$alignment_logcat_pid" ]]; then kill "$alignment_logcat_pid" 2>/dev/null || true; wait "$alignment_logcat_pid" 2>/dev/null || true; fi
  if [[ "$alignment_wifi" == 1 ]]; then "$alignment_adb" shell svc wifi enable; fi
  if [[ "$alignment_data" == 1 ]]; then "$alignment_adb" shell svc data enable; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [[ "${1:-}" == --offline ]]; then
  alignment_wifi="$("$alignment_adb" shell settings get global wifi_on | tr -d '\r')"
  alignment_data="$("$alignment_adb" shell settings get global mobile_data | tr -d '\r')"
  [[ "$alignment_wifi" =~ ^[01]$ && "$alignment_data" =~ ^[01]$ ]] || { echo 'Cannot determine network state; no changes made.' >&2; exit 1; }
  printf 'wifi=%s\nmobile_data=%s\n' "$alignment_wifi" "$alignment_data" > output/alignment-release-network-before.txt
  "$alignment_adb" shell svc wifi disable
  "$alignment_adb" shell svc data disable
  for alignment_attempt in $(seq 1 10); do
    "$alignment_adb" shell dumpsys connectivity | sed -n '/^Active default network:/p' > output/alignment-release-connectivity-offline.txt
    if rg -q '^Active default network: none' output/alignment-release-connectivity-offline.txt; then break; fi
    sleep 1
  done
  rg -q '^Active default network: none' output/alignment-release-connectivity-offline.txt || { echo 'Offline state not verified.' >&2; exit 1; }
fi
"$alignment_adb" shell am force-stop "$alignment_package"
# Read only newly arriving Flutter logs; do not clear device logs.
"$alignment_adb" logcat -T 1 -v brief flutter:I '*:S' > output/alignment-release-logcat.txt &
alignment_logcat_pid=$!
"$alignment_adb" shell am start -n "$alignment_package/com.example.quran_reel_maker.MainActivity"
ADB="$alignment_adb" bash scripts/alignment/monitor-device.sh output/alignment-release-samples 240 > output/alignment-release-monitor.log 2>&1 &
alignment_monitor_pid=$!
for alignment_attempt in $(seq 1 240); do
  # logcat -T 1 may include the previous process's last DONE line. Only accept
  # completion after this launch's START marker, never stale benchmark evidence.
  if awk '/QRM_RELEASE_START/ {started=1} started && /QRM_RELEASE_DONE/ {done=1} END {exit !done}' output/alignment-release-logcat.txt; then
    rg 'QRM_RELEASE_CASE|QRM_RELEASE_DONE' output/alignment-release-logcat.txt
    awk '/QRM_RELEASE_START/ {started=1} started && /QRM_RELEASE_DONE passed/ {passed=1} END {exit !passed}' output/alignment-release-logcat.txt
    exit $?
  fi
  sleep 1
done
echo 'Release probe timed out. Inspect output/alignment-release-logcat.txt.' >&2
exit 1
