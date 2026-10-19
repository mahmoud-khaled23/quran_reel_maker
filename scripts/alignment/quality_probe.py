"""Objective acoustic and known-silence probes for automatic alignment drafts.

This is NOT human gold and does not satisfy the independent accuracy gates in
docs/ANDROID_ALIGNMENT.md. `score` measures how well predicted word boundaries
agree with pauses that actually exist in the audio. `synthetic-pause` inserts
digitally silent samples at a known position, realigns, and measures (a)
speech claimed inside that known silence, which is provably wrong by that many
milliseconds, and (b) drift after removing the known time shift. Everything is
measured, never inferred from model scores; thresholds are documented
engineering heuristics, not calibrated accuracy.

Subcommands:
  align           run the Linux worker once and write a worker result JSON
  predictions     run the worker for every reference clip and write the
                  predictions.json consumed by scripts/alignment/evaluate.py
  score           score an existing worker result against the audio acoustics
  synthetic-pause insert known silence, realign, report violations and drift

Requires FFmpeg on PATH. `synthetic-pause` and `predictions` need the worker
environment (./scripts/setup-alignment.sh). Pure functions below stay stdlib
only so unit tests run without model, network or numpy.
"""
import argparse
import array
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SAMPLE_RATE = 16000
FRAME_SAMPLES = 320   # 20 ms, matching the model's frame lattice
HOP_SAMPLES = 160     # 10 ms resolution for pause edges
# Silence detection: threshold = max(noise floor + margin, peak - speech drop).
# The floor is the 5th percentile so quiet elongation inside words (which can
# sit 10-20 dB above the pauses of a clean recording) is not misread as silence.
FLOOR_PERCENTILE = 0.05
MARGIN_DB = 10.0
SPEECH_DROP_DB = 40.0
FLOOR_SPEECH_GUARD_DB = 12.0
MIN_SILENCE_SECONDS = 0.12
MERGE_GAP_SECONDS = 0.06
MIN_PAUSE_SECONDS = 0.15   # shortest predicted inter-word gap considered a pause
WORD_EDGE_MARGIN_SECONDS = 0.05  # silence must sit this far inside a word to count
# Rejection codes mean the model declined the audio/text as configured; any
# other worker error is an environment/setup failure, not a correct rejection.
REJECTION_CODES = {
    "text_mismatch", "low_quality", "alignment_path", "selection", "silent_audio",
}


def percentile(values, proportion):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * proportion
    lo = math.floor(position)
    return ordered[lo] + (ordered[math.ceil(position)] - ordered[lo]) * (position - lo)


def as_pcm(audio):
    """Accept a numpy float32 vector or any float sequence; return array('f')."""
    if isinstance(audio, array.array):
        return audio
    try:
        raw = audio.astype("<f4").tobytes()  # numpy path at runtime only
    except AttributeError:
        raw = array.array("f", [float(v) for v in audio]).tobytes()
    pcm = array.array("f")
    pcm.frombytes(raw)
    if sys.byteorder != "little":
        pcm.byteswap()
    return pcm


def frame_db(pcm, frame=FRAME_SAMPLES, hop=HOP_SAMPLES):
    """RMS dB per frame; each value belongs to the frame starting hop * i."""
    out = []
    limit = len(pcm) - frame + 1
    start = 0
    while start < limit:
        total = 0.0
        for sample in pcm[start:start + frame]:
            total += sample * sample
        out.append(10.0 * math.log10(total / frame + 1e-12))
        start += hop
    return out


def detect_silences(frames, hop=HOP_SAMPLES / SAMPLE_RATE, *, margin_db=MARGIN_DB,
                    speech_drop_db=SPEECH_DROP_DB, min_seconds=MIN_SILENCE_SECONDS,
                    merge_seconds=MERGE_GAP_SECONDS):
    """Return [(startSeconds, endSeconds)] plus diagnostics about reliability.

    Frames below the adaptive threshold are non-speech. The diagnostics are
    part of the result so a thin or speech-dominated recording reports
    inconclusive pause metrics instead of confident-looking nonsense.
    """
    if len(frames) < 5:
        return [], {"error": "too few audio frames to detect pauses"}
    floor_db = percentile(frames, FLOOR_PERCENTILE)
    peak_db = percentile(frames, .95)
    median_db = percentile(frames, .50)
    threshold = max(floor_db + margin_db, peak_db - speech_drop_db)
    silent = [value < threshold for value in frames]
    runs, start = [], None
    for index, is_silent in enumerate(silent):
        if is_silent and start is None:
            start = index
        elif not is_silent and start is not None:
            runs.append([start, index])
            start = None
    if start is not None:
        runs.append([start, len(silent)])
    merged = []
    for run in runs:
        if merged and (run[0] - merged[-1][1]) * hop <= merge_seconds:
            merged[-1][1] = run[1]
        else:
            merged.append(run)
    silences = [(start * hop, min(end * hop + hop, len(frames) * hop))
                for start, end in merged if (end - start) * hop >= min_seconds]
    silent_fraction = sum(silent) / len(silent)
    diagnostics = {
        "floorDb": floor_db, "peakDb": peak_db, "thresholdDb": threshold,
        "dynamicRangeDb": peak_db - floor_db, "silentFrameFraction": silent_fraction,
        "silenceCount": len(silences),
        "warnings": [],
    }
    if silent_fraction < .02:
        diagnostics["warnings"].append(
            "Almost no non-speech audio; pause-based metrics are inconclusive.")
    if silent_fraction > .60:
        diagnostics["warnings"].append(
            "Most frames fall below the speech threshold; check recording level "
            "before trusting pause-based metrics.")
    if peak_db - floor_db < 20:
        diagnostics["warnings"].append(
            "Less than 20 dB between quiet and loud frames; pause detection may "
            "be unreliable for this recording.")
    if floor_db > median_db - FLOOR_SPEECH_GUARD_DB:
        diagnostics["warnings"].append(
            "The quiet floor is within %0.0f dB of typical speech; pause "
            "detection may be unreliable for this recording."
            % FLOOR_SPEECH_GUARD_DB)
    return silences, diagnostics


def overlap_seconds(a_start, a_end, b_start, b_end):
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def flatten_words(result):
    """Worker result cues -> source-timeline words carrying surah/ayah."""
    words = []
    for cue in result.get("cues", []):
        for word in cue.get("words", []):
            words.append({**word, "surah": cue["surah"], "ayah": cue["ayah"]})
    words.sort(key=lambda w: (w["start"], w["end"]))
    return words


def inter_word_gaps(words, min_pause=MIN_PAUSE_SECONDS):
    gaps = []
    for first, second in zip(words, words[1:]):
        gap = (first["end"], second["start"])
        if gap[1] - gap[0] >= min_pause:
            gaps.append(gap)
    return gaps


def acoustic_metrics(words, silences, *, min_pause=MIN_PAUSE_SECONDS,
                     edge_margin=WORD_EDGE_MARGIN_SECONDS):
    """Plausibility of predicted boundaries against detected natural pauses."""
    words = sorted(words, key=lambda w: (w["start"], w["end"]))
    gaps = inter_word_gaps(words, min_pause)
    coverages = [sum(overlap_seconds(start, end, *silence) for silence in silences)
                 / (end - start) for start, end in gaps]
    inside = []
    for silence in silences:
        for word in words:
            if (overlap_seconds(*silence, word["start"], word["end"])
                    >= silence[1] - silence[0]
                    and silence[0] >= word["start"] + edge_margin
                    and silence[1] <= word["end"] - edge_margin):
                inside.append({"surah": word["surah"], "ayah": word["ayah"],
                               "index": word["index"],
                               "silenceSeconds": silence[1] - silence[0]})
                break
    per_word_silence = []
    for word in words:
        span = word["end"] - word["start"]
        held = sum(overlap_seconds(word["start"], word["end"], *silence)
                   for silence in silences)
        per_word_silence.append(held / span if span > 0 else 0.0)
    worst = max(range(len(per_word_silence)), key=per_word_silence.__getitem__) \
        if per_word_silence else None
    # Classify every detected pause so a reviewer can see *where* the model and
    # the acoustics disagree instead of one collapsed number.
    placement = []
    for silence in silences:
        held = silence[1] - silence[0]
        if words and silence[1] < words[0]["start"]:
            kind = "before-first-word"
        elif words and silence[0] > words[-1]["end"]:
            kind = "after-last-word"
        elif any(overlap_seconds(*silence, word["start"], word["end"]) >= held
                 and silence[0] >= word["start"] + edge_margin
                 and silence[1] <= word["end"] - edge_margin for word in words):
            kind = "inside-word"
        elif gaps:
            between = max((overlap_seconds(start, end, *silence)
                           for start, end in gaps), default=0.0)
            kind = "between-words" if between >= held * .5 else "mixed"
        else:
            kind = "mixed"
        placement.append({"start": silence[0], "end": silence[1],
                          "seconds": held, "kind": kind})
    warnings = []
    if not gaps:
        warnings.append(
            "No predicted inter-word pause of %.2fs or longer; pause coverage is "
            "inconclusive for this selection." % min_pause)
    if not silences:
        warnings.append("No non-speech region detected; pause coverage is inconclusive.")
    elif gaps and not any(p["kind"] == "between-words" for p in placement):
        warnings.append(
            "Detected pauses exist, but none sits between two predicted words; "
            "the model's word boundaries do not follow the recording's pauses.")
    return {
        "pausePlacement": placement,
        "interWordPauses": {
            "count": len(gaps),
            "majoritySilentCount": sum(1 for value in coverages if value >= .5),
            "coverageMedian": statistics.median(coverages) if coverages else None,
            "coverageMin": min(coverages) if coverages else None,
        },
        "silenceInsideWords": {
            "count": len(inside),
            "words": inside,
        },
        "wordInteriorSilenceFraction": {
            "median": statistics.median(per_word_silence) if per_word_silence else None,
            "max": per_word_silence[worst] if worst is not None else None,
            "maxWord": ({k: words[worst][k] for k in ("surah", "ayah", "index")}
                        if worst is not None else None),
        },
        "warnings": warnings,
    }


def violations_inside(intervals, words):
    """Speech predicted inside known-silent intervals, in milliseconds.

    Any overlap is provably wrong: the interval holds digital silence, so true
    word occupancy there is exactly zero. This is a one-sided bound; it never
    certifies a boundary that stays clear of the interval.
    """
    per_interval, total = [], 0.0
    for start, end in intervals:
        offending, seconds = [], 0.0
        for word in words:
            held = overlap_seconds(start, end, word["start"], word["end"])
            if held > 0:
                seconds += held
                offending.append({"surah": word["surah"], "ayah": word["ayah"],
                                  "index": word["index"], "insideMs": held * 1000})
        total += seconds
        per_interval.append({"start": start, "end": end,
                             "violationMs": seconds * 1000,
                             "violatingWords": offending})
    return {"totalViolationMs": total * 1000, "intervals": per_interval}


def pause_coverage_of(intervals, words, *, min_pause=MIN_PAUSE_SECONDS):
    """Fraction of each known interval covered by predicted inter-word pauses."""
    gaps = inter_word_gaps(words, min_pause)
    values = []
    for start, end in intervals:
        duration = end - start
        covered = sum(overlap_seconds(start, end, *gap) for gap in gaps)
        values.append(covered / duration if duration > 0 else None)
    return values


def map_generated_to_source(seconds, insertion, inserted, source_offset):
    """Generated-wav timeline -> source timeline with the known shift removed."""
    return seconds + source_offset - (inserted if seconds >= insertion + inserted else 0.0)


def derive_selection(clip, verses=None):
    """Selection for a reference clip: explicit `selection` or its word list.

    Words must be one contiguous canonical run (interior ayahs complete), the
    same rule the worker enforces, so predictions cannot silently select a
    different excerpt than the one a reviewer will annotate.
    """
    if clip.get("selection"):
        return dict(clip["selection"])
    words = clip.get("words") or []
    if not words:
        raise ValueError(
            "Clip %s has no words and no explicit selection; reject clips need "
            "a selection object with trim and ayah/word fields."
            % clip.get("id"))
    keys = [(w.get("surah"), w.get("ayah"), w.get("index")) for w in words]
    if any(k[0] is None or k[1] is None or k[2] is None for k in keys):
        raise ValueError("Clip %s has words without surah/ayah/index." % clip["id"])
    if len(set(keys)) != len(keys):
        raise ValueError("Clip %s lists duplicate words." % clip["id"])
    previous = None
    for position, (surah, ayah, index) in enumerate(keys):
        if position and (surah, ayah) == previous[:2]:
            if index != previous[2] + 1:
                raise ValueError(
                    "Clip %s words are not contiguous inside ayah %d."
                    % (clip["id"], ayah))
        elif position:
            if ayah != previous[1] + 1:
                raise ValueError(
                    "Clip %s jumps from ayah %d to %d; a selection must cover "
                    "every ayah in between." % (clip["id"], previous[1], ayah))
            if index != 0:
                raise ValueError(
                    "Clip %s starts ayah %d at word %d; interior ayahs must be "
                    "complete from word 0." % (clip["id"], ayah, index))
        previous = (surah, ayah, index)
    first_surah, first_ayah, first_word = keys[0]
    last_surah, last_ayah, last_word = keys[-1]
    if first_surah != last_surah:
        raise ValueError(
            "Clip %s spans surahs; select one surah per clip." % clip["id"])
    selection = {
        "surah": first_surah, "firstAyah": first_ayah, "lastAyah": last_ayah,
        "firstWord": first_word, "lastWord": last_word,
        "trimStart": clip["trimStart"], "trimEnd": clip["trimEnd"],
    }
    if verses is not None:
        for ayah in range(first_ayah, last_ayah + 1):
            try:
                length = len(verses[(first_surah, ayah)].split())
            except KeyError:
                raise ValueError(
                    "Clip %s selects surah %d ayah %d, which the verified text "
                    "does not contain." % (clip["id"], first_surah, ayah))
            if ayah == first_ayah and first_word >= length:
                raise ValueError("Clip %s firstWord is out of range." % clip["id"])
            if ayah == last_ayah and last_word >= length:
                raise ValueError("Clip %s lastWord is out of range." % clip["id"])
    return selection


def load_verses():
    """Verified Tanzil text as {(surah, ayah): verse} without hashing (the
    worker already verifies the digest before any inference)."""
    verses = {}
    for line in (ROOT / "assets/quran/quran-uthmani.txt").read_text().splitlines():
        if line and not line.startswith("#"):
            surah, ayah, text = line.split("|", 2)
            verses[int(surah), int(ayah)] = text
    return verses


def request_for(audio_path, selection):
    return {"protocol": 1,
            "quranSha256": "6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f",
            "audioPath": str(Path(audio_path).resolve()),
            "trimStart": selection["trimStart"], "trimEnd": selection["trimEnd"],
            "surah": selection["surah"], "firstAyah": selection["firstAyah"],
            "lastAyah": selection["lastAyah"],
            "firstWord": selection.get("firstWord", 0),
            **({"lastWord": selection["lastWord"]}
               if selection.get("lastWord") is not None else {})}


def worker():
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    from alignment_worker import worker as module
    return module


def decode_pcm(request):
    return as_pcm(worker().decode(request))


def run_alignment(request):
    return worker().align(request)


def write_wav(pcm, path):
    """Write float32 samples as a WAV through FFmpeg, like benchmark.py."""
    raw = path.with_suffix(".f32")
    data = array.array("f", pcm)
    if sys.byteorder != "little":
        data = data.byteswap()
    raw.write_bytes(data.tobytes())
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar",
                    str(SAMPLE_RATE), "-ac", "1", "-i", str(raw), str(path)],
                   check=True)
    raw.unlink()


def pick_insertion(pcm, *, min_gap=0.25, edge_margin=0.5):
    """Longest detected pause away from the trim edges; midpoint is the cut."""
    duration = len(pcm) / SAMPLE_RATE
    silences, diagnostics = detect_silences(frame_db(pcm))
    candidates = [(end - start, start, end) for start, end in silences
                  if start >= edge_margin and end <= duration - edge_margin
                  and end - start >= min_gap]
    if not candidates:
        raise SystemExit(
            "No pause of at least %.2fs away from the trim edges; pick a "
            "selection containing a clear pause or pass --insert-at. "
            "Diagnostics: %s" % (min_gap, json.dumps(diagnostics)))
    _, start, end = max(candidates)
    return (start + end) / 2, {"insertionWindow": [start, end],
                               "silenceDiagnostics": diagnostics}


def report_drift(base_words, mapped_words):
    base = {(w["surah"], w["ayah"], w["index"]): w for w in base_words}
    mapped = {(w["surah"], w["ayah"], w["index"]): w for w in mapped_words}
    shared = sorted(set(base) & set(mapped))
    deltas = [abs(mapped[key][field] - base[key][field]) * 1000
              for key in shared for field in ("start", "end")]
    return {
        "wordSetsMatched": set(base) == set(mapped),
        "baseWords": len(base), "mappedWords": len(mapped),
        "n": len(deltas),
        "medianMs": statistics.median(deltas) if deltas else None,
        "p90Ms": percentile(deltas, .9) if deltas else None,
        "maxMs": max(deltas) if deltas else None,
    }


def command_align(args):
    selection = {"trimStart": args.trim_start, "trimEnd": args.trim_end,
                 "surah": args.surah, "firstAyah": args.first_ayah,
                 "lastAyah": args.last_ayah, "firstWord": args.first_word,
                 "lastWord": args.last_word}
    result = run_alignment(request_for(args.audio, selection))
    Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("Wrote %s (%d cues)" % (args.out, len(result["cues"])))


def command_predictions(args):
    reference = json.loads(Path(args.reference).read_text())
    if reference.get("schema") != 1:
        raise SystemExit("Expected a schema 1 reference file.")
    verses = load_verses()
    clips = []
    for clip in reference["clips"]:
        selection = derive_selection(clip, verses)
        audio = ROOT / clip["audio"] if not Path(clip["audio"]).is_absolute() \
            else Path(clip["audio"])
        if not audio.is_file():
            raise SystemExit("Missing audio for clip %s: %s" % (clip["id"], audio))
        words = []
        try:
            result = run_alignment(request_for(audio, selection))
            words = [{"surah": cue["surah"], "ayah": cue["ayah"], **word}
                     for cue in result["cues"] for word in cue["words"]]
            status = "aligned"
        except worker().AlignmentError as error:
            status = "rejected" if error.code in REJECTION_CODES else "error"
            print("clip %s -> %s (%s: %s)"
                  % (clip["id"], status, error.code, error), file=sys.stderr)
        clips.append({"id": clip["id"], "status": status, "words": words})
    out = {"clips": clips}
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    print("Wrote %s (%d clips)" % (args.out, len(clips)))


def command_score(args):
    result = json.loads(Path(args.result).read_text())
    words = flatten_words(result)
    if not words:
        raise SystemExit("The result file contains no aligned words.")
    trim_start = args.trim_start
    trim_end = args.trim_end
    if trim_start is None:
        trim_start = max(0.0, min(w["start"] for w in words) - 1.0)
    if trim_end is None:
        trim_end = max(w["end"] for w in words) + 1.0
    def decode_window(start, end):
        return decode_pcm({"trimStart": start, "trimEnd": end,
                           "audioPath": str(Path(args.audio).resolve())})
    try:
        pcm = decode_window(trim_start, trim_end)
    except Exception as error:
        # The default one-second margin can reach past the file end; retry the
        # exact spanned interval before giving up.
        exact = (min(w["start"] for w in words), max(w["end"] for w in words))
        if exact == (trim_start, trim_end):
            raise SystemExit("Could not decode the selection: %s" % error)
        try:
            pcm = decode_window(*exact)
        except Exception:
            raise SystemExit("Could not decode the selection: %s" % error)
        trim_start, trim_end = exact
    silences, diagnostics = detect_silences(frame_db(pcm))
    # The worker timeline is the source timeline; shift trim-relative pauses.
    silences = [(start + trim_start, end + trim_start) for start, end in silences]
    report = {
        "probe": "acoustic",
        "scope": "plausibility against detected pauses; not human accuracy",
        "audio": str(args.audio), "trimStart": trim_start, "trimEnd": trim_end,
        "model": result.get("model"), "mismatchRatio": result.get("mismatchRatio"),
        "wordCount": len(words),
        "silenceDiagnostics": diagnostics,
        "detectedPauses": [[round(a, 3), round(b, 3)] for a, b in silences],
        "metrics": acoustic_metrics(words, silences),
    }
    report["metrics"]["warnings"] += diagnostics.get("warnings", [])
    Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["metrics"], ensure_ascii=False, indent=2))
    print("Wrote %s" % args.out)


def command_synthetic_pause(args):
    selection = {"trimStart": args.trim_start, "trimEnd": args.trim_end,
                 "surah": args.surah, "firstAyah": args.first_ayah,
                 "lastAyah": args.last_ayah, "firstWord": args.first_word,
                 "lastWord": args.last_word}
    request = request_for(args.audio, selection)
    pcm = decode_pcm(request)
    try:
        base_result = run_alignment(request)
    except Exception as error:
        raise SystemExit("Base alignment failed: %s" % error)
    base_words = flatten_words(base_result)
    if args.insert_at is not None:
        insertion = args.insert_at
        origin = {"insertionEvidence":
                  "explicit --insert-at; inter-word placement was not verified "
                  "acoustically on this clip, so the violation metric below "
                  "assumes the position lies between two spoken words"}
    else:
        insertion, origin = pick_insertion(pcm)
        origin["insertionEvidence"] = "longest detected interior pause"
    inserted = args.insert_seconds
    cut = int(round(insertion * SAMPLE_RATE))
    zero = array.array("f", [0.0] * int(round(inserted * SAMPLE_RATE)))
    generated = array.array("f", pcm[:cut]) + zero + array.array("f", pcm[cut:])
    folder = Path(args.out).parent
    folder.mkdir(parents=True, exist_ok=True)
    wav = folder / "synthetic-pause.wav"
    write_wav(generated, wav)
    generated_request = dict(request, audioPath=str(wav.resolve()), trimStart=0,
                             trimEnd=len(generated) / SAMPLE_RATE)
    try:
        gen_result = run_alignment(generated_request)
    except Exception as error:  # keep the report dir usable for the next attempt
        wav.unlink(missing_ok=True)
        raise SystemExit("Generated-silence alignment failed: %s" % error)
    gen_words = flatten_words(gen_result)
    mapped = [{**word, "start": map_generated_to_source(
        word["start"], insertion, inserted, selection["trimStart"]),
        "end": map_generated_to_source(
            word["end"], insertion, inserted, selection["trimStart"])}
        for word in gen_words]
    known = [[insertion, insertion + inserted]]
    report = {
        "probe": "synthetic-pause",
        "scope": "known inserted silence and transformation invariance; "
                 "not human accuracy and not a substitute for the accuracy gates",
        "audio": str(args.audio),
        "insertedSilenceSeconds": inserted,
        "insertedAtTrimSeconds": insertion,
        "insertedAtSourceSeconds": insertion + selection["trimStart"],
        "insertionOrigin": origin,
        "speechInsideInsertedSilence": violations_inside(known, gen_words),
        "insertedSilencePauseCoverage": pause_coverage_of(known, gen_words),
        "mappedDrift": report_drift(base_words, mapped),
        "baseWordCount": len(base_words), "generatedWordCount": len(gen_words),
        "baseWarnings": sorted({w for cue in base_result["cues"]
                                for w in cue.get("warnings", [])}),
        "generatedWarnings": sorted({w for cue in gen_result["cues"]
                                     for w in cue.get("warnings", [])}),
    }
    # Keep the raw results next to the report for independent re-checking.
    Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    Path(str(args.out) + ".base.json").write_text(
        json.dumps({"words": base_words}, ensure_ascii=False, indent=2) + "\n")
    Path(str(args.out) + ".generated.json").write_text(
        json.dumps({"words": gen_words, "wordsMapped": mapped},
                   ensure_ascii=False, indent=2) + "\n")
    wav.unlink()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("Wrote %s" % args.out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p, *, words=False):
        p.add_argument("--audio", type=Path, required=True)
        p.add_argument("--trim-start", type=float, required=True)
        p.add_argument("--trim-end", type=float, required=True)
        p.add_argument("--surah", type=int)
        p.add_argument("--first-ayah", type=int)
        p.add_argument("--last-ayah", type=int)
        p.add_argument("--first-word", type=int, default=0)
        p.add_argument("--last-word", type=int)

    align_p = sub.add_parser("align", help="run the worker once, write its result")
    common(align_p)
    align_p.add_argument("--out", type=Path, required=True)
    align_p.set_defaults(func=command_align)

    predictions_p = sub.add_parser(
        "predictions", help="worker predictions for a reference file")
    predictions_p.add_argument("--reference", type=Path, required=True)
    predictions_p.add_argument("--out", type=Path, required=True)
    predictions_p.set_defaults(func=command_predictions)

    score_p = sub.add_parser("score", help="acoustic plausibility of a result")
    score_p.add_argument("--audio", type=Path, required=True)
    score_p.add_argument("--result", type=Path, required=True)
    score_p.add_argument("--trim-start", type=float)
    score_p.add_argument("--trim-end", type=float)
    score_p.add_argument("--out", type=Path, required=True)
    score_p.set_defaults(func=command_score)

    synthetic_p = sub.add_parser(
        "synthetic-pause", help="insert known silence and measure violations")
    common(synthetic_p)
    synthetic_p.add_argument("--insert-seconds", type=float, default=2.0)
    synthetic_p.add_argument("--insert-at", type=float,
                             help="trim-relative seconds; default: longest pause")
    synthetic_p.add_argument("--out", type=Path, required=True)
    synthetic_p.set_defaults(func=command_synthetic_pause)

    args = parser.parse_args(argv)
    if args.command in ("align", "synthetic-pause"):
        missing = [name for name in ("surah", "first_ayah", "last_ayah")
                   if getattr(args, name) is None]
        if missing:
            parser.error("align/synthetic-pause require %s" % ", ".join(
                "--" + name.replace("_", "-") for name in missing))
        if not 0.5 <= args.trim_end - args.trim_start <= 180:
            parser.error("the trim must be 0.5–180 seconds")
    args.func(args)


if __name__ == "__main__":
    main()
