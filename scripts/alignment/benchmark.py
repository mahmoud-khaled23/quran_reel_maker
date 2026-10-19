"""Real native-core/Linux-worker parity and resource checks; NOT word-accuracy gold.
Run with .alignment-venv/bin/python after setup-native-benchmark.sh.
Generated variants inherit the bundled CC0 fixture's license. No new recordings.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from alignment_worker.model import DEFAULT_MODEL, MANIFEST, verify
from alignment_worker.worker import QURAN_SHA256, AlignmentError, align, decode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", default="base,partial,pause,slow,repeat,wrong,noise")
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--output", type=Path, default=ROOT / "output/alignment-benchmark")
    args = parser.parse_args()
    if not 1 <= args.runs <= 10:
        parser.error("runs must be 1–10")
    os.chdir(ROOT)
    args.output.mkdir(parents=True, exist_ok=True)
    verify(DEFAULT_MODEL)
    source = ROOT / "test/fixtures/alignment/fatiha-cc0.ogg"
    assert hashlib.sha256(source.read_bytes()).hexdigest() == "59a4eef339d3e42aeaf9b77a6423297a0f830e4872783fc0718a64862b02df32"
    base = {"protocol": 1, "quranSha256": QURAN_SHA256, "audioPath": str(source), "trimStart": 14, "trimEnd": 27, "surah": 1, "firstAyah": 2, "lastAyah": 3}
    # Variants are controlled transformations, not independent word labels.
    selected = decode(base)
    import numpy as np
    cases = {
        "base": (base, selected, True),
        "partial": (dict(base, trimStart=17, trimEnd=21.7, lastAyah=2, firstWord=1, lastWord=3), None, True),
        "pause": (dict(base, trimStart=0, trimEnd=15), np.concatenate([selected[:int(7.75*16000)], np.zeros(32000, dtype=np.float32), selected[int(7.75*16000):]]), True),
        "slow": (dict(base, trimStart=0, trimEnd=26), None, True),
        "repeat": (dict(base, trimStart=0, trimEnd=26), np.tile(selected, 2), False),
        "wrong": (dict(base, firstAyah=5, lastAyah=7), selected, False),
        "noise": (dict(base, trimStart=0, trimEnd=13), np.random.default_rng(42).normal(0,.03,13*16000).astype(np.float32), False),
    }
    classpath = os.pathsep.join(str(ROOT / f) for f in ["output/alignment-native-classes", "output/alignment-native-deps/onnxruntime-1.23.2.jar", "output/alignment-native-deps/json-20250517.jar"])
    java = str(Path(os.environ["JAVA_HOME"]) / "bin/java") if "JAVA_HOME" in os.environ else "java"
    reports = []
    for name in args.cases.split(","):
        request, samples, expected = cases[name]
        folder = args.output / name
        folder.mkdir(exist_ok=True)
        if name == "slow":
            wav = folder / "source.wav"
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "14", "-i", str(source), "-af", "atrim=duration=13,asetpts=PTS-STARTPTS,atempo=0.5,apad,atrim=duration=26", "-ar", "16000", "-ac", "1", str(wav)], check=True)
            request["audioPath"] = str(wav.resolve())
            samples = decode(request)
        elif samples is None:
            samples = decode(request)
        pcm = folder / "selected.f32"
        samples.astype("<f4").tofile(pcm)
        # The Linux worker still decodes audio itself; preserve source offsets.
        if name in ("pause", "repeat", "noise"):
            wav = folder / "source.wav"
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", "16000", "-ac", "1", "-i", str(pcm), str(wav)], check=True)
            request["audioPath"] = str(wav.resolve())
        req = folder / "request.json"; req.write_text(json.dumps(request))
        report = folder / "native.json"; resource = folder / "resource.txt"
        start = time.perf_counter()
        subprocess.run(["/usr/bin/time", "-f", "%M %U %S %e", "-o", str(resource), java, "-Xmx512m", "-cp", classpath, "NativeHarness",
                        str(DEFAULT_MODEL / "onnx/model_q4.onnx"), str(ROOT / "assets/quran/quran-uthmani.txt"),
                        str(ROOT / "assets/models/quran-ctc-vocab.json"), str(req), str(pcm), str(args.runs), str(report)], check=True)
        elapsed = time.perf_counter() - start
        data = json.loads(report.read_text())
        rss, user, system, wall = map(float, resource.read_text().split())
        data.update(case=name, expectedAligned=expected, peakRssKiB=rss, processCpuSeconds=user+system,
                    processWallSeconds=wall, processCpuPercent=100*(user+system)/wall, launcherWallSeconds=elapsed,
                    accuracyGroundTruth=False, referenceBoundaryMetrics=None)
        for run in data["runs"]:
            run["rtf"] = run["elapsedMs"] / 1000 / (request["trimEnd"]-request["trimStart"])
            assert (run["status"] == "aligned") == expected, f"{name}: unexpected native acceptance/rejection"
        try:
            baseline = align(request)
            assert expected, f"{name}: Linux unexpectedly accepted"
            (folder / "linux.json").write_text(json.dumps(baseline, ensure_ascii=False, indent=2))
            native_words = [(c["ayah"], w) for c in data["runs"][0]["result"]["cues"] for w in c["words"]]
            linux_words = [(c["ayah"], w) for c in baseline["cues"] for w in c["words"]]
            assert [(a,w["index"]) for a,w in native_words] == [(a,w["index"]) for a,w in linux_words]
            delta = max(abs(n[k]-l[k]) for (_,n),(_,l) in zip(native_words,linux_words) for k in ("start","end"))
            data["linuxParityMaxBoundaryDifferenceMs"] = delta*1000
            assert delta <= .04001, f"{name}: native/Linux parity exceeds two CTC frames: {delta}"
        except AlignmentError as error:
            assert not expected, f"{name}: Linux rejected: {error}"
            data["linuxRejection"] = str(error)
        report.write_text(json.dumps(data, ensure_ascii=False, indent=2)+"\n")
        reports.append(data)
        print(name, "passed", "peak RSS MiB", round(rss/1024,1), "load ms", round(data["loadMs"],1), "RTFs", [round(r["rtf"],3) for r in data["runs"]], flush=True)
    summary = {"platform": platform.platform(), "processor": platform.processor(), "model": MANIFEST["id"], "modelBytes": MANIFEST["files"]["onnx/model_q4.onnx"]["size"],
               "dataset": "one CC0 reciter plus synthetic transformations; regression, not accuracy benchmark",
               "deviceVerified": False, "accuracyGroundTruth": False, "cases": reports}
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2)+"\n")


if __name__ == "__main__":
    main()
