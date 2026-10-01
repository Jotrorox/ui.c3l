#!/usr/bin/env python3
"""Run opt-in native tests when the Windows runner exposes an input desktop."""
import ctypes as c
from ctypes import wintypes
import os
from pathlib import Path
import subprocess
import sys


def main():
    if sys.platform != "win32":
        raise SystemExit("this runner requires Windows")
    api = c.WinDLL("user32", use_last_error=True)
    api.OpenInputDesktop.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    api.OpenInputDesktop.restype = wintypes.HANDLE
    api.CloseDesktop.argtypes = [wintypes.HANDLE]
    desktop = api.OpenInputDesktop(0, False, 1)  # DESKTOP_READOBJECTS
    if not desktop:
        print(f"::warning::Native Windows tests skipped: no accessible input desktop (error {c.get_last_error()}).")
        return 0
    api.CloseDesktop(desktop)
    print("Input desktop available; running native Windows tests", flush=True)
    return subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests",
                           "-p", "test_native.py", "-v"],
                          cwd=Path(__file__).resolve().parents[1],
                          env={**os.environ, "UI_NATIVE_TESTS": "1"}, timeout=180).returncode


if __name__ == "__main__":
    raise SystemExit(main())
