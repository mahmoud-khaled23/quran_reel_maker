#!/usr/bin/env bash
# Read-only sampling. Run alongside release manual workflow or debug integration.
set -euo pipefail
alignment_adb="${ADB:-adb}"
alignment_output="${1:-output/alignment-device-samples}"
mkdir -p "$alignment_output"
"$alignment_adb" get-state
"$alignment_adb" shell getprop > "$alignment_output/getprop.txt"
"$alignment_adb" shell cat /proc/meminfo > "$alignment_output/meminfo.txt"
"$alignment_adb" shell dumpsys package com.example.quran_reel_maker.benchmark > "$alignment_output/package.txt"
for alignment_index in $(seq 1 "${2:-120}"); do
  {
    date -u +%FT%TZ
    "$alignment_adb" shell dumpsys meminfo com.example.quran_reel_maker.benchmark
    "$alignment_adb" shell dumpsys cpuinfo
    "$alignment_adb" shell dumpsys thermalservice
    "$alignment_adb" shell dumpsys battery
  } > "$alignment_output/sample-$alignment_index.txt"
  sleep 2
done
