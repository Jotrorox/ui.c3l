"""Exercise native rendering and input against a simulated X server."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

from build_support import compile_fixture, compiler_flags

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples/window"
BINARY = EXAMPLE / "build/window"
BLANK_BINARY = ROOT / "build/blank_window"
KEYBOARD_BINARY = ROOT / "build/keyboard_window"
SCROLL_BINARY = ROOT / "build/scroll_window"
SCROLLBAR_BINARY = ROOT / "build/scrollbar_window"
COUNTER_BINARY = ROOT / "build/counter_window"


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise EOFError("client disconnected")
        result.extend(chunk)
    return bytes(result)


def field(value):
    return struct.pack(">H", len(value)) + value


def setup_reply():
    body = bytearray(72)
    struct.pack_into("<III", body, 4, 0x200000, 0x1FFFFF, 0)
    struct.pack_into("<H", body, 18, 65535)
    body[20] = 1  # one screen
    body[26:28] = bytes([8, 255])  # valid keyboard keycode range
    struct.pack_into("<IIII", body, 32, 0x100, 0x101, 0xFFFFFF, 0)
    body[70] = 24
    return struct.pack("<BBHHH", 1, 0, 11, 0, len(body) // 4) + body


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux X11 backend only")
class X11IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["c3c", "build", "--path", str(EXAMPLE), *compiler_flags()],
                       cwd=ROOT, check=True, timeout=60)
        for name in ("blank_window", "keyboard_window", "scroll_window", "scrollbar_window", "counter_window"):
            compile_fixture(name, ROOT / "build")

    def run_server(self, mode="close", authenticated=False, widgets=False, keyboard=False, scrolling=False, scrollbars=False,
                   auto_wayland=False):
        widgets = widgets or keyboard or scrolling or scrollbars
        errors = []
        with tempfile.TemporaryDirectory() as temp, socket.socket(socket.AF_UNIX) as server:
            # Reserve a unique Linux abstract X socket without touching /tmp.
            for number in range(40000, 60000):
                if Path(f"/tmp/.X11-unix/X{number}").exists():
                    continue
                try:
                    server.bind(f"\0/tmp/.X11-unix/X{number}")
                    break
                except OSError:
                    continue
            else:
                self.fail("no free test display")
            server.listen(1)
            server.settimeout(5)
            cookie = bytes(range(16))
            authority = Path(temp) / "authority"
            if authenticated:
                # An unrelated cookie must not be selected before the local one.
                authority.write_bytes(
                    struct.pack(">H", 256) + field(b"other-host")
                    + field(str(number).encode()) + field(b"MIT-MAGIC-COOKIE-1") + field(b"x" * 16)
                    + struct.pack(">H", 256) + field(socket.gethostname().encode())
                    + field(str(number).encode()) + field(b"MIT-MAGIC-COOKIE-1") + field(cookie)
                )

            def serve():
                try:
                    with server.accept()[0] as connection:
                        connection.settimeout(5)
                        header = read_exact(connection, 12)
                        self.assertEqual(header[:4], b"l\0\x0b\0")
                        name_length, data_length = struct.unpack_from("<HH", header, 6)
                        name = read_exact(connection, (name_length + 3) & ~3)[:name_length]
                        data = read_exact(connection, (data_length + 3) & ~3)[:data_length]
                        self.assertEqual(name, b"MIT-MAGIC-COOKIE-1" if authenticated else b"")
                        self.assertEqual(data, cookie if authenticated else b"")
                        if mode == "disconnect":
                            return
                        if mode == "denied":
                            connection.sendall(b"\0" * 8)
                            self.assertEqual(connection.recv(1), b"")
                            return
                        if mode == "truncated_setup":
                            connection.sendall(setup_reply()[:20])
                            return
                        if mode == "malformed_setup":
                            connection.sendall(struct.pack("<BBHHH", 1, 0, 11, 0, 1) + b"\0" * 4)
                            self.assertEqual(connection.recv(1), b"")
                            return
                        # Deliberately fragment the setup and all replies.
                        for byte in setup_reply():
                            connection.sendall(bytes([byte]))
                        atoms = {b"WM_PROTOCOLS": 100, b"WM_DELETE_WINDOW": 101,
                                 b"_NET_WM_NAME": 102, b"UTF8_STRING": 103}
                        properties = {}
                        window = None
                        sequence = 0
                        while True:
                            header = read_exact(connection, 4)
                            sequence += 1
                            opcode, _, words = struct.unpack("<BBH", header)
                            self.assertGreaterEqual(words, 1)
                            request = header + read_exact(connection, words * 4 - 4)
                            if opcode == 16:
                                length = struct.unpack_from("<H", request, 4)[0]
                                name = request[8:8 + length]
                                reply = bytearray(32)
                                reply[0] = 1
                                struct.pack_into("<H", reply, 2, sequence)
                                struct.pack_into("<I", reply, 8, atoms[name])
                                connection.sendall(reply[:3])
                                connection.sendall(reply[3:])
                            elif opcode == 1:
                                self.assertIsNone(window)
                                window, parent = struct.unpack_from("<II", request, 4)
                                self.assertEqual((window, parent), (0x200001, 0x100))
                                self.assertEqual(struct.unpack_from("<HH", request, 16), (800, 600))
                                self.assertEqual(struct.unpack_from("<III", request, 28),
                                                 (0x802, 0xFFFFFF, 0x22C07F if widgets else 1 << 17))
                            elif opcode == 49 and widgets:  # ListFonts: exercise fixed fallback.
                                self.assertEqual(struct.unpack_from("<H", request, 4)[0], 1)
                                self.assertIn(b"-14-", request[8:])
                                reply = bytearray(32)
                                reply[0] = 1
                                struct.pack_into("<H", reply, 2, sequence)
                                connection.sendall(reply)
                            elif opcode == 84 and widgets:  # AllocColor uses the root colormap.
                                self.assertEqual(struct.unpack_from("<I", request, 4)[0], 0x101)
                                red, green, blue = struct.unpack_from("<HHH", request, 8)
                                reply = bytearray(32)
                                reply[0] = 1
                                struct.pack_into("<H", reply, 2, sequence)
                                struct.pack_into("<HHH", reply, 8, red, green, blue)
                                struct.pack_into("<I", reply, 16,
                                                 (red // 257) << 16 | (green // 257) << 8 | blue // 257)
                                connection.sendall(reply)
                            elif opcode == 45 and widgets:  # OpenFont
                                self.assertEqual(struct.unpack_from("<I", request, 4)[0], 0x200002)
                                self.assertEqual(request[12:17], b"fixed")
                            elif opcode == 47 and widgets:  # QueryFont
                                reply = bytearray(60)
                                reply[0] = 1
                                struct.pack_into("<HI", reply, 2, sequence, 7)
                                for offset in (8, 24):
                                    struct.pack_into("<hhhhhH", reply, offset, 0, 6, 6, 10, 3, 0)
                                struct.pack_into("<HHH", reply, 40, 32, 126, 63)
                                struct.pack_into("<hh", reply, 52, 10, 3)
                                connection.sendall(reply)
                            elif opcode == 101 and widgets:  # GetKeyboardMapping
                                self.assertEqual(request[4:6], bytes([8, 248]))
                                reply = bytearray(32 + 248 * 4)
                                reply[0:2] = bytes([1, 1])
                                struct.pack_into("<HI", reply, 2, sequence, 248)
                                keycodes = {symbol: request[4] + index
                                            for index, symbol in enumerate((0xFF09, 0xFF0D, 0x20))}
                                for symbol, key in keycodes.items():
                                    struct.pack_into("<I", reply, 32 + (key - request[4]) * 4, symbol)
                                connection.sendall(reply)
                            elif opcode == 55 and widgets:  # CreateGC
                                self.assertEqual(struct.unpack_from("<II", request, 4), (0x200003, 0x100))
                            elif opcode == 18:
                                target, prop, kind = struct.unpack_from("<III", request, 4)
                                self.assertEqual(target, window)
                                count = struct.unpack_from("<I", request, 20)[0]
                                properties[prop] = (kind, request[16], request[24:24 + count * (request[16] // 8)])
                            elif opcode == 8:
                                self.assertEqual(struct.unpack_from("<I", request, 4)[0], window)
                                self.assertEqual(properties[100], (4, 32, struct.pack("<I", 101)))
                                title = b"ui scrollbar test 0" if scrollbars else b"ui scroll test" if scrolling else b"ui keyboard test 0" if keyboard else b"Native C3 window"
                                self.assertEqual(properties[39], (31, 8, title))
                                self.assertEqual(properties[102], (103, 8, title))
                                break
                            else:
                                self.fail(f"unexpected X11 opcode {opcode}")
                        if keyboard:
                            self.keyboard_scenario(connection, window, sequence, keycodes, mode)
                            return
                        if scrollbars:
                            self.scrollbar_scenario(connection, window, keycodes)
                            return
                        if scrolling:
                            self.scroll_scenario(connection, window, keycodes)
                            return
                        if widgets:
                            stage = 0
                            labels = []
                            fills = []
                            clips = {}
                            current_clip = None

                            event_time = 1000

                            def input_event(kind, detail, x=0, y=0):
                                nonlocal event_time
                                event_time += 10
                                event = bytearray(32)
                                event[0:2] = bytes([kind | 0x80, detail])
                                struct.pack_into("<I", event, 4, event_time)
                                struct.pack_into("<I", event, 12, window)
                                struct.pack_into("<hh", event, 24, x, y)
                                connection.sendall(event)

                            foreground = None
                            colored_fills = []
                            checkbox_mark = None
                            unchecked_drawn = False
                            checked_drawn = False
                            while stage < 5:
                                header = read_exact(connection, 4)
                                opcode, _, words = struct.unpack("<BBH", header)
                                request = header + read_exact(connection, words * 4 - 4)
                                self.assertIn(opcode, (56, 59, 70, 75))
                                if opcode == 59:
                                    current_clip = struct.unpack_from("<hhHH", request, 12)
                                if opcode == 56:
                                    foreground = struct.unpack_from("<I", request, 12)[0]
                                if opcode == 70:
                                    rect = struct.unpack_from("<hhHH", request, 12)
                                    fills.append(rect)
                                    colored_fills.append((rect, foreground))
                                if opcode != 75:
                                    continue
                                self.assertEqual(struct.unpack_from("<II", request, 4), (window, 0x200003))
                                label = request[18:18 + request[16] * 2].decode("utf-16-be")
                                labels.append(label)
                                clips[label] = current_clip
                                if stage == 0 and label == "Reset":
                                    self.assertIn("Count: 5", labels)
                                    self.assertIn((0, 0, 800, 600), fills)
                                    toggle = clips["Show counter"]
                                    checkbox_mark = (toggle[0] + 8, toggle[1] + (toggle[3] - 16) // 2 + 4, 8, 8)
                                    self.assertIn((checkbox_mark, 0), colored_fills)
                                    # Both buttons are descendants of a Row inside a Column.
                                    left = clips["Increment"]
                                    right = clips["Reset"]
                                    self.assertEqual(left[1], right[1])
                                    self.assertGreater(right[0], left[0] + left[2])
                                    labels.clear()
                                    fills.clear()
                                    x, y = left[0] + left[2] // 2, left[1] + left[3] // 2
                                    input_event(4, 1, x, y)
                                    input_event(5, 1, x, y)
                                    stage = 1
                                elif stage == 1 and "Count: 6" in labels and label == "Increment":
                                    # The click repaints damaged widgets, not the whole window.
                                    self.assertNotIn((0, 0, 800, 600), fills)
                                    labels.clear()
                                    input_event(2, keycodes[0xFF0D])  # Mapped Return key.
                                    input_event(3, keycodes[0xFF0D])
                                    stage = 2
                                elif stage == 2 and label == "Count: 7":
                                    labels.clear()
                                    colored_fills.clear()
                                    x, y = toggle[0] + toggle[2] // 2, toggle[1] + toggle[3] // 2
                                    input_event(4, 1, x, y)
                                    input_event(5, 1, x, y)
                                    stage = 3
                                elif stage == 3 and label == "Show counter":
                                    # Mouse-down paints the old checked mark in white.
                                    # Mouse-up collapses the section and paints no mark.
                                    if not any(rect == checkbox_mark for rect, _ in colored_fills):
                                        unchecked_drawn = True
                                        labels.clear()
                                        input_event(2, keycodes[0x20])  # Restore with mapped Space.
                                        input_event(3, keycodes[0x20])
                                        stage = 4
                                    colored_fills.clear()
                                elif stage == 4:
                                    if label == "Show counter":
                                        self.assertIn((checkbox_mark, 0), colored_fills)
                                        checked_drawn = True
                                    if label == "Reset":
                                        self.assertTrue(unchecked_drawn and checked_drawn)
                                        self.assertIn("Count: 7", labels)
                                        self.assertEqual(clips["Increment"], left)
                                        self.assertEqual(clips["Reset"], right)
                                        stage = 5
                        if mode == "protocol_error":
                            connection.sendall(bytes(32))
                        elif mode == "event_disconnect":
                            return
                        elif mode == "destroy":
                            event = bytearray(32)
                            event[0] = 17
                            struct.pack_into("<I", event, 8, window)
                            connection.sendall(event)
                        else:
                            # Generic extension event with trailing data, then an unrelated
                            # ClientMessage, then the real window-manager close request.
                            extension = bytearray(32)
                            extension[0] = 35
                            struct.pack_into("<I", extension, 4, 2)
                            connection.sendall(extension + b"payload!")
                            event = bytearray(32)
                            event[0:2] = bytes([0x80 | 33, 32])
                            struct.pack_into("<III", event, 4, window + 1, 100, 101)
                            connection.sendall(event)
                            struct.pack_into("<I", event, 4, window)
                            for byte in event:
                                connection.sendall(bytes([byte]))
                        if widgets:
                            while connection.recv(4096):
                                pass  # Finish any already queued drawing requests before close.
                        else:
                            self.assertEqual(connection.recv(1), b"", "client must release the connection")
                except BaseException as error:
                    errors.append(error)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            environment = {**os.environ, "DISPLAY": f":{number}.0", "XAUTHORITY": str(authority),
                           "UI_BACKEND": "auto" if auto_wayland else "x11",
                           "WAYLAND_DISPLAY": str(Path(temp) / "unavailable-wayland")}
            environment.pop("WAYLAND_SOCKET", None)
            result = subprocess.run([str(SCROLLBAR_BINARY if scrollbars else SCROLL_BINARY if scrolling else KEYBOARD_BINARY if keyboard else COUNTER_BINARY if widgets else BLANK_BINARY)], env=environment,
                                    capture_output=True, text=True, timeout=8)
            thread.join(6)
            self.assertFalse(thread.is_alive(), "test server did not finish")
            if errors:
                errors[0].add_note(f"client exit={result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}")
                raise errors[0]
            return result

    def scrollbar_scenario(self, connection, window, keycodes):
        clips, fills = {}, []
        clip, foreground = None, None
        pixels = bytearray([255]) * (800 * 600)

        def request():
            nonlocal clip, foreground
            header = read_exact(connection, 4)
            opcode, _, words = struct.unpack("<BBH", header)
            data = header + read_exact(connection, words * 4 - 4)
            self.assertIn(opcode, (56, 59, 70, 75))
            if opcode == 59:
                clip = struct.unpack_from("<hhHH", data, 12)
            elif opcode == 56:
                foreground = struct.unpack_from("<I", data, 12)[0]
            elif opcode == 70:
                rect = struct.unpack_from("<hhHH", data, 12)
                x, y, width, height = rect
                cx, cy, cw, ch = clip
                self.assertTrue(cx <= x <= x + width <= cx + cw)
                self.assertTrue(cy <= y <= y + height <= cy + ch)
                fills.append((rect, foreground))
                for row in range(y, y + height):
                    pixels[row * 800 + x:row * 800 + x + width] = bytes([foreground & 255]) * width
            elif opcode == 75:
                label = data[18:18 + data[16] * 2].decode("utf-16-be")
                clips[label] = clip

        while "Outer filler" not in clips:
            request()
        # Fixed fixture dimensions deliberately oversize children across the
        # gutter: native clip rectangles must still exclude track pixels.
        self.assertEqual(clips["First"], (30, 70, 276, 32))
        self.assertIn(((306, 70, 12, 33), 0), fills)
        self.assertEqual(pixels[80 * 800 + 312], 0)  # Solid thumb.
        self.assertEqual(pixels[120 * 800 + 306], 0)  # Outlined track.
        self.assertEqual(pixels[120 * 800 + 312], 255)  # Empty track interior.

        def event(kind, detail=1, x=0, y=0, mode=0):
            data = bytearray(32)
            data[:2] = bytes([kind | 0x80, detail])
            struct.pack_into("<I", data, 12, window)
            struct.pack_into("<hh", data, 24, x, y)
            data[30] = mode
            if kind == 10:
                struct.pack_into("<I", data, 4, window)
            if kind == 18:
                struct.pack_into("<I", data, 8, window)
            connection.sendall(data)

        def click(x, y):
            event(4, x=x, y=y)
            event(5, x=x, y=y)

        def inspect():
            click(60, 32)

        def keyboard_inspect():
            event(2, keycodes[0xFF0D])
            event(3, keycodes[0xFF0D])

        inspect()
        click(312, 150)  # One page is the 88-pixel padded viewport.
        inspect()
        event(4, x=312, y=106)  # Thumb after paging starts at y=104.
        event(6, x=312, y=126)
        event(8, x=-1, y=-1)  # A leave is not a jump to the top.
        keyboard_inspect()
        event(6, x=-100, y=700)
        event(5, x=-100, y=700)
        inspect()
        click(60, 86)  # Former First location, now filler, must not activate.
        inspect()
        click(150, 32)  # Reset.
        for kind in (8, 10, 18):
            event(4, x=312, y=72)
            event(kind, x=-1, y=-1, mode=2)
            event(6, x=-100, y=700)
            event(5, x=60, y=86)  # Cancellation cannot become a First release.
            inspect()
        click(250, 32)  # Reactive shrink removes the track and clears its pixels.
        # The final native close is deliberately in a fresh active thumb drag.
        click(250, 32)
        event(4, x=312, y=72)
        close = bytearray(32)
        close[:2] = bytes([33, 32])
        struct.pack_into("<III", close, 4, window, 100, 101)
        connection.sendall(close)
        while True:
            try:
                request()
            except EOFError:
                break
        self.assertIn(((306, 125, 12, 33), 0), fills)  # Bottom endpoint.
        self.assertIn(((24, 64, 300, 100), 0xFFFFFF), fills)  # Exposed content is erased.
        self.assertEqual(sum(rect == (0, 0, 800, 600) for rect, _ in fills), 1)

    def test_scrollbar_native_drag_page_crossing_cancel_and_render(self):
        result = self.run_server(scrollbars=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        states = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([s["inner_offset"] for s in states],
                         [0, 88, 140, 144, 144, 0, 0, 0, 0, 0, 0, 0])
        self.assertTrue(states[2]["dragging"] and states[2]["scroll_press"])
        self.assertTrue(all(s["clicks"] == 0 and s["outer_offset"] == 0 for s in states))
        self.assertEqual(states[9]["inner_extent"], 0)
        self.assertEqual(states[9]["inner_track"], [0, 0, 0, 0])
        self.assertEqual(states[-1]["source"], "closed")
        self.assertFalse(states[-1]["dragging"] or states[-1]["scroll_press"])

    def scroll_scenario(self, connection, window, keycodes):
        clips = {}
        current_clip = None
        foreground = None
        paper_fills = []
        text_positions = []

        def request():
            nonlocal current_clip, foreground
            header = read_exact(connection, 4)
            opcode, _, words = struct.unpack("<BBH", header)
            data = header + read_exact(connection, words * 4 - 4)
            self.assertIn(opcode, (56, 59, 70, 75))
            if opcode == 59:
                current_clip = struct.unpack_from("<hhHH", data, 12)
            elif opcode == 56:
                foreground = struct.unpack_from("<I", data, 12)[0]
            elif opcode == 70:
                x, y, width, height = struct.unpack_from("<hhHH", data, 12)
                cx, cy, cw, ch = current_clip
                self.assertTrue(cx <= x <= x + width <= cx + cw)
                self.assertTrue(cy <= y <= y + height <= cy + ch)
                if foreground == 0xFFFFFF:
                    paper_fills.append((x, y, width, height))
            elif opcode == 75:
                label = data[18:18 + data[16] * 2].decode("utf-16-be")
                clips[label] = current_clip
                x, baseline = struct.unpack_from("<hh", data, 12)
                text_positions.append((label, x, baseline, current_clip))

        while "Outer filler" not in clips:
            request()
        self.assertNotIn("Last", clips)
        first, inspector, resetter = clips["First"], clips["Inspect"], clips["Reset scroll"]
        inner = (first[0] - 6, first[1] - 6, 300, 100)
        timestamp = 1000

        def event(kind, detail, rect=None, shift=False):
            nonlocal timestamp
            timestamp += 10
            data = bytearray(32)
            data[:2] = bytes([kind | 0x80, detail])
            struct.pack_into("<I", data, 4, timestamp)
            struct.pack_into("<I", data, 12, window)
            if rect:
                x, y, width, height = rect
                struct.pack_into("<hh", data, 24, x + width // 2, y + height // 2)
            struct.pack_into("<H", data, 28, int(shift))
            connection.sendall(data)

        def click(rect):
            for kind in (4, 5):
                event(kind, 1, rect)

        def wheel(button=5):
            for kind in (4, 5):
                event(kind, button, first)

        def key(symbol, shift=False):
            for kind in (2, 3):
                event(kind, keycodes[symbol], shift=shift)

        click(inspector)
        wheel()
        click(inspector)
        click(first)  # The former button location now contains clipped filler.
        click(inspector)
        wheel(4)
        click(inspector)
        for _ in range(4):
            wheel()
        click(inspector)
        wheel()
        click(inspector)
        event(5, 4, first)  # An isolated wheel release must not scroll or click.
        click(inspector)
        click(resetter)
        key(0xFF09)
        key(0xFF09)
        key(0xFF0D)
        key(0xFF09)
        key(0xFF0D)
        key(0xFF09, shift=True)
        key(0xFF0D)
        close = bytearray(32)
        close[:2] = bytes([33, 32])
        struct.pack_into("<III", close, 4, window, 100, 101)
        connection.sendall(close)
        while True:
            try:
                request()
            except EOFError:
                break
        self.assertIn(inner, paper_fills)  # Scroll damage clears the full old viewport.
        self.assertEqual(paper_fills.count((0, 0, 800, 600)), 1)
        self.assertIn("Last", clips)
        self.assertIn("Tail", clips)
        for label, _, baseline, clip in text_positions:
            # Font ascent=10/descent=3: scrolled text wholly outside its clip
            # must never reappear through INT16 wrapping or spurious requests.
            self.assertGreater(baseline + 3, clip[1], (label, baseline, clip))
            self.assertLess(baseline - 10, clip[1] + clip[3], (label, baseline, clip))

    def test_scroll_wheel_nested_routing_focus_and_clipped_damage(self):
        result = self.run_server(scrolling=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        states = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([(state["source"], state["inner_offset"], state["outer_offset"]) for state in states[:8]],
                         [("inspect", 0, 0), ("inspect", 40, 0), ("inspect", 40, 0),
                          ("inspect", 0, 0), ("inspect", 144, 0), ("inspect", 144, 40),
                          ("inspect", 144, 40), ("reset", 0, 0)])
        self.assertEqual([state["first_clicks"] for state in states], [0] * 11)
        self.assertEqual([(state["source"], state["last_clicks"], state["tail_clicks"])
                          for state in states[8:]], [("last", 1, 0), ("tail", 1, 1), ("last", 2, 1)])
        self.assertTrue(states[8]["focused_last"] and states[9]["focused_tail"] and states[10]["focused_last"])

    def keyboard_scenario(self, connection, window, sequence, keycodes, mode):
        # Read real renderer clips for clicks and count every request, including
        # drawing requests, to test reply sequence matching on the live stream.
        clips = {}
        clip = None

        def request():
            nonlocal sequence, clip
            header = read_exact(connection, 4)
            sequence = (sequence + 1) & 0xFFFF
            opcode, _, words = struct.unpack("<BBH", header)
            data = header + read_exact(connection, words * 4 - 4)
            if opcode == 59:
                clip = struct.unpack_from("<hhHH", data, 12)
            if opcode == 75:
                label = data[18:18 + data[16] * 2].decode("utf-16-be")
                clips[label] = clip
            return opcode, data

        while "Check" not in clips:
            request()

        timestamp = 1000

        def event(kind, code=0, time=None, shift=False):
            nonlocal timestamp
            timestamp += 10
            data = bytearray(32)
            data[:2] = bytes([kind, code])
            struct.pack_into("<I", data, 4, timestamp if time is None else time)
            struct.pack_into("<I", data, 12, window)
            struct.pack_into("<H", data, 28, int(shift))
            return data

        def key(symbol, down=True, repeat=False, shift=False):
            code = keycodes[symbol]
            if repeat:
                when = timestamp + 10
                connection.sendall(event(3, code, when))
                # Split the repeat pair across writes; socket buffering is irrelevant.
                data = event(2, code, when, shift)
                connection.sendall(data[:9])
                connection.sendall(data[9:])
            else:
                connection.sendall(event(2 if down else 3, code, shift=shift))

        def cycle(symbol, shift=False):
            key(symbol, shift=shift)
            key(symbol, down=False, shift=shift)

        def inspect():
            x, y, width, height = clips["Inspect"]
            for kind in (4, 5):
                data = event(kind, 1)
                struct.pack_into("<hh", data, 24, x + width // 2, y + height // 2)
                connection.sendall(data)

        def notify(kind=1, first=8, count=248):
            data = bytearray(32)
            data[0] = 34
            data[4:7] = bytes([kind, first, count])
            connection.sendall(data)

        def close():
            data = bytearray(32)
            data[:2] = bytes([33, 32])
            struct.pack_into("<III", data, 4, window, 100, 101)
            connection.sendall(data)

        cycle(0xFF09)  # Inspector.
        cycle(0xFF09)  # Button.
        key(0xFF0D)
        key(0xFF0D)  # Repeated KeyPress without release.
        key(0xFF0D, repeat=True)
        inspect()  # clicks=1
        key(0xFF0D, repeat=True)  # Newly focused inspector must NOT emit a snapshot.
        cycle(0xFF09)
        key(0xFF0D, repeat=True)
        key(0xFF0D, down=False)
        key(0xFF0D)
        inspect()  # clicks=2
        cycle(0xFF09)
        cycle(0xFF09)
        key(0x20)
        key(0x20)
        key(0x20, repeat=True)
        key(0x20, down=False)
        key(0x20)
        key(0x20, down=False)
        inspect()  # changes=2, checked=false

        # MappingPointer does not produce a mapping request. A subsequent keyboard
        # notification does, with exposure, extension, focus and input interleaved.
        notify(2)
        if mode == "bad_range":
            notify(first=255, count=2)
        else:
            notify()
        if mode == "bad_range":
            try:
                while connection.recv(4096):
                    pass
            except ConnectionResetError:
                pass
            return
        while request()[0] != 101:
            pass
        mapping_sequence = sequence
        expose = bytearray(32)
        expose[0] = 12
        struct.pack_into("<IHHHH", expose, 4, window, 0, 0, 800, 600)
        connection.sendall(expose)
        extension = bytearray(32)
        extension[0] = 35
        struct.pack_into("<I", extension, 4, 2)
        connection.sendall(extension + b"payload!")
        if mode == "map_error":
            connection.sendall(bytes(32))
        elif mode == "map_disconnect":
            return
        else:
            old_codes = keycodes.copy()
            keycodes = {0xFF09: 40, 0xFF0D: 41, 0x20: 42}
            # Input arrives BEFORE the reply, but uses the new mapping. It must
            # wait in order, then execute against the replacement mapping.
            cycle(0xFF09)
            cycle(0xFF0D)
            cycle(0xFF09)
            cycle(0x20)
            inspect()  # clicks=3, changes=3
            reply = bytearray(32 + 248 * 2 * 4)
            reply[:2] = bytes([1, 2])
            struct.pack_into("<HI", reply, 2, mapping_sequence, 248 * 2)
            for symbol, code in keycodes.items():
                struct.pack_into("<I", reply, 32 + (code - 8) * 8, symbol)
            if mode == "map_sequence":
                struct.pack_into("<H", reply, 2, (mapping_sequence - 1) & 0xFFFF)
            elif mode == "map_width":
                reply[1] = 0
            elif mode == "map_length":
                struct.pack_into("<I", reply, 4, 0xFFFFFFFF)
            elif mode == "map_short_length":
                struct.pack_into("<I", reply, 4, 1)
            elif mode == "map_truncated":
                connection.sendall(reply[:40])
                return
            connection.sendall(reply[:13])
            connection.sendall(reply[13:])
            if mode == "close":
                # A second refresh from MappingModifier changes stride again.
                notify(0)
                while request()[0] != 101:
                    pass
                reply = bytearray(32 + 248 * 3 * 4)
                reply[:2] = bytes([1, 3])
                struct.pack_into("<HI", reply, 2, sequence, 248 * 3)
                for symbol, code in keycodes.items():
                    struct.pack_into("<I", reply, 32 + (code - 8) * 12, symbol)
                connection.sendall(reply)
                cycle(0xFF09, shift=True)  # Wrap backwards to checkbox.
                cycle(0x20)
                # Old mapping no longer activates. Release the previously held key.
                for kind in (3, 2, 3):
                    connection.sendall(event(kind, old_codes[0xFF0D]))
                inspect()  # changes=4
                close()
        try:
            while connection.recv(4096):
                pass
        except ConnectionResetError:
            pass  # Invalid protocol frames close the socket with unread input.

    def test_keyboard_repeat_cycles_and_live_mapping_refresh(self):
        result = self.run_server(keyboard=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        states = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([(s["clicks"], s["changes"], s["checked"]) for s in states],
                         [(1, 0, False), (2, 0, False), (2, 2, False),
                          (3, 3, True), (3, 4, False)])

    def test_live_mapping_protocol_failures_release_connection(self):
        for mode in ("bad_range", "map_error", "map_disconnect", "map_sequence", "map_width",
                     "map_length", "map_short_length", "map_truncated"):
            with self.subTest(mode=mode):
                result = self.run_server(keyboard=True, mode=mode)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("CONNECTION_FAILED" if mode in ("map_disconnect", "map_truncated")
                              else "PROTOCOL_ERROR", result.stderr)

    def test_create_title_map_and_wm_close(self):
        result = self.run_server()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_auto_falls_back_to_x11_when_wayland_is_unavailable(self):
        result = self.run_server(auto_wayland=True, widgets=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_local_authority_cookie(self):
        result = self.run_server(authenticated=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_counter_draws_and_reacts_to_mouse_and_keyboard(self):
        result = self.run_server(widgets=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_destroy_notification(self):
        result = self.run_server("destroy")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_errors_release_the_connection(self):
        for mode, error in [("denied", "AUTHENTICATION_FAILED"),
                            ("disconnect", "CONNECTION_FAILED"),
                            ("truncated_setup", "CONNECTION_FAILED"),
                            ("malformed_setup", "PROTOCOL_ERROR"),
                            ("protocol_error", "PROTOCOL_ERROR"),
                            ("event_disconnect", "CONNECTION_FAILED")]:
            with self.subTest(mode=mode):
                result = self.run_server(mode)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(error, result.stderr)

    def test_missing_and_remote_display(self):
        for display, error in [("", "DISPLAY_UNAVAILABLE"), ("remote:0", "UNSUPPORTED_DISPLAY")]:
            with self.subTest(display=display):
                result = subprocess.run([str(BINARY)], env={**os.environ, "DISPLAY": display, "UI_BACKEND": "x11"},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertIn(error, result.stderr)


if __name__ == "__main__":
    unittest.main()
