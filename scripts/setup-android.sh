#!/usr/bin/env bash
set -euo pipefail
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [[ ! -d "$sdk" ]]; then
  echo "Install Android Studio, SDK 35/36, build-tools 36.0.0, NDK 28.2.13676358, platform-tools and command-line tools."
  echo "Set ANDROID_HOME to the SDK directory. See README.md."
  exit 1
fi
export ANDROID_HOME="$sdk"
export PATH="$sdk/platform-tools:$sdk/cmdline-tools/latest/bin:$PATH"
command -v java
command -v flutter
java -version
flutter doctor -v
if command -v sdkmanager >/dev/null; then sdkmanager --list_installed; fi
adb devices -l
echo "A connected authorized device or a separately started emulator is needed for flutter run."
echo "Build without a device: flutter build apk --release --split-per-abi"
