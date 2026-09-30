"""Opt-in desktop test: UI_NATIVE_TESTS=1 python3 -m unittest discover -s tests -v.

Uses the OS APIs through ctypes only in the test driver. The Linux library and
example themselves do not link libX11. Works with Xvfb and with Windows desktops.
"""
import ctypes as c
from ctypes import wintypes
import os
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class XClientMessage(c.Structure):
    _fields_ = [("type", c.c_int), ("serial", c.c_ulong), ("send_event", c.c_int),
                ("display", c.c_void_p), ("window", c.c_ulong), ("message_type", c.c_ulong),
                ("format", c.c_int), ("data", c.c_long * 5)]


class XInputEvent(c.Structure):
    _fields_ = [("type", c.c_int), ("serial", c.c_ulong), ("send_event", c.c_int),
                ("display", c.c_void_p), ("window", c.c_ulong), ("root", c.c_ulong),
                ("subwindow", c.c_ulong), ("time", c.c_ulong), ("x", c.c_int), ("y", c.c_int),
                ("x_root", c.c_int), ("y_root", c.c_int), ("state", c.c_uint),
                ("detail", c.c_uint), ("same_screen", c.c_int)]


class XEvent(c.Union):
    _fields_ = [("client", XClientMessage), ("input", XInputEvent), ("pad", c.c_long * 24)]


XErrorHandler = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)


class X11Desktop:
    def __init__(self):
        self.api = c.CDLL("libX11.so.6")
        # Windows can disappear between tree enumeration and property reads.
        self.error_handler = XErrorHandler(lambda display, error: 0)
        self.api.XSetErrorHandler.argtypes = [XErrorHandler]
        self.api.XSetErrorHandler(self.error_handler)
        declarations = {
            "XOpenDisplay": ([c.c_char_p], c.c_void_p),
            "XDefaultRootWindow": ([c.c_void_p], c.c_ulong),
            "XQueryTree": ([c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                            c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)], c.c_int),
            "XFetchName": ([c.c_void_p, c.c_ulong, c.POINTER(c.c_void_p)], c.c_int),
            "XFree": ([c.c_void_p], c.c_int),
            "XGetGeometry": ([c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int),
                              c.POINTER(c.c_int), c.POINTER(c.c_uint), c.POINTER(c.c_uint),
                              c.POINTER(c.c_uint), c.POINTER(c.c_uint)], c.c_int),
            "XInternAtom": ([c.c_void_p, c.c_char_p, c.c_int], c.c_ulong),
            "XSendEvent": ([c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.POINTER(XEvent)], c.c_int),
            "XFlush": ([c.c_void_p], c.c_int),
            "XKeysymToKeycode": ([c.c_void_p, c.c_ulong], c.c_ubyte),
            "XResizeWindow": ([c.c_void_p, c.c_ulong, c.c_uint, c.c_uint], c.c_int),
            "XCloseDisplay": ([c.c_void_p], c.c_int),
        }
        for name, (args, result) in declarations.items():
            function = getattr(self.api, name)
            function.argtypes = args
            function.restype = result
        self.display = self.api.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("cannot connect to the test display")

    def find(self, title):
        pending = [self.api.XDefaultRootWindow(self.display)]
        while pending:
            window = pending.pop()
            name = c.c_void_p()
            if self.api.XFetchName(self.display, window, c.byref(name)) and name.value:
                try:
                    if c.string_at(name) == title.encode():
                        return window
                finally:
                    self.api.XFree(name)
            root, parent, count = c.c_ulong(), c.c_ulong(), c.c_uint()
            children = c.POINTER(c.c_ulong)()
            if self.api.XQueryTree(self.display, window, c.byref(root), c.byref(parent),
                                   c.byref(children), c.byref(count)):
                try:
                    pending.extend(children[index] for index in range(count.value))
                finally:
                    if children:
                        self.api.XFree(children)
        return None

    def size(self, window):
        root, x, y = c.c_ulong(), c.c_int(), c.c_int()
        width, height, border, depth = (c.c_uint() for _ in range(4))
        if not self.api.XGetGeometry(self.display, window, c.byref(root), c.byref(x), c.byref(y),
                                    c.byref(width), c.byref(height), c.byref(border), c.byref(depth)):
            raise RuntimeError("XGetGeometry failed")
        return width.value, height.value

    def close_window(self, window):
        event = XEvent()
        event.client = XClientMessage(33, 0, 1, self.display, window,
                                      self.api.XInternAtom(self.display, b"WM_PROTOCOLS", 0),
                                      32, (c.c_long * 5)(self.api.XInternAtom(self.display, b"WM_DELETE_WINDOW", 0)))
        if not self.api.XSendEvent(self.display, window, 0, 0, c.byref(event)):
            raise RuntimeError("XSendEvent failed")
        self.api.XFlush(self.display)

    def click_and_activate(self, window):
        for kind, detail, mask in ((4, 1, 1 << 2), (5, 1, 1 << 3),
                                   (2, self.api.XKeysymToKeycode(self.display, 0x20), 1)):
            event = XEvent()
            event.input = XInputEvent(type=kind, display=self.display, window=window,
                                      root=self.api.XDefaultRootWindow(self.display),
                                      x=20, y=20, detail=detail, same_screen=1)
            if not self.api.XSendEvent(self.display, window, 0, mask, c.byref(event)):
                raise RuntimeError("XSendEvent failed")
        self.api.XFlush(self.display)

    def input(self, window, kind, detail, x=0, y=0):
        event = XEvent()
        event.input = XInputEvent(type=kind, display=self.display, window=window,
                                  root=self.api.XDefaultRootWindow(self.display),
                                  x=x, y=y, detail=detail, same_screen=1)
        mask = {2: 1, 4: 1 << 2, 5: 1 << 3}[kind]
        if not self.api.XSendEvent(self.display, window, 0, mask, c.byref(event)):
            raise RuntimeError("XSendEvent failed")
        self.api.XFlush(self.display)

    def click(self, window, rect):
        x, y, width, height = rect
        self.input(window, 4, 1, x + width // 2, y + height // 2)
        self.input(window, 5, 1, x + width // 2, y + height // 2)

    def key(self, window, name):
        symbol = {"Tab": 0xFF09, "Return": 0xFF0D, "Space": 0x20}[name]
        code = self.api.XKeysymToKeycode(self.display, symbol)
        if not code:
            raise RuntimeError(f"no key mapped for {name}")
        self.input(window, 2, code)

    def resize(self, window, width, height):
        self.api.XResizeWindow(self.display, window, width, height)
        self.api.XFlush(self.display)

    def close(self):
        self.api.XCloseDisplay(self.display)


class WindowsDesktop:
    def __init__(self):
        self.api = c.WinDLL("user32", use_last_error=True)
        self.api.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
        self.api.FindWindowW.restype = wintypes.HWND
        self.api.IsWindowVisible.argtypes = [wintypes.HWND]
        self.api.GetClientRect.argtypes = [wintypes.HWND, c.POINTER(wintypes.RECT)]
        self.api.GetWindowRect.argtypes = [wintypes.HWND, c.POINTER(wintypes.RECT)]
        self.api.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, c.c_int, c.c_int,
                                         c.c_int, c.c_int, wintypes.UINT]
        self.api.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]

    def find(self, title):
        window = self.api.FindWindowW("ui.c3l.window", title)
        return window if window and self.api.IsWindowVisible(window) else None

    def size(self, window):
        rect = wintypes.RECT()
        if not self.api.GetClientRect(window, c.byref(rect)):
            raise c.WinError(c.get_last_error())
        return rect.right - rect.left, rect.bottom - rect.top

    def close_window(self, window):
        if not self.api.PostMessageW(window, 0x10, 0, 0):  # WM_CLOSE
            raise c.WinError(c.get_last_error())

    def click_and_activate(self, window):
        for message, wparam, lparam in ((0x201, 1, 20 | (20 << 16)),
                                         (0x202, 0, 20 | (20 << 16)), (0x100, 32, 0)):
            if not self.api.PostMessageW(window, message, wparam, lparam):
                raise c.WinError(c.get_last_error())

    def click(self, window, rect):
        x, y, width, height = rect
        position = (x + width // 2) | ((y + height // 2) << 16)
        for message, wparam in ((0x201, 1), (0x202, 0)):
            if not self.api.PostMessageW(window, message, wparam, position):
                raise c.WinError(c.get_last_error())

    def key(self, window, name):
        key = {"Tab": 9, "Return": 13, "Space": 32}[name]
        if not self.api.PostMessageW(window, 0x100, key, 0):
            raise c.WinError(c.get_last_error())

    def resize(self, window, width, height):
        rect = wintypes.RECT()
        if not self.api.GetWindowRect(window, c.byref(rect)):
            raise c.WinError(c.get_last_error())
        old_width, old_height = self.size(window)
        width += rect.right - rect.left - old_width
        height += rect.bottom - rect.top - old_height
        if not self.api.SetWindowPos(window, None, 0, 0, width, height, 0x16):
            raise c.WinError(c.get_last_error())

    def close(self):
        pass


@unittest.skipUnless(os.environ.get("UI_NATIVE_TESTS") == "1", "set UI_NATIVE_TESTS=1 to open test windows")
class NativeWindowTests(unittest.TestCase):
    def test_nested_input_resize_clipping_and_subtree_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            suffix = ".exe" if sys.platform == "win32" else ""
            binary = Path(directory) / ("nested_window_test" + suffix)
            subprocess.run(["c3c", "compile", str(ROOT / "tests/fixtures/nested_window.c3"),
                            "--libdir", str(ROOT.parent), "--lib", "ui", "-o", str(binary),
                            "--obj-out", directory], check=True)
            desktop = WindowsDesktop() if sys.platform == "win32" else X11Desktop()
            try:
                with subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True) as process:
                    lines = queue.Queue()

                    def read_lines():
                        for line in process.stdout:
                            lines.put(line)

                    reader = threading.Thread(target=read_lines, daemon=True)
                    reader.start()

                    def snapshot():
                        try:
                            return json.loads(lines.get(timeout=5))
                        except queue.Empty:
                            self.fail(f"nested fixture did not report geometry (exit={process.poll()})")

                    try:
                        deadline = time.monotonic() + 5
                        window = None
                        while time.monotonic() < deadline and process.poll() is None:
                            window = desktop.find("ui nested test")
                            if window:
                                break
                            time.sleep(0.02)
                        self.assertTrue(window, "nested window did not appear")
                        # Ask the fixture for geometry after native measurement and placement.
                        desktop.key(window, "Tab")
                        desktop.key(window, "Return")
                        initial = snapshot()
                        self.assertEqual(initial["count"], 0)
                        self.assertGreater(initial["action"][2], 0)
                        desktop.click(window, initial["action"])
                        state = snapshot()
                        self.assertEqual((state["count"], state["label"]), (1, "Count: 1"))
                        # Use the clipped origin: the overflowing lower portion can
                        # overlap the separate, visible removal button.
                        desktop.click(window, (*initial["hidden"][:2], 1, 1))
                        desktop.click(window, initial["inspect"])
                        state = snapshot()
                        self.assertEqual(state["hidden_clicks"], 0)
                        self.assertTrue(state["alive"])

                        # Confirm descendant activation before asking the window manager
                        # to resize; native resize and posted input may arrive separately.
                        desktop.key(window, "Tab")
                        desktop.key(window, "Space")
                        self.assertEqual(snapshot()["count"], 2)
                        narrow = initial["action_bounds"][0]
                        desktop.resize(window, narrow, initial["viewport"][1])
                        deadline = time.monotonic() + 5
                        while desktop.size(window)[0] != narrow and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertEqual(desktop.size(window)[0], narrow)
                        desktop.key(window, "Return")
                        desktop.key(window, "Tab")
                        desktop.key(window, "Return")
                        clipped = snapshot()
                        self.assertEqual(clipped["count"], 2, clipped)
                        self.assertEqual(clipped["action"][2], 0)
                        desktop.resize(window, *initial["viewport"])
                        deadline = time.monotonic() + 5
                        while desktop.size(window) != tuple(initial["viewport"]) and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertEqual(desktop.size(window), tuple(initial["viewport"]))
                        desktop.click(window, initial["inspect"])
                        restored = snapshot()
                        self.assertEqual(restored["action"], initial["action"])
                        desktop.click(window, restored["action"])
                        self.assertEqual(snapshot()["count"], 3)
                        desktop.click(window, restored["remove"])
                        desktop.click(window, restored["inspect"])
                        removed = snapshot()
                        self.assertEqual(removed["count"], 4)
                        self.assertFalse(removed["alive"] or removed["subscribed"] or removed["pending"])
                        desktop.click(window, initial["action"])
                        desktop.click(window, removed["inspect"])
                        self.assertEqual(snapshot()["count"], 4)
                        desktop.close_window(window)
                        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=5)
                        reader.join(timeout=5)
            finally:
                desktop.close()

    def test_reactive_widgets_draw_and_receive_input(self):
        with tempfile.TemporaryDirectory() as directory:
            suffix = ".exe" if sys.platform == "win32" else ""
            binary = Path(directory) / ("reactive_window_test" + suffix)
            subprocess.run(["c3c", "compile", str(ROOT / "tests/fixtures/reactive_window.c3"),
                            "--libdir", str(ROOT.parent), "--lib", "ui", "-o", str(binary),
                            "--obj-out", directory], check=True)
            desktop = WindowsDesktop() if sys.platform == "win32" else X11Desktop()
            try:
                with subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                    try:
                        deadline = time.monotonic() + 5
                        window = None
                        while time.monotonic() < deadline:
                            if process.poll() is not None:
                                self.fail(f"window exited early: {process.communicate()}")
                            window = desktop.find("ui reactive test")
                            if window:
                                break
                            time.sleep(0.02)
                        self.assertTrue(window, "reactive window did not appear")
                        desktop.click_and_activate(window)
                        desktop.close_window(window)
                        stdout, stderr = process.communicate(timeout=5)
                        self.assertEqual(process.returncode, 0, stdout + stderr)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.communicate()
            finally:
                desktop.close()

    def test_title_client_size_close_and_reopen(self):
        with tempfile.TemporaryDirectory() as directory:
            suffix = ".exe" if sys.platform == "win32" else ""
            binary = Path(directory) / ("native_window_test" + suffix)
            subprocess.run(["c3c", "compile", str(ROOT / "tests/fixtures/native_window.c3"),
                            "--libdir", str(ROOT.parent), "--lib", "ui", "-o", str(binary),
                            "--obj-out", directory], check=True)
            desktop = WindowsDesktop() if sys.platform == "win32" else X11Desktop()
            try:
                with subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                    try:
                        for index in range(2):
                            deadline = time.monotonic() + 5
                            window = None
                            while time.monotonic() < deadline:
                                if process.poll() is not None:
                                    self.fail(f"window exited early: {process.communicate()}")
                                window = desktop.find(f"ui native test {index} — 世界")
                                if window:
                                    break
                                time.sleep(0.02)
                            self.assertTrue(window, "native window did not appear")
                            self.assertEqual(desktop.size(window), (321, 234))
                            desktop.close_window(window)
                        stdout, stderr = process.communicate(timeout=5)
                        self.assertEqual(process.returncode, 0, stdout + stderr)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.communicate()
            finally:
                desktop.close()


if __name__ == "__main__":
    unittest.main()
