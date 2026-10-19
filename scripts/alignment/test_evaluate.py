import copy
import unittest
from evaluate import evaluate


class EvaluationTest(unittest.TestCase):
    def setUp(self):
        word = dict(surah=1, ayah=2, index=0, start=1.0, end=2.0, uncertaintyMs=20)
        self.ref = dict(schema=1, timeline="source", annotationStatus="independently-reviewed", reviewers=["synthetic-test"], clips=[dict(id="a", audioSha256="synthetic", license="CC0-1.0", source="synthetic", reciter="synthetic", trimStart=0, trimEnd=3, words=[word])])
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


if __name__ == "__main__": unittest.main()
