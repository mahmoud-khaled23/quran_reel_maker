# Supplied application artwork

`Emerald Quran Media Icon.png` was supplied by the project owner, 1254 × 1254 RGB.
The original is unchanged (SHA-256
`1035de77d44e683b3a4823dc30bbcedb479222bb83e7c2f45ea92c5715fa4a98`).
No external artwork was downloaded. This repository does not assert a separate
third-party license for owner-provided artwork.

Run `scripts/generate-icons.sh` with ImageMagick to regenerate Android 48/72/96/
144/192 px launchers, density-specific 108 dp adaptive foreground canvases with
66 dp centered artwork, and Linux 64/128/256/512 px icons. The original is used in
full without artistic alteration. Background color is emerald `#093E32`.

Android uses `mipmap-anydpi-v26/ic_launcher.xml` with foreground/background layers;
round launchers use the same adaptive resource. Linux CMake bundles its icon,
GTK loads it relative to the executable, and `scripts/install-linux-desktop.py`
installs a user desktop entry plus hicolor icons.

References: [Android adaptive icon guidance](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive),
[Desktop Entry specification](https://specifications.freedesktop.org/desktop-entry-spec/latest/).
