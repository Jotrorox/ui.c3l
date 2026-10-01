#!/usr/bin/env python3
"""Install native C3 0.8.4 on Linux/Windows x64/ARM64, verified by SHA-256.

Linux ARM64 builds the pinned release source using CMake, Ninja and LLVM/LLD 19.
"""
import argparse
import hashlib
import os
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
    ("Linux", "x64"): ("c3-linux-static.tar.gz", "5e996d88feeddf8aca9bdd374233665c90bd3f57c4aec97d49f3dffc48ec54b6"),
    ("Windows", "x64"): ("c3-windows.zip", "9da56ed7b9302ce21737f6562a32dbcf28fb527507c0babcd37234526b5ac0d5"),
    ("Windows", "arm64"): ("c3-windows-aarch64.zip", "d5673f1bb708f4bba696f1ad8dd321c16572bed58e890b5f048241aa841dc1c8"),
}
SOURCE_COMMIT = "3c446b5af28f79cef0204c86fbd2c1c4a8b75d32"  # v0.8.4
SOURCE_SHA256 = "4c8cdf3e2bccbab47e1767858bc9481629ac13ec849126e71364d4e6f5398887"


def build_linux_source(source, destination, llvm_root=Path("/usr/lib/llvm-19")):
    build = source.parent / "build"
    subprocess.run(["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
                    "-DCMAKE_BUILD_TYPE=Release", "-DC3_LLVM_VERSION=auto",
                    f"-DLLVM_DIR={llvm_root / 'lib/cmake/llvm'}",
                    f"-DC3_LLD_INCLUDE_DIR={llvm_root / 'include'}"], check=True, timeout=120)
    subprocess.run(["cmake", "--build", str(build), "--target", "c3c", "--parallel",
                    str(min(os.cpu_count() or 1, 4))], check=True, timeout=900)
    destination.mkdir(parents=True)
    shutil.copy2(build / "c3c", destination / "c3c")
    shutil.copytree(build / "lib", destination / "lib")


def verify_compiler(executable, architecture):
    result = subprocess.check_output([str(executable.resolve()), "--version"], text=True, timeout=30)
    print(result, end="")
    if f"C3 Compiler Version:       {VERSION}" not in result:
        raise RuntimeError("installed compiler reports a different version")
    triple_arch = {"x64": "x86_64", "arm64": "aarch64"}[architecture]
    if f"LLVM default target:       {triple_arch}-" not in result:
        raise RuntimeError(f"installed compiler is not native {architecture}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", type=Path, required=True, help="new installation directory")
    args = parser.parse_args()
    architecture = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(
        platform.machine().lower())
    system = platform.system()
    from_source = (system, architecture) == ("Linux", "arm64")
    if not from_source and (system, architecture) not in ARCHIVES:
        parser.error("supported platforms are Linux/Windows x64 and ARM64")
    if args.dest.exists():
        parser.error("destination already exists; choose a new directory")
    if from_source:
        name, expected = "c3-source.tar.gz", SOURCE_SHA256
        url = f"https://codeload.github.com/c3lang/c3c/tar.gz/{SOURCE_COMMIT}"
    else:
        name, expected = ARCHIVES[system, architecture]
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
        executable = "c3c.exe" if system == "Windows" else "c3c"
        if from_source:
            build_linux_source(unpacked / f"c3c-{SOURCE_COMMIT}", args.dest)
        else:
            candidates = [path for path in unpacked.rglob(executable) if path.is_file()]
            if len(candidates) != 1:
                raise RuntimeError(f"unexpected archive layout: {candidates}")
            args.dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(candidates[0].parent, args.dest)
    verify_compiler(args.dest / executable, architecture)


if __name__ == "__main__":
    main()
