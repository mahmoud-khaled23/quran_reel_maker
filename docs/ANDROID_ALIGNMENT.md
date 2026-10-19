# Android Quran alignment: engineering evaluation

Research/evaluation dates: **2026-10-18–19**. This is a **provisional integration**, not
a claim that a model has won a representative Quran timing benchmark. The pinned
Quran CTC model now has a native Android CPU path. Independent word-boundary
accuracy still needs an annotated evaluation corpus. No ASR WER is substituted
for timestamp accuracy.

## Architecture inspected before implementation

- Riverpod `AppServices`/editor owns the project; MediaKit previews; `MediaEngine`
  dispatches FFmpeg/FFprobe on Linux and FFmpegKit on Android. The independent
  Video Trimmer and optional completed-reel segmentation share these services.
- Tanzil Uthmani text is verified against SHA-256
  `6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f`.
  Surah/ayah references and **original whitespace word indices** identify text.
  Acoustic normalization never edits display text, spelling or diacritics.
- Linux `setup-alignment.sh`, `alignment-worker.sh`, `model.py`, requirements lock,
  model/config/vocabulary, `worker.py` and `ctc.py` were inspected. It is one Quran
  ASR acoustic model plus a strict CTC forced-alignment algorithm, not a dedicated
  phoneme aligner and not an unconstrained transcript-to-subtitle pipeline.
- Linux uses Python, NumPy and ONNX Runtime 1.23.2, CPU, 16 kHz mono; 15-second
  centers with one second of context, 320-sample lattice/400-sample receptive
  field; at most 180 seconds/40 million CTC trace cells. It remains unchanged.
- Results use source seconds. The renderer rebases once onto the trimmed export,
  rounds word onsets forward to 30 fps, uses canonical prefixes and blanks long
  gaps. Existing review/edit/manual timing and MP4 export remain in place.
- Android API 24 minimum/API 36 target, NDK 28.2.13676358, Java 17 target,
  Flutter 3.47.7/Dart 3.13.5. Release ABIs remain ARMv7, ARM64 and x86-64.
  Alignment requires a **64-bit process**; ARMv7 retains manual timing/export.
  Existing native FFmpegKit and MediaKit dependencies are reused for media.
- Before this change: ARM64 release APK **78,449,088 bytes**, ARMv7
  **113,109,488**, x86-64 **90,065,107**, universal debug **385,431,006**.
  Baseline: `da017d5`, `output/trimmer-apk-baseline.json`.

## Candidates and verified evidence

Sizes below are repository file sizes unless explicitly marked measured. No
Android RAM/RTF is inferred from parameter count or a desktop/GPU benchmark.

| Candidate | Files, text/language support, license | Timing/runtime trade-off | Measured Quran timing accuracy / Android resources |
|---|---|---|---|
| [Quran Wav2Vec2 CTC q4](https://huggingface.co/mostafanewir70/quran-recitation-ctc-onnx) | **241,230,289-byte** ONNX; 56-class Arabic/harakat vocabulary **672 bytes**; publisher Apache-2.0 declaration. [Pinned files](https://huggingface.co/mostafanewir70/quran-recitation-ctc-onnx/tree/f90650aac5d9dcff15230a19998c0027f45b33f1). | Frame logits support canonical-text CTC alignment directly. q4 `MatMulNBits`, not int8 despite the card heading. No new weight conversion. CPU ORT Java/Android implemented here; full operators needed. | Independent accuracy **unmeasured**. Desktop same-core measurements below; device evidence recorded separately. |
| [Tarteel Whisper Tiny Arabic Quran](https://huggingface.co/tarteel-ai/whisper-tiny-ar-quran/tree/main) | PyTorch weights **151 MB**; vocab.json **1.04 MB**, merges **494 kB**, preprocessor **185 kB**. Apache-2.0; Quran fine-tune of multilingual Tiny. Last model training artifacts are from 2022. | Smaller ASR model; transcription does not guarantee canonical coverage/timing. [whisper.cpp](https://github.com/ggml-org/whisper.cpp) has CPU Android and integer quantization, but calls word timestamps experimental. HF→GGML conversion and timing validation still required for these weights. | **Not benchmarked here**; model card WER is not word-boundary error. Quantized installed size, ARM64 RAM/RTF unknown. |
| [Tarteel Whisper Base Arabic Quran](https://huggingface.co/tarteel-ai/whisper-base-ar-quran/tree/main) | PyTorch weights **290 MB**, same approximately 1.04 MB vocabulary/494 kB merges. Apache-2.0. | Same conversion/timestamp issues; larger encoder/decoder. An alignment stage or validated constrained attention/DTW approach is still needed. Offline after local conversion/setup; CPU possible via whisper.cpp, not measured for this fine-tune. | **Not benchmarked**. No claim that more parameters improve Quran boundaries. |
| [MMS_FA](https://docs.pytorch.org/audio/stable/generated/torchaudio.pipelines.MMS_FA.html) | Official multilingual pretrained forced-alignment bundle and downloadable checkpoint. **CC-BY-NC-4.0**; not selected for unrestricted application distribution. No weights downloaded here. | [Official tutorial](https://docs.pytorch.org/audio/stable/tutorials/forced_alignment_for_multilingual_data_tutorial.html) requires transcript normalization/romanization; no word separator class. PyTorch/torchaudio reference path, not a ready Android package. Mobile conversion/operator/Arabic pronunciation checks required. | Quran gold accuracy, installed/quantized size, ARM64 RAM/RTF **unmeasured**. Noncommercial constraint is a separate selection gate. |
| [NVIDIA Arabic FastConformer Hybrid Large PCD](https://huggingface.co/nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0) | Available [459 MB .nemo](https://huggingface.co/nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0/tree/main), about 115M parameters, 1,024 SentencePiece vocabulary. Arabic diacritics; includes EveryAyah in declared training. **CC-BY-4.0**. | RNNT + CTC; the CTC branch could support known-text alignment. Eightfold subsampling and subword grouping need timing evaluation. Official deployment is NeMo/Linux/NVIDIA hardware; no validated Android conversion selected here. | Reported A5000 GPU ASR results are **not** phone or timing evidence. Converted size, CPU RAM/RTF and boundary accuracy **unmeasured**. |

The CTC candidate is carried forward because it has a verified, already working
Quran acoustic path and allows direct known-text alignment with identical weights.
This is an integration-risk decision, **not evidence it is the best model**.
Whisper Tiny and FastConformer remain credible challengers once independent
references exist; evaluate all finalists on the same clips before choosing a
production winner. No challenger was downloaded or timed and no conversion
accuracy loss was invented.

The fine-tune provenance is
[rabah2026](https://huggingface.co/rabah2026/wav2vec2-large-xlsr-53-arabic-quran-v_final),
with the declared [Arabic XLSR base](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-arabic).
Training/licensing completeness is limited to the publishers' declarations;
the application does not redistribute their training recordings.

[ONNX Runtime Android 1.23.2](https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.23.2/)
was downloaded and inspected: ARM64/ARMv7/x86/x86-64 JNI and runtime libraries are
present. AAR SHA-256 `82048d1f462218adae4ba76477089ab0ba76093d84f733540066db1a8ba6b827`.
[Reduced mobile operator packages](https://onnxruntime.ai/docs/reference/operators/MobileOps.html)
stopped at 1.19; this uses the full Android package, CPU execution, two intra-op
threads, one inter-op thread, no GPU/NNAPI/QNN dependency. The
[q4 kernel source](https://github.com/microsoft/onnxruntime/blob/v1.23.2/onnxruntime/contrib_ops/cpu/quantization/matmul_nbits.cc)
and actual artifacts were checked; packaging alone is not model execution proof.
[JNI keep rules](https://onnxruntime.ai/docs/build/android.html) and official MIT/
third-party notices are included.

## Setup and interface

1. In the editor open **Alignment model → Download / repair**. This is explicit
   setup, approximately 241.2 MB; allow at least 300 MB free plus media/workspace
   storage. The filename/revision are pinned, transfer size is bounded, progress
   and cancellation are shown, and SHA-256 is verified before promotion from
   `.part`. Failure removes partial output and permits retry.
2. The single weight file lives in private application support storage. It is
   excluded from Android cloud backup/device transfer. Weights, Python, datasets
   and desktop JARs are **not bundled in the APK**.
3. Select the matching surah/ayah and boundary words, trim 0.5–180 seconds, and
   choose **Align automatically**. FFmpegKit decodes just that trim to mono16k
   float32; the Java engine reads it on a worker thread, verifies model/Quran/
   vocabulary, infers in bounded windows and aligns canonical characters.
4. Listen, seek, inspect/edit words and ayahs, then mark reviewed before exporting.
   Re-running replaces timings only on a complete validated success. Missing,
   corrupt, incompatible, cancelled, low-memory or mismatched results preserve
   existing timing and show a remedy. Manual timing remains available.

Flutter↔Android MethodChannel `quran_reel/alignment`: `align` accepts a JSON
protocol-1 request plus app-private `pcmPath`, `modelPath`, request `id`; `progress`
is tagged with that ID; `cancel` interrupts active ORT `RunOptions`. Results keep
the existing `timeline: source`, model/revision/Quran hashes, ayah references,
canonical word indices, source start/end **seconds**, acoustic scores and warnings.
Optional `metrics` adds measured load/inference/work duration and process RSS.
The Android activity cancels when backgrounded or asked to relieve memory.
Session initialization cannot be forcibly interrupted inside ORT; cancellation
is checked immediately afterward. Sessions/tensors/scratch are closed per job.

CTC scores are **uncalibrated acoustic indicators, not confidence probabilities**.
Greedy-text mismatch checks reject gross wrong selections; they cannot prove
every repeated/similar word is assigned correctly. Strict monotonic CTC cannot
represent extra recited repetitions as new canonical occurrences. Crop them or
correct manually. Elongations, pauses, noise, trim-edge speech and uncertain
words produce warnings; matching exact text does not prove precise boundaries.

## Evaluation gates, set before device inference

Target observed: Samsung SM-A528B/A52s, Android 14, ARM64, MemTotal 7,541,152 KiB
(8 GB-class device). Initial available RAM was about 1.79 GiB; it was USB charging.
No hardware accelerator is assumed.

Production acceptance needs **all** gates, not a favorable average alone:

| Gate | Provisional target / rationale |
|---|---|
| Independent corpus | At least 24 clips, 3 reciters, 500 selected spoken words; different surahs/lengths/speeds, partial ayahs, repeated/similar words, pauses, elongated speech and noisy recordings. Include deliberate wrong-text/extra-repetition negatives. A six-word fixture cannot establish these rates. |
| Boundary accuracy | Combined start/end median ≤100 ms, p90 ≤250 ms; ≥40% within50 ms, ≥70% within100 ms, ≥85% within200 ms. Report starts/ends separately, uncertainty-eligible denominators and every per-reciter breakdown. Targets reflect useful word highlighting, not phonetic precision; 20 ms CTC frames do not establish 20 ms accuracy. |
| Coverage/failures | ≥98% canonical word coverage; ≤5% failed positive clips and ≤5% accepted negatives. No successful clip may omit a word silently. |
| Latency | Median end-to-end RTF ≤1 on 10–30 s clips, p90 ≤1.5; first model verification/load ≤8 s. Measure fresh process/session and repeated requests separately; record OS cache state. |
| Memory/storage | App peak RSS ≤1.25 GiB, sampled peak PSS ≤1 GiB; runtime aborts on memory pressure. Preflight requires 1,200 MiB available. Model ≤300 MB, incremental ARM64 release APK ≤15 MB. These budgets are provisional given desktop peaks and the observed device, not proof that 6 GB variants work. |
| Responsiveness/cancel | Release heartbeat gaps ≤250 ms during inference; active-inference cancellation returns within2 s. Model-load cancellation reported separately. No stale result or scratch files after cancel. |
| Sustained behavior | Repeat ten representative clips and a 3-minute clip; no crash/LMK, ≥20% slowdown flagged, no severe thermal state. Battery energy needs an unplugged controlled test; USB-charging percentages are not energy measurements. |
| Offline/regression | Actual no-default-network inference after setup; debug + release native launch; trimmed text overlay/export and trimmer checks. |

Targets must not be relaxed after observing results without recording the reason.
Unmet or unmeasured gates keep the model provisional.

## Independent accuracy references

The bundled CC0 recording has **model-assisted broad regression windows**, not
human word labels. Its first useful selection has six words from one reciter.
No 50/100/200 ms accuracy result is claimed. Examined
[quranlab dataset licensing](https://huggingface.co/datasets/quranlab/quran-audio-text/blob/main/LICENSES.md)
does not grant open redistribution of the referenced reciter audio; licensed
timing metadata alone does not license recordings or prove human boundary review.

`test/fixtures/alignment/reference-template.json` is intentionally unfilled.
An Arabic/Quran-literate reviewer should listen independently (without predicted
times), mark audible first phoneme/final phoneme per selected canonical word,
include full elongations, leave actual pauses unassigned and record uncertainty.
A second reviewer adjudicates disagreements. Keep original audio hashes, sources,
licenses, reciter IDs, annotation method and reviewer IDs. Do not score a boundary
at tolerance T unless annotation uncertainty ≤T/2. Repetition cases must be marked
as negative unless occurrence-level annotation is explicitly supported.

`scripts/alignment/evaluate.py` refuses draft/model-assisted references, validates
time/order/IDs and reports median/p90, eligible within50/100/200 proportions,
coverage, failures, extra words and false acceptance. Missing predictions count
as failures. Accuracy is computed only on matched boundaries and must always be
read with coverage. The included evaluator tests use mathematical values, not
invented Quran timings.

`scripts/alignment/quality_probe.py` adds objective, human-free evidence that
**does not satisfy the gates above**: `score` checks predicted boundaries
against pauses detected in the audio (floor-based VAD heuristics with explicit
reliability diagnostics), `synthetic-pause` inserts known digital silence,
realigns, and reports speech claimed inside that silence (provably wrong by
that many milliseconds) plus boundary drift after removing the known time
shift, and `predictions` prepares evaluator-ready predictions the moment gold
labels exist. Measured 2026-10-19 on the CC0 fixture: zero speech inside 2 s of
inserted silence, full pause coverage, mapped drift median 0.0 ms / max 20 ms
(one CTC frame). The fixture is a continuous recitation, so natural-pause
agreement is inconclusive there; multi-reciter human references remain the
acceptance requirement. See [VALIDATION.md](VALIDATION.md).

## Repeatable commands

```bash
./scripts/setup-alignment.sh
JAVA_HOME=/path/to/jdk bash scripts/alignment/setup-native-benchmark.sh
JAVA_HOME=/path/to/jdk .alignment-venv/bin/python scripts/alignment/benchmark.py
# Equivalent pinned container; inference service has network_mode: none:
mkdir -p output/alignment-native-docker
docker compose --profile alignment build alignment-native-checks
docker compose --profile alignment run --rm alignment-native-checks
python3 -m unittest discover -s scripts/alignment -p 'test_*.py' -v
python3 scripts/alignment/evaluate.py independent-reference.json predictions.json
# Objective probes (no human labels; never a substitute for the gates):
.alignment-venv/bin/python scripts/alignment/quality_probe.py predictions \
  --reference test/fixtures/alignment/reference-template.json \
  --out output/quality/predictions.json
.alignment-venv/bin/python scripts/alignment/quality_probe.py synthetic-pause \
  --audio test/fixtures/alignment/fatiha-cc0.ogg \
  --trim-start 14 --trim-end 27 --surah 1 --first-ayah 2 --last-ayah 3 \
  --insert-at 7.75 --out output/quality/synthetic-pause.json

# Isolated benchmark package; does not replace the normal app.
flutter build apk --debug --dart-define=QRM_ALIGNMENT_BENCHMARK=true
adb install -r build/app/outputs/flutter-apk/app-debug.apk
ADB=/path/to/adb bash scripts/alignment/prepare-device.sh
# Explicit --offline disables Wi-Fi/data and restores the prior state on exit.
ADB=/path/to/adb bash scripts/alignment/run-device-check.sh --offline
flutter test integration_test/android_regression_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true
# Real native aligner through editor review/editing and MP4 export:
flutter test integration_test/alignment_flow_test.dart -d DEVICE_ID --no-uninstall --dart-define=QRM_ALIGNMENT_BENCHMARK=true --dart-define=QRM_REAL_ALIGNMENT=true
# After debug tests: same-signed isolated release, ten sequential native jobs + 180-second negative stress input.
# No flutter_test or VM service is included in this release entrypoint.
ADB=/path/to/adb bash scripts/alignment/run-release-check.sh --offline
# Read-only sampler, alongside the device run:
ADB=/path/to/adb bash scripts/alignment/monitor-device.sh output/device-samples 90
```

The test scripts use `com.example.quran_reel_maker.benchmark` and Flutter's
`--no-uninstall`. Flutter 3.47.7 otherwise uninstalls integration test applications
on completion, removing their private files. Do not run device tests under the
ordinary application ID. The first attempt exposed this cleanup default and the
next lacked its fixture; neither is reported as a passed inference benchmark.
The release probe replaces only the benchmark app and retains its private model.
Isolated debug/release builds use the same version code (2000 + the pubspec code)
and suppress Flutter's additional split-ABI version offset. Android refused an
earlier debug downgrade even with `adb install -r -d`; no uninstall was performed.
Matching versions avoid that destructive workaround. `--no-uninstall` controls
test teardown only: Flutter can still uninstall/retry after an installation
failure, another reason all tests must use the isolated ID. Never uninstall the
normal application to resolve test installation issues. Release reports are read from new logcat
lines because Android correctly disallows `run-as` on non-debuggable builds.

Development JARs are downloaded only by the setup command and verified against
pinned SHA-256; inference does not fetch dependencies. Java 17+ and the existing
Python worker environment/FFmpeg are needed only for desktop evaluation. Python
and Docker are not Android runtime requirements. The native harness uses the
**same Java source** as Android but a desktop ONNX library; desktop results are
never relabeled phone results. It records fresh-session load, first/warm-session
alignment, RTF, process peak RSS, user/system CPU and wall time. App requests
deliberately release sessions instead of retaining a warm model indefinitely.

Detailed measured results and final package checks are recorded in
[VALIDATION.md](VALIDATION.md). Raw generated reports/media/logs remain under
ignored `output/`; only non-private summaries belong in the repository.

## Implementation files and dependencies

- [Java alignment core](../android/app/src/main/java/com/example/quran_reel_maker/alignment/QuranAligner.java)
  and [Kotlin bridge](../android/app/src/main/kotlin/com/example/quran_reel_maker/AlignmentBridge.kt):
  bounded CPU jobs, cancellation, memory checks and metrics. `MainActivity.kt`
  handles lifecycle, screen wakefulness and Android rotation metadata fallback.
  Gradle adds **ONNX Runtime Android 1.23.2**, JNI keep rules and isolated test
  application/version configuration; XML backup rules exclude downloaded weights.
- [Flutter engine/setup](../lib/features/synchronization/android_alignment_engine.dart),
  [model page](../lib/features/synchronization/alignment_model_page.dart), `main.dart`
  and the editor wire explicit model installation, canonical coverage validation,
  offline drafts and review into existing services. `media_engine.dart` corrects
  Android portrait inspection without duplicating the segmentation pipeline.
- [Benchmark/evaluator scripts](../scripts/alignment), model manifests/notices,
  Android unit/integration/release probes, media/editor regressions,
  `Dockerfile.alignment`, Compose and CI provide repeatable checks. No new Flutter
  dependency, Python runtime dependency or Linux inference algorithm was added.
