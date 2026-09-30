"""Exercise the actual example against a small X11 server; no display is needed."""
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples/window"
BINARY = EXAMPLE / "build/window"


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
    struct.pack_into("<IIII", body, 32, 0x100, 0, 0xFFFFFF, 0)
    body[70] = 24
    return struct.pack("<BBHHH", 1, 0, 11, 0, len(body) // 4) + body


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux X11 backend only")
class X11IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["c3c", "build", "--path", str(EXAMPLE)], check=True)

    def run_server(self, mode="close", authenticated=False):
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
                                                 (0x802, 0xFFFFFF, 1 << 17))
                            elif opcode == 18:
                                target, prop, kind = struct.unpack_from("<III", request, 4)
                                self.assertEqual(target, window)
                                count = struct.unpack_from("<I", request, 20)[0]
                                properties[prop] = (kind, request[16], request[24:24 + count * (request[16] // 8)])
                            elif opcode == 8:
                                self.assertEqual(struct.unpack_from("<I", request, 4)[0], window)
                                self.assertEqual(properties[100], (4, 32, struct.pack("<I", 101)))
                                self.assertEqual(properties[39], (31, 8, b"Native C3 window"))
                                self.assertEqual(properties[102], (103, 8, b"Native C3 window"))
                                break
                            else:
                                self.fail(f"unexpected X11 opcode {opcode}")
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
                        self.assertEqual(connection.recv(1), b"", "client must release the connection")
                except BaseException as error:
                    errors.append(error)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            environment = {**os.environ, "DISPLAY": f":{number}.0", "XAUTHORITY": str(authority)}
            result = subprocess.run([str(BINARY)], env=environment, capture_output=True, text=True, timeout=8)
            thread.join(6)
            self.assertFalse(thread.is_alive(), "test server did not finish")
            if errors:
                raise errors[0]
            return result

    def test_create_title_map_and_wm_close(self):
        result = self.run_server()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_local_authority_cookie(self):
        result = self.run_server(authenticated=True)
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
                result = subprocess.run([str(BINARY)], env={**os.environ, "DISPLAY": display},
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertIn(error, result.stderr)


if __name__ == "__main__":
    unittest.main()
