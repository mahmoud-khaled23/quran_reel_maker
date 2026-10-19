import copy
import unittest
from evaluate import evaluate, validate_reference


class EvaluationTest(unittest.TestCase):
    def setUp(self):
        word = dict(surah=1, ayah=2, index=0, start=1.0, end=2.0, uncertaintyMs=20)
        self.ref = dict(schema=1, timeline="source", annotationStatus="independently-reviewed", reviewers=["synthetic-test"], clips=[dict(id="a", audio="synthetic.ogg", audioSha256="0" * 64, license="CC0-1.0", source="synthetic", reciter="synthetic", trimStart=0, trimEnd=3, words=[word])])
        self.pred = dict(clips=[dict(id="a", status="aligned", words=[dict(word,start=1.04,end=2.16)])])

    def test_known_metrics(self):
        result = evaluate(self.ref,self.pred)
        self.assertAlmostEqual(result["boundaries"]["medianMs"],100)
        self.assertAlmostEqual(result["boundaries"]["p90Ms"],148)
        self.assertEqual(result["within"]["50"]["percent"],50)
        self.assertEqual(result["within"]["200"]["percent"],100)
        self.assertEqual(result["coverage"],1)

    def test_failures_not_hidden_by_matched_error(self):
        self.pred["clips"][0] = dict(id="a", status="rejected", words=[])
        result = evaluate(self.ref,self.pred)
        self.assertEqual(result["failureRate"],1)
        self.assertEqual(result["coverage"],0)
        self.assertIsNone(result["boundaries"]["medianMs"])

    def test_no_model_gold_or_unsupported_precision(self):
        for status in ["pending-independent-review", "model-assisted"]:
            ref = copy.deepcopy(self.ref); ref["annotationStatus"] = status
            with self.assertRaises(ValueError): evaluate(ref,self.pred)
        self.ref["clips"][0]["words"][0]["uncertaintyMs"] = 60
        result = evaluate(self.ref,self.pred)
        self.assertIsNone(result["within"]["100"]["percent"])
        self.assertEqual(result["within"]["200"]["percent"],100)

    def test_invalid_order_extra_and_wrong_text(self):
        self.pred["clips"][0]["words"][0]["start"] = float("nan")
        with self.assertRaises(ValueError): evaluate(self.ref,self.pred)
        self.pred["clips"][0]["words"][0].update(start=1,index=8)
        result = evaluate(self.ref,self.pred)
        self.assertEqual(result["extraWords"],1); self.assertEqual(result["failureRate"],1)
        self.ref["clips"][0]["expected"] = "reject"
        self.assertEqual(evaluate(self.ref,self.pred)["falseAcceptRate"],1)

    def test_negative_runtime_failure_is_not_correct_rejection(self):
        self.ref["clips"][0]["expected"] = "reject"
        self.pred["clips"][0] = dict(id="a", status="error", words=[])
        result = evaluate(self.ref,self.pred)
        self.assertEqual(result["negativeErrors"], 1)
        self.assertEqual(result["correctRejections"], 0)
        self.pred["clips"][0]["status"] = "rejected"
        self.assertEqual(evaluate(self.ref,self.pred)["correctRejections"], 1)

    def test_per_reciter_breakdown_keeps_missing_predictions(self):
        second = copy.deepcopy(self.ref["clips"][0])
        second.update(id="b", reciter="second-synthetic")
        self.ref["clips"].append(second)
        result = evaluate(self.ref, self.pred)
        self.assertEqual(result["reciters"], 2)
        self.assertEqual(result["failureRate"], .5)
        self.assertEqual(result["perReciter"]["synthetic"]["failureRate"], 0)
        missing = result["perReciter"]["second-synthetic"]
        self.assertEqual(missing["failureRate"], 1)
        self.assertEqual(missing["coverage"], 0)
        self.assertIsNone(missing["boundaries"]["medianMs"])


class MalformedInputTest(unittest.TestCase):
    """Every malformed shape must raise ValueError, never KeyError/TypeError.

    These cases mirror the adversarial matrix run against the pipeline before
    validation was hardened; they exist so evaluator refactors cannot silently
    reintroduce crashes or accept bad references.
    """

    def setUp(self):
        word = dict(surah=1, ayah=2, index=0, start=1.0, end=2.0, uncertaintyMs=20)
        self.ref = dict(schema=1, timeline="source",
                        annotationStatus="independently-reviewed",
                        reviewers=["synthetic-test"],
                        clips=[dict(id="a", audio="synthetic.ogg", audioSha256="0" * 64,
                                    license="CC0-1.0", source="synthetic",
                                    reciter="synthetic", trimStart=0, trimEnd=3,
                                    words=[word])])
        self.pred = dict(clips=[dict(id="a", status="aligned",
                                     words=[dict(word, start=1.04, end=2.16)])])

    def assertRejected(self, mutate_ref=None, mutate_pred=None):
        ref, pred = copy.deepcopy(self.ref), copy.deepcopy(self.pred)
        if mutate_ref:
            mutate_ref(ref)
        if mutate_pred:
            mutate_pred(pred)
        with self.assertRaises(ValueError):
            evaluate(ref, pred)

    def test_malformed_reference_shapes_are_value_errors(self):
        cases = {
            "reference is not an object": lambda r: r.clear(),
            "clips missing": lambda r: r.pop("clips"),
            "clips not a list": lambda r: r.update(clips="x"),
            "clips empty": lambda r: r.update(clips=[]),
            "clip not an object": lambda r: r["clips"].__setitem__(0, "a"),
            "clip id missing": lambda r: r["clips"][0].pop("id"),
            "clip id blank": lambda r: r["clips"][0].update(id="  "),
            "clip id duplicated": lambda r: r["clips"].append(
                copy.deepcopy(r["clips"][0])),
            "provenance missing license": lambda r: r["clips"][0].pop("license"),
            "provenance blank reciter": lambda r: r["clips"][0].update(reciter=""),
            "audio path missing": lambda r: r["clips"][0].pop("audio"),
            "audio path blank": lambda r: r["clips"][0].update(audio="  "),
            "audioSha256 short": lambda r: r["clips"][0].update(audioSha256="abc123"),
            "audioSha256 non-hex": lambda r: r["clips"][0].update(audioSha256="z" * 64),
            "trimStart string": lambda r: r["clips"][0].update(trimStart="0"),
            "trimEnd missing": lambda r: r["clips"][0].pop("trimEnd"),
            "trim inverted": lambda r: r["clips"][0].update(trimStart=5),
            "expected garbage": lambda r: r["clips"][0].update(expected="ALIGN"),
            "words missing": lambda r: r["clips"][0].pop("words"),
            "words not a list": lambda r: r["clips"][0].update(words="x"),
            "words empty": lambda r: r["clips"][0].update(words=[]),
            "word not an object": lambda r: r["clips"][0]["words"].__setitem__(0, "w"),
            "word start missing": lambda r: r["clips"][0]["words"][0].pop("start"),
            "word index missing": lambda r: r["clips"][0]["words"][0].pop("index"),
            "word index string": lambda r: r["clips"][0]["words"][0].update(index="0"),
            "word start bool": lambda r: r["clips"][0]["words"][0].update(start=True),
            "word half-filled": lambda r: r["clips"][0]["words"][0].update(end=None),
            "word uncertainty negative": lambda r: r["clips"][0]["words"][0].update(uncertaintyMs=-5),
            "word end before start": lambda r: r["clips"][0]["words"][0].update(start=2.5, end=1.0),
            "word end past trim": lambda r: r["clips"][0]["words"][0].update(end=9.0),
            "word out of order": lambda r: r["clips"][0]["words"].append(
                dict(surah=1, ayah=2, index=1, start=.5, end=.9, uncertaintyMs=5)),
            "word duplicated": lambda r: r["clips"][0]["words"].append(
                dict(r["clips"][0]["words"][0])),
            "reviewers missing": lambda r: r.pop("reviewers"),
            "reviewers string": lambda r: r.update(reviewers="team"),
            "reviewers empty": lambda r: r.update(reviewers=[]),
            "reviewers blank names": lambda r: r.update(reviewers=[""]),
            "status model-assisted": lambda r: r.update(annotationStatus="model-assisted"),
        }
        for name, mutate in cases.items():
            with self.subTest(name):
                self.assertRejected(mutate_ref=mutate)

    def test_malformed_prediction_shapes_are_value_errors(self):
        cases = {
            "predictions not an object": lambda p: p.clear(),
            "clips missing": lambda p: p.pop("clips"),
            "clips not a list": lambda p: p.update(clips="x"),
            "clip not an object": lambda p: p["clips"].__setitem__(0, "a"),
            "clip id missing": lambda p: p["clips"][0].pop("id"),
            "status missing": lambda p: p["clips"][0].pop("status"),
            "status bogus": lambda p: p["clips"][0].update(status="yes"),
            "words not a list": lambda p: p["clips"][0].update(words="x"),
            "word not an object": lambda p: p["clips"][0]["words"].__setitem__(0, "w"),
            "word end missing": lambda p: p["clips"][0]["words"][0].pop("end"),
            "word surah missing": lambda p: p["clips"][0]["words"][0].pop("surah"),
            "start string": lambda p: p["clips"][0]["words"][0].update(start="1.5"),
            "start NaN": lambda p: p["clips"][0]["words"][0].update(start=float("nan")),
            "end Infinity": lambda p: p["clips"][0]["words"][0].update(end=float("inf")),
            "clip duplicated": lambda p: p["clips"].append(copy.deepcopy(p["clips"][0])),
            "clip unknown": lambda p: p["clips"].append(dict(id="zzz", status="aligned", words=[])),
        }
        for name, mutate in cases.items():
            with self.subTest(name):
                self.assertRejected(mutate_pred=mutate)

    def test_valid_edge_cases_stay_accepted(self):
        for name, mutate in {
            "start at trimStart": lambda r: r["clips"][0]["words"][0].update(start=0.0),
            "end at trimEnd": lambda r: r["clips"][0]["words"][0].update(end=3.0),
            "uncertainty zero": lambda r: r["clips"][0]["words"][0].update(uncertaintyMs=0),
        }.items():
            with self.subTest(name):
                ref, pred = copy.deepcopy(self.ref), copy.deepcopy(self.pred)
                mutate(ref)
                evaluate(ref, pred)

    def test_missing_and_false_accept_predictions_are_scored_not_errors(self):
        missing = dict(clips=[])
        result = evaluate(self.ref, missing)
        self.assertEqual(result["failureRate"], 1)
        self.assertEqual(result["coverage"], 0)
        ref, pred = copy.deepcopy(self.ref), copy.deepcopy(self.pred)
        ref["clips"][0]["expected"] = "reject"
        self.assertEqual(evaluate(ref, pred)["falseAcceptRate"], 1)

    def test_predictions_file_cannot_be_scored_as_a_reference(self):
        # The predictions document has no schema/timeline/annotationStatus, so
        # passing it as a reference must fail rather than score itself.
        with self.assertRaises(ValueError):
            evaluate(self.pred, self.pred)
        with self.assertRaises(ValueError):
            evaluate(self.ref, self.ref)

    def test_shipped_template_is_refused_and_has_no_annotations(self):
        import json
        from pathlib import Path
        template = json.loads((Path(__file__).resolve().parents[2]
                               / "test/fixtures/alignment/reference-template.json")
                              .read_text())
        with self.assertRaisesRegex(ValueError, "independent human-reviewed"):
            evaluate(template, dict(clips=[]))
        # Pre-annotation tooling may inspect it, but it reports no timings.
        validate_reference(template, require_annotations=False)
        annotated = [w for clip in template["clips"]
                     for w in clip.get("words", [])
                     if any(w.get(k) is not None
                            for k in ("start", "end", "uncertaintyMs"))]
        self.assertEqual(annotated, [])


if __name__ == "__main__": unittest.main()
