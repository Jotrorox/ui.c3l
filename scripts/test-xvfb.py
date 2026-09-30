#!/usr/bin/env python3
"""Run desktop tests on a fresh isolated Xvfb; never use the desktop's DISPLAY."""
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    executable = shutil.which("Xvfb")
    if not executable:
        raise SystemExit("Xvfb is required; install xvfb and libX11 test libraries, then retry")
    with tempfile.TemporaryDirectory(prefix="ui-c3-xvfb-") as directory:
        log_path = Path(directory) / "Xvfb.log"
        read_fd, write_fd = os.pipe()
        with log_path.open("wb") as log:
            server = subprocess.Popen([executable, "-displayfd", str(write_fd), "-screen", "0",
                                       "1024x768x24", "-nolisten", "tcp", "-noreset"],
                                      pass_fds=(write_fd,), stdout=log, stderr=log)
        os.close(write_fd)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(read_fd, selectors.EVENT_READ)
                if not selector.select(timeout=10):
                    raise RuntimeError("Xvfb did not report a display within 10 seconds")
                display = os.read(read_fd, 32).decode().strip()
            if not display.isdecimal() or server.poll() is not None:
                raise RuntimeError(f"Xvfb failed to start: {display!r}")
            print(f"Native tests on isolated Xvfb :{display}", flush=True)
            environment = {**os.environ, "DISPLAY": f":{display}", "XAUTHORITY": str(Path(directory) / "no-authority"),
                           "UI_NATIVE_TESTS": "1", "UI_TEST_ISOLATED_X11": "1"}
            result = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
                                    cwd=ROOT, env=environment, timeout=180)
            if result.returncode:
                raise RuntimeError(f"desktop tests failed (exit {result.returncode})")
        except BaseException:
            print(log_path.read_text(errors="replace"), file=sys.stderr)
            raise
        finally:
            os.close(read_fd)
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)


if __name__ == "__main__":
    main()
