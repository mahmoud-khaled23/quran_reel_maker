"""Score independent source-timeline references, never model-assisted labels.
python scripts/alignment/evaluate.py reference.json predictions.json
Predictions: {clips: [{id, status: aligned|rejected|error, words: [...]}]}.
References follow test/fixtures/alignment/reference-template.json; the reviewer
procedure and field-by-field schema are documented in docs/ALIGNMENT_ANNOTATION.md.
"""
import argparse
import json
import math
from pathlib import Path
import statistics


def word_key(word):
    return tuple(word[k] for k in ("surah", "ayah", "index"))


def is_number(value):
    """Finite int/float, rejecting bool (True is an int)."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) \
        and math.isfinite(value)


def require_number(value, what):
    if not is_number(value):
        raise ValueError("%s must be a finite number, got %r." % (what, value))
    return value


def require_int(value, what):
    if type(value) is not int:
        raise ValueError("%s must be an integer, got %r." % (what, value))
    return value


def require_nonempty_string(value, what):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("%s must be a nonempty string." % what)
    return value


def validate_word_identity(word, what):
    if not isinstance(word, dict):
        raise ValueError("%s must be a JSON object." % what)
    for field in ("surah", "ayah", "index"):
        require_int(word.get(field), "%s %s" % (what, field))


def validate_timings(word, what, *, require_annotations):
    """Validate one word's gold timings; return False when left unannotated.

    Pre-annotation checks (require_annotations=False) allow every timing field
    to stay null, but a partially filled word (e.g. start set, end missing) is
    always malformed. Scoring requires every boundary to be present.
    """
    start, end, uncertainty = (word.get(field)
                               for field in ("start", "end", "uncertaintyMs"))
    if start is None and end is None and uncertainty is None:
        if require_annotations:
            raise ValueError("Invalid or incomplete independent reference boundary.")
        return False
    if start is None or end is None or uncertainty is None:
        raise ValueError(
            "%s mixes filled and missing timing fields; annotate start, end and "
            "uncertaintyMs together or leave all three null." % what)
    require_number(start, "%s start" % what)
    require_number(end, "%s end" % what)
    require_number(uncertainty, "%s uncertaintyMs" % what)
    if uncertainty < 0:
        raise ValueError("%s uncertaintyMs must not be negative." % what)
    if end <= start:
        raise ValueError("%s end must be after start." % what)
    return True


def validate_clip(clip, *, require_annotations):
    if not isinstance(clip, dict):
        raise ValueError("Every clip must be a JSON object.")
    clip_id = require_nonempty_string(clip.get("id"), "clip id")
    for field in ("audio", "license", "source", "reciter"):
        require_nonempty_string(clip.get(field), "clip %s %s" % (clip_id, field))
    digest = require_nonempty_string(clip.get("audioSha256"),
                                     "clip %s audioSha256" % clip_id)
    if len(digest) != 64 or any(character not in "0123456789abcdefABCDEF"
                                for character in digest):
        raise ValueError(
            "Clip %s audioSha256 must be 64 hex characters (sha256sum)." % clip_id)
    trim_start = require_number(clip.get("trimStart"), "clip %s trimStart" % clip_id)
    trim_end = require_number(clip.get("trimEnd"), "clip %s trimEnd" % clip_id)
    if trim_end <= trim_start:
        raise ValueError("Clip %s trimEnd must be after trimStart." % clip_id)
    expected = clip.get("expected", "align")
    if expected not in ("align", "reject"):
        raise ValueError(
            "Clip %s expected must be 'align' or 'reject', got %r."
            % (clip_id, expected))
    if expected == "reject":
        # Negative clips carry no gold; their words field is ignored on purpose.
        return clip_id
    words = clip.get("words")
    if not isinstance(words, list) or not words:
        raise ValueError(
            "Positive references need a nonempty canonical word list "
            "(clip %s)." % clip_id)
    previous = trim_start
    for position, word in enumerate(words):
        what = "clip %s word %d" % (clip_id, position)
        validate_word_identity(word, what)
        if validate_timings(word, what, require_annotations=require_annotations):
            start, end = word["start"], word["end"]
            if end > trim_end:
                raise ValueError("%s end lies after the clip trim." % what)
            if start < previous:
                raise ValueError(
                    "%s start precedes the previous word's end; gold timings "
                    "must be monotonic in recitation order." % what)
            previous = end
    if len({word_key(w) for w in words}) != len(words):
        raise ValueError(
            "Positive references need unique canonical words (clip %s)."
            % clip_id)
    return clip_id


def validate_reference(reference, *, require_annotations=True):
    """Shared validation for scoring and pre-annotation checks.

    require_annotations=False is the pre-annotation mode used by tooling: gold
    timings may stay null, but everything structural (schema, provenance,
    canonical words, consistent partial timings) is still enforced.
    """
    if not isinstance(reference, dict) or reference.get("schema") != 1 \
            or reference.get("timeline") != "source":
        raise ValueError("Expected schema 1 source-timeline references.")
    if require_annotations:
        reviewers = reference.get("reviewers")
        if reference.get("annotationStatus") != "independently-reviewed" \
                or not isinstance(reviewers, list) or not reviewers \
                or not all(isinstance(name, str) and name.strip()
                           for name in reviewers):
            raise ValueError(
                "Accuracy scoring requires independent human-reviewed "
                "annotations; draft/model-assisted labels are not ground truth.")
    clips = reference.get("clips")
    if not isinstance(clips, list) or not clips:
        raise ValueError("References need a nonempty clips list.")
    clip_ids = [validate_clip(clip, require_annotations=require_annotations)
                for clip in clips]
    if len(set(clip_ids)) != len(clip_ids):
        raise ValueError("References need unique, nonempty clip ids.")
    return reference


def validate_predictions(reference, predictions):
    """Structural checks for a predictions file; returns {clipId: entry}."""
    if not isinstance(predictions, dict) or not isinstance(predictions.get("clips"), list):
        raise ValueError("Predictions need a clips list.")
    known = {clip["id"] for clip in reference["clips"]}
    predicted = {}
    for entry in predictions["clips"]:
        if not isinstance(entry, dict):
            raise ValueError("Every prediction clip must be a JSON object.")
        clip_id = require_nonempty_string(entry.get("id"), "prediction clip id")
        if clip_id in predicted:
            raise ValueError("Duplicate or unknown prediction clip.")
        if entry.get("status") not in ("aligned", "rejected", "error"):
            raise ValueError("Unknown prediction status for clip %s." % clip_id)
        words = entry.get("words", [])
        if not isinstance(words, list):
            raise ValueError("Prediction words must be a list (clip %s)." % clip_id)
        for position, word in enumerate(words):
            what = "prediction %s word %d" % (clip_id, position)
            validate_word_identity(word, what)
            require_number(word.get("start"), "%s start" % what)
            require_number(word.get("end"), "%s end" % what)
        predicted[clip_id] = entry
    if set(predicted) - known:
        raise ValueError("Duplicate or unknown prediction clip.")
    return predicted


def percentile(values, proportion):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * proportion
    lo = math.floor(position)
    return ordered[lo] + (ordered[math.ceil(position)] - ordered[lo]) * (position - lo)


def evaluate(reference, predictions, *, include_breakdowns=True):
    validate_reference(reference, require_annotations=True)
    clips = reference["clips"]
    predicted = validate_predictions(reference, predictions)
    errors, starts, ends = [], [], []
    thresholds = {v: [] for v in (50, 100, 200)}
    failed = positive = negative = false_accepts = negative_errors = words_total = matched = extra = 0
    for clip in clips:
        prediction = predicted.get(clip["id"], {"status": "error", "words": []})
        if clip.get("expected", "align") == "reject":
            negative += 1
            false_accepts += prediction["status"] == "aligned"
            negative_errors += prediction["status"] == "error"
            if prediction["status"] != "aligned" and prediction.get("words"):
                raise ValueError("Rejected/error results must not contain accepted words.")
            continue
        positive += 1
        gold = clip["words"]
        guess = prediction.get("words", [])
        if prediction["status"] != "aligned" and guess:
            raise ValueError("Rejected/error results must not contain accepted words.")
        mapping = {word_key(w): w for w in guess}
        if len(mapping) != len(guess):
            raise ValueError("Duplicate predicted word; repetitions need occurrence annotations, not collapsed metrics.")
        previous = clip["trimStart"]
        for word in guess:
            a, b = word["start"], word["end"]
            if a < previous - .001 or b <= a or b > clip["trimEnd"] + .001:
                raise ValueError("Non-monotonic/non-finite/out-of-trim prediction.")
            previous = b
        keys = {word_key(w) for w in gold}
        extra += len(set(mapping) - keys)
        failed += prediction["status"] != "aligned" or set(mapping) != keys
        previous = clip["trimStart"]
        for word in gold:
            a, b, uncertainty = word["start"], word["end"], word["uncertaintyMs"]
            if a < previous or b > clip["trimEnd"]:
                raise ValueError("Invalid or incomplete independent reference boundary.")
            previous = b; words_total += 1
            found = mapping.get(word_key(word))
            if found is None:
                continue
            matched += 1
            pair = [abs(found[k] - word[k]) * 1000 for k in ("start", "end")]
            errors.extend(pair); starts.append(pair[0]); ends.append(pair[1])
            # Annotation uncertainty must be <= half the evaluated tolerance.
            for tolerance, eligible in thresholds.items():
                if uncertainty <= tolerance / 2:
                    eligible.extend(e <= tolerance for e in pair)
    def summary(values):
        return {"n": len(values), "medianMs": statistics.median(values) if values else None, "p90Ms": percentile(values,.9)}
    result = {
        "scope": "matched boundaries only; inspect failure and coverage alongside errors",
        "boundaries": summary(errors), "starts": summary(starts), "ends": summary(ends),
        "within": {str(t): {"eligibleBoundaries": len(v), "percent": 100*sum(v)/len(v) if v else None} for t,v in thresholds.items()},
        "positiveClips": positive, "failedPositiveClips": failed, "failureRate": failed/positive if positive else None,
        "expectedWords": words_total, "matchedWords": matched, "coverage": matched/words_total if words_total else None, "extraWords": extra,
        "negativeClips": negative, "falseAccepts": false_accepts, "falseAcceptRate": false_accepts/negative if negative else None,
        "negativeErrors": negative_errors, "correctRejections": negative-false_accepts-negative_errors,
        "reciters": len({c["reciter"] for c in clips}),
    }
    if include_breakdowns:
        result["perReciter"] = {}
        for reciter in sorted({c["reciter"] for c in clips}):
            subset = [c for c in clips if c["reciter"] == reciter]
            ids = {c["id"] for c in subset}
            result["perReciter"][reciter] = evaluate(
                dict(reference, clips=subset),
                {"clips": [c for c in predictions["clips"] if c["id"] in ids]},
                include_breakdowns=False,
            )
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Score a reviewed reference against model predictions. "
                    "Refuses unreviewed, incomplete or malformed inputs.")
    parser.add_argument("reference", type=Path)
    parser.add_argument("predictions", type=Path)
    args = parser.parse_args()
    try:
        result = evaluate(json.loads(args.reference.read_text()),
                          json.loads(args.predictions.read_text()))
    except ValueError as error:
        raise SystemExit("Cannot score: %s" % error)
    print(json.dumps(result, indent=2))
