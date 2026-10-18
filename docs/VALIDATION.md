# Validation record

## Editing, progressive words and branding (2026-10-18)

This follow-up extends the existing Riverpod/MediaKit/FFmpeg editor and local CTC
worker. No new Flutter or Python runtime dependencies were added. ImageMagick is
needed only to regenerate committed launcher derivatives.

Implemented and exercised:

- Shared `HH:MM:SS:FFF` parsing/formatting, non-destructive confirmed audio/video
  trim dialogs, source-duration validation, source aspect/rotation metadata,
  and saved video trim ranges. Source seconds remain the schema-1 storage format;
  new fields have defaults for old projects.
- Original-index partial-ayah targets in the real worker; progressive canonical
  excerpts shared by preview/export. No future words; long gaps and word/ayah ends
  clear text. Editable manual word boundaries have no invented acoustic score.
  Unchanged formatted timestamps retain their original sub-millisecond precision.
- Project overlay position/color/background settings, all six export qualities,
  source-video size caps, actual prepared-video trim looping, safe readable
  filenames with atomic collision reservations, and MP4 stream/duration checks.
- Supplied artwork integrated into Android density/adaptive resources and the
  Linux bundle/window. `desktop-file-validate` passed for both the packaged entry
  and an installed entry in a temporary XDG directory with spaces, quotes,
  dollar signs, backticks, backslashes and percent signs in the bundle path.
  The original artwork SHA-256 remains unchanged.

Executed checks:

- `docker compose --profile alignment build alignment alignment-checks`: passed.
- `docker compose --profile alignment run --rm -e QRM_TEST_MODEL=1 -v
  "$PWD/.alignment-models/quran-ctc-q4-v1:/opt/quran-reel/.alignment-models/quran-ctc-q4-v1:ro,z"
  alignment python -m unittest discover -s alignment_worker/tests -v`:
  **12 passed with networking disabled**, including actual partial-ayah inference
  retaining original word indices. The first native run had an obsolete diagnostic
  assertion; updating that assertion was followed by the complete offline pass.
- `docker compose run --rm dev bash scripts/check-editor-ui.sh`: passed in private
  Xvfb. Real audio/video import, native play/pause, confirmed trims, source deletion
  after import, manual timing/review, save/reopen and MP4 export. Only the OS file
  picker was replaced. Fixture-generation and tooltip-finder mistakes found during
  development were corrected before the successful run.
- `docker compose --profile alignment run --rm alignment-checks`: passed the real
  model → Flutter review/edit/save → 13-second MP4 workflow in private Xvfb.
- The worker launcher runs from `/tmp` using its absolute script path; it does not
  depend on the caller's working directory. Python compilation, shell syntax,
  desktop entry validation and `git diff --check` passed.
- `adb devices -l`: no connected device/emulator. Android runtime playback,
  trimming/export and launcher appearance therefore remain unverified on-device.

- Final `flutter analyze --no-pub`: **no issues**. Final `flutter test --no-pub`:
  **40 passed**, including real FFmpeg exports and a regression for switching
  Fill to Fit after adjusting crop focus. Fit preview now centers the background
  consistently with export. These checks followed the last application change.
- `flutter build apk --debug --no-pub`: passed. `bash scripts/build-apk.sh`:
  **all three release APKs passed** (ARMv7, ARM64, x86-64). The final debug build
  took 13.6 seconds and release Gradle build 113.6 seconds. `apksigner verify`
  and `zipalign -c -P 16 4` passed for all four APKs. Manifest inspection confirmed
  the app name, API 24 minimum, API 36 target, adaptive icon and expected ABIs.
  These are package checks, not evidence of Android device execution.
- `docker compose run --rm dev bash scripts/build-linux.sh output/linux-enhanced`:
  **final Linux release passed**. The executable and bundled shared libraries
  have no unresolved host dependencies. The updated app was launched on Fedora
  and remained running; native players initialized. GTK accessibility/cursor
  warnings and MediaKit's software-rendering fallback were nonfatal. Physical
  speaker output was not independently checked.
- `.gitignore` excludes model weights, Python environments, generated media,
  APKs and signing properties. Publishable-file inspection found no private-key
  blocks or common access-token patterns and no file larger than 10 MB.

Artifacts: the complete Linux bundle is `output/linux-enhanced/`; the debug APK,
three release APKs and release SHA-256 checksums are in `output/android/`.
Development logs are `output/enhanced-*.log`; generated MP4/PNG evidence is in
`output/enhanced-evidence/`. All these generated artifacts are ignored by Git.

Limits: partial selections require choosing the matching first/last recited words;
there is no arbitrary partial-passage discovery. Word boundaries remain approximate
and uncalibrated, repetitions require correction/cropping, and 30 fps onset rounding
can delay display by less than one frame. The 750 ms pause threshold is a display
heuristic, not acoustic silence detection. Manual passage timing shows its selected
excerpt throughout the ayah interval. Exporting needs temporary storage for the
trimmed background, overlays and final video. Android alignment remains manual.
Release signing remains the development configuration; this task does not publish
a production-signed Android application. Existing historical results follow.

Validation date: 2026-10-17. The starting workspace was the Flutter counter
starter. No existing application functionality was overwritten.

## Automatic alignment follow-up (2026-10-17)

The following checks apply to the new Linux local Python/ONNX alignment pipeline;
the older build records below describe the preceding manual-only release.

- Verified the public Quran CTC export, pinned its revision and all file hashes,
  matched the 241,230,289-byte weight file to its published LFS SHA-256, and loaded
  the actual q4 graph with ONNX Runtime 1.23.2 CPU. Native Python 3.13 and container
  Python 3.12 successfully inferred on the licensed CC0 recording.
- `QRM_TEST_MODEL=1 .alignment-venv/bin/python -m unittest discover -s
  alignment_worker/tests -v`: **11 passed**, including real inference, expected
  ayah windows, analytic source-offset/pause transformations, and rejection of
  silence, noise, repeated passages and a wrong ayah range; slowed audio across
  an inference chunk boundary also passed its expected timing checks.
- Docker worker image built with `--require-hashes` Python dependencies. The same
  **11 tests passed with networking disabled**, using the read-only/non-root
  `alignment` service. No inference downloads were possible in that run.
- `flutter analyze`: **no issues**. `flutter test`: **27 passed**, including
  subprocess protocol errors, missing-model diagnostics, cancellation/timeouts,
  malformed-output termination, alignment persistence, manual-edit invalidation,
  source-to-export rebasing, populated desktop/mobile word-review layouts and
  existing media/project/UI regressions.
- `python3 -m compileall -q alignment_worker` and `git diff --check` passed.
  Model downloads, environments and generated evidence are ignored; only the
  attributed 809,597-byte CC0 fixture is explicitly included in Git.
- `./scripts/setup-alignment.sh` successfully reused the installed pinned
  dependencies and verified all model files. The selected launcher is executable.
- `docker compose --profile alignment run --rm alignment-checks`: **passed**.
  The native Flutter app used the actual Python worker and CC0 audio, aligned
  a nonzero trim, sought ayahs/expanded word review, saved, edited an ayah boundary,
  cleared stale word timings/reset review, and exported a 13-second MP4.
  This test caught/fixed a missing Material ancestor in the word expansion panel.
  Its initial dialog-idle wait was also corrected; modal project selection
  intentionally keeps the editor busy.
- Populated 1366×900 and 390×844 screenshots exposed reversed word timestamp
  ranges caused by RTL layout. Time ranges now use LTR layout alongside the
  preserved Arabic word. Screenshots are under `output/evidence/` (ignored).
- The original native manual workflow test also passed after these changes.
  `flutter build linux --release --no-pub` succeeded; the new complete bundle
  is in `output/linux-alignment/` so the preceding running bundle is untouched.
- Android's first follow-up build reproduced the development-plugin registration
  failure even with Pub enabled. The build script now explicitly runs
  `flutter build apk --release --config-only` before the `--no-pub` release build,
  following Flutter issue 169336. The generated release registrant was checked
  and no longer referenced `integration_test`.
- With that configuration fix, **all three Android release APKs passed**
  (ARMv7, ARM64, x86-64; 47.2-second Gradle build). They are in `output/android/`
  with refreshed SHA-256 checksums. The script now refreshes those checksums on
  every build. No Android device was available; automatic alignment remains Linux-only.
- The rebuilt `output/linux-alignment/quran_reel_maker` was launched on the host;
  native players and EGL rendering initialized and the process stayed running.
  GTK accessibility/cursor and optional CUDA-probe warnings were nonfatal.
  Physical speaker output was not independently checked.

The real fixture's expected windows are model-assisted regression data, **not
independent human accuracy labels**. There is no multi-reciter error benchmark
or calibrated confidence. See [alignment provenance and limitations](ALIGNMENT.md).

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
- Linux forced alignment is implemented with an optional local worker. Android
  retains manual timing. Accuracy remains uncalibrated and requires human review;
  one licensed regression fixture does not establish general recitation accuracy.
- The private display test initializes native media players, but does not verify
  audio through physical speakers or real desktop file choosers.
- Container desktop binaries depend on host GTK/GL/mpv runtime libraries.
- APKs use development signing. No store publishing, production signing,
  binary license clearance, or corresponding-source distribution was performed.
- The follow-up push triggered GitHub Actions. Local checks above passed; consult
  the [Actions page](https://github.com/mahmoud-khaled23/quran_reel_maker/actions)
  for the current remote run status.
