# Offline Quran forced alignment

Linux supports **local automatic draft timings** for a known surah/ayah range.
This is forced alignment against the bundled, hash-verified Tanzil Uthmani 1.1
text, not automatic surah identification. Android retains the manual workflow;
a Python executable is not an Android inference runtime.

## Install once, then work offline

Install Python **3.11–3.13**, venv/pip support and FFmpeg on Linux, then run:

```bash
./scripts/setup-alignment.sh
```

This explicitly downloads hash-locked dependencies into `.alignment-venv` and
241 MB of weights plus small configuration/tokenizer files into
`.alignment-models/quran-ctc-q4-v1`. Allow additional disk space for Python wheels
and the environment. Every model file's size/SHA-256 is verified; downloads use
atomic replacement and already valid files are reused. The app itself never
downloads weights or calls a remote inference service. Native inference needs
neither Docker nor a GPU, PyTorch or Transformers.

In the editor, **Choose local worker** → select `scripts/alignment-worker.sh`.
This preference persists. Keep the source checkout, Quran assets, environment
and weights together; moving them requires selecting the worker again. The
launcher is found automatically when running from the source checkout.
Alternatively set `QRM_ALIGNMENT_WORKER=/absolute/path/to/launcher`. A packaged
Flutter bundle needs this separately installed worker. For development only,
`QRM_ALIGNMENT_PYTHON` can select another compatible Python environment.

The validated CPU platform is Linux x86-64: native Python 3.13 and Ubuntu
24.04/Python 3.12 in Docker. Other CPU architectures/Python versions are untested.
Once setup is complete, inference works with networking disabled. Missing files,
corrupt weights, incompatible runtime, unavailable FFmpeg and unsuitable audio
produce actionable diagnostics. Failure/cancellation keeps existing cues.
**Create manual timings** remains available on Linux and Android.

## Verified model provenance

| Item | Source/details |
| --- | --- |
| Export | [mostafanewir70/quran-recitation-ctc-onnx](https://huggingface.co/mostafanewir70/quran-recitation-ctc-onnx) |
| Pinned revision | `f90650aac5d9dcff15230a19998c0027f45b33f1` |
| Weights | `onnx/model_q4.onnx`, 241,230,289 bytes |
| Weight SHA-256 | `9b17e04fdc2aef54720e62216a7c7ae7f55d27911ee7cd55253baa231845a587` |
| Upstream fine-tune | [rabah2026/wav2vec2-large-xlsr-53-arabic-quran-v_final](https://huggingface.co/rabah2026/wav2vec2-large-xlsr-53-arabic-quran-v_final) |
| Declared base | [jonatasgrosman/wav2vec2-large-xlsr-53-arabic](https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-arabic) |
| Declared training corpus | [rabah2026/Quran-Ayah-Corpus](https://huggingface.co/datasets/rabah2026/Quran-Ayah-Corpus) |
| License/language | Export and upstream cards declare Apache-2.0; Arabic Quran recitation |
| Graph | Wav2Vec2 CTC; 56 classes including Arabic letters/harakat; float32 `input_values` `[batch,samples]` → `logits` `[batch,frames,56]` |
| Input/runtime | Normalized mono 16 kHz; ONNX Runtime 1.23.2 CPU; NumPy 2.2.6 |

The export README title says “int8”, but its body, filename and actual graph use
**4-bit MatMulNBits** weight quantization. We use that q4 export.
[ONNX Runtime documents this operator](https://onnxruntime.ai/docs/performance/model-optimizations/quantization.html).
The actual weights were downloaded, hash-checked, loaded and exercised on CPU.
The weight checksum matches published LFS metadata. All auxiliary files are
pinned in [model_manifest.json](../alignment_worker/model_manifest.json), with
hashes calculated from the pinned downloads. Publisher license declarations are
not an independent audit of every training recording's rights. No training
corpus is downloaded or redistributed. Upstream WER/segmentation claims are
not app accuracy guarantees and are not adopted here.

[tarteel-ai/whisper-base-ar-quran](https://huggingface.co/tarteel-ai/whisper-base-ar-quran)
was also inspected (Apache-2.0 declaration). Its sparse model card and heavier
Whisper/alignment dependency chain made the verified CTC export a more practical
first implementation. This is not a comparative accuracy claim.

## Processing and review

1. Validate Quran digest, local file, references and a 0.5–180 second trim.
   Verify local model hashes before loading. Reject oversized text/DP requests.
2. FFmpeg decodes exactly the selected trim to mono 16 kHz float32. Network
   protocols are disabled. Reject unreadable, truncated or silent audio.
3. CPU inference uses two threads and 15-second chunks with one second of context
   on each side. Keep frame centers once on the model's 320-sample stride and
   400-sample receptive-field clock.
4. Create an **acoustic token view**, folding vocalization/annotation and spelling
   variants against equivalent model emissions. Original Tanzil bytes, display
   text, export text and whitespace word indices remain unchanged. No ASR text
   replaces Quran text. Projects store references rather than generated text.
5. Monotonic CTC Viterbi allows blank pauses, elongated token dwell, and a blank
   between repeated identical letters. The DP is limited to 40 million cells.
6. Aggregate tokens into word/ayah drafts; add `trimStart` **once** to obtain
   source seconds. Return acoustic scores, model provenance and warnings.
   `confidence` stays null: acoustic scores are **not calibrated probabilities**.
7. A greedy token/text comparison rejects severe mismatch (>0.65 edit ratio).
   Mean acoustic score <0.15 is rejected. Mismatch >0.20, low/short word matches,
   long words/pauses and speech at trim edges trigger warnings. These thresholds
   are engineering heuristics, not calibrated accuracy measurements.

Use **Align automatically / Rerun alignment**, the segment strip, playback/seek
slider, ayah and word seeking, and editable start/end seconds. Cancel keeps prior
cues. Editing an ayah boundary discards obsolete word timings/scores. Successful
alignment and manual timing/trim edits reset the review checkbox; export requires
review. All displayed times are original-source seconds. The existing PNG subtitle
timeline clips/subtracts the trim start exactly once, quantizes to 30 fps and
keeps gaps blank. Word drafts support review; export still uses **ayah-level** text.

## Local process protocol, version 1

The worker reads one JSON line on stdin (maximum 64 KiB):

```json
{"protocol":1,"quranSha256":"6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f","audioPath":"/absolute/recitation.ogg","trimStart":14,"trimEnd":27,"surah":1,"firstAyah":2,"lastAyah":3}
```

Stdout contains NDJSON `progress` events (`protocol:1`, `value:0..1`, `message`),
then exactly one `result`, or an `error` with a code and actionable message.
Result fields: `timeline:"source"`, `model`, `revision`, `quranSha256`,
`mismatchRatio`, `cues`. Cues contain references/start/end, `timingSource`,
`alignmentModel`, `alignmentScore`, `warnings`, and `words` with
`{index,start,end,score}`. Word indices address whitespace tokens of the original
verse, skipping annotation-only tokens. Errors exit nonzero; logs use stderr.
Flutter bounds output, validates provenance/references/finite ordered times and
requires exit status zero. Cancellation/ten-minute timeout terminates the worker,
with a two-second kill fallback. Worker SIGTERM also terminates active FFmpeg.

## Optional Docker and tests

```bash
mkdir -p .alignment-models/quran-ctc-q4-v1 output
export DEV_UID="$(id -u)" DEV_GID="$(id -g)"
docker compose --profile alignment build alignment
# Explicit model setup, if native setup has not already populated this folder:
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD/.alignment-models/quran-ctc-q4-v1:/models:z" \
  quran-reel-alignment:1 python -m alignment_worker.model --model-dir /models

# Actual model tests with networking disabled by the compose service:
docker compose --profile alignment run --rm -e QRM_TEST_MODEL=1 \
  -v "$PWD/.alignment-models/quran-ctc-q4-v1:/opt/quran-reel/.alignment-models/quran-ctc-q4-v1:ro,z" \
  alignment python -m unittest discover -s alignment_worker/tests -v

# Native Flutter + real worker review/export test in private Xvfb:
docker compose build dev
docker compose --profile alignment build alignment-checks
docker compose --profile alignment run --rm alignment-checks

# Native Python checks; opt-in real-model tests do not download anything:
.alignment-venv/bin/python -m unittest discover -s alignment_worker/tests -v
QRM_TEST_MODEL=1 .alignment-venv/bin/python -m unittest discover -s alignment_worker/tests -v
flutter analyze
flutter test
```

The `alignment` service has `network_mode: none`, a non-root UID, read-only root
filesystem/model/media mounts, and temporary `/tmp`. For standalone inference,
put audio in `output/`, refer to `/media/...` in the request, and pipe JSON to
`docker compose --profile alignment run --rm -T alignment`. Images contain the
runtime, code and CC0 test fixture, not weights. The base digest, dependency
versions/hashes and model files are pinned; Ubuntu packages receive repository
updates. The optional development target builds on the Flutter development image.

Without `QRM_TEST_MODEL=1`, real-model Python tests explicitly skip. The bundled
[CC0 fixture and expected windows](../test/fixtures/alignment/README.md) test actual
inference, inserted pauses/source offsets, silence, noise and wrong selections.
Expected windows are **model-assisted regression data**, not human gold labels.
Synthetic emissions independently test CTC path behavior. Dart tests check process
failure/cancellation, persisted metadata and export rebasing.

## Limits

- A monotonic pass assumes the selected ayahs are recited **once, in order**.
  Repetitions, omitted phrases, ta'awwudh and extra basmala can cause rejection
  or distort a draft. Crop them out or edit manually. Repeated passages are not
  automatically duplicated into additional cues.
- Tajweed elongation can outlast a lexical emission; CTC frame times are not
  guaranteed phonetic boundaries. Word times are approximate. Pauses within an
  ayah do not automatically blank the ayah subtitle.
- Noise, music, echo, multiple voices, unfamiliar styles, very short selections
  and chunk seams can produce confident-looking errors. Acoustic scores and
  mismatch checks cannot prove recitation/text correctness.
- The licensed real-audio fixture covers one Al-Fatiha passage. There is no
  multi-reciter benchmark, independent onset/offset error measurement, calibrated
  confidence or production accuracy guarantee. Review every final MP4.
- Android on-device automatic alignment is not implemented or tested.

See [VALIDATION.md](VALIDATION.md) for commands actually executed and results.
