import array
import math
import unittest

from quality_probe import (
    acoustic_metrics,
    detect_silences,
    derive_selection,
    flatten_words,
    frame_db,
    inter_word_gaps,
    map_generated_to_source,
    pause_coverage_of,
    reference_report,
    report_drift,
    request_for,
    violations_inside,
)

SR = 16000


def tone(seconds, freq=440.0, amplitude=.4):
    return array.array(
        "f",
        [amplitude * math.sin(2 * math.pi * freq * i / SR)
         for i in range(int(seconds * SR))],
    )


def silence(seconds):
    return array.array("f", [0.0] * int(seconds * SR))


def word(start, end, index=0, ayah=1):
    return {"start": start, "end": end, "index": index, "surah": 1, "ayah": ayah}


class AcousticProbeTest(unittest.TestCase):
    def test_frame_db_separates_tone_from_digital_silence(self):
        frames = frame_db(tone(1) + silence(1) + tone(1))
        quiet = [value for value in frames if value < -60]
        loud = [value for value in frames if value > -40]
        self.assertGreater(len(quiet), 50)
        self.assertGreater(len(loud), 100)
        self.assertLess(max(quiet), min(loud) - 50)

    def test_detect_silences_finds_the_known_gap(self):
        silences, diagnostics = detect_silences(
            frame_db(tone(1) + silence(1) + tone(1)))
        self.assertEqual(len(silences), 1)
        start, end = silences[0]
        self.assertAlmostEqual(start, 1.0, delta=.2)
        self.assertAlmostEqual(end, 2.0, delta=.2)
        self.assertEqual(diagnostics["warnings"], [])
        self.assertGreater(diagnostics["silentFrameFraction"], .2)
        self.assertLess(diagnostics["silentFrameFraction"], .5)

    def test_pause_coverage_prefers_boundaries_around_real_silence(self):
        aligned = acoustic_metrics([word(.5, .95), word(2.05, 2.5)], [(1.0, 2.0)])
        self.assertEqual(aligned["interWordPauses"]["count"], 1)
        self.assertEqual(aligned["interWordPauses"]["majoritySilentCount"], 1)
        self.assertAlmostEqual(
            aligned["interWordPauses"]["coverageMedian"], 1.0 / 1.1)
        misplaced = acoustic_metrics([word(2.5, 2.9), word(3.1, 3.5)], [(1.0, 2.0)])
        self.assertEqual(misplaced["interWordPauses"]["majoritySilentCount"], 0)
        self.assertEqual(misplaced["interWordPauses"]["coverageMedian"], 0.0)

    def test_word_swallowing_a_pause_is_flagged(self):
        metrics = acoustic_metrics([word(.5, .8), word(.9, 2.1)], [(1.0, 2.0)])
        self.assertEqual(metrics["silenceInsideWords"]["count"], 1)
        self.assertEqual(
            metrics["silenceInsideWords"]["words"][0]["silenceSeconds"], 1.0)
        self.assertAlmostEqual(
            metrics["wordInteriorSilenceFraction"]["max"], 1.0 / 1.2, delta=.01)

    def test_gap_metrics_require_a_minimum_pause(self):
        self.assertEqual(inter_word_gaps([word(.0, .5), word(.55, .9)]), [])
        self.assertEqual(
            inter_word_gaps([word(.0, .5), word(.8, .9)]), [(.5, .8)])

    def test_known_silence_violations_are_one_sided_milliseconds(self):
        report = violations_inside(
            [(2.0, 4.0)], [word(1.6, 2.4), word(4.1, 4.5)])
        self.assertAlmostEqual(report["totalViolationMs"], 400.0)
        self.assertEqual(len(report["intervals"][0]["violatingWords"]), 1)
        self.assertAlmostEqual(
            report["intervals"][0]["violatingWords"][0]["insideMs"], 400.0)
        clean = violations_inside([(2.0, 4.0)], [word(.5, 1.9), word(4.2, 5.0)])
        self.assertEqual(clean["totalViolationMs"], 0.0)

    def test_pause_coverage_of_known_interval(self):
        values = pause_coverage_of([(2.0, 4.0)], [word(1.0, 1.9), word(4.2, 5.0)])
        self.assertAlmostEqual(values[0], 1.0)
        missed = pause_coverage_of([(2.0, 4.0)], [word(2.1, 3.0), word(3.2, 3.9)])
        self.assertAlmostEqual(missed[0], 0.1)

    def test_map_generated_to_source_removes_the_known_shift(self):
        self.assertAlmostEqual(
            map_generated_to_source(1.0, 3.0, 2.0, 14.0), 15.0)
        self.assertAlmostEqual(
            map_generated_to_source(4.999, 3.0, 2.0, 14.0), 18.999)
        self.assertAlmostEqual(
            map_generated_to_source(5.0, 3.0, 2.0, 14.0), 17.0)

    def test_report_drift_matches_words_by_canonical_key(self):
        base = [word(1.0, 1.4), word(1.5, 1.9, index=1)]
        mapped = [word(1.0, 1.45), word(1.5, 1.9, index=1)]
        drift = report_drift(base, mapped)
        self.assertTrue(drift["wordSetsMatched"])
        self.assertEqual(drift["n"], 4)
        self.assertAlmostEqual(drift["maxMs"], 50.0)
        missing = report_drift(base, mapped[:1])
        self.assertFalse(missing["wordSetsMatched"])
        self.assertEqual(missing["n"], 2)


class SelectionDerivationTest(unittest.TestCase):
    def clip(self, words):
        return {"id": "c", "trimStart": 14, "trimEnd": 27, "words": words}

    def test_selection_comes_from_a_contiguous_word_run(self):
        selection = derive_selection(self.clip([
            {"surah": 1, "ayah": 2, "index": 1},
            {"surah": 1, "ayah": 2, "index": 2},
            {"surah": 1, "ayah": 3, "index": 0},
            {"surah": 1, "ayah": 3, "index": 1},
        ]))
        self.assertEqual(selection, {
            "surah": 1, "firstAyah": 2, "lastAyah": 3,
            "firstWord": 1, "lastWord": 1,
            "trimStart": 14, "trimEnd": 27,
        })

    def test_explicit_selection_is_used_verbatim(self):
        selection = {"surah": 2, "firstAyah": 1, "lastAyah": 1,
                     "trimStart": 0, "trimEnd": 9}
        self.assertEqual(derive_selection(
            {"id": "r", "selection": selection}), selection)

    def test_reject_clip_without_words_or_selection_is_actionable(self):
        with self.assertRaisesRegex(ValueError, "reject clips"):
            derive_selection({"id": "r", "trimStart": 0, "trimEnd": 9})

    def test_noncontiguous_jumped_or_duplicate_words_are_rejected(self):
        cases = [
            [{"surah": 1, "ayah": 2, "index": 0}, {"surah": 1, "ayah": 2, "index": 2}],
            [{"surah": 1, "ayah": 2, "index": 0}, {"surah": 1, "ayah": 4, "index": 0}],
            [{"surah": 1, "ayah": 2, "index": 0}, {"surah": 1, "ayah": 2, "index": 0}],
            [{"surah": 1, "ayah": 2, "index": 0}, {"surah": 2, "ayah": 1, "index": 0}],
            [{"surah": 1, "ayah": 2}],
        ]
        for words in cases:
            with self.subTest(words=words):
                with self.assertRaises(ValueError):
                    derive_selection(self.clip(words))

    def test_verified_text_bounds_are_checked_when_text_is_available(self):
        verses = {(1, 2): "a b c", (1, 3): "d e"}
        ok = self.clip([{"surah": 1, "ayah": 2, "index": 1},
                        {"surah": 1, "ayah": 3, "index": 0},
                        {"surah": 1, "ayah": 3, "index": 1}])
        self.assertEqual(derive_selection(ok, verses)["lastWord"], 1)
        out_of_range = self.clip([{"surah": 1, "ayah": 2, "index": 0},
                                  {"surah": 1, "ayah": 3, "index": 0},
                                  {"surah": 1, "ayah": 3, "index": 1}])
        with self.assertRaisesRegex(ValueError, "out of range"):
            derive_selection(out_of_range, {(1, 2): "a b c", (1, 3): "d"})
        missing = self.clip([{"surah": 1, "ayah": 9, "index": 0}])
        with self.assertRaisesRegex(ValueError, "does not contain"):
            derive_selection(missing, verses)


class RequestAndResultTest(unittest.TestCase):
    def test_request_omits_last_word_only_when_absent(self):
        selection = {"trimStart": 14, "trimEnd": 27, "surah": 1,
                     "firstAyah": 2, "lastAyah": 3, "firstWord": 0,
                     "lastWord": None}
        request = request_for("/tmp/audio.ogg", selection)
        self.assertNotIn("lastWord", request)
        self.assertTrue(request["audioPath"].endswith("/tmp/audio.ogg"))
        self.assertEqual(request["protocol"], 1)
        request = request_for("/tmp/audio.ogg", dict(selection, lastWord=5))
        self.assertEqual(request["lastWord"], 5)

    def test_flatten_words_carries_references_and_order(self):
        result = {"cues": [
            {"surah": 1, "ayah": 3, "words": [{"index": 0, "start": 3.0, "end": 3.5}]},
            {"surah": 1, "ayah": 2, "words": [{"index": 1, "start": 1.5, "end": 2.0},
                                              {"index": 0, "start": 1.0, "end": 1.4}]},
        ]}
        words = flatten_words(result)
        self.assertEqual([(w["ayah"], w["index"]) for w in words],
                         [(2, 0), (2, 1), (3, 0)])
        self.assertEqual(words[0]["surah"], 1)


class ReferenceReportTest(unittest.TestCase):
    def template(self):
        import json
        from pathlib import Path
        path = (Path(__file__).resolve().parents[2]
                / "test/fixtures/alignment/reference-template.json")
        return json.loads(path.read_text())

    def fill(self, reference, count=6):
        start = 14.5
        for word in reference["clips"][0]["words"][:count]:
            word.update(start=start, end=start + 1.0, uncertaintyMs=20)
            start += 1.5
        return reference

    def test_shipped_template_preflights_clean_but_unannotated(self):
        report = reference_report(self.template(), check_hashes=True)
        self.assertTrue(report["valid"], report["errors"])
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["corpus"]["clips"]["value"], 1)
        self.assertEqual(report["corpus"]["reciters"]["value"], 1)
        self.assertEqual(report["corpus"]["expectedWords"]["value"], 6)
        self.assertEqual(report["corpus"]["annotatedWords"], 0)
        self.assertEqual(report["corpus"]["negativeClips"]["value"], 0)
        self.assertFalse(report["corpus"]["scoreable"])
        self.assertFalse(report["corpus"]["clips"]["met"])
        self.assertFalse(report["corpus"]["expectedWords"]["met"])
        self.assertIn("no word timings", report["clips"][0]["warnings"][0])

    def test_fully_annotated_reference_is_scoreable(self):
        reference = self.fill(self.template())
        reference.update(annotationStatus="independently-reviewed",
                         reviewers=["synthetic-test"])
        report = reference_report(reference, check_hashes=True)
        self.assertTrue(report["valid"], report["errors"])
        self.assertEqual(report["corpus"]["annotatedWords"], 6)
        self.assertTrue(report["corpus"]["scoreable"])

    def test_partial_annotation_reports_progress_without_errors(self):
        report = reference_report(self.fill(self.template(), count=3))
        self.assertTrue(report["valid"], report["errors"])
        self.assertEqual(report["corpus"]["annotatedWords"], 3)
        self.assertIn("3 of 6 words annotated", report["clips"][0]["warnings"][0])

    def test_half_filled_word_is_an_error(self):
        reference = self.template()
        reference["clips"][0]["words"][0].update(start=14.5, end=None)
        report = reference_report(reference)
        self.assertFalse(report["valid"])
        self.assertIn("mixes filled and missing", report["errors"][0])

    def test_missing_audio_file_is_an_error(self):
        reference = self.template()
        reference["clips"][0]["audio"] = "test/fixtures/alignment/missing.ogg"
        report = reference_report(reference)
        self.assertFalse(report["valid"])
        self.assertTrue(any("audio file is missing" in error
                            for error in report["errors"]))

    def test_hash_mismatch_only_checked_on_request(self):
        reference = self.template()
        reference["clips"][0]["audioSha256"] = "0" * 64
        self.assertTrue(reference_report(reference)["valid"])
        report = reference_report(reference, check_hashes=True)
        self.assertFalse(report["valid"])
        self.assertTrue(any("audioSha256 does not match" in error
                            for error in report["errors"]))

    def test_negative_clip_needs_an_explicit_selection(self):
        reference = self.template()
        clip = reference["clips"][0]
        clip.update(expected="reject")
        clip.pop("words")
        report = reference_report(reference)
        self.assertFalse(report["valid"])
        self.assertTrue(any("selection" in error and "reject" in error
                            for error in report["errors"]))

    def test_negative_selection_inherits_the_clip_trim(self):
        reference = self.template()
        clip = reference["clips"][0]
        clip.update(expected="reject", selection={
            "surah": 1, "firstAyah": 1, "lastAyah": 1})
        clip.pop("words")
        report = reference_report(reference)
        self.assertTrue(report["valid"], report["errors"])
        self.assertEqual(report["corpus"]["negativeClips"]["value"], 1)
        self.assertEqual(report["clips"][0]["selection"]["trimStart"], 14)
        self.assertEqual(report["clips"][0]["selection"]["trimEnd"], 27)

    def test_noncontiguous_words_are_flagged(self):
        reference = self.template()
        reference["clips"][0]["words"].pop(1)
        report = reference_report(reference)
        self.assertFalse(report["valid"])
        self.assertTrue(any("not contiguous" in error
                            for error in report["errors"]))

    def test_reviewed_status_with_incomplete_annotations_is_an_error(self):
        reference = self.template()
        reference.update(annotationStatus="independently-reviewed",
                         reviewers=["synthetic-test"])
        report = reference_report(reference)
        self.assertFalse(report["valid"])
        self.assertTrue(any("claims independent review" in error
                            for error in report["errors"]))

    def test_unknown_annotation_status_warns(self):
        reference = self.template()
        reference.update(annotationStatus="reviewing")
        report = reference_report(reference)
        self.assertTrue(report["valid"], report["errors"])
        self.assertIn("unrecognized annotationStatus",
                      report["warnings"][0])

    def test_explicit_selection_fills_missing_trim_from_clip(self):
        clip = {"id": "r", "trimStart": 2, "trimEnd": 9,
                "selection": {"surah": 1, "firstAyah": 1, "lastAyah": 1}}
        selection = derive_selection(clip)
        self.assertEqual(selection["trimStart"], 2)
        self.assertEqual(selection["trimEnd"], 9)


if __name__ == "__main__":
    unittest.main()
