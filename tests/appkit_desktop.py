"""Control the fixture's AppKit windows through a test-only main-thread helper."""
import json
import os
from pathlib import Path
import platform
import socket
import subprocess


class AppKitDesktop:
    def __init__(self, directory):
        directory = Path(directory)
        library = directory / "appkit_driver.dylib"
        target = os.environ.get("UI_TEST_TARGET")
        architecture = {"macos-x64": "x86_64", "macos-aarch64": "arm64"}.get(target, platform.machine())
        subprocess.run(["clang", "-dynamiclib", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        "-arch", architecture, "-framework", "Cocoa", "-o", str(library),
                        str(Path(__file__).with_name("appkit_driver.m"))], check=True, timeout=60)
        self.path = str(directory / "appkit.sock")
        self.environment = {"DYLD_INSERT_LIBRARIES": str(library), "UI_TEST_APPKIT_SOCKET": self.path}
        self.connection = None
        self.reader = None

    def command(self, action, **arguments):
        if self.connection is None:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(5)
            try:
                connection.connect(self.path)
            except (FileNotFoundError, ConnectionRefusedError):
                connection.close()
                if action == "find":
                    return None
                raise
            self.connection = connection
            self.reader = connection.makefile("rb")
        self.connection.sendall((json.dumps({"action": action, **arguments}) + "\n").encode())
        line = self.reader.readline()
        if not line:
            raise RuntimeError("AppKit fixture disconnected before acknowledging the command")
        response = json.loads(line)
        if "error" in response:
            raise RuntimeError(response["error"])
        return response["result"]

    def find(self, title):
        return self.command("find", title=title)

    def size(self, window):
        return tuple(self.command("size", window=window))

    def resize(self, window, width, height):
        self.command("resize", window=window, width=width, height=height)

    def close_window(self, window):
        self.command("close", window=window)

    def click(self, window, rect):
        x, y, width, height = rect
        for action in ("down", "up"):
            self.pointer(window, action, x + width // 2, y + height // 2)

    def pointer(self, window, action, x=0, y=0):
        self.command("pointer", window=window, kind=action, x=x, y=y)

    def pixel(self, window, x, y):
        return self.command("pixel", window=window, x=x, y=y)

    def wheel(self, window, rect, steps=1):
        x, y, width, height = rect
        for _ in range(abs(steps)):
            self.command("wheel", window=window, x=x + width // 2, y=y + height // 2,
                         steps=1 if steps > 0 else -1)

    def key_event(self, window, name, down=True, repeat=False, shift=False):
        self.command("key", window=window, name=name, down=down, repeat=repeat, shift=shift)

    def key(self, window, name, shift=False):
        self.key_event(window, name, shift=shift)
        self.key_event(window, name, down=False, shift=shift)

    def refocus(self, window):
        self.command("refocus", window=window)

    def close(self):
        if self.reader is not None:
            self.reader.close()
        if self.connection is not None:
            self.connection.close()
