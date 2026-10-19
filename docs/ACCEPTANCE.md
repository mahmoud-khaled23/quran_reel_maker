# Enhancement request acceptance audit

Audited 2026-10-18 against the owner's “Enhance Quran Reel Maker — Video Editing,
Audio Alignment, Export, and App Branding” request. The implementation baseline
is commit `02b4934`. This document distinguishes implemented behavior from the
platforms and cases actually exercised; it is not a claim of universal device or
alignment accuracy.

Updated **2026-10-19** for the native Android alignment follow-up. Physical A52s
debug/offline and release/offline alignment now run, alongside real media/export/
segmentation regressions. See [current measured results](VALIDATION.md) and
[candidate research and remaining accuracy gates](ANDROID_ALIGNMENT.md).

## Architecture and implementation phases

The initial audit inspected the existing Flutter/Riverpod editor, MediaKit
players, platform media engines, project store, Quran assets, Python worker,
setup/launcher scripts, Docker services and native runners. Their implementation
was extended rather than replaced. All six phases were carried out, with remaining
runtime verification limits identified below:

1. **Audit:** existing local project storage, source-audio timestamps, ayah/word
   alignment protocol and FFmpeg export were inspected before editing.
2. **Shared timing/media:** one timestamp formatter/parser, import preview and
   trim dialogs, validation, saved video ranges and source geometry.
3. **Synchronization:** original-index partial-ayah targets, progressive word
   display, explicit manual passage fallback and editable word timestamps.
4. **Overlay/export:** shared painter and clock, drag/sliders/colors, quality
   selection, project filenames and actual trimmed-video preparation.
5. **Branding:** supplied artwork, Android density/adaptive icons and Linux
   window/desktop integration.
6. **Verification:** formatting, analysis, unit/widget tests, real offline model
   tests, Linux native workflows, Linux release and Android debug/release builds.
   Android on-device verification has a separate status below.

## Requested feature groups

| Feature | Implemented behavior | Main implementation and evidence |
| --- | --- | --- |
| A — Quality | 144/240/360/480/720/1080p selector; displayed dimensions; aspect fitting; source-video size cap; progress/cancel; storage/codec diagnostics. Labels describe the short edge for landscape or portrait video. | [Export settings](../lib/features/export/export_settings.dart), [FFmpeg plan](../lib/features/export/export_plan.dart), [export service](../lib/features/export/export_service.dart); all six sizes covered in logic tests, real 240p and 1080p MP4 regressions. |
| B — Audio | Preview before copying, play/pause, seek, duration/current position, range handles and editable boundaries; confirmation keeps the original file and stores non-destructive bounds. Alignment/export use the selected interval. | [Trim dialog](../lib/features/media_editor/trim_dialog.dart), [editor](../lib/features/home/editor_screen.dart); native import/play/pause/trim workflow and exported audio-frequency check. |
| C — Video | Preview before copying, selected segment controls, source duration validation, saved trim range, aspect/orientation metadata, muted background playback and export looping of the prepared selected clip. | Same trim dialog; [media probe](../lib/media_engine/media_engine.dart), export plan/service; actual red/green/blue source regression confirms only the selected green interval repeats. |
| D — Filename | Project title is shown as a sanitized MP4 filename before rendering; Unicode remains readable; atomic numbered reservations prevent overwrite; output streams/duration are checked. | Export settings/service and [save destination](../lib/services/export_destination.dart); filename/collision tests and real MP4 export. |
| E — Icons | Original supplied PNG preserved; launcher density images and adaptive XML; app remains Quran Reel Maker; GTK window icon, bundled desktop entry, user launcher installer. | [Artwork provenance](../assets/icons/README.md), Android resources, [Linux packaging](../linux/packaging/com.example.quran_reel_maker.desktop); APK/resource inspection, successful platform builds and desktop-file validation. Actual Android launcher appearance still needs device review. |
| F — Recited words | Only the selected canonical excerpt is targeted; word onsets reveal prefixes, long pauses/ends clear text, trim offsets are applied once, and boundary words can be selected for partial ayahs. Wordless cues have an explicitly labeled passage fallback. | [Shared overlay state](../lib/features/preview/overlay_state.dart), [word review](../lib/features/synchronization/word_timing_dialog.dart), [CTC tokenizer](../alignment_worker/ctc.py), [worker](../alignment_worker/worker.py); real partial-ayah inference, prefix/pause/rebase tests and rendered frame checks. |
| G — Position/color | Drag or horizontal/vertical sliders; font-color palette; optional background; canvas bounds clamp the text; project storage and preview/export use the same settings/painter. | [Painter](../lib/features/preview/ayah_painter.dart), editor and project model; style round-trip and actual colored overlay export tests, plus the follow-up UI interaction regression. |
| H — Time format | All application-generated time labels/inputs use HH:MM:SS:FFF, with hours and three millisecond digits. Stored source seconds remain backward compatible; unchanged labels preserve original sub-millisecond values. | [Time utilities](../lib/features/audio_editor/time_format.dart), [time field](../lib/features/audio_editor/time_field.dart); rollover, malformed input, overflow, trim and unchanged precision regressions. Low-level third-party error text is displayed as supplied by the dependency. |

## Fifteen acceptance criteria

“Verified” below identifies the evidence and does not imply Android device testing
where only shared tests, Linux execution or APK inspection were available.

| # | Acceptance criterion | Evidence / remaining limit |
| --- | --- | --- |
| 1 | Audio import/play/pause/trim | Verified in the native Linux editor workflow. Android runtime status is below. |
| 2 | Video import/play/pause/trim | Verified in the native Linux editor workflow. Android runtime status is below. |
| 3 | Trims affect generated output | Actual exported audio checked for the selected tone; actual video frames checked across repeated selected segments. |
| 4 | Standard timestamps | Shared parser/formatter tests, mobile/desktop widgets, trim and word-review dialog tests; source code searched for alternative time displays. |
| 5 | All six export resolutions | Selector and all six dimension calculations implemented/tested; actual 240p and 1080p exports tested. Not every resolution/codec/device combination has been rendered. |
| 6 | Project-based MP4 name | Sanitization, Unicode, reserved names, extension removal and concurrent collision reservations tested; actual export name asserted. |
| 7 | Word overlays follow recitation | Real model inference and generated frames tested. Acoustic boundaries remain approximate and require listening review. |
| 8 | Partial ayahs omit unrecited words | Boundary word selection, original word indices and real partial inference tested. The user must select the matching first/last words. |
| 9 | Reposition and recolor text | Drag, palette, background switch, shared painter and saved settings exercised by the follow-up widget test; colored/positioned output exercised by FFmpeg test. |
| 10 | Preview/export settings agree | Same painter and overlay clock; raster/MP4 checks, project persistence, and Fit centering regression. Preview players can have small clock drift; inspect the final MP4. |
| 11 | Offline Linux alignment | Actual pinned model tests passed with container networking disabled; the app also ran its real local worker in a native workflow. Docker is optional at runtime. |
| 12 | Android manual timing | Physical A52s editor created manual timings, saved/reopened and exported; shared controls and mobile layouts tested. Optional native automatic drafts preserve this fallback. |
| 13 | Android/Linux icons | Resources, manifests, native icon paths and desktop installer validated; builds passed. Android launcher visual check remains pending. |
| 14 | Existing projects/workflows | Schema-1 defaults and round-trip tests; manual workflow, mixed-surah reopening, copied-media independence and automatic alignment workflow passed. |
| 15 | Checks/builds or documented failures | Successful commands/artifacts are recorded in [VALIDATION.md](VALIDATION.md); emulator attempts and remaining limitations are recorded below. |

## Platform and model limits

- Physical A52s debug/release offline inference and real FFmpegKit regressions
  now have measured results in [VALIDATION.md](VALIDATION.md). Earlier failed
  emulator attempts remain historical records, not application passes. Actual
  document-provider dialogs and other Android hardware remain unverified.
- Android retains manual ayah/word timing and never executes the Python launcher.
  Optional native ONNX alignment is provisional until independent multi-reciter
  boundary accuracy and all resource gates are met.
- Automatic alignment uses the already verified Quran dataset and installed
  pinned model. Canonical text and its bytes are unchanged. Repetitions are not
  independently segmented; warnings/rejection and manual correction remain
  necessary. No calibrated confidence or independent accuracy benchmark is claimed.
- Audio/video trim/export services are real. Native workflow tests replace the OS
  file chooser with fixture paths. Real chooser/provider behavior and physical
  audio output still need a manual check on each target environment.
- The 750 ms pause threshold and 30 fps word-onset rounding are explicit display
  heuristics, not phoneme-perfect acoustic timing. There is no automatic discovery
  of arbitrary partial excerpts.
- Export needs space for temporary overlays, the selected background clip and the
  output. Errors/cancellation clean these up. Replaced project media is retained;
  automatic project-media garbage collection was not requested or implemented.
- No new Flutter/Python runtime packages were introduced. ImageMagick is only
  needed to regenerate committed icon derivatives. Release APKs still use
  development signing; production distribution is a separate setup step.

## Commands and remaining manual steps

See [VALIDATION.md](VALIDATION.md) for the exact executed Docker, model, integration
and build commands and their results; see [README.md](../README.md) for normal use.

For a new Linux checkout, run `./scripts/setup-alignment.sh` once and select the
absolute `scripts/alignment-worker.sh` path in the app. Setup downloads verified
weights explicitly; inference then runs offline. Both launcher scripts resolve
the repository relative to their own location. If relocating an existing Python
virtual environment, rerun setup at its new location; virtual environments are
not portable build artifacts.

To install the Linux launcher, keep the whole release bundle at a permanent path
and run `python3 scripts/install-linux-desktop.py /absolute/path/to/bundle`.
The installer was first validated in an isolated XDG directory. This acceptance
recheck also installed the owner's actual user launcher and four hicolor icons,
most recently pointing to `output/linux-alignment/`; the installed desktop entry passed
`desktop-file-validate`. Keep that bundle in place or rerun the installer after
moving it.

On an available Android device/emulator, run:

```bash
flutter test integration_test/media_export_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
flutter test integration_test/enhanced_media_export_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
flutter test integration_test/editor_flow_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
```

Then inspect the launcher, real file chooser/Save exported video flow and audible
playback. Configure production application ID/signing before public distribution.
