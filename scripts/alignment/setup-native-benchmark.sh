#!/usr/bin/env bash
# Development-only jars. Never packaged into the app; no model/network on inference.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
mkdir -p output/alignment-native-deps output/alignment-native-classes
fetch_verified() {
  local file="$1" url="$2" digest="$3"
  if ! printf '%s  %s\n' "$digest" "$file" | sha256sum --check --status 2>/dev/null; then
    curl --fail --location --retry 2 --output "$file.part" "$url"
    printf '%s  %s\n' "$digest" "$file.part" | sha256sum --check
    mv -- "$file.part" "$file"
  fi
}
fetch_verified output/alignment-native-deps/onnxruntime-1.23.2.jar \
  https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime/1.23.2/onnxruntime-1.23.2.jar \
  e0ab4a1af57d2da09097202f2dfd691e390c82e81183314788ccde4cf7c3cc38
fetch_verified output/alignment-native-deps/json-20250517.jar \
  https://repo.maven.apache.org/maven2/org/json/json/20250517/json-20250517.jar \
  3ea61b2a06e31edf1c91134fe9106b0ebb16628be169f3db75bc7a2b06b45796
alignment_javac="${JAVA_HOME:+$JAVA_HOME/bin/}javac"
"$alignment_javac" -encoding UTF-8 --release 17 \
  -cp output/alignment-native-deps/onnxruntime-1.23.2.jar:output/alignment-native-deps/json-20250517.jar \
  -d output/alignment-native-classes \
  android/app/src/main/java/com/example/quran_reel_maker/alignment/QuranAligner.java \
  scripts/alignment/NativeHarness.java
printf '%s\n' 'Native benchmark harness compiled. Use .alignment-venv/bin/python scripts/alignment/benchmark.py.'
