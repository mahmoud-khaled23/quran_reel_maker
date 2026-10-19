# AGENTS.md — Quran Reel Maker

Verified project memory for coding agents. Last audited **2026-10-19** on branch
`working-side` at commit `62ebef7` ("Finish Android auto alignment"), plus the
later P1 probe/hardening commits described below and in
`docs/PROJECT_STATUS.md`. See `docs/PROJECT_STATUS.md` for exact commands and
results. Do not update the status tables unless you personally ran the check.

## What this is

Offline Flutter (3.47.7 / Dart 3.13.5) editor that builds Quran recitation reels
as MP4 for **Linux desktop and Android**. No backend, no database, no server.
All processing is local: FFmpeg (subprocess on Linux, FFmpegKit on Android),
MediaKit/mpv playback, optional on-device forced alignment.

## Architecture (verified)

- `lib/main.dart` — bootstrap: MediaKit init with an explicit playback-error
  fallback, Quran asset load, license registry, Riverpod `AppServices` override.
  Chooses `AndroidAlignmentEngine` on Android, `ProcessAlignmentEngine` elsewhere.
- `lib/app.dart` — `MaterialApp` (dark, `NotoSans` + `AmiriQuran` fallback),
  `home: EditorScreen`. There is no named router; pages are pushed from
  `EditorScreen` (e.g. Video Trimmer).
- `lib/features/home/editor_screen.dart` (~1788 lines) — the whole editing UI:
  import, trim, surah/ayah/word selection, alignment/manual timing, overlay style,
  export dialog, navigation to the trimmer.
- `lib/features/synchronization/`
  - `alignment_engine.dart` — `AlignmentEngine` interface, `ProcessAlignmentEngine`
    (Linux NDJSON worker protocol 1, timeout + cancellation), result validation,
    `manualTimingGrid()` (explicitly approximate manual fallback, both platforms).
  - `android_alignment_engine.dart` — `AlignmentModelStore` (241.2 MB pinned
    weights, SHA-256 verified download/repair) + `AndroidAlignmentEngine`
    (MethodChannel `quran_reel/alignment`, FFmpegKit decode of the trim to
    mono 16 kHz f32, canonical coverage validation).
  - `alignment_model_page.dart` — Android "Alignment model → Download / repair" UI.
  - `ayah_timeline.dart`, `word_timing_dialog.dart` — review/edit word cues.
- `alignment_worker/` — Linux Python worker: `worker.py` (NDJSON on stdin/stdout),
  `ctc.py` (monotonic CTC forced alignment), `model.py` (hash-locked setup),
  `requirements.lock`, `tests/`. Launchers: `scripts/setup-alignment.sh`,
  `scripts/alignment-worker.sh`.
- `scripts/alignment/` — offline evaluation tooling (stdlib-only except model
  runs): `evaluate.py` (accuracy scoring; hardened structural validation; refuses
  non-human-reviewed references, malformed files and swapped prediction/
  reference inputs), `quality_probe.py` (`validate-reference` preflight for
  reference structure/canonical text/audio hashes + corpus-gate counts;
  `predictions`/`score`/`synthetic-pause` objective probes —
  known-digital-silence violations + transformation invariance, acoustic pause
  plausibility), `benchmark.py` (native/worker parity + resources),
  `test_evaluate.py`/`test_quality_probe.py` (40 tests, no
  model/network/ffmpeg needed). Reviewer guide + 24-clip/3-reciter procedure:
  `docs/ALIGNMENT_ANNOTATION.md`. The shipped template must stay unfilled
  (enforced by a test); annotate a copy under ignored `output/quality/`.
- `android/app/src/main/java/.../alignment/QuranAligner.java` — Java CTC core;
  `kotlin/.../AlignmentBridge.kt` + `MainActivity.kt` — channel, lifecycle,
  rotation metadata fallback. Gradle adds `com.microsoft.onnxruntime:onnxruntime-android:1.23.2`.
- `lib/media_engine/media_engine.dart` — platform boundary: argument-list
  subprocesses on Linux, FFmpegKit/FFprobeKit on Android. `CancellationToken` lives here.
- `lib/features/export/` — `export_settings.dart` (all six resolutions:
  `const exportResolutions = [144, 240, 360, 480, 720, 1080]`), `export_plan.dart`,
  `export_service.dart`; `lib/services/export_destination.dart` — collision-safe
  filenames, Linux chooser + Android SAF batch saving.
- `lib/features/video_trimmer/` — standalone `VideoTrimmerPage`,
  `segment_plan.dart` (µs-integer plan, `_NNN` numbering width ≥3, per-segment
  rename via `SegmentNames`), `segmentation_service.dart` (stream-copy when keyframes
  allow, else single re-encode; shares `MediaEngine`).
- `lib/models/reel_project.dart` — versioned domain model (`ReelProject.validate()`).
- `lib/services/project_store.dart` — per-project folder `project.json` + `media/`
  with atomic saves; stored under the platform app-support dir (`projects/`,
  sibling `exports/`).
- `lib/features/preview/` — `ayah_painter.dart` (shared preview/export RTL painter),
  `overlay_state.dart` (progressive word prefixes, 750 ms pause clearing, 30 fps
  onset rounding).

## Build / test commands

Host (Fedora, Flutter 3.47.7 on PATH):

```bash
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test                       # 60 tests incl. real FFmpeg export tests (needs ffmpeg on PATH)
python3 -m unittest discover -s scripts/alignment -p 'test_*.py' -v   # evaluator + probe/preflight invariants (40)
QRM_TEST_MODEL=1 .alignment-venv/bin/python -m unittest discover -s alignment_worker/tests -v  # 12, offline
```

Docker (uses `compose.yaml`; `export DEV_UID=$(id -u) DEV_GID=$(id -g)` first):

```bash
./scripts/check.sh                  # format + analyze + flutter test
./scripts/docker-integration-test.sh  # native editor flow in private Xvfb
./scripts/check-trimmer-ui.sh       # standalone trimmer flow
./scripts/check-alignment-ui.sh     # real local alignment flow (needs .alignment-venv + models)
./scripts/docker-build-linux.sh     # release bundle -> output/linux/
```

Android (host SDK, no SDK in Docker; run host/container Flutter commands sequentially):

```bash
./scripts/setup-android.sh
./scripts/build-apk.sh              # --release --split-per-abi, copies to output/android/
# Device tests MUST use the isolated benchmark id and --no-uninstall:
flutter test integration_test/android_regression_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
```

CI: `.github/workflows/checks.yml` (alignment job + linux job incl. editor/trimmer
native flows and release artifact). Last run for this branch/HEAD: **success**.

## Implementation status (audited 2026-10-19)

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Linux + Android | Done | Linux bundle built; Android debug/release split-ABI APKs built; CI green |
| 2 | Word-level sync, partial ayahs | Done | `overlay_state.dart`, word review dialog, real-model partial tests; requires user to pick boundary words |
| 3 | Linux offline alignment via setup/worker scripts | Done | `scripts/setup-alignment.sh`, `scripts/alignment-worker.sh`; 12 offline model tests pass locally |
| 4 | Android manual timing + small mobile auto-alignment model | Partial | Manual timing verified on device (docs). Auto model chosen/integrated/measured on A52s; **independent word-level accuracy unmeasured** — acceptance explicitly provisional |
| 5 | Audio upload/playback/preview/trim | Done | `trim_dialog.dart`, native workflow tests |
| 6 | Video upload/preview/trim | Done | same dialog + export loop tests |
| 7 | Resolutions 144p–1080p | Done | `export_settings.dart`, selector in editor, real 240p/1080p exports |
| 8 | `HH:MM:SS:FFF` everywhere | Done | `time_format.dart`/`time_field.dart` + tests |
| 9 | Text position + font color | Done | `ayah_painter.dart`, style persistence tests |
| 10 | MP4 named after project | Done | `export_destination.dart`, collision tests |
| 11 | Dedicated Video Trimmer page | Done | `video_trimmer_page.dart`, `video_trimmer_flow_test.dart` (passes in CI) |
| 12 | 30/60/90/custom post-segmentation | Done | `segment_plan.dart`, "Split completed reel…" hand-off, `segmentation_media_test.dart` |
| 13 | Trimmer default name + `_001` numbering + renames | Done | `video_trimmer_page.dart:217-219`, `segment_plan.dart:68-82` |
| 14 | Android + Linux icons | Done | `android/.../mipmap-*`, `linux/packaging/*.desktop`, `scripts/generate-icons.sh` |

## Constraints (do not break)

- **Linux offline alignment and Android manual timing must keep working.** Never
  remove the Python worker path or `manualTimingGrid()`; Android auto alignment is
  optional and never the only route to cues.
- Quran text is the bundled Tanzil Uthmani 1.1 (SHA-256
  `6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f`); the app
  never edits/generates it. Store references + timestamps, not rendered text.
- Model weights are pinned: `quran-ctc-q4-v1`, 241,230,289 bytes, SHA-256
  `9b17e04fdc2aef54720e62216a7c7ae7f55d27911ee7cd55253baa231845a587`,
  revision `f90650aac5d9dcff15230a19998c0027f45b33f1`. Weights are **never**
  bundled in the APK (only downloaded to private storage).
- No new Flutter/Python runtime dependencies without recording why (pinned SDK,
  `--enforce-lockfile`, GPL `ffmpeg_kit_flutter_new` obligations — see
  `THIRD_PARTY_NOTICES.md`).
- Release signing is the debug key and application id is
  `com.example.quran_reel_maker` — intentional until production setup.
- Device tests use `com.example.quran_reel_maker.benchmark` +
  `--no-uninstall` + matching debug/release version codes. **Never** run device
  tests under the normal app id: Flutter's default cleanup once deleted the
  owner's app-private projects.
- Host and container `flutter` commands must run sequentially (shared generated
  metadata, `android/local.properties`).
- Keep displayed timings `HH:MM:SS:FFF`; keep project/segment filename
  sanitization and atomic collision reservation.

## Known issues / open items

1. **Android/Linux automatic alignment accuracy is unverified** — no independent
   multi-reciter annotated corpus; `test/fixtures/alignment/reference-template.json`
   is deliberately unfilled. Gates are defined in `docs/ANDROID_ALIGNMENT.md`.
   Objective probes exist (`scripts/alignment/quality_probe.py`, measured
   2026-10-19 on the CC0 fixture: 0 ms speech inside 2 s inserted silence,
   mapped drift median 0.0 / max 20 ms) but are evidence, not gate compliance.
   The pipeline is reviewer-ready: `validate-reference` preflights a reference
   (structure, canonical Tanzil selection, audio hashes, corpus counts, no
   model), `predictions` is SHA-256-bound to the annotated audio, the evaluator
   refuses unreviewed/incomplete/malformed inputs, and
   `docs/ALIGNMENT_ANNOTATION.md` gives the field-level guide + 24-clip/3-reciter
   plan. Human annotation is the remaining blocker.
2. **ARM64 incremental APK size gate failed**: +19.78 MB vs ≤15 MB target
   (full ONNX Runtime ARM64 libs ≈19.4 MB). Documented, not silently accepted.
3. Release-mode cancellation timing, unplugged battery energy, real SAF dialogs,
   audible speakers, Android launcher visual check: **device-only, unmeasured**.
4. `flutter test integration_test/...` for Linux flows needs `xvfb` + `mpv` (host
   has neither; use Docker). No Android device/emulator connected in this
   environment.
5. A prior test run under the normal app id removed the owner's app-private
   projects (see `docs/VALIDATION.md`); recovery was never verified.
