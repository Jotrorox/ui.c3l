"""Opt-in desktop test: UI_NATIVE_TESTS=1 python3 -m unittest discover -s tests -v.

Uses the OS APIs through ctypes only in the test driver. The Linux library and
example themselves do not link libX11. Works with Xvfb and with Windows desktops.
"""
import ctypes as c
from ctypes import wintypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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

    def close(self):
        self.api.XCloseDisplay(self.display)


class WindowsDesktop:
    def __init__(self):
        self.api = c.WinDLL("user32", use_last_error=True)
        self.api.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
        self.api.FindWindowW.restype = wintypes.HWND
        self.api.IsWindowVisible.argtypes = [wintypes.HWND]
        self.api.GetClientRect.argtypes = [wintypes.HWND, c.POINTER(wintypes.RECT)]
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

    def close(self):
        pass


@unittest.skipUnless(os.environ.get("UI_NATIVE_TESTS") == "1", "set UI_NATIVE_TESTS=1 to open test windows")
class NativeWindowTests(unittest.TestCase):
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
