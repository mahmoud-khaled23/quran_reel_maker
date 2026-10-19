# Project status

Last updated: **2026-10-19**, agent handover audit (Codex → OpenCode).
Branch `working-side`, HEAD `62ebef7` ("Finish Android auto alignment") plus the
uncommitted P1 probe work described below. `main` points at the same commit.
Session changes: added `AGENTS.md`, this file,
`scripts/alignment/quality_probe.py`, `scripts/alignment/test_quality_probe.py`,
and documentation of the new measurements in `docs/VALIDATION.md` /
`docs/ANDROID_ALIGNMENT.md`. No `lib/`, `test/`, `integration_test/` or Android
code was touched.

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
  **22 passed** (6 evaluator invariants + 16 new quality-probe tests).
- `bash -n scripts/*.sh scripts/alignment/*.sh` → all pass.
- New 2026-10-19 (P1): `quality_probe.py` measured on the CC0 fixture —
  0 ms speech inside 2 s known inserted silence, pause coverage 1.0, mapped
  drift median 0.0 ms / max 20 ms (one CTC frame); `predictions` generated
  evaluator-ready output; `evaluate.py` still correctly refuses the unfilled
  template. Raw reports under ignored `output/quality/`.
- CI: run `39256846086` on `working-side` @ `62ebef7` → **success** (4m42s,
  2026-10-19). Also green on `main`.
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
| 1 | **Independent word-level alignment accuracy evaluation** for the chosen Android/Linux CTC model | `docs/ANDROID_ALIGNMENT.md` sets gates (≥24 clips, 3 reciters, ≥500 words, median ≤100 ms etc.) that are **unmet**: no annotated reference exists; `reference-template.json` intentionally unfilled. Acceptance is explicitly "provisional". The autonomous part is now done: `scripts/alignment/quality_probe.py` provides objective known-silence/invariance evidence (measured on the CC0 fixture, see VALIDATION.md) and an evaluator-ready `predictions` path; natural-pause scoring is inconclusive on this continuous fixture. Gates still require gold labels. | A Quran-literate human listener to fill `reference-template.json` (tooling ready end-to-end: `predictions` → `evaluate.py`), ideally ≥24 clips / 3 reciters per the gate table |
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
python3 -m unittest discover -s scripts/alignment -p 'test_*.py' -v → 22 tests, OK
.alignment-venv/bin/python scripts/alignment/quality_probe.py synthetic-pause … --insert-at 7.75 → 0.0 ms speech in inserted silence, coverage 1.0, mapped drift median 0.0 / p90 18 / max 20 ms
.alignment-venv/bin/python scripts/alignment/quality_probe.py predictions …reference-template.json → status "aligned", 6 words
python3 scripts/alignment/evaluate.py <template> <predictions> → correctly refused: unfilled template is not ground truth
bash -n scripts/*.sh scripts/alignment/*.sh                → OK
gh run list → 39256846086 working-side@62ebef7            → completed/success
```

Not run this session (no host `xvfb`/`mpv`, no connected Android device):
Docker integration flows, Linux release rebuild, Android builds. Prior results
for those are in `docs/VALIDATION.md` and `output/*.log`.

## Exact next step

**P1 autonomous part is done** (probe tooling + objective measurements +
annotation path ready). What remains, in order:

1. **Human annotation (P1 remainder, owner/reviewer):** fill
   `test/fixtures/alignment/reference-template.json` per its `instructions`
   field (listen without seeing predictions; second reviewer adjudicates),
   then run:
   ```bash
   .alignment-venv/bin/python scripts/alignment/quality_probe.py predictions \
     --reference test/fixtures/alignment/reference-template.json \
     --out output/quality/predictions.json
   python3 scripts/alignment/evaluate.py \
     test/fixtures/alignment/reference-template.json output/quality/predictions.json
   ```
   To reach the documented gates (≥24 clips, 3 reciters, ≥500 words), add more
   evaluation-use recitation clips with clear licenses (evaluation-only local
   download does not redistribute audio — record source, license, hash).
2. **Next autonomous engineering task: P2 — the failed ARM64 incremental APK
   size gate** (+19.78 MB vs ≤15 MB): investigate an operator-reduced ONNX
   Runtime build (the aligner uses a small op set: MatMul/Gather/Conv/LayerNorm
   family per `QuranAligner.java`) or a lighter ARM64 runtime, keeping the
   pinned model and native-core parity tests unchanged, then re-measure with
   `scripts/alignment/run-device-check.sh` on the A52s.
3. Then the device-only tasks (P3/P4) and production signing (P5) once the
   physical device and owner decisions are available.
