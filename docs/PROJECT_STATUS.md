# Project status

Last updated: **2026-10-19**, reference-annotation pipeline hardening.
Branch `working-side`, HEAD includes the hardening described below (parent
`ddedb92`, "Add objective alignment quality probes and agent status docs");
`main` points at `62ebef7`. Session changes: hardened
`scripts/alignment/evaluate.py` validation, added the `validate-reference`
preflight and audio-hash binding to `scripts/alignment/quality_probe.py`,
extended both alignment test files (22 → 40 tests), and documented the reviewer
procedure plus the ≥24-clip / 3-reciter plan in the new
`docs/ALIGNMENT_ANNOTATION.md`. No `lib/`, `test/`, `integration_test/`, Android
or worker code was touched.

## Completed work (audited, with evidence)

All 14 requested requirements are implemented. Verified this session:

- `flutter analyze` → **No issues found**.
- `dart format --output=none --set-exit-if-changed lib test integration_test` →
  **48 files, 0 changed**.
- `flutter test` → **60 passed** (includes real FFmpeg export, segmentation,
  trimmer widget, and Android bridge/model tests).
- `QRM_TEST_MODEL=1 .alignment-venv/bin/python -m unittest discover -s
  alignment_worker/tests -v` → **12 passed** (real offline model inference).
- `python3 -m unittest discover -s scripts/alignment -p 'test_*.py'` →
  **40 passed** (12 evaluator tests incl. the malformed-input matrix and the
  shipped-template invariant; 28 probe/preflight tests).
- `bash -n scripts/*.sh scripts/alignment/*.sh` → all pass.
- New 2026-10-19 (P1 probes): `quality_probe.py` measured on the CC0 fixture —
  0 ms speech inside 2 s known inserted silence, pause coverage 1.0, mapped
  drift median 0.0 ms / max 20 ms (one CTC frame); `predictions` generated
  evaluator-ready output; `evaluate.py` still correctly refuses the unfilled
  template. Raw reports under ignored `output/quality/`.
- New 2026-10-19 (hardening): the evaluator now refuses every malformed
  reference/prediction shape with a clean `ValueError`/CLI message (the
  pre-change adversarial matrix had 15 `KeyError`/`TypeError` crashes and 3
  silently accepted malformed files); predictions cannot be used as a reference
  and vice versa; `validate-reference --check-audio` preflights the shipped
  template as structurally valid but unannotated (`scoreable: false`, corpus
  gate unmet); `predictions` re-ran the Linux worker with SHA-256 verification.
  Evidence in `docs/VALIDATION.md`.
- CI: run `39256846086` on `working-side` @ `62ebef7` → **success** (4m42s,
  2026-10-19). Also green on `main`; `ddedb92` is a later push on the same job
  definition.
- Requirement spot-checks in code: six export resolutions
  (`export_settings.dart:9`), trimmer default name from uploaded filename
  (`video_trimmer_page.dart:217-219`), `_001`-style segment numbering and
  per-segment rename (`segment_plan.dart:68-82`), Android mipmaps +
  `linux/packaging/*.desktop` icons, ARM64 APK present in `output/android/`.

Detailed feature-by-feature evidence lives in `docs/ACCEPTANCE.md`,
`docs/ALIGNMENT.md`, `docs/ANDROID_ALIGNMENT.md`, `docs/VIDEO_TRIMMER.md`, and
`docs/VALIDATION.md` (prior agent's recorded runs — treat as documented claims,
not re-verified this session, except where listed above).

## Outstanding tasks (prioritized)

| P | Task | Why it is still open | Blocked on |
|---|---|---|---|
| 1 | **Independent word-level alignment accuracy evaluation** for the chosen Android/Linux CTC model | `docs/ANDROID_ALIGNMENT.md` sets gates (≥24 clips, 3 reciters, ≥500 words, median ≤100 ms etc.) that are **unmet**: no annotated reference exists; `reference-template.json` intentionally unfilled. Acceptance is explicitly "provisional". The autonomous part is done: objective probes (measured on the CC0 fixture, see VALIDATION.md), an evaluator-ready `predictions` path, a hardened evaluator, and a `validate-reference` preflight with corpus-gate counts. Exact reviewer steps and the 24-clip/3-reciter plan are in `docs/ALIGNMENT_ANNOTATION.md`. | A Quran-literate human reviewer (blind annotation + adjudication) to fill a **copy** of the template with ≥24 clips / 3 reciters / ≥500 words, then run `predictions` → `evaluate.py` |

| 2 | **ARM64 incremental APK size gate** | Measured +19,778,509 bytes vs the ≤15 MB target (ONNX Runtime full ARM64 runtime ≈19.4 MB). Recorded as failed, not fixed. | Engineering only (custom reduced ORT build or alternative runtime) + device re-check |
| 3 | Release-mode cancellation timing; unplugged energy; thermal/sustained runs with representative clips | Measured only in debug for cancellation; long/representative clips not run. | Physical A52s device |
| 4 | Real SAF/file-provider dialogs, audible playback, Android launcher visual check | Never exercised outside automated harnesses. | Physical device + human |
| 5 | Production application id + signing config | Deliberately still `com.example.quran_reel_maker` + debug key. | Owner decision / keystore |

## Test results for this audit (exact commands, this session)

```
flutter analyze                                            → No issues found (2.9s)
dart format --output=none --set-exit-if-changed lib test integration_test → 48 files, 0 changed
flutter test                                               → 00:22 +60: All tests passed!
QRM_TEST_MODEL=1 .alignment-venv/bin/python -m unittest discover -s alignment_worker/tests -v → 12 tests, OK (52.4s)
python3 -m unittest discover -s scripts/alignment -p 'test_*.py' -v → 40 tests, OK
python3 scripts/alignment/quality_probe.py validate-reference --reference test/fixtures/alignment/reference-template.json --check-audio → valid: true, 1 clip / 1 reciter / 6 words / 0 annotated, scoreable: false
.alignment-venv/bin/python scripts/alignment/quality_probe.py predictions --reference test/fixtures/alignment/reference-template.json --out output/quality/predictions.json → 1 clip (SHA-256 verified)
python3 scripts/alignment/evaluate.py <template> output/quality/predictions.json → refused: "Cannot score: Accuracy scoring requires independent human-reviewed annotations…"
python3 scripts/alignment/evaluate.py output/quality/predictions.json output/quality/predictions.json → refused: "Cannot score: Expected schema 1 source-timeline references."
.alignment-venv/bin/python scripts/alignment/quality_probe.py synthetic-pause … --insert-at 7.75 → 0.0 ms speech in inserted silence, coverage 1.0, mapped drift median 0.0 / p90 18 / max 20 ms
bash -n scripts/*.sh scripts/alignment/*.sh                → OK
gh run list → 39256846086 working-side@62ebef7            → completed/success
```

Not run this session (no host `xvfb`/`mpv`, no connected Android device):
Docker integration flows, Linux release rebuild, Android builds. Prior results
for those are in `docs/VALIDATION.md` and `output/*.log`.

## Exact next step

**P1 autonomous part is done** (probe tooling, hardened evaluator, preflight,
annotation guide). What remains, in order:

1. **Human annotation (P1 remainder, owner/reviewer):** follow
   `docs/ALIGNMENT_ANNOTATION.md`. In short: copy the template to a working file
   (`cp test/fixtures/alignment/reference-template.json
   output/quality/reference.json`), add ≥24 clips / ≥3 reciters / ≥500 words /
   negatives with provenance, preflight it, generate predictions before
   annotating, annotate blind, adjudicate, then score:
   ```bash
   python3 scripts/alignment/quality_probe.py validate-reference \
     --reference output/quality/reference.json --check-audio
   .alignment-venv/bin/python scripts/alignment/quality_probe.py predictions \
     --reference output/quality/reference.json --out output/quality/predictions.json
   # … blind annotation + second-reviewer adjudication …
   python3 scripts/alignment/quality_probe.py validate-reference \
     --reference output/quality/reference.json --check-audio   # scoreable: true
   python3 scripts/alignment/evaluate.py \
     output/quality/reference.json output/quality/predictions.json \
     > output/quality/report.json
   ```
   The shipped template stays unfilled; evaluation-use audio is downloaded
   locally and not redistributed (record source, license, SHA-256).
2. **Next autonomous engineering task: P2 — the failed ARM64 incremental APK
   size gate** (+19.78 MB vs ≤15 MB): investigate an operator-reduced ONNX
   Runtime build (the aligner uses a small op set: MatMul/Gather/Conv/LayerNorm
   family per `QuranAligner.java`) or a lighter ARM64 runtime, keeping the
   pinned model and native-core parity tests unchanged, then re-measure with
   `scripts/alignment/run-device-check.sh` on the A52s.
3. Then the device-only tasks (P3/P4) and production signing (P5) once the
   physical device and owner decisions are available.
