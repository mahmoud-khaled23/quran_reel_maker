"""Explicit model installation; inference never downloads anything."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((Path(__file__).parent / "model_manifest.json").read_text())
DEFAULT_MODEL = ROOT / ".alignment-models" / MANIFEST["id"]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(directory):
    for name, expected in MANIFEST["files"].items():
        path = directory / name
        if not path.is_file():
            raise ValueError(f"Missing model file {name}. Run ./scripts/setup-alignment.sh.")
        if path.stat().st_size != expected["size"] or digest(path) != expected["sha256"]:
            raise ValueError(f"Model integrity failed: {name}. Run ./scripts/setup-alignment.sh to repair it.")


def download(directory):
    for name, expected in MANIFEST["files"].items():
        path = directory / name
        if path.is_file() and path.stat().st_size == expected["size"] and digest(path) == expected["sha256"]:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".part")
        url = f"https://huggingface.co/{MANIFEST['repository']}/resolve/{MANIFEST['revision']}/{name}"
        print(f"Downloading {name} ({expected['size']} bytes)", flush=True)
        try:
            with urllib.request.urlopen(url, timeout=120) as source, temporary.open("wb") as target:
                while block := source.read(1024 * 1024):
                    target.write(block)
            if temporary.stat().st_size != expected["size"] or digest(temporary) != expected["sha256"]:
                raise ValueError(f"Downloaded file failed integrity verification: {name}")
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    verify(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL)
    args = parser.parse_args()
    download(args.model_dir)
    print(f"Verified {MANIFEST['id']} at {args.model_dir}. Inference is now offline.")
