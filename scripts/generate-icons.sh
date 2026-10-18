#!/usr/bin/env bash
# Build-time only; the original user-supplied artwork is never modified.
set -euo pipefail
cd "$(dirname "$0")/.."
source_icon='assets/icons/Emerald Quran Media Icon.png'
command -v magick >/dev/null || { echo 'Install ImageMagick to regenerate icons.' >&2; exit 1; }
for entry in mdpi:48:108:66 hdpi:72:162:99 xhdpi:96:216:132 xxhdpi:144:324:198 xxxhdpi:192:432:264; do
  IFS=: read -r density legacy canvas artwork <<< "$entry"
  mkdir -p "android/app/src/main/res/mipmap-$density" "android/app/src/main/res/drawable-$density"
  magick "$source_icon" -resize "${legacy}x${legacy}" "android/app/src/main/res/mipmap-$density/ic_launcher.png"
  magick "$source_icon" -resize "${artwork}x${artwork}" -background none -gravity center -extent "${canvas}x${canvas}" "android/app/src/main/res/drawable-$density/ic_launcher_foreground.png"
done
mkdir -p linux/packaging/icons
for size in 64 128 256 512; do
  magick "$source_icon" -resize "${size}x${size}" "linux/packaging/icons/quran-reel-maker-$size.png"
done
