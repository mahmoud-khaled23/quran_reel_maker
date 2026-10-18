"""Opt-in real ONNX/FFmpeg tests. No downloads; run with QRM_TEST_MODEL=1."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave
import numpy as np
from alignment_worker.model import DEFAULT_MODEL, ROOT
from alignment_worker.worker import AlignmentError, QURAN_SHA256, align

FIXTURE = ROOT / "test/fixtures/alignment/fatiha-cc0.ogg"


def request(audio=FIXTURE, start=14, end=27, first=2, last=3):
    return {"protocol": 1, "quranSha256": QURAN_SHA256, "audioPath": str(audio.resolve()),
            "trimStart": start, "trimEnd": end, "surah": 1, "firstAyah": first, "lastAyah": last}


def write_wave(path, samples):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())


@unittest.skipUnless(os.environ.get("QRM_TEST_MODEL") == "1", "Set QRM_TEST_MODEL=1 after explicit model setup")
class RealAlignmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.temp = Path(cls.directory.name)
        cls.baseline = align(request())

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_fixture_integrity_and_expected_ayah_windows(self):
        self.assertEqual(hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), "59a4eef339d3e42aeaf9b77a6423297a0f830e4872783fc0718a64862b02df32")
        expected = json.loads((FIXTURE.parent / "expected.json").read_text())
        for cue, window in zip(self.baseline["cues"], expected["cues"], strict=True):
            self.assertEqual(cue["ayah"], window["ayah"])
            for boundary in ("start", "end"):
                self.assertGreaterEqual(cue[boundary], window[boundary][0])
                self.assertLessEqual(cue[boundary], window[boundary][1])
            self.assertTrue(cue["warnings"])
            self.assertGreater(len(cue["words"]), 1)
            self.assertNotIn("confidence", cue)

    def test_source_offset_inserted_pause_and_offline_protocol(self):
        raw = subprocess.check_output(["ffmpeg", "-v", "error", "-ss", "14", "-i", str(FIXTURE), "-t", "13", "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1"])
        audio = np.frombuffer(raw, dtype=np.float32)
        # Add five seconds before the selected window and a two-second pause
        # at a fixed cut between ayahs. Source-clock expectations are analytic.
        cut = int((21.75 - 14) * 16000)
        shifted = np.concatenate((np.zeros(5 * 16000), audio[:cut], np.zeros(2 * 16000), audio[cut:]))
        file = self.temp / "shifted.wav"
        write_wave(file, shifted)
        result = subprocess.run([sys.executable, "-m", "alignment_worker.worker"], input=json.dumps(request(file, 5, 20)) + "\n",
                                text=True, capture_output=True, timeout=120, cwd=ROOT,
                                env={**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "http_proxy": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events[-1]["timeline"], "source")
        self.assertTrue(any(e["type"] == "progress" for e in events))
        shifted_cues = events[-1]["cues"]
        for i, (baseline, changed) in enumerate(zip(self.baseline["cues"], shifted_cues, strict=True)):
            for boundary in ("start", "end"):
                self.assertAlmostEqual(changed[boundary], baseline[boundary] - 14 + 5 + i * 2, delta=0.7)
        self.assertGreater(shifted_cues[1]["start"] - shifted_cues[0]["end"], 1.5)

    def test_partial_ayah_keeps_original_word_indices(self):
        words = self.baseline["cues"][0]["words"]
        selection = request(start=words[1]["start"] - 0.1, end=words[2]["end"] + 0.1, first=2, last=2)
        selection.update(firstWord=1, lastWord=2)
        result = align(selection)["cues"][0]
        self.assertEqual([w["index"] for w in result["words"]], [1, 2])
        self.assertEqual((result["firstWord"], result["lastWord"]), (1, 2))
        self.assertAlmostEqual(result["start"], words[1]["start"], delta=0.5)
        self.assertAlmostEqual(result["end"], words[2]["end"], delta=0.5)

    def test_silence_is_rejected_before_inference(self):
        file = self.temp / "silence.wav"
        write_wave(file, np.zeros(32000))
        with self.assertRaisesRegex(AlignmentError, "No usable audio"):
            align(request(file, 0, 2))

    def test_wrong_selection_and_noise_are_rejected(self):
        wrong = request(first=6, last=7)
        with self.assertRaisesRegex(AlignmentError, "does not match"):
            align(wrong)
        file = self.temp / "noise.wav"
        write_wave(file, np.random.default_rng(1).normal(0, 0.05, 5 * 16000))
        with self.assertRaisesRegex(AlignmentError, "does not match"):
            align(request(file, 0, 5))

    def test_repeated_passage_is_rejected_and_slow_audio_stays_ordered(self):
        raw = subprocess.check_output(["ffmpeg", "-v", "error", "-ss", "14", "-i", str(FIXTURE), "-t", "7.75", "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1"])
        passage = np.frombuffer(raw, dtype=np.float32)
        repeated = np.concatenate((passage, np.zeros(16000), passage))
        file = self.temp / "repeat.wav"
        write_wave(file, repeated)
        with self.assertRaisesRegex(AlignmentError, "does not match"):
            align(request(file, 0, len(repeated) / 16000, first=2, last=2))
        # Deterministic slower playback exercises elongation and a 15-second
        # inference seam. This is not a substitute for diverse real reciters.
        slow = subprocess.check_output(["ffmpeg", "-v", "error", "-ss", "14", "-t", "13", "-i", str(FIXTURE), "-af", "atempo=0.8", "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1"])
        samples = np.frombuffer(slow, dtype=np.float32)
        file = self.temp / "slow.wav"
        write_wave(file, samples)
        result = align(request(file, 0, len(samples) / 16000))
        for original, stretched in zip(self.baseline["cues"], result["cues"], strict=True):
            for boundary in ("start", "end"):
                self.assertAlmostEqual(stretched[boundary], (original[boundary] - 14) / 0.8, delta=0.8)


if __name__ == "__main__":
    unittest.main()
