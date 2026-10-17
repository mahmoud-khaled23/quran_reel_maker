# Validation record

Validation date: 2026-10-17. The starting workspace was the Flutter counter
starter. No existing application functionality was overwritten.

## Pre-push review

Follow-up review on 2026-10-17 fixed:

- A rejected trim/cue edit now shows an inline error rather than appearing applied.
- Submitting an unchanged millisecond display preserves the original precise
  timestamp, avoiding unexpected rounding and overlaps between adjacent cues.
- Reopening a project with multiple surahs keeps the ayah dropdown in range.
- Empty projects reject non-finite, negative or inconsistent timing metadata
  before the editor can attempt to render it.
- CI matches the container UID/GID to the checkout owner and wraps the Linux
  artifact in a tarball to preserve executable permissions.

The final Docker command ran `dart format lib test integration_test`,
`bash scripts/check.sh`, the native editor integration test under Xvfb, and
`bash scripts/build-linux.sh`. Analysis passed with no issues, **all 17 tests
passed**, the native workflow passed (including reopening/exporting a timeline
containing multiple surahs), and the Linux release rebuilt successfully.
The reviewed code also rebuilt all three Android release APKs successfully with
`flutter pub get --offline --enforce-lockfile` followed by
`flutter build apk --release --split-per-abi` (75.1 seconds). Updated APKs and
checksums are in `output/android/`; no Android device was available.

Fedora `mpv-libs` 0.40.0 was installed with system administrator authentication.
The executable and four bundled libraries resolve their dependencies with the
bundle's library directory on the search path. Physical audio output still
requires a listening check.
The installed host libmpv also loaded the generated H.264/AAC evidence MP4 and
played it to EOF without errors using null audio/video outputs. This exercises
host decoding without making a claim about physical speakers or display output.

Git ignore rules were checked against representative build/cache, SDK paths,
private media, signing keys and local editor files. Required Quran/font assets
and `pubspec.lock` remain publishable. A scan of publishable files found no
private-key blocks, common access-token patterns or credential assignments;
no file exceeded 10 MB. Generated APKs and exports are excluded from Git.
Git attributes preserve upstream Quran/font bytes and original license notices;
the staged assets were compared byte-for-byte with the verified local files.
`git diff --cached --check` and shell script syntax checks passed.

## Environment and baseline

- Fedora 42 host; Flutter 3.47.7, Dart 3.13.5; Docker 29.5.3 and Compose 5.1.4.
- Host FFmpeg/FFprobe 7.1.4. Its available software H.264 encoder was OpenH264.
- Android SDK 36.0.0, Studio JDK 25; no Android device/emulator connected.
- `flutter doctor -v`: host Flutter, Linux and Android toolchains detected.
- Initial `flutter test`: original counter test passed.
- Initial `flutter build linux --release`: starter built successfully.

## Completed application checks

- `docker compose build dev`: succeeded. Final digest-pinned Dockerfile also
  rebuilt successfully from cached layers.
- `docker compose run --rm dev flutter doctor -v`: Linux toolchain passed.
  Absent Android SDK/browser and the detached pinned Flutter channel are expected.
- `docker compose run --rm dev flutter pub get --enforce-lockfile`: succeeded.
- `flutter analyze --no-pub`: no issues (host and Docker).
- `flutter test --no-pub --dart-define=MEDIA_EVIDENCE=/output/evidence` inside
  Docker: 14 tests passed after fixing the test harness and narrow-layout fonts.
- Real media tests also passed using the host FFmpeg/OpenH264. An initial combined
  host test run was interrupted because a widget test waited on filesystem I/O
  inside Flutter's fake async zone; the fixture now uses `runAsync` and seeded state.
- `xvfb-run -a -s "-screen 0 1366x900x24" flutter test
  integration_test/editor_flow_test.dart -d linux --no-pub` in Docker: passed.
  Real native startup, import/probe/waveform, trim edits, ayah grid/review,
  save/reopen and MP4 export ran. The original imported files were deleted before
  reopening, proving that project-owned copies are used. Only OS file-dialog
  selection was replaced with deterministic fixture paths.
- `docker compose run --rm build-linux`: release bundle built and copied to
  `output/linux/`.
- `bash -n scripts/*.sh` and `docker compose config --quiet`: passed.
- Final Docker run: formatting unchanged, analysis clean, all 14 tests passed
  in the checks service and the evidence run, then the Linux release rebuilt
  successfully. The complete bundle occupies approximately 29 MiB.

The native workflow test initially waited indefinitely when the Projects dialog
was open: the editor deliberately stays busy until a selection is made. The test
now waits explicitly for either completion or the expected dialog, avoiding a
blanket `pumpAndSettle` on a native media UI.

## Media and visual evidence

The generated test clip uses synthetic tones and a solid background, not a real
recitation. Checks verify 1080×1920, 30 fps, H.264, AAC, duration within 0.1 seconds, `yuv420p`, fast-start atom order, nonzero audio trimming (880 Hz after a
440 Hz prefix), visible Arabic text, a blank gap, short-video looping, fit mode,
progress completion, cancellation, and temporary-directory cleanup.

The evidence run writes `output/evidence/arabic-trim-test.mp4`, its attribution
sidecar, `export-frame.png`, and desktop/mobile editor screenshots. Visual review
caught and corrected centering of short Arabic lines and dependence on default
caption fonts. Amiri Quran and Noto Sans are now explicit, bundled families.
The rendered Quran wording and diacritics are preserved from the source asset.

## Android validation

The first `flutter build apk --release --split-per-abi --no-pub` installed SDK 35
and CMake 3.22.1 as required by plugins, and downloaded native media artifacts.
It reached Java compilation but failed because the generated plugin registrant
included the dev-only `integration_test` plugin, which Gradle excludes from
release builds. A sequential retry reproduced this, ruling out concurrency as
the sole cause. Inspection of the pinned Flutter tooling and
[upstream issue 169336](https://github.com/flutter/flutter/issues/169336)
identified `--no-pub` skipping the required release registration phase. The APK
script now keeps that phase enabled. Host/container Flutter commands must still
run sequentially because they share some generated platform metadata.

Final `flutter build apk --release --split-per-abi`: **passed** (57 seconds with
downloaded dependencies cached). APKs were copied into `output/android/`:

| ABI | File | Size (bytes) |
| --- | --- | ---: |
| ARM64 | `app-arm64-v8a-release.apk` | 77,728,568 |
| ARMv7 | `app-armeabi-v7a-release.apk` | 112,339,816 |
| x86-64 | `app-x86_64-release.apk` | 89,279,051 |

All three APK ZIP integrity checks passed and confirmed the bundled Quran text,
Amiri Quran and Noto Sans assets. SHA-256 values are in
`output/android/SHA256SUMS`. Build-tools 36.0.0 `apksigner verify --verbose
--print-certs` verified the ARM64 APK's v2 signature and identified the Android
Debug certificate. `aapt dump badging` confirmed API 24 minimum, API 36 target,
the Quran Reel Maker label and ARM64 ABI. `zipalign -c -P 16 4` passed for the
ARM64 archive; all 15 packaged ARM64 ELF libraries have LOAD-segment alignment
of at least 16 KiB. These package checks do not establish successful device execution.

Upstream compatibility warnings observed: older plugin Kotlin Gradle integration,
SDK XML version mismatch, Java 8 source/target warnings from dependencies. The
Flutter/Gradle/plugin versions are pinned; upgrades require renewed validation.

## Limits

- No physical Android device or emulator test was possible in this environment.
  Real Android SAF save dialogs, audible playback, 16 KB page-size devices,
  memory/thermal behavior and long exports need device testing.
- No suitable alignment weights/runtime/evaluation corpus was installed.
  Automatic ayah recognition is not implemented and no accuracy is claimed.
- The private display test initializes native media players, but does not verify
  audio through physical speakers or real desktop file choosers.
- Container desktop binaries depend on host GTK/GL/mpv runtime libraries.
- APKs use development signing. No store publishing, production signing,
  binary license clearance, or corresponding-source distribution was performed.
- The follow-up push triggered GitHub Actions. Local checks above passed; consult
  the [Actions page](https://github.com/mahmoud-khaled23/quran_reel_maker/actions)
  for the current remote run status.
