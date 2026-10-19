# Validation record

## Objective alignment quality probes (2026-10-19)

Tooling: `scripts/alignment/quality_probe.py` with 16 new stdlib-only unit
tests in `scripts/alignment/test_quality_probe.py`. These probes produce
human-free evidence about word-boundary behavior. They do **not** satisfy the
independent accuracy gates in [ANDROID_ALIGNMENT.md](ANDROID_ALIGNMENT.md);
human-reviewed multi-reciter references remain required.

`python3 -m unittest discover -s scripts/alignment -p 'test_*.py' -v` →
**22 passed** (6 pre-existing evaluator invariants + 16 new probe tests; the
new tests need no model, network, ffmpeg or numpy, so the existing CI step
covers them unchanged).

`predict` step (`quality_probe.py predictions`) ran the Linux worker for the
one CC0 reference clip and wrote evaluator-ready
`output/quality/fatiha-predictions.json` (status `aligned`, all 6 canonical
words, selection derived from the reference word list and validated against the
bundled Tanzil text). Running `scripts/alignment/evaluate.py` against the still
unfilled template correctly fails with *"Accuracy scoring requires independent
human-reviewed annotations"* — the tooling cannot bypass the human gate.

`synthetic-pause` (2 s of digitally silent samples inserted at trim-relative
7.75 s, inside the base alignment's inter-word gap; the model realigned the
modified audio offline, then the known shift was removed):

- `speechInsideInsertedSilence.totalViolationMs` = **0.0 ms** — no word was
  claimed inside known-silent samples.
- `insertedSilencePauseCoverage` = **1.0** — the predicted inter-word pause
  covered the full inserted silence.
- `mappedDrift` over all 12 word boundaries: median **0.0 ms**, p90 **18.0 ms**,
  max **20.0 ms** (one CTC frame); identical word sets before/after.
- Caveat recorded in the report: the insertion position's inter-word status
  comes from the base alignment plus surrounding quiet acoustics, not from
  human listening.

`score` (acoustic plausibility, floor-based VAD at threshold −43.9 dBFS with
reliability diagnostics): the 13-second fixture is a continuous recitation —
exactly one deep pause (26.2–26.98 s, after the last word, which ends at
26.043 s) and **no** between-word pause, so natural-pause agreement is
**inconclusive** on this clip and the report says so explicitly
(`pausePlacement`, warning text). Earlier permissive thresholds (p10-based)
misclassified quiet elongation (−27 dBFS) as silence and produced misleading
"silence inside word" flags; the detector was retuned to a p05 floor plus
guards, and per-pause placement classification was added so borderline cases
are visible rather than collapsed into one number.

Raw reports remain under ignored `output/quality/` (`fatiha-result.json`,
`fatiha-acoustic.json`, `fatiha-synthetic-pause.json` + per-word base/generated
files, `fatiha-predictions.json`).

## Native Android alignment (2026-10-19, provisional)

Architecture and candidate research are in [ANDROID_ALIGNMENT.md](ANDROID_ALIGNMENT.md).
The selected integration is Quran Wav2Vec2 q4 acoustic inference plus canonical
CTC forced alignment through ONNX Runtime Android 1.23.2. This is **not a validated
winner on Quran word accuracy**: the one CC0 reciter fixture has broad,
model-assisted regression windows, not independent word-boundary ground truth.
No median/p90 boundary error or accuracy percentage is claimed. A scorer that
requires independently reviewed references and a pending annotation template are
included. Multi-reciter references and challenger evaluation remain outstanding.

### Physical Galaxy A52s debug, with networking disabled

Observed SM-A528B, Android 14, ARM64, MemTotal 7,541,152 KiB. The isolated package
`com.example.quran_reel_maker.benchmark` used the same native core as the normal
application. Both Wi-Fi and mobile data were disabled with permission; Android
reported `Active default network: none`. Previous settings (Wi-Fi on, data off)
were restored by the script. Weights and the CC0 fixture were provisioned into
private storage beforehand, with the model hash verified on the phone.

`bash scripts/alignment/run-device-check.sh --offline`: **passed**, 50 seconds
of test execution after build/install. Fresh model sessions per app request;
OS file cache was not flushed. Results:

| Case | Audio seconds | Total seconds | Load seconds | Inference seconds | Total RTF | Result |
|---|---:|---:|---:|---:|---:|---|
| Base, first | 13 | 10.023 | 4.187 | 5.302 | 0.771 | 2 ayahs / 6 canonical words |
| Base, repeat | 13 | 6.743 | 1.255 | 5.190 | 0.519 | same word boundaries |
| Partial ayah | 4.7 | 3.149 | 1.284 | 1.645 | 0.670 | original indices 1–3 preserved; trim-edge warning |
| Wrong text | 13 | 6.620 | — | — | 0.509 | rejected for mismatch |
| Half-speed | 26 | 13.604 | 1.262 | 11.807 | 0.523 | 6 words; elongation/uncertainty warnings |
| Cancel during inference | — | — | — | — | — | returned in **59 ms** |

Process high-water RSS reached **873,916 KiB (853.4 MiB)** across the successful
sequence; sampled PSS peaked at **786,929 KiB (768.5 MiB)**. Sampling every ~2s can
miss peaks; VmHWM is cumulative for the process, not a per-job allocation. The
50ms UI timer's largest interval was **65ms**. Thermal service status stayed 0
(no throttling reported), sampled battery temperature 32.4–32.6°C. USB charging
precludes an energy/battery-life claim. Cached `dumpsys cpuinfo` did not yield
reliable app CPU samples; release instrumentation uses process CPU-time deltas.
Raw ignored reports: `output/alignment-device-report.json`,
`android-alignment-device-test.log`, `alignment-device-samples-final/`.

An earlier attempt stopped at Android memory-relief level 10 after 2.8s. It is
recorded as a resource failure, not an alignment rejection/success. The guard
was retained; a later run with more free memory passed. Under pressure users
must close other apps, shorten the selection or use manual timing. An earlier
termination had ambiguous background/memory cause; cancellation diagnostics now
preserve the exact lifecycle reason. No out-of-memory immunity is claimed.

**Test tooling incident:** the first phone test used Flutter 3.47.7's default
uninstall cleanup under the normal application ID. That removed its private
model/test data and may have removed existing app-private projects. Recovery of
prior phone projects was not verified; repository/exported host files were not
changed. The user was informed. Subsequent tests use the separate benchmark ID
and explicit `--no-uninstall`; scripts never uninstall the normal app.

### Physical Galaxy A52s release/R8, with networking disabled

`bash scripts/alignment/run-release-check.sh --offline`: **passed**. The isolated
ARM64 release APK built in 140.8s and replaced only the benchmark package using
`adb install -r`. Native JNI/ORT ran with `dart.vm.product=true`. Ten requests used
fresh sessions on the same 13-second/six-word fixture; a final 180-second repeated
recording deliberately mismatched the selected text and was correctly rejected.
No-default-network state was verified and original Wi-Fi on/data off restored.

| Measurement | Observed release result |
|---|---|
| First / repeated end-to-end latency | 6.978s first; 6.472–6.671s on the other nine |
| Ten-request total RTF | median **0.502**, p90 **0.516** |
| Model verification/load | 1.518s first; 1.200–1.296s repeated; OS cache not flushed |
| 180-second negative | **93.129s**, RTF **0.517**; rejected for text mismatch |
| Process high-water RSS reported by jobs | **687,252 KiB (671.1 MiB)** |
| Sampled PSS / RSS peak | **683,929 / 743,776 KiB (667.9 / 726.3 MiB)** |
| Process CPU time / native wall time | **190–220%**, where one fully used core is 100%; includes all app threads |
| Largest 50ms timer interval | **62ms**, including the long input; isolate responsiveness, not frame-jank measurement |
| Thermal / temperature | thermal status **0** for all 67 samples; battery **30.1–30.9°C** |

First-three mean latency was 6.680s and last-three 6.506s: no ≥20% sustained
slowdown was observed. `dumpsys` sampled memory and `/proc` high-water RSS have
different accounting and sampling; both are reported, rather than treating one
as an exact allocation peak. The phone was USB charging, so battery energy was
not measured. Ten identical short inputs plus a long negative exercise allocation,
cleanup and runtime limits; they do **not** satisfy the representative multi-reciter
corpus or positive long-clip accuracy gate. Release cancellation was not separately
timed; the actual active-inference cancellation result above is from debug.
Reports: `output/alignment-release-report.json`, `alignment-release-logcat.txt`,
`alignment-release-samples/`, `android-alignment-release-test.log`.

### Automated and container checks

- Host analyzer: **no issues**. Full Flutter suite: **60 passed**, including six
  Android bridge/model setup tests and all existing real media/export tests.
- Independent-reference metric invariants: **6 passed**, including per-reciter
  failure/coverage breakdowns with missing predictions. These are synthetic
  metric tests, not a substitute for human timing references.
- Java core algorithm checks cover repeated CTC labels, impossible paths,
  cancellation, Arabic folding and edit distance. Desktop CPU parity results
  follow below.
- Bugs corrected during validation include asynchronous file-write error handling
  in model downloads, preserving cancellation reasons, test package isolation,
  Java UTF-8 compilation in the container, and loading the verified JNI libraries
  from the immutable image rather than a noexec temporary mount.
- Final Docker Linux sequence: `check.sh`, `check-alignment-ui.sh`,
  `check-editor-ui.sh`, `check-trimmer-ui.sh` and the release build **all passed**.
  This includes 60 tests, clean analysis/formatting, real local alignment with
  review/word editing/export, the editor flow (22s), and independent trimmer
  playback/splitting/renaming/saving (15s). Log: `output/alignment-final-linux.log`.
  The complete release bundle is `output/linux-alignment/`; host shared libraries
  resolved and the user desktop launcher was updated to that bundle.
- Physical A52s regression: **4 passed** in 44s after a 44.3s debug build and
  91.3s APK installation. Real FFmpegKit verified progressive Quran MP4 export,
  fractional cuts retaining all frames and synchronized tones, silent/portrait
  encode and stream-copy paths, and 120s sources split into 4/2/2 files for
  30/60/90s presets. The editor imported/trimmed native media, saved/reopened
  manual timing, exported, and opened the trimmer on the completed MP4.
  The first successful editor run emitted one missed pause-tap warning; the
  harness now treats missed taps as failures and re-reveals the control after
  the phone's dialog/keyboard transition. The stricter A52s editor rerun
  **passed in 25s**, including both play/pause controls and completed-reel export,
  with no missed-tap warning. Log: `output/android-alignment-editor-strict.log`.
  Its debug build/install took 103.6/87.8s on the loaded development host.
- Returning from the split release benchmark initially failed with
  `INSTALL_FAILED_VERSION_DOWNGRADE`, including with `adb install -r -d`.
  No uninstall was performed. Benchmark-only Gradle configuration now uses
  matching debug/release version codes and disables the split-ABI offset;
  the strict editor run updated the release installation without losing its
  private storage. Normal application IDs/version codes are unchanged.
- The physical portrait test uncovered FFprobe's missing display-matrix metadata.
  Android now falls back to `MediaMetadataRetriever` when probe rotation is
  absent, preserving explicit rotation metadata where present. The fixture sets
  a known MP4 track matrix directly. Source, encoded and copied orientations
  passed on the A52s; no processing workaround was needed. Earlier test runs
  interrupted by the lock screen are not counted as passes. Benchmark activities
  now keep their screen awake; normal alignment does so only during an active
  job, without changing the user's system timeout.

### Final Android packages and resource decision

`flutter analyze --no-pub`: **no issues** (2.8s). Normal all-ABI debug build:
**passed**, 34.2s. `bash scripts/build-apk.sh`: **all three release ABIs passed**,
114.4s. Packages are development-signed, under `output/android/`; the isolated
benchmark APK is kept separately. Release checksums are in `SHA256SUMS`.

| Normal APK | Bytes | Increase from pre-alignment `da017d5` build |
|---|---:|---:|
| ARM64 release | **98,227,597** | **19,778,509** |
| ARMv7 release | 127,563,201 | 14,453,713 |
| x86-64 release | 113,611,934 | 23,546,827 |
| Debug, all three ABIs | 442,361,757 | 56,930,751 |

The ARM64 **≤15 MB incremental APK gate failed**; it was not silently increased.
The full ORT ARM64 runtime/JNI contribute 19,423,368 uncompressed bytes. A smaller
custom runtime remains future work requiring its own operator and device checks.
The pinned weights add **241,230,289 bytes (241.2 MB / 230.1 MiB)** in private
storage, downloaded separately; APKs contain no weights, Python, desktop JARs or
audio fixtures. Project media, temporary files, ART profiles and exports require
additional device space; APK plus weight size is not a complete storage estimate.

`apksigner verify` and `zipalign -c -P 16 4` **passed for all four normal APKs**.
Archive inspection found complete Flutter/ORT/JNI/FFmpeg/mpv libraries for each
intended ABI, including all three in debug. ARM64/x86-64 ELF load segments have
alignment ≥16 KiB. ARMv7 media libraries retain 4 KiB ELF alignment; ZIP alignment
alone is not claimed to change that. Android automatic alignment rejects 32-bit
processes with a manual-timing remedy. ARMv7/x86-64 packages were built/inspected,
not executed on corresponding Android hardware. No AAB/Play Store validation was
performed. Inspection: `output/alignment-apk-inspection.json`.

The normal app's debug APK was installed directly with `adb install -r`; its
private model was provisioned from the already verified local weights and its
SHA-256 verified on the phone. No fixture or project was copied into the normal
app. This verifies local setup, not an on-device HTTP download test. In-app
download failure/corruption/retry paths have automated unit coverage.

The runtime is usable as a reviewed draft generator on this A52s. The unmet APK
budget, missing independent multi-reciter accuracy, representative sustained
workloads and release-mode cancellation measurement keep **overall acceptance
provisional**. Real Android file-provider dialogs, speaker listening, other
devices and controlled unplugged energy tests also remain outstanding.

### Desktop native/Python parity, network-disabled container

`docker compose --profile alignment build alignment-native-checks` and
`docker compose --profile alignment run --rm alignment-native-checks`: **passed**
after fixing the UTF-8/noexec issues above. The actual Android Java core ran on
desktop ONNX Runtime 1.23.2/JDK17, with the same pinned model and canonical text,
and was compared against the unchanged Python worker on all seven cases.
Base/partial/pause/half-speed aligned; extra repetition/wrong text/noise were
rejected. These are transformed cases of **one** reciter, not seven independent
recordings. Native and Python accepted word indices matched; maximum boundary difference
was **0 ms** on all four accepted cases. This is implementation parity, not
independent timing accuracy.

| Case | Peak RSS MiB | Session load ms | First / second alignment ms |
|---|---:|---:|---:|
| Base | 667.2 | 1,193 | 7,377 / 9,069 |
| Partial | 575.3 | 2,467 | 2,597 / 2,460 |
| Pause | 705.5 | 2,536 | 11,082 / 7,382 |
| Half-speed | 751.0 | 2,493 | 19,471 / 19,222 |
| Extra repetition | 757.1 | 1,130 | 19,288 / 19,466 |
| Wrong text | 663.3 | 1,263 | 7,892 / 9,349 |
| Noise | 664.6 | 2,471 | 9,740 / 9,140 |

Host: AMD Ryzen 7 5700U, Linux x86-64, 16 logical CPUs, 24GB-class RAM. Two ORT
intra-op threads; CPU time was 169–198% of wall time across these processes.
The host also ran development/build work, so these timings are observational,
not a controlled speed comparison. Second runs reuse the harness session; the
app instead closes each session. No OS cache flushing was performed.
Reports: `output/alignment-native-docker/summary.json` and per-case files.

An earlier host ablation disabled ORT's CPU arena and memory-pattern allocation:
base peak RSS fell from 905.3 to 738.9 MiB, half-speed from 1,033.1 to 824.4 MiB,
with zero native/Python boundary changes. Runs used different background loads,
so no speed improvement is claimed. The memory-saving settings are retained;
the final seven-case container check and A52s run above use them.

## Dedicated Video Trimmer (2026-10-18)

Architecture inspection found the Riverpod editor, MediaKit preview players,
`MediaEngine` Linux/Android boundary, verified completed `lastExport` MP4 and
existing Linux/SAF save service. The feature adds a separate route/state and a
single-pass segmentation service using those dependencies. Quran alignment and
reel composition remain separate. See [workflow, acceptance mapping and cut
limitations](VIDEO_TRIMMER.md).

Executed checks for this feature:

- Host `flutter analyze --no-pub`: **no issues**; `flutter test --no-pub`:
  **53 passed** using Fedora FFmpeg/OpenH264. Logs: `output/trimmer-analyze.log`
  and `output/trimmer-tests.log`.
- Container `bash scripts/check.sh`: **53 passed**, formatting unchanged and
  analysis clean, using Ubuntu FFmpeg/x264. This final run also includes the
  silent-video case. Log: `output/trimmer-docker-checks.log`.
- Real 120-second H.264/AAC sources produced **four 30-second, two 60-second,
  and 90+30-second outputs**. Fractional 1.25-second cuts retained all 37 distinct
  frames from a 3.7-second source, in order without duplicates; measured chirp
  frequencies verified audio/source timing. Portrait metadata, stream copy,
  re-encoding, silent video, final remainders and cancellation/storage cleanup
  are exercised. Fixtures are generated mathematical frames/tones.
- The existing real progressive Quran export test now also splits the completed
  reel, checks increasing gold Arabic word prefixes and the final blank segment,
  retains audio/notices and confirms the full MP4 remains available.
- Desktop and phone widget tests pass at 1366×900 and 390×844 for independent
  navigation, source-derived names, custom names surviving project edits,
  presets/custom durations, invalid inputs and unchanged reel state.
- `bash scripts/check-trimmer-ui.sh` in Docker/private Xvfb: **passed**. Actual
  import, native video play/pause, source/generated previews, custom splitting,
  renaming, batch saving with an existing destination filename and temporary
  cleanup ran; only OS file/folder dialogs were replaced. The final screenshot
  review refined card widths and corrected a misleading decode warning for an
  unavailable audio device. Final analysis, both responsive tests and the native
  workflow passed again (20 seconds for the native test). Screenshots:
  `output/trimmer-evidence/trimmer-source.png` and `trimmer-segments.png`.
- `bash scripts/check-editor-ui.sh` in Docker/private Xvfb: **passed** (26 seconds),
  including normal import/trim/timing/save/reopen/export, opening the trimmer
  against the actual completed export, and returning to single-file saving.
  Logs: `output/trimmer-native-ui.log` and `output/trimmer-native-editor.log`.
  The container has no audio device: video playback/controls ran, and encoded
  audio was checked digitally, but physical speaker output was not verified.
- Tests caught and fixed an FFmpeg global timestamp shift that skipped the first
  stream-copy cut, and a rename-dialog controller disposed during its closing
  animation. A rotation fixture was corrected to use FFmpeg's input display
  rotation option; no missing orientation check was waived.
- Final Android debug build: **passed** (27.7 seconds). Release builds: **all three ABIs
  passed** (68.8 seconds). The new Kotlin document-tree batch-saving bridge
  compiled. Debug and ARMv7/ARM64/x86-64 release APKs are in `output/android/`;
  release checksums refreshed. `apksigner verify` and `zipalign -c -P 16 4` passed
  for all four packages. Logs: `output/trimmer-android-debug.log` and
  `output/trimmer-android-release.log`.
- Final Linux release build passed into `output/linux-trimmer/`, with no unresolved
  host shared libraries. The desktop launcher was updated to this complete bundle
  and the application was launched successfully; native players and EGL rendering
  initialized. The optional CUDA probe warning was nonfatal.
- `adb devices -l`: **no attached devices**. Android FFmpegKit execution,
  playback, actual SAF dialogs and provider cancellation remain unverified on a
  device. Earlier emulator attempts crashed before boot (see the acceptance
  record below); they are not reported as application test results. APKs continue
  to use development signing.
- Shell syntax, documentation links and `git diff --check` passed. CI includes
  the new native trimmer workflow. Existing Docker dependencies were sufficient;
  no new runtime package or model download was added.

Changed implementation files: `lib/features/video_trimmer/segment_plan.dart`,
`segmentation_service.dart`, `video_trimmer_page.dart`, editor navigation,
shared export naming/destination services and Android `MainActivity.kt`.
Tests, the native check script, CI, README and this documentation accompany them.

Cut limits: durations follow actual video frames, with small AAC packet-boundary
offsets possible. HDR re-encoding is rejected pending explicit tone mapping.
Unverifiable/VFR boundaries fail with a remedy instead of being fabricated.
Temporary and destination storage are both needed; abrupt process termination
and document-provider deletion failures can require manual cleanup.

## Request acceptance recheck (2026-10-18)

The owner's full enhancement request was re-read and mapped to all eight feature
groups and 15 acceptance criteria in [ACCEPTANCE.md](ACCEPTANCE.md).

An additional interaction test found that the preview's pan recognizer lost
vertical/diagonal drags to its enclosing scroll view. The preview now uses
Flutter's draggable interaction with an invisible feedback widget; its actual
text continues to move through the shared painter. Desktop (1366×900) and phone
(390×844) tests now drag the overlay, select gold text, toggle the background and
save/reload the resulting settings. Both pass. The test fixture was corrected to
load the real fonts and include its media path before checking saved projects.

Android runtime acceptance remains **blocked by emulator startup**, not passed:

- `adb devices -l` found no attached physical device. `emulator -list-avds` did
  reveal two existing configurations, and `emulator -accel-check` reported usable
  KVM. This improves on the preceding check, which only looked for connected devices.
- The API 35 `Medium_Phone_API_35` AVD was attempted read-only without snapshots,
  first with `swiftshader_indirect` and then supported `software` graphics with
  Vulkan disabled. Both emulator processes terminated with exit 139 before boot.
- The second `my_a52s` configuration uses an API 37 image; the same read-only,
  software-rendered attempt also terminated with exit 139 before boot.
- `flutter test integration_test/enhanced_media_export_test.dart -d emulator-5580
  --no-pub` could not retrieve device properties (`error: closed`, then no supported
  device). **No Android application test executed or passed in these attempts.**
  Every attempt used `-read-only -no-snapshot`; no wipe or snapshot save was
  requested. Logs are under `output/acceptance-android-emulator*.log`
  and `output/acceptance-android-enhanced.log`. A working emulator or connected
  device is still required for native Android acceptance, launcher appearance,
  physical playback and real document-provider checks.

- Final `flutter analyze --no-pub`: **no issues**. `flutter test --no-pub`:
  **42 passed**, including both new drag/color/persistence interaction tests
  and the real FFmpeg regressions. Logs: `output/acceptance-analyze.log` and
  `output/acceptance-flutter-tests.log`.
- `flutter build apk --debug --no-pub`: **passed** (27.1-second Gradle build).
  `bash scripts/build-apk.sh`: **all three release ABIs passed** (80.1-second
  Gradle build). Debug and release artifacts in `output/android/` were refreshed;
  `apksigner verify` and `zipalign -c -P 16 4` passed for all four packages.
  Logs: `output/acceptance-android-debug.log` and
  `output/acceptance-android-release.log`.
- `docker compose run --rm dev bash scripts/build-linux.sh output/linux-acceptance`:
  **passed**. The complete updated bundle is `output/linux-acceptance/` so an older
  running bundle was not overwritten. It was launched on Fedora; native players
  and EGL rendering initialized and the process remained running. Existing GTK
  accessibility/cursor and optional CUDA-probe warnings were nonfatal.
- `python3 scripts/install-linux-desktop.py
  /home/ma7moud-5aled/Projects/quran_reel_maker/output/linux-acceptance`: installed
  the app launcher and four hicolor icon sizes into the owner's user data folder.
  `desktop-file-validate` passed on the actual installed entry at
  `~/.local/share/applications/com.example.quran_reel_maker.desktop`.
- `dart format --output=none --set-exit-if-changed lib test integration_test`:
  **34 files checked, no changes**. `git diff --check` and documentation-relative
  link checks passed. The Python worker/export algorithm did not change in this
  recheck; their preceding 12 offline-model tests and two native workflow results
  are retained below rather than reported as new executions.

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
