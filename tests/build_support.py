"""Compile integration fixtures with the target and optimization selected by CI."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def compiler_flags():
    profile = os.environ.get("UI_TEST_OPTIMIZATION", "debug")
    if profile not in ("debug", "release"):
        raise ValueError("UI_TEST_OPTIMIZATION must be debug or release")
    flags = ["-O3" if profile == "release" else "-O0"]
    if sys.platform == "darwin":
        # Apple's linker supports the current SDK for both ARM64 and Rosetta.
        flags.append("--linker=cc")
    target = os.environ.get("UI_TEST_TARGET")
    if target:
        flags.extend(["--target", target])
    return flags


def compile_fixture(name, directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    suffix = ".exe" if sys.platform == "win32" else ""
    binary = directory / (name + suffix)
    subprocess.run(["c3c", "compile", str(ROOT / "tests/fixtures" / (name + ".c3")),
                    *compiler_flags(), "--libdir", str(ROOT.parent), "--lib", "ui",
                    "-o", str(binary), "--obj-out", str(directory)],
                   cwd=ROOT, check=True, timeout=60)
    return binary
