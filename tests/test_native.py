"""Opt-in desktop test: UI_NATIVE_TESTS=1 python3 -m unittest discover -s tests -v.

Uses the OS APIs through ctypes only in the test driver. The Linux library and
example themselves do not link libX11. Works with Xvfb and with Windows desktops.
"""
import ctypes as c
from contextlib import contextmanager
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
        self.event_time = 1000
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
            "XDisplayKeycodes": ([c.c_void_p, c.POINTER(c.c_int), c.POINTER(c.c_int)], c.c_int),
            "XGetKeyboardMapping": ([c.c_void_p, c.c_ubyte, c.c_int, c.POINTER(c.c_int)], c.POINTER(c.c_ulong)),
            "XChangeKeyboardMapping": ([c.c_void_p, c.c_int, c.c_int, c.POINTER(c.c_ulong), c.c_int], c.c_int),
            "XSync": ([c.c_void_p, c.c_int], c.c_int),
            "XSetInputFocus": ([c.c_void_p, c.c_ulong, c.c_int, c.c_ulong], c.c_int),
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

    def input(self, window, kind, detail, x=0, y=0, timestamp=None, shift=False):
        event = XEvent()
        event.input = XInputEvent(type=kind, display=self.display, window=window,
                                  root=self.api.XDefaultRootWindow(self.display),
                                  time=self.event_time if timestamp is None else timestamp,
                                  state=int(shift), x=x, y=y, detail=detail, same_screen=1)
        self.event_time += 10
        mask = {2: 1, 3: 1 << 1, 4: 1 << 2, 5: 1 << 3}[kind]
        if not self.api.XSendEvent(self.display, window, 0, mask, c.byref(event)):
            raise RuntimeError("XSendEvent failed")
        self.api.XFlush(self.display)

    def click(self, window, rect):
        x, y, width, height = rect
        self.input(window, 4, 1, x + width // 2, y + height // 2)
        self.input(window, 5, 1, x + width // 2, y + height // 2)

    def wheel(self, window, rect, steps=1):
        x, y, width, height = rect
        for _ in range(abs(steps)):
            for kind in (4, 5):
                self.input(window, kind, 5 if steps > 0 else 4,
                           x + width // 2, y + height // 2)

    def key_event(self, window, name, down=True, repeat=False, shift=False):
        symbol = {"Tab": 0xFF09, "Return": 0xFF0D, "Space": 0x20}[name]
        first, stride, symbols = self.keyboard_mapping()
        code = next((first + index // stride for index, value in enumerate(symbols)
                     if value == symbol and index % stride == 0), 0)
        if not code:
            raise RuntimeError(f"no key mapped for {name}")
        if repeat:  # Core X11 autorepeat release/press share one server timestamp.
            timestamp = self.event_time
            self.input(window, 3, code, timestamp=timestamp)
            self.input(window, 2, code, timestamp=timestamp, shift=shift)
        else:
            self.input(window, 2 if down else 3, code, shift=shift)

    def key(self, window, name, shift=False):
        self.key_event(window, name, shift=shift)
        self.key_event(window, name, down=False, shift=shift)

    def keyboard_mapping(self):
        first, last, stride = c.c_int(), c.c_int(), c.c_int()
        self.api.XDisplayKeycodes(self.display, c.byref(first), c.byref(last))
        mapping = self.api.XGetKeyboardMapping(self.display, first.value,
                                               last.value - first.value + 1, c.byref(stride))
        if not mapping:
            raise RuntimeError("XGetKeyboardMapping failed")
        try:
            return first.value, stride.value, list(mapping[:(last.value - first.value + 1) * stride.value])
        finally:
            self.api.XFree(mapping)

    @contextmanager
    def swapped_mapping(self):
        if os.environ.get("UI_TEST_ISOLATED_X11") != "1":
            raise RuntimeError("keyboard map edits require the isolated Xvfb runner")
        first, stride, original = self.keyboard_mapping()

        def apply(symbols):
            self.api.XChangeKeyboardMapping(self.display, first, stride,
                                            (c.c_ulong * len(symbols))(*symbols), len(symbols) // stride)
            self.api.XSync(self.display, 0)

        try:
            apply([{0xFF0D: 0x20, 0x20: 0xFF0D}.get(value, value) for value in original])
            yield
        finally:
            apply(original)

    def refocus(self, window):
        self.api.XSetInputFocus(self.display, self.api.XDefaultRootWindow(self.display), 1, 0)
        self.api.XSetInputFocus(self.display, window, 1, 0)
        self.api.XSync(self.display, 0)

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
        self.api.ClientToScreen.argtypes = [wintypes.HWND, c.POINTER(wintypes.POINT)]

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

    def click(self, window, rect):
        x, y, width, height = rect
        position = (x + width // 2) | ((y + height // 2) << 16)
        for message, wparam in ((0x201, 1), (0x202, 0)):
            if not self.api.PostMessageW(window, message, wparam, position):
                raise c.WinError(c.get_last_error())

    def wheel_delta(self, window, rect, delta):
        x, y, width, height = rect
        point = wintypes.POINT(x + width // 2, y + height // 2)
        if not self.api.ClientToScreen(window, c.byref(point)):
            raise c.WinError(c.get_last_error())
        position = (point.x & 0xFFFF) | ((point.y & 0xFFFF) << 16)
        if not self.api.PostMessageW(window, 0x20A, (delta & 0xFFFF) << 16, position):
            raise c.WinError(c.get_last_error())

    def wheel(self, window, rect, steps=1):
        for _ in range(abs(steps)):
            self.wheel_delta(window, rect, -120 if steps > 0 else 120)

    def key_event(self, window, name, down=True, repeat=False):
        key = {"Tab": 9, "Return": 13, "Space": 32}[name]
        scan = {"Tab": 0x0F, "Return": 0x1C, "Space": 0x39}[name]
        flags = 1 | (scan << 16) | ((1 << 30) if repeat or not down else 0) | ((1 << 31) if not down else 0)
        if not self.api.PostMessageW(window, 0x100 if down else 0x101, key, flags):
            raise c.WinError(c.get_last_error())

    def key(self, window, name):
        self.key_event(window, name)
        self.key_event(window, name, down=False)

    def refocus(self, window):
        # Exercise native focus messages without stealing the user's desktop.
        for message in (8, 7):
            if not self.api.PostMessageW(window, message, 0, 0):
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
    @contextmanager
    def fixture(self, name, title, reopen=False):
        with tempfile.TemporaryDirectory() as directory:
            suffix = ".exe" if sys.platform == "win32" else ""
            binary = Path(directory) / (name + suffix)
            subprocess.run(["c3c", "compile", str(ROOT / "tests/fixtures" / (name + ".c3")),
                            "--libdir", str(ROOT.parent), "--lib", "ui", "-o", str(binary),
                            "--obj-out", directory], check=True)
            desktop = WindowsDesktop() if sys.platform == "win32" else X11Desktop()
            try:
                with subprocess.Popen([str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      env={**os.environ, "UI_TEST_REOPEN": "1" if reopen else "0"},
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
                            self.fail(f"{name} did not report geometry (exit={process.poll()})")

                    try:
                        deadline = time.monotonic() + 5
                        window = None
                        while time.monotonic() < deadline and process.poll() is None:
                            window = desktop.find(title)
                            if window:
                                break
                            time.sleep(0.02)
                        self.assertTrue(window, f"{name} window did not appear")
                        yield desktop, window, snapshot
                        if reopen:
                            window = desktop.find("ui keyboard test 1")
                            self.assertTrue(window, "reopened keyboard window missing")
                        desktop.close_window(window)
                        self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=5)
                        reader.join(timeout=5)
            finally:
                desktop.close()

    def test_nested_wheel_boundary_bubbling_stale_clicks_and_focus_reveal(self):
        with self.fixture("scroll_window", "ui scroll test") as (desktop, window, snapshot):
            desktop.key(window, "Tab")
            desktop.key(window, "Return")
            initial = snapshot()
            self.assertEqual((initial["inner_offset"], initial["outer_offset"]), (0, 0))
            self.assertEqual(initial["last"][3], 0)

            def inspect():
                desktop.click(window, initial["inspect"])
                state = snapshot()
                self.assertEqual(state["source"], "inspect", state)
                return state

            desktop.wheel(window, initial["first"])
            moved = inspect()
            self.assertEqual((moved["inner_offset"], moved["outer_offset"]), (40, 0))
            self.assertEqual(moved["first_clicks"], 0)
            desktop.click(window, initial["first"])
            self.assertEqual(inspect()["first_clicks"], 0)
            desktop.wheel(window, initial["first"], steps=3)
            bottom = inspect()
            self.assertEqual(bottom["inner_offset"], bottom["inner_extent"])
            self.assertEqual(bottom["outer_offset"], 0)  # Last partial step is consumed once.
            desktop.wheel(window, initial["first"])
            bubbled = inspect()
            self.assertEqual((bubbled["inner_offset"], bubbled["outer_offset"]),
                             (bottom["inner_extent"], 40))
            desktop.wheel(window, bubbled["inner"], steps=-1)
            reverse = inspect()
            self.assertEqual((reverse["inner_offset"], reverse["outer_offset"]),
                             (bottom["inner_extent"] - 40, 40))

            desktop.click(window, initial["reset"])
            self.assertEqual(snapshot()["source"], "reset")
            desktop.key(window, "Tab")  # First.
            desktop.key(window, "Tab")  # Last, initially fully clipped.
            desktop.key_event(window, "Return")
            revealed = snapshot()
            self.assertEqual((revealed["source"], revealed["last_clicks"]), ("last", 1))
            self.assertTrue(revealed["focused_last"])
            self.assertEqual(revealed["inner_offset"], revealed["inner_extent"])
            self.assertGreater(revealed["last"][3], 0)
            desktop.key_event(window, "Return", repeat=True)
            desktop.key(window, "Tab")  # Tail needs the outer viewport to scroll.
            desktop.key_event(window, "Return", repeat=True)
            desktop.key_event(window, "Return", down=False)
            desktop.key(window, "Return")
            tail = snapshot()
            self.assertEqual((tail["source"], tail["last_clicks"], tail["tail_clicks"]),
                             ("tail", 1, 1))
            self.assertTrue(tail["focused_tail"])
            self.assertEqual(tail["outer_offset"], tail["outer_extent"])
            self.assertGreater(tail["tail"][3], 0)

    @unittest.skipUnless(sys.platform == "win32", "native Windows wheel delta messages only")
    def test_windows_partial_wheel_deltas_use_screen_coordinates(self):
        with self.fixture("scroll_window", "ui scroll test") as (desktop, window, snapshot):
            desktop.key(window, "Tab")
            desktop.key(window, "Return")
            initial = snapshot()
            for _ in range(3):
                desktop.wheel_delta(window, initial["first"], -1)
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["inner_offset"], 1)
            desktop.wheel_delta(window, initial["first"], -57)
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["inner_offset"], 20)
            desktop.wheel_delta(window, initial["first"], 60)
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["inner_offset"], 0)

    def test_keyboard_repeats_focus_and_reopen(self):
        with self.fixture("keyboard_window", "ui keyboard test 0", reopen=True) as (desktop, window, snapshot):
            desktop.key(window, "Tab")
            desktop.key(window, "Return")
            initial = snapshot()
            desktop.key(window, "Tab")
            desktop.key_event(window, "Return")
            desktop.key_event(window, "Return", repeat=True)
            desktop.key_event(window, "Return", repeat=True)
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["clicks"], 1)
            desktop.key(window, "Tab")  # Focus Button while Return remains held.
            desktop.key_event(window, "Return", repeat=True)
            desktop.key_event(window, "Return", down=False)
            desktop.key_event(window, "Return")
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["clicks"], 2)
            desktop.key(window, "Tab")
            desktop.key(window, "Tab")
            desktop.key_event(window, "Space")
            desktop.key_event(window, "Space", repeat=True)
            desktop.key_event(window, "Space", down=False)
            desktop.key_event(window, "Space")
            desktop.click(window, initial["inspect"])
            state = snapshot()
            self.assertEqual((state["changes"], state["checked"]), (2, False))
            desktop.refocus(window)
            desktop.key(window, "Tab")  # Focus restarts at Inspect.
            desktop.key_event(window, "Return", repeat=True)
            desktop.key_event(window, "Return", down=False)
            desktop.key(window, "Return")
            self.assertEqual(snapshot()["clicks"], 2)  # No extra snapshot from repeat.
            # Close with both activation keys held; reuse the very same View.
            desktop.key_event(window, "Return")
            self.assertEqual(snapshot()["clicks"], 2)
            desktop.key_event(window, "Space")
            self.assertEqual(snapshot()["clicks"], 2)
            desktop.close_window(window)
            deadline = time.monotonic() + 5
            reopened = None
            while time.monotonic() < deadline:
                reopened = desktop.find("ui keyboard test 1")
                if reopened:
                    break
                time.sleep(0.02)
            self.assertTrue(reopened, "keyboard View did not reopen")
            desktop.key(reopened, "Tab")
            desktop.key(reopened, "Return")
            self.assertEqual(snapshot()["generation"], 1)
            desktop.key(reopened, "Tab")
            desktop.key(reopened, "Space")
            desktop.click(reopened, initial["inspect"])
            self.assertEqual(snapshot()["clicks"], 3)

    @unittest.skipUnless(sys.platform.startswith("linux") and os.environ.get("UI_TEST_ISOLATED_X11") == "1",
                         "mapping edits require scripts/test-xvfb.py")
    def test_live_server_keyboard_mapping_change(self):
        with self.fixture("keyboard_window", "ui keyboard test 0") as (desktop, window, snapshot):
            desktop.key(window, "Tab")
            desktop.key(window, "Return")
            initial = snapshot()
            with desktop.swapped_mapping():
                desktop.key(window, "Tab")
                desktop.key(window, "Return")
                desktop.key(window, "Tab")
                desktop.key(window, "Space")
                desktop.click(window, initial["inspect"])
                state = snapshot()
                self.assertEqual((state["clicks"], state["changes"], state["checked"]), (1, 1, True))
            desktop.key(window, "Tab")
            desktop.key(window, "Return")
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["clicks"], 2)

    def test_checkbox_properties_visibility_and_native_activation(self):
        with self.fixture("checkbox_window", "ui checkbox test") as (desktop, window, snapshot):
            desktop.key(window, "Tab")
            desktop.key(window, "Return")
            initial = snapshot()
            self.assertEqual(initial["label"], "Value: 0")
            self.assertTrue(initial["shown"] and initial["enabled"])
            desktop.click(window, initial["bound"])
            state = snapshot()
            self.assertEqual((state["checked"], state["changes"]), (True, 1))
            desktop.key(window, "Space")
            state = snapshot()
            self.assertEqual((state["checked"], state["changes"]), (False, 2))
            desktop.key(window, "Return")  # Enter explicitly toggles, too.
            state = snapshot()
            self.assertEqual((state["checked"], state["changes"]), (True, 3))
            desktop.click(window, initial["owned"])
            state = snapshot()
            self.assertEqual((state["owned_checked"], state["own_changes"]), (True, 1))
            self.assertEqual(initial["clipped"][2:4], [0, 0])
            desktop.click(window, (*initial["clipped_bounds"][:2], 1, 1))
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["clipped_changes"], 0)

            desktop.click(window, initial["show"])
            hidden = snapshot()
            self.assertFalse(hidden["shown"])
            self.assertEqual(hidden["bound"][2:4], [0, 0])
            self.assertLess(hidden["footer"][1], initial["footer"][1])
            desktop.click(window, hidden["mutate"])
            state = snapshot()
            self.assertEqual((state["label"], state["checked"], state["changes"]), ("Value: 1", False, 3))
            desktop.click(window, hidden["show"])
            restored = snapshot()
            self.assertEqual(restored["bound"], initial["bound"])
            self.assertEqual(restored["footer"], initial["footer"])
            self.assertEqual(restored["label"], "Value: 1")
            self.assertTrue(restored["owned_checked"])
            desktop.key(window, "Space")
            self.assertFalse(snapshot()["shown"])
            desktop.key(window, "Return")
            self.assertTrue(snapshot()["shown"])

            desktop.click(window, initial["enable"])
            self.assertFalse(snapshot()["enabled"])
            desktop.click(window, initial["bound"])
            desktop.click(window, initial["inspect"])
            self.assertEqual(snapshot()["changes"], 3)
            for _ in range(4):  # Skip all disabled descendants and wrap to Inspect.
                desktop.key(window, "Tab")
            desktop.key(window, "Return")
            self.assertFalse(snapshot()["enabled"])
            desktop.click(window, initial["enable"])
            self.assertTrue(snapshot()["enabled"])
            desktop.click(window, initial["bound"])
            self.assertEqual(snapshot()["changes"], 4)
            desktop.key(window, "Tab")
            desktop.key(window, "Space")
            self.assertFalse(snapshot()["owned_checked"])
            desktop.key(window, "Tab")
            desktop.key(window, "Space")  # Checkbox callback removes its own ancestor.
            removed = snapshot()
            self.assertFalse(removed["alive"] or removed["pending"])
            desktop.click(window, removed["mutate"])
            self.assertEqual(snapshot()["count"], 3)

    def test_alignment_stretch_resize_and_reactive_input(self):
        with self.fixture("alignment_window", "ui alignment test") as (desktop, window, snapshot):
            def read(source):
                state = snapshot()
                self.assertEqual(state["source"], source, state)
                return state

            def check_geometry(state):
                panel, summary, text = state["panel"], state["summary"], state["text"]
                actions, action = state["actions"], state["action"]
                # Root padding and panel padding are fixture inputs; every font
                # dimension comes from the native backend's actual geometry.
                self.assertEqual((panel[0], panel[2]), (16, state["viewport"][0] - 32))
                self.assertEqual(summary[0], panel[0] + 7)
                self.assertEqual(summary[2], panel[2] - 14)
                self.assertEqual((actions[0], actions[2]), (summary[0], summary[2]))
                self.assertEqual(text[0], summary[0] + (summary[2] - text[2]) // 2)
                expected_action_x = actions[0] if state["aligned_start"] else actions[0] + actions[2] - action[2]
                self.assertEqual(action[0], expected_action_x)
                self.assertGreater(action[2], 0)
                group_height = panel[1] + panel[3] - state["inspect"][1]
                self.assertEqual(state["inspect"][1], 16 + (state["viewport"][1] - 32 - group_height) // 2)

            desktop.key(window, "Tab")
            desktop.key(window, "Return")
            initial = read("inspect")
            check_geometry(initial)
            self.assertEqual(initial["count"], 0)

            target_size = (initial["viewport"][0] + 240, initial["viewport"][1] + 80)
            desktop.resize(window, *target_size)
            deadline = time.monotonic() + 5
            while desktop.size(window) != target_size and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertEqual(desktop.size(window), target_size)
            # A native size query can finish before the fixture processes its
            # resize event. Acknowledge that event through the focused inspector.
            while True:
                desktop.key(window, "Return")
                resized = read("inspect")
                if tuple(resized["viewport"]) == target_size:
                    break
                self.assertLess(time.monotonic(), deadline, "fixture did not acknowledge resize")
            check_geometry(resized)
            self.assertGreater(resized["action"][0], initial["action"][0])
            self.assertGreater(resized["action"][1], initial["action"][1])
            desktop.click(window, initial["action"])
            desktop.click(window, resized["inspect"])
            self.assertEqual(read("inspect")["count"], 0)

            desktop.click(window, resized["action"])
            grown = read("action")
            self.assertEqual(grown["count"], 1)
            self.assertTrue(grown["focused_action"])
            self.assertGreater(grown["text"][2], resized["text"][2])
            self.assertLess(grown["text"][0], resized["text"][0])
            check_geometry(grown)

            desktop.click(window, grown["align"])
            shifted = read("align")
            self.assertTrue(shifted["aligned_start"])
            self.assertLess(shifted["action"][0], grown["action"][0])
            check_geometry(shifted)
            desktop.click(window, grown["action"])
            desktop.click(window, shifted["inspect"])
            self.assertEqual(read("inspect")["count"], 1)
            desktop.click(window, shifted["action"])
            final = read("action")
            self.assertEqual(final["count"], 2)
            self.assertTrue(final["focused_action"])
            check_geometry(final)

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
        with self.fixture("reactive_window", "ui reactive test") as (desktop, window, snapshot):
            desktop.key(window, "Tab")
            desktop.key(window, "Space")
            geometry = snapshot()
            desktop.click(window, geometry)
            self.assertEqual(snapshot(), geometry)

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
