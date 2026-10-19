"""Score independent source-timeline references, never model-assisted labels.
python scripts/alignment/evaluate.py reference.json predictions.json
Predictions: {clips: [{id, status: aligned|rejected|error, words: [...]}]}.
References follow test/fixtures/alignment/reference-template.json.
"""
import argparse
import json
import math
from pathlib import Path
import statistics


def word_key(word):
    return tuple(word[k] for k in ("surah", "ayah", "index"))


def percentile(values, proportion):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * proportion
    lo = math.floor(position)
    return ordered[lo] + (ordered[math.ceil(position)] - ordered[lo]) * (position - lo)


def evaluate(reference, predictions, *, include_breakdowns=True):
    if reference.get("schema") != 1 or reference.get("timeline") != "source":
        raise ValueError("Expected schema 1 source-timeline references.")
    if reference.get("annotationStatus") != "independently-reviewed" or not reference.get("reviewers"):
        raise ValueError("Accuracy scoring requires independent human-reviewed annotations; draft/model-assisted labels are not ground truth.")
    clips = reference["clips"]
    if not clips or len({c["id"] for c in clips}) != len(clips):
        raise ValueError("References need unique, nonempty clips.")
    predicted = {c["id"]: c for c in predictions["clips"]}
    if len(predicted) != len(predictions["clips"]) or set(predicted) - {c["id"] for c in clips}:
        raise ValueError("Duplicate or unknown prediction clip.")
    errors, starts, ends = [], [], []
    thresholds = {v: [] for v in (50, 100, 200)}
    failed = positive = negative = false_accepts = negative_errors = words_total = matched = extra = 0
    for clip in clips:
        if not all(clip.get(k) for k in ("audioSha256", "license", "source", "reciter")):
            raise ValueError("Every clip needs audio/license/reciter provenance.")
        prediction = predicted.get(clip["id"], {"status": "error", "words": []})
        if prediction.get("status") not in ("aligned", "rejected", "error"):
            raise ValueError("Unknown prediction status.")
        if clip.get("expected") == "reject":
            negative += 1
            false_accepts += prediction["status"] == "aligned"
            negative_errors += prediction["status"] == "error"
            if prediction["status"] != "aligned" and prediction.get("words"):
                raise ValueError("Rejected/error results must not contain accepted words.")
            continue
        positive += 1
        gold = clip["words"]
        if not gold or len({word_key(w) for w in gold}) != len(gold):
            raise ValueError("Positive references need unique canonical words.")
        guess = prediction.get("words", [])
        if prediction["status"] != "aligned" and guess:
            raise ValueError("Rejected/error results must not contain accepted words.")
        mapping = {word_key(w): w for w in guess}
        if len(mapping) != len(guess):
            raise ValueError("Duplicate predicted word; repetitions need occurrence annotations, not collapsed metrics.")
        previous = clip["trimStart"]
        for word in guess:
            a, b = word["start"], word["end"]
            if not all(math.isfinite(v) for v in (a,b)) or a < previous - .001 or b <= a or b > clip["trimEnd"] + .001:
                raise ValueError("Non-monotonic/non-finite/out-of-trim prediction.")
            previous = b
        keys = {word_key(w) for w in gold}
        extra += len(set(mapping) - keys)
        failed += prediction["status"] != "aligned" or set(mapping) != keys
        previous = clip["trimStart"]
        for word in gold:
            a, b, uncertainty = word["start"], word["end"], word["uncertaintyMs"]
            if not all(isinstance(v, (float,int)) and math.isfinite(v) for v in (a,b,uncertainty)) or uncertainty < 0 or a < previous or b <= a or b > clip["trimEnd"]:
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
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path); parser.add_argument("predictions", type=Path)
    args = parser.parse_args()
    print(json.dumps(evaluate(json.loads(args.reference.read_text()), json.loads(args.predictions.read_text())), indent=2))
