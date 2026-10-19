# Independent alignment reference: reviewer guide and corpus procedure

This document explains exactly how a Quran-literate reviewer fills in a
reference file (starting from
[`test/fixtures/alignment/reference-template.json`](../test/fixtures/alignment/reference-template.json)),
and how the project runs the ≥24-clip / 3-reciter evaluation required by the
gates in [ANDROID_ALIGNMENT.md](ANDROID_ALIGNMENT.md). It describes the tooling
as implemented; every rule below is enforced by
`scripts/alignment/evaluate.py` or `scripts/alignment/quality_probe.py` unless
explicitly marked as a human-review rule.

Nothing here fabricates reference timings. The template ships **unfilled on
purpose** and one test asserts it stays that way; the six-word CC0 clip is a
pipeline smoke test, not an accuracy corpus.

## Why an independent reference is needed

The CTC model is validated only against model-assisted windows and objective
probes so far. Those cannot establish word-level accuracy, so the production
gates require independent human annotations:

- ≥24 clips, ≥3 reciters, ≥500 selected spoken words, varied recordings and
  negatives (see the corpus plan below);
- combined start/end median ≤100 ms and p90 ≤250 ms, with ≥40 % within 50 ms,
  ≥70 % within 100 ms, ≥85 % within 200 ms, reporting starts/ends separately
  and per-reciter breakdowns;
- ≥98 % canonical word coverage, ≤5 % failed positive clips, ≤5 % accepted
  negatives.

Training-quality labels, regression windows from `expected.json`, or any model
output are **not** ground truth and are refused by the evaluator.

## Independence rules (human-review rules, not code-enforced)

1. The annotator never opens the predictions file and never runs the aligner
   with visible timings before annotating.
2. Nobody copies model times, regression windows, or another file's timings
   into a reference; every `start`/`end`/`uncertaintyMs` comes from listening.
3. A second Arabic/Quran-literate reviewer adjudicates disagreements. Only then
   is `annotationStatus` set to `independently-reviewed` and `reviewers` filled.
   Editing those fields without a real review invalidates the result.
4. Uncertainty is recorded honestly. Inflating `uncertaintyMs` shrinks the
   evaluated boundary set and changes the reported proportions; shrinking it
   fabricates precision. Both are prohibited.

## Units and timelines

| Quantity | Unit and timeline |
|---|---|
| `trimStart`, `trimEnd` | Seconds (decimal) on the **source audio file** timeline, not the trimmed clip |
| word `start`, `end` | Seconds (decimal) on the **source audio file** timeline — the same clock as the trims. The worker adds the trim back before reporting. |
| `uncertaintyMs` | Milliseconds |

Timestamps are decimal seconds in JSON (`14.52`, not `14,52` and not
`HH:MM:SS:FFF`; the `HH:MM:SS:FFF` format is only the editor's display format).
All timing values must be finite numbers; booleans, numeric strings, `NaN` and
`Infinity` are rejected.

## Word identity: canonical Tanzil indices

Each word is identified by `surah`, `ayah`, `index` (all integers):

- `index` is the **0-based position of the word among the whitespace-separated
  tokens** of that ayah in the bundled verified Uthmani text
  (`assets/quran/quran-uthmani.txt`, SHA-256
  `6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f`).
  The worker splits the verse text on whitespace, so diacritics and Quranic
  marks stay attached to their word token. Example: Al-Fatiha `1|2`
  (ٱلْحَمْدُ لِلَّهِ رَبِّ ٱلْعَـٰلَمِينَ) has four words, indices 0–3.
- A clip selects **one surah** and one contiguous run of words: the first ayah
  may start at `firstWord > 0`, interior ayahs must be complete from index 0,
  and the last ayah may stop early at `lastWord`. Repetitions cannot be
  annotated as a contiguous run; use a negative clip instead.
- The words array must list words in recitation order and must not repeat a
  `(surah, ayah, index)` key. The preflight derives the same selection the
  worker will be given and checks it against the verified text, so an
  out-of-range or non-contiguous list fails before any model run.

The template's selection is `1:2` words 0–3 plus `1:3` words 0–1 — six words,
matching what the CC0 fixture recites in source seconds 14–27.

## Reference file schema

Top level:

| Field | Rule |
|---|---|
| `schema` | Literal `1` |
| `timeline` | Literal `"source"` |
| `annotationStatus` | `"pending-independent-review"` while drafting; `"independently-reviewed"` only after adjudication. Scoring refuses every other value. |
| `reviewers` | Non-empty JSON array of non-blank reviewer names/IDs once reviewed. Refused if missing, empty, a string, or blank names. |
| `clips` | Non-empty array with unique, non-blank string `id`s |

Each clip:

| Field | Rule |
|---|---|
| `id` | Unique non-blank string; the predictions file must use the same IDs. Suggested convention: `<reciter-slug>-<surah>-<ayah-span>-<nn>`, e.g. `ibrahimmusa4-1-2-3-01`. |
| `audio` | Path to the source audio, absolute or relative to the repository root. Must exist for preflight/predictions. |
| `audioSha256` | SHA-256 of that exact file (64 hex characters; `sha256sum <file>`). `validate-reference --check-audio` and the `predictions` command verify it; a mismatch is fatal. |
| `license`, `source` | Non-blank provenance strings (license identifier and source URL/citation). |
| `reciter` | Non-blank stable reciter ID. Per-reciter breakdowns key off this string; the corpus gate needs ≥3 distinct values. |
| `trimStart`, `trimEnd` | Numbers with `trimEnd > trimStart`. The clip under review is `[trimStart, trimEnd)` on the source timeline. |
| `expected` | `"align"` (default when absent) or `"reject"` (deliberate negative). Any other value is rejected. |
| `tags` | Optional free-form labels (unused by scoring) |
| `words` | Required for `"align"` clips: non-empty array of word objects (below). Ignored for `"reject"` clips. |
| `selection` | Required for `"reject"` clips (see negatives); `trimStart`/`trimEnd` are inherited from the clip when omitted. |

Each word object in `words`:

| Field | Rule |
|---|---|
| `surah`, `ayah`, `index` | Integers, unique within the clip, forming the canonical contiguous run described above |
| `start`, `end` | Decimal seconds on the source timeline; `start < end`; each start ≥ the previous word's end; both inside `[trimStart, trimEnd]` |
| `uncertaintyMs` | Non-negative milliseconds. The boundary is excluded from the tolerance-`T` denominator when `uncertaintyMs > T/2` (e.g. >25 ms excludes it from the 50 ms proportion). |

All three timing fields are annotated together or left all `null` while
drafting. A word with only some of them filled is rejected.

## Annotation procedure for one clip

1. Choose the excerpt and its canonical word run. For a positive clip, copy the
   eligible words from the verified text so indices and ayah boundaries are
   exact. Record `trimStart`/`trimEnd` on the source timeline.
2. Listen to the trimmed window without looking at any model output.
3. For every selected word mark:
   - `start`: the first audible phoneme of that word (not the preceding pause,
     breath or beat);
   - `end`: the final audible phoneme, **including** madd/elongation and the
     release of the last letter;
   - `uncertaintyMs`: genuine boundary ambiguity, e.g. 0–20 ms for a clear
     release, 30–80 ms for a soft or masked one. A boundary counts toward the
     tolerance-`T` proportion only when `uncertaintyMs ≤ T/2` (e.g. >25 ms
     removes it from the 50 ms proportion).
4. Leave actual silences and breaths unassigned: they are not part of any word.
   Do not stretch a boundary to meet the next word; gaps are expected.
5. A second reviewer re-listens and adjudicates every disagreement. Record both
   reviewer IDs and set the status.

Enforced constraints on every annotated clip (checked by preflight and scoring):
timings finite, `start < end`, monotonic in list order, inside the trim, and
uncertainty non-negative.

## Negative clips (deliberate wrong text or extra repetition)

Negatives measure false acceptance: the model must refuse, not invent cues.

```json
{
  "id": "reciter-id-2-1-1-07-negative",
  "audio": "…", "audioSha256": "…", "license": "…", "source": "…",
  "reciter": "reciter-id",
  "trimStart": 10.0, "trimEnd": 22.0,
  "expected": "reject",
  "selection": {"surah": 2, "firstAyah": 1, "lastAyah": 1}
}
```

- No gold words are needed (any `words` present are ignored for scoring).
- `selection` is required so `predictions` can present text to the aligner;
  it is validated for integer fields, a single surah, an ordered ayah range and
  in-text word bounds.
- Prediction statuses on a negative clip mean:
  - `rejected` (worker rejection code) → correct rejection;
  - `error` (environment/worker failure) → **not** a correct rejection; reported
    separately as `negativeErrors`;
  - `aligned` → false accept, counted in `falseAcceptRate`.

## Corpus plan for the documented gates

The gate wording (ANDROID_ALIGNMENT.md, "Evaluation gates") sets the minimums;
this is one allocation that satisfies them without relaxing anything:

| Requirement | Suggested allocation |
|---|---|
| Clips | ≥24 positive clips **plus** negatives below, so ≥27 clips total |
| Reciters | 3 reciters (IDs in `reciter`), 8 positive clips each |
| Words | ≥500 selected words total (≈21 per positive clip at 24 clips) |
| Negatives | ≥1 deliberate wrong-text/extra-repetition clip per reciter (≥3 total) |
| Diversity | different surahs, clip lengths and speeds; partial first/last ayahs; repeated/similar words; pauses; elongated speech; at least some noisy recordings |

Checklist that no script can verify — review it by hand before scoring:

- [ ] Three genuinely different reciters (not the same voice re-labelled).
- [ ] Surah/length/speed variety; partial-ayah selections included.
- [ ] Pauses and elongations present, including at least one long madd.
- [ ] Repeated/similar-word passages included (as positives where the run is
      contiguous, otherwise as negatives).
- [ ] Negatives present, wrong text or extra repetition, one per reciter.
- [ ] Every clip's provenance (license, source, SHA-256) recorded.
- [ ] Annotation blind, uncertainty honest, two reviewers for adjudication.

Audio licensing: evaluation audio is used locally for measurement. Do not
redistribute recordings the license does not allow; the reference JSON
(timestamps, hashes, source URLs, licenses) is the auditable artifact.

## Reproducible procedure

The shipped template must stay unfilled (a test enforces it); copy it first.
Working files belong under git-ignored `output/quality/`.

```bash
# 0. Working copy of the reference (fill structure first: ids, provenance,
#    trims, canonical word lists).
mkdir -p output/quality
cp test/fixtures/alignment/reference-template.json output/quality/reference.json

# 1. Structural + provenance + canonical-text preflight (no model, fast).
#    Run after every edit; --check-audio also re-hashes the audio files.
python3 scripts/alignment/quality_probe.py validate-reference \
  --reference output/quality/reference.json --check-audio

# 2. Model predictions for the selected words. This file is sealed: the
#    annotator must not open it before annotating. Generation is hash-bound to
#    the annotated audio and never reads gold timings.
.alignment-venv/bin/python scripts/alignment/quality_probe.py predictions \
  --reference output/quality/reference.json --out output/quality/predictions.json

# 3. Annotate blind, get a second reviewer's adjudication, then set
#    annotationStatus="independently-reviewed" and fill reviewers.

# 4. Preflight again: it now also proves every word is annotated when the
#    status claims independent review.
python3 scripts/alignment/quality_probe.py validate-reference \
  --reference output/quality/reference.json --check-audio

# 5. Score. Refuses anything unreviewed, incomplete or malformed.
python3 scripts/alignment/evaluate.py output/quality/reference.json \
  output/quality/predictions.json > output/quality/report.json

# 6. Compare report.json against the gate table by hand (values below).
```

The evaluator refuses with an explicit message, for example:

```text
Cannot score: Accuracy scoring requires independent human-reviewed annotations; draft/model-assisted labels are not ground truth.
```

Predictions cannot be promoted to ground truth: they have no `schema`,
`timeline`, `annotationStatus` or `reviewers`, so using them as a reference
fails schema validation, and using a reference as predictions fails the
prediction-status check (both covered by tests).

## Reading the report (gate mapping)

`report.json` fields map to the gate rows as follows; the `starts` and `ends`
blocks are reported separately as the gate requires.

| Gate | Report field | Targets |
|---|---|---|
| Independent corpus | counts in the preflight (`corpus`), plus `reciters` | ≥24 clips, ≥3 reciters, ≥500 `expectedWords`, negatives included |
| Boundary accuracy | `boundaries.medianMs`, `boundaries.p90Ms` | ≤100 ms, ≤250 ms |
| Within tolerances | `within` keys `"50"`, `"100"`, `"200"` (`.percent`, with uncertainty-eligible denominators in `.eligibleBoundaries`) | ≥40 %, ≥70 %, ≥85 % |
| Starts/ends reporting | `starts.*`, `ends.*` | must be reported separately |
| Per-reciter | `perReciter` | one entry per reciter |
| Coverage/failures | `coverage`, `failureRate`, `falseAcceptRate`, `extraWords` | ≥0.98, ≤0.05, ≤0.05; extra words count as failures |
| Missing predictions | counted as failed clips (`failureRate`, `coverage`) | never hidden |

Not evaluated by this tooling (device-only gates in ANDROID_ALIGNMENT.md):
latency/RTF, memory, thermal/battery, APK size and release-mode responsiveness.
They remain separate measurements and continue to keep the model provisional.

## What the tooling rejects (summary)

- Unreviewed, draft or model-assisted `annotationStatus`; missing/blank
  reviewers. Scoring refuses these; the preflight reports them as not scoreable.
- Empty clip lists; duplicate or blank clip IDs; non-object clips.
- Missing/blank `audio` path; missing, blank or non-64-hex `audioSha256`;
  missing/blank `license`, `source`, `reciter`; non-numeric or inverted trims;
  non-object or empty `words` on positive clips.
- Garbage `expected` values; non-integer word identity fields; booleans or
  numeric strings in timings; `NaN`/`Infinity`; negative uncertainty;
  non-monotonic or out-of-trim timings; duplicate words; partially filled words.
- Word runs that are not one canonical contiguous selection of the verified
  text, or clips selecting text outside it.
- Audio files that are missing, or (with `--check-audio` / predictions) whose
  SHA-256 does not match `audioSha256`.
- Malformed predictions: missing `clips`, unknown/duplicate IDs, unknown
  statuses, non-numeric timings, rejected/error entries carrying words.

All of these raise clean `ValueError`s or CLI refusals, never `KeyError`
crashes; `scripts/alignment/test_evaluate.py` and
`scripts/alignment/test_quality_probe.py` pin the behaviour.

## Final checklist before declaring the gates evaluated

1. The `validate-reference` report shows `valid: true` and
   `corpus.scoreable: true`.
2. Corpus counts meet 24 clips / 3 reciters / 500 words / negatives.
3. All timing values came from blind human listening; reviewers recorded.
4. `evaluate.py` ran without refusing; `coverage ≥ 0.98`, failure and false
   acceptance ≤ 5 %, median/p90 and within-50/100/200 all within the table.
5. Starts and ends and every per-reciter breakdown were inspected, not just the
   combined average.
6. Device-only gates were measured separately before calling the model
   production-ready.
