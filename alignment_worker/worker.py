"""One request on stdin; NDJSON progress/result/error on stdout. No network."""
import argparse
import json
import math
from pathlib import Path
import signal
import subprocess
import sys

from .model import DEFAULT_MODEL, MANIFEST, ROOT, digest, verify

QURAN_SHA256 = "6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f"
MAX_SECONDS = 180
child = None


class AlignmentError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def emit(kind, **data):
    print(json.dumps({"type": kind, "protocol": 1, **data}, ensure_ascii=False, allow_nan=False), flush=True)


def stop(_signal, _frame):
    if child is not None:
        child.terminate()
    raise SystemExit(130)


def validate_request(request):
    if request.get("protocol") != 1 or request.get("quranSha256") != QURAN_SHA256:
        raise AlignmentError("protocol", "Worker/app Quran version differs. Update the app and worker together; manual timing is still available.")
    start, end = request.get("trimStart"), request.get("trimEnd")
    if any(type(v) not in (int, float) or not math.isfinite(v) for v in (start, end)) or start < 0 or not 0.5 <= end - start <= MAX_SECONDS:
        raise AlignmentError("trim", f"Select a complete recitation segment between 0.5 and {MAX_SECONDS} seconds.")
    surah, first, last = (request.get(k) for k in ("surah", "firstAyah", "lastAyah"))
    if any(type(v) is not int for v in (surah, first, last)) or not 1 <= surah <= 114 or not 1 <= first <= last <= 286:
        raise AlignmentError("selection", "Select a valid surah and ayah range.")
    audio = request.get("audioPath")
    if not isinstance(audio, str) or not Path(audio).is_absolute() or not Path(audio).is_file():
        raise AlignmentError("audio", "The local audio file is missing. Reimport the audio and retry.")
    quran = ROOT / "assets/quran/quran-uthmani.txt"
    if digest(quran) != QURAN_SHA256:
        raise AlignmentError("quran_integrity", "Worker Quran asset failed verification. Restore the original Tanzil asset before aligning.")
    verses = {}
    for line in quran.read_text().splitlines():
        if line and not line.startswith("#"):
            s, a, text = line.split("|", 2)
            verses[int(s), int(a)] = text
    try:
        return [verses[surah, a] for a in range(first, last + 1)]
    except KeyError as error:
        raise AlignmentError("selection", "The selected ayah does not exist in the verified dataset.") from error


def decode(request):
    global child
    import numpy as np
    command = ["ffmpeg", "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe",
               "-ss", str(request["trimStart"]), "-i", request["audioPath"],
               "-t", str(request["trimEnd"] - request["trimStart"]), "-vn",
               "-ac", "1", "-ar", "16000", "-f", "f32le", "pipe:1"]
    try:
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            raw, error = child.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            raise AlignmentError("audio_timeout", "Decoding timed out. Convert the audio to WAV and retry.")
        if child.returncode:
            raise AlignmentError("decode", "FFmpeg could not read this audio. Reimport or convert it to WAV. " + error.decode(errors="replace")[-1000:])
    except FileNotFoundError as error:
        raise AlignmentError("ffmpeg_missing", "Install FFmpeg and put ffmpeg on PATH; then retry alignment.") from error
    finally:
        child = None
    audio = np.frombuffer(raw, dtype=np.float32).copy()
    duration = request["trimEnd"] - request["trimStart"]
    if abs(len(audio) / 16000 - duration) > 0.1 or len(audio) < 8000:
        raise AlignmentError("audio_length", "The trim extends beyond readable audio. Reimport and select a shorter segment.")
    if not np.isfinite(audio).all() or np.sqrt(np.mean(audio ** 2)) < 0.0001:
        raise AlignmentError("silent_audio", "No usable audio was detected. Select audible recitation or use manual timings.")
    return audio


def infer(audio, model_dir, progress):
    import numpy as np
    try:
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        session = ort.InferenceSession(str(model_dir / "onnx/model_q4.onnx"), options, providers=["CPUExecutionProvider"])
    except Exception as error:
        raise AlignmentError("runtime", "ONNX CPU runtime could not load the pinned model. Rerun setup with Python 3.11–3.13 on a supported CPU. " + str(error)[:500]) from error
    if [i.name for i in session.get_inputs()] != ["input_values"]:
        raise AlignmentError("runtime", "Unexpected ONNX inputs. Reinstall the pinned worker/model.")
    chunks, clocks = [], []
    # Context windows prevent hard chunk seams; centers stay on the model's
    # 320-sample lattice (400-sample receptive field). Keep each center once.
    for start in range(0, len(audio), 15 * 16000):
        low, high = max(0, start - 16000), min(len(audio), start + 16 * 16000)
        wave = audio[low:high].copy()
        wave = (wave - wave.mean()) / np.sqrt(wave.var() + 1e-7)
        try:
            logits = session.run(None, {"input_values": wave[None, :]})[0][0]
        except Exception as error:
            raise AlignmentError("inference", "CPU inference failed. Close other applications or select a shorter segment. " + str(error)[:300]) from error
        if logits.ndim != 2 or logits.shape[1] != 56 or not np.isfinite(logits).all():
            raise AlignmentError("runtime", "Invalid model output. Reinstall the pinned model/runtime.")
        clock = (np.arange(len(logits)) * 320 + 200 + low) / 16000
        keep = (clock >= start / 16000) & (clock < min(start / 16000 + 15, len(audio) / 16000))
        chunks.append(logits[keep])
        clocks.append(clock[keep])
        progress(min(0.85, 0.1 + 0.75 * min(start + 15 * 16000, len(audio)) / len(audio)), "Listening locally on CPU…")
    return np.concatenate(chunks), np.concatenate(clocks)


def align(request, model_dir=DEFAULT_MODEL, progress=lambda *_: None):
    import numpy as np
    from .ctc import alphabet, edit_distance, fold_logits, greedy, tokenize, viterbi
    verses = validate_request(request)
    progress(0.02, "Verifying local model files…")
    try:
        verify(model_dir)
    except ValueError as error:
        raise AlignmentError("model_missing_or_corrupt", str(error)) from error
    progress(0.05, "Decoding the selected audio…")
    audio = decode(request)
    vocab = json.loads((model_dir / "vocab.json").read_text())
    labels = alphabet(vocab)
    target, owners, words = tokenize(verses, labels)
    estimated_frames = max(0, (len(audio) - 400) // 320 + 1)
    if not len(target) or len(target) > estimated_frames or estimated_frames * (2 * len(target) + 1) > 40_000_000:
        raise AlignmentError("selection_size", "Too much text for this audio/worker memory limit. Select fewer complete ayahs and a matching shorter audio segment.")
    logits, clocks = infer(audio, model_dir, progress)
    progress(0.9, "Aligning verified ayah text and checking boundaries…")
    logp = fold_logits(logits, vocab, labels)
    recognized = greedy(logp)
    # Ignore spaces in mismatch checking: the recognizer often joins words.
    space = labels.index("|")
    lexical_target = [int(i) for i in target if i != space]
    lexical_recognized = [i for i in recognized if i != space]
    mismatch = edit_distance(lexical_target, lexical_recognized) / max(1, len(lexical_target))
    if mismatch > 0.65:
        raise AlignmentError("text_mismatch", "Audio does not match the selected ayahs reliably. Check the surah/range, exclude introductions or repeated passages, reduce noise, or create manual timings.")
    try:
        path = viterbi(logp, target)
    except ValueError as error:
        raise AlignmentError("alignment_path", str(error)) from error
    global_warnings = ["Automatic draft: listen to every boundary before export. Acoustic scores are not accuracy probabilities.",
                       "Repeated phrases are not separately segmented; crop them out or correct timings manually."]
    if mismatch > 0.2:
        global_warnings.append("Possible repeated/omitted words, vocalization differences or background noise. Check the entire selection; repeated phrases are not separately segmented.")
    cues = [{"surah": request["surah"], "ayah": request["firstAyah"] + i,
             "timingSource": "automatic", "alignmentModel": MANIFEST["id"],
             "warnings": [], "words": []} for i in range(len(verses))]
    for word_id, (ayah_index, word_index) in enumerate(words):
        tokens = [i for i, owner in enumerate(owners) if owner == word_id]
        frames = np.flatnonzero(np.isin(path, [i * 2 + 1 for i in tokens]))
        if not len(frames):
            raise AlignmentError("alignment_path", "A word could not be located. Check the selection or use manual timing.")
        start = max(0.0, float(clocks[frames[0]]) - 0.01)
        end = min(len(audio) / 16000, float(clocks[frames[-1]]) + 0.01)
        score = float(np.exp(np.mean(logp[frames, target[(path[frames] - 1) // 2]])))
        cue = cues[ayah_index]
        cue["words"].append({"index": word_index, "start": start + request["trimStart"],
                             "end": end + request["trimStart"], "score": score})
        if score < 0.35 or end - start < 0.08:
            cue["warnings"].append("Uncertain word boundary; listen and adjust the ayah.")
        if end - start > 4:
            cue["warnings"].append("Long word/elongation or internal pause; verify the boundary.")
    for cue in cues:
        cue["start"], cue["end"] = cue["words"][0]["start"], cue["words"][-1]["end"]
        cue["alignmentScore"] = float(np.mean([word["score"] for word in cue["words"]]))
        if any(b["start"] - a["end"] > 1.5 for a, b in zip(cue["words"], cue["words"][1:])):
            cue["warnings"].append("Long pause inside the ayah; check for a repeated phrase.")
        cue["warnings"] = list(dict.fromkeys(global_warnings + cue["warnings"]))
    if cues[0]["start"] - request["trimStart"] < 0.15 or request["trimEnd"] - cues[-1]["end"] < 0.15:
        cues[0]["warnings"].append("Speech touches a trim edge. Include the complete first/last ayah and rerun if any syllable is cut.")
    if float(np.mean([cue["alignmentScore"] for cue in cues])) < 0.15:
        raise AlignmentError("low_quality", "Acoustic alignment is too uncertain. Try cleaner audio or a shorter selection; manual timings remain available.")
    return {"timeline": "source", "model": MANIFEST["id"], "revision": MANIFEST["revision"],
            "quranSha256": QURAN_SHA256, "mismatchRatio": mismatch, "cues": cues}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        line = sys.stdin.buffer.readline(65537)
        if len(line) > 65536:
            raise AlignmentError("protocol", "Alignment request exceeds 64 KiB.")
        request = json.loads(line)
        if not isinstance(request, dict):
            raise AlignmentError("protocol", "Expected one JSON request object.")
        result = align(request, args.model_dir, lambda value, message: emit("progress", value=value, message=message))
        emit("result", **result)
        return 0
    except ImportError:
        emit("error", code="dependencies", message="Python inference dependencies are missing. Run ./scripts/setup-alignment.sh, then select scripts/alignment-worker.sh in the app.")
    except AlignmentError as error:
        emit("error", code=error.code, message=str(error))
    except Exception as error:
        emit("error", code="worker", message=f"Worker could not complete alignment ({type(error).__name__}): {str(error)[:400]}. Check setup or use manual timing.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
