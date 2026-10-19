#!/usr/bin/env bash
# Install the debug APK first. This only provisions its private test/model files.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
alignment_adb="${ADB:-adb}"
alignment_package=com.example.quran_reel_maker.benchmark
alignment_model=.alignment-models/quran-ctc-q4-v1/onnx/model_q4.onnx
printf '%s  %s\n' 9b17e04fdc2aef54720e62216a7c7ae7f55d27911ee7cd55253baa231845a587 "$alignment_model" | sha256sum --check
"$alignment_adb" get-state
"$alignment_adb" shell -T run-as "$alignment_package" mkdir -p files/alignment-models/quran-ctc-q4-v1
# A non-PTY shell streams directly into app-private storage: no shared-storage copy.
"$alignment_adb" shell -T run-as "$alignment_package" sh -c '"cat > files/alignment-models/quran-ctc-q4-v1/model_q4.onnx.part"' < "$alignment_model"
"$alignment_adb" shell -T run-as "$alignment_package" sh -c '"sha256sum files/alignment-models/quran-ctc-q4-v1/model_q4.onnx.part"' | \
  python3 -c 'import sys; assert sys.stdin.read().split()[0] == "9b17e04fdc2aef54720e62216a7c7ae7f55d27911ee7cd55253baa231845a587", "device model checksum mismatch"'
"$alignment_adb" shell -T run-as "$alignment_package" mv files/alignment-models/quran-ctc-q4-v1/model_q4.onnx.part files/alignment-models/quran-ctc-q4-v1/model_q4.onnx
"$alignment_adb" shell -T run-as "$alignment_package" sh -c '"cat > files/alignment-test.ogg"' < test/fixtures/alignment/fatiha-cc0.ogg
printf '%s\n' 'Provisioned. Turn off network access and run integration_test/android_alignment_test.dart on the device.'
