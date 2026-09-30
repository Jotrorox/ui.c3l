#!/usr/bin/env python3
"""Install official C3 0.8.4 release archives, verified against pinned SHA-256."""
import argparse
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

VERSION = "0.8.4"
# Digests from https://api.github.com/repos/c3lang/c3c/releases/tags/v0.8.4
ARCHIVES = {
    "Linux": ("c3-linux-static.tar.gz", "5e996d88feeddf8aca9bdd374233665c90bd3f57c4aec97d49f3dffc48ec54b6"),
    "Windows": ("c3-windows.zip", "9da56ed7b9302ce21737f6562a32dbcf28fb527507c0babcd37234526b5ac0d5"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", type=Path, required=True, help="new installation directory")
    args = parser.parse_args()
    if platform.machine().lower() not in ("x86_64", "amd64") or platform.system() not in ARCHIVES:
        parser.error("these pinned archives support Linux/Windows x64")
    if args.dest.exists():
        parser.error("destination already exists; choose a new directory")
    name, expected = ARCHIVES[platform.system()]
    url = f"https://github.com/c3lang/c3c/releases/download/v{VERSION}/{name}"
    with tempfile.TemporaryDirectory() as temp:
        archive = Path(temp) / name
        print(f"Downloading {url}", flush=True)
        with urllib.request.urlopen(url, timeout=60) as source, archive.open("wb") as target:
            shutil.copyfileobj(source, target)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != expected:
            raise RuntimeError(f"SHA-256 mismatch: expected {expected}, received {digest}")
        unpacked = Path(temp) / "unpacked"
        if name.endswith(".zip"):
            with zipfile.ZipFile(archive) as source:
                source.extractall(unpacked)
        else:
            with tarfile.open(archive) as source:
                source.extractall(unpacked, filter="data")
        executable = "c3c.exe" if platform.system() == "Windows" else "c3c"
        candidates = list(unpacked.rglob(executable))
        if len(candidates) != 1:
            raise RuntimeError(f"unexpected archive layout: {candidates}")
        args.dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(candidates[0].parent, args.dest)
    result = subprocess.check_output([str(args.dest.resolve() / executable), "--version"], text=True)
    print(result, end="")
    if f"C3 Compiler Version:       {VERSION}" not in result:
        raise RuntimeError("installed compiler reports a different version")


if __name__ == "__main__":
    main()
