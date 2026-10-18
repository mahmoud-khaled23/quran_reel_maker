import tempfile
import unittest
from pathlib import Path
import numpy as np
from alignment_worker.ctc import alphabet, character, fold_logits, tokenize, viterbi
from alignment_worker.model import verify
from alignment_worker.worker import AlignmentError, QURAN_SHA256, validate_request


class CtcTests(unittest.TestCase):
    def test_repeated_letters_need_blank_and_elongation_can_dwell(self):
        probabilities = np.full((8, 3), 0.01)
        for t, token in enumerate([0, 1, 1, 0, 1, 2, 2, 0]):
            probabilities[t, token] = 0.98
        path = viterbi(np.log(probabilities), np.array([1, 1, 2]))
        self.assertEqual(path.tolist(), [0, 1, 1, 2, 3, 5, 5, 6])

    def test_impossible_repeated_target_is_rejected(self):
        with self.assertRaises(ValueError):
            viterbi(np.log(np.full((2, 2), 0.5)), np.array([1, 1]))

    def test_acoustic_view_does_not_mutate_text_or_word_indices(self):
        original = "ٱلرَّحْمَٰنِ ۚ ٱلرَّحِيمِ"
        vocab = {"<pad>": 0, "|": 1, "ا": 2, "ل": 3, "ر": 4, "ح": 5, "م": 6, "ن": 7, "ي": 8}
        labels = alphabet(vocab)
        target, owners, words = tokenize([original], labels)
        self.assertEqual(words, [(0, 0), (0, 2)])
        self.assertEqual("".join(labels[i] for i in target), "الرحمان|الرحيم")
        self.assertEqual(original, "ٱلرَّحْمَٰنِ ۚ ٱلرَّحِيمِ")
        self.assertEqual(character("۞"), "")
        self.assertIn(None, owners)

    def test_folding_conserves_probability(self):
        vocab = {"<pad>": 0, "ا": 1, "ٱ": 2, "َ": 3, "|": 4}
        folded = np.exp(fold_logits(np.zeros((3, 5)), vocab, alphabet(vocab)))
        np.testing.assert_allclose(folded.sum(axis=1), 1)
        np.testing.assert_allclose(folded[:, 0], 0.4)

    def test_missing_model_is_actionable(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(ValueError, "setup-alignment"):
            verify(Path(directory))

    def test_request_rejects_bad_time_and_quran_version(self):
        request = {"protocol": 1, "quranSha256": QURAN_SHA256, "trimStart": 0, "trimEnd": float("nan")}
        with self.assertRaisesRegex(AlignmentError, "matching recitation"):
            validate_request(request)
        request["quranSha256"] = "wrong"
        with self.assertRaisesRegex(AlignmentError, "Quran version"):
            validate_request(request)


if __name__ == "__main__":
    unittest.main()
