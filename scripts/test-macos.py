#!/usr/bin/env python3
"""Run opt-in AppKit desktop checks on macOS (including Intel under Rosetta)."""
import os
from pathlib import Path
import subprocess
import sys


def main():
    if sys.platform != "darwin":
        raise SystemExit("this runner requires macOS")
    return subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests",
                           "-p", "test_native.py", "-v"],
                          cwd=Path(__file__).resolve().parents[1],
                          env={**os.environ, "UI_NATIVE_TESTS": "1"}, timeout=180).returncode


if __name__ == "__main__":
    raise SystemExit(main())
