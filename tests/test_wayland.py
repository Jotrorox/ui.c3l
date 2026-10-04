"""Exercise the real Wayland client, Cairo and xkbcommon against an isolated compositor.

The driver implements just the advertised protocol, records shm contents, and
supplies keyboard keymaps through SCM_RIGHTS. No user's desktop is contacted.
"""
import array
import ctypes as c
import json
import mmap
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from collections import deque

from build_support import compile_fixture

ROOT = Path(__file__).resolve().parents[1]


def uints(*values):
    return struct.pack('<' + 'I' * len(values), *values)


def string(value):
    data = value.encode() + b'\0'
    return uints(len(data)) + data + bytes(-len(data) % 4)


def wire_array(data=b''):
    return uints(len(data)) + data + bytes(-len(data) % 4)


def keymap():
    api = c.CDLL('libxkbcommon.so.0')
    api.xkb_context_new.argtypes = [c.c_int]
    api.xkb_context_new.restype = c.c_void_p
    api.xkb_keymap_new_from_names.argtypes = [c.c_void_p, c.c_void_p, c.c_int]
    api.xkb_keymap_new_from_names.restype = c.c_void_p
    api.xkb_keymap_get_as_string.argtypes = [c.c_void_p, c.c_int]
    api.xkb_keymap_get_as_string.restype = c.c_void_p
    api.xkb_keymap_unref.argtypes = [c.c_void_p]
    api.xkb_context_unref.argtypes = [c.c_void_p]
    libc = c.CDLL(None)
    libc.free.argtypes = [c.c_void_p]
    context = api.xkb_context_new(0)
    mapping = api.xkb_keymap_new_from_names(context, None, 0)
    if not mapping:
        raise RuntimeError('xkbcommon test keymap unavailable (install xkb-data)')
    pointer = api.xkb_keymap_get_as_string(mapping, 1)
    try:
        return c.string_at(pointer) + b'\0'
    finally:
        libc.free(pointer)
        api.xkb_keymap_unref(mapping)
        api.xkb_context_unref(context)


class Compositor:
    def __init__(self, connection, scenario='close', widgets=False, missing=False):
        self.connection = connection
        self.connection.settimeout(8)
        self.data = bytearray()
        self.fds = deque()
        self.objects = {1: 'display'}
        self.scenario = scenario
        self.widgets = widgets
        self.missing = missing
        self.pools = {}
        self.buffers = {}
        self.surface_frames = {}
        self.attached = {}
        self.surface = self.xsurface = self.top = self.pointer = self.keyboard = None
        self.ack = None
        self.title = None
        self.commits = 0
        self.images = []
        self.held_buffers = {}
        self.requested_sizes = []
        self.pongs = []
        self.decoration_modes = []
        self.data_device = None
        self.clipboard_receives = []

    def send(self, target, opcode, payload=b'', fd=None):
        packet = uints(target, ((8 + len(payload)) << 16) | opcode) + payload
        if fd is None:
            # Fragment events across writes to exercise library framing.
            self.connection.sendall(packet[:5])
            self.connection.sendall(packet[5:])
        else:
            self.connection.sendmsg([packet], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd]))])

    def receive(self):
        while len(self.data) < 8 or len(self.data) < struct.unpack_from('<I', self.data, 4)[0] >> 16:
            data, control, flags, _ = self.connection.recvmsg(65536, socket.CMSG_SPACE(16 * 4))
            if not data:
                raise EOFError
            self.data.extend(data)
            for level, kind, value in control:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    fds = array.array('i')
                    fds.frombytes(value[:len(value) - len(value) % fds.itemsize])
                    self.fds.extend(fds)
        target, header = struct.unpack_from('<II', self.data)
        size, opcode = header >> 16, header & 0xffff
        payload = bytes(self.data[8:size])
        del self.data[:size]
        return target, opcode, payload

    def configure(self, width=0, height=0, serial=77):
        self.send(self.top, 0, uints(width, height) + wire_array())
        self.send(self.xsurface, 0, uints(serial))

    def key(self, code, down=True):
        self.send(self.keyboard, 3, uints(50, 1000, code, int(down)))

    def cycle(self, code):
        self.key(code)
        self.key(code, False)

    def motion(self, x, y):
        self.send(self.pointer, 2, struct.pack('<Iii', 1000, x * 256, y * 256))

    def click(self, x, y):
        self.motion(x, y)
        for state in (1, 0):
            self.send(self.pointer, 3, uints(50, 1000, 0x110, state))

    def run(self):
        try:
            while True:
                target, opcode, payload = self.receive()
                kind = self.objects[target]
                if kind == 'display':
                    new_id, = struct.unpack('<I', payload)
                    if opcode == 1:
                        self.objects[new_id] = 'registry'
                        globals = [(10, 'wl_compositor', 4), (11, 'wl_shm', 1),
                                   (12, 'xdg_wm_base', 1), (13, 'wl_seat', 5)]
                        if self.widgets:
                            globals.append((15, 'wl_data_device_manager', 1))
                        if self.scenario in ('decorations', 'decorations_client'):
                            globals.append((14, 'zxdg_decoration_manager_v1', 1))
                        for name, iface, version in globals:
                            if self.missing and name == 12:
                                continue
                            self.send(new_id, 0, uints(name) + string(iface) + uints(version))
                    else:
                        self.send(new_id, 0, uints(1))
                        self.send(1, 1, uints(new_id))
                elif kind == 'registry':
                    name, length = struct.unpack_from('<II', payload)
                    iface = payload[8:8 + length - 1].decode()
                    version, new_id = struct.unpack_from('<II', payload, 8 + ((length + 3) & ~3))
                    self.objects[new_id] = iface
                    if iface == 'wl_shm':
                        self.send(new_id, 0, uints(0))
                        self.send(new_id, 0, uints(1))
                    if iface == 'wl_seat':
                        self.send(new_id, 0, uints(3))
                        self.send(new_id, 1, string('test-seat'))
                    if iface == 'xdg_wm_base':
                        self.send(new_id, 0, uints(123))
                elif kind == 'wl_compositor':
                    new_id, = struct.unpack('<I', payload)
                    self.objects[new_id] = 'wl_surface'
                    if self.surface is None:
                        self.surface = new_id
                elif kind == 'wl_data_device_manager':
                    new_id, = struct.unpack_from('<I', payload)
                    if opcode == 1:
                        self.data_device = new_id
                        self.objects[new_id] = 'wl_data_device'
                    else:
                        self.objects[new_id] = 'wl_data_source'
                elif kind == 'wl_data_offer':
                    if opcode == 1:
                        length, = struct.unpack_from('<I', payload)
                        mime = payload[4:4 + length - 1].decode()
                        self.clipboard_receives.append(mime)
                        fd = self.fds.popleft()
                        try:
                            data = {'clipboard': '世界'.encode(), 'clipboard_invalid': b'line\nbreak',
                                    'clipboard_utf8': b'\xff', 'clipboard_large': b'x' * 4097}[self.scenario]
                            os.write(fd, data)
                        finally:
                            os.close(fd)
                        self.send(self.top, 1)
                elif kind == 'xdg_wm_base':
                    if opcode == 2:
                        new_id, surface = struct.unpack('<II', payload)
                        assert surface == self.surface
                        self.xsurface = new_id
                        self.objects[new_id] = 'xdg_surface'
                    if opcode == 3:
                        self.pongs.append(struct.unpack('<I', payload)[0])
                elif kind == 'xdg_surface':
                    if opcode == 1:
                        new_id, = struct.unpack('<I', payload)
                        self.top = new_id
                        self.objects[new_id] = 'xdg_toplevel'
                    if opcode == 4:
                        self.ack, = struct.unpack('<I', payload)
                elif kind == 'xdg_toplevel':
                    if opcode == 2:
                        length, = struct.unpack_from('<I', payload)
                        self.title = payload[4:4 + length - 1].decode()
                elif kind == 'zxdg_decoration_manager_v1':
                    new_id, top = struct.unpack('<II', payload)
                    assert top == self.top
                    self.objects[new_id] = 'zxdg_toplevel_decoration_v1'
                    # A compositor may choose client-side mode even when the
                    # client requests server decorations.
                    self.send(new_id, 0, uints(1 if self.scenario == 'decorations_client' else 2))
                elif kind == 'zxdg_toplevel_decoration_v1':
                    self.decoration_modes.append(struct.unpack('<I', payload)[0])
                elif kind == 'wl_seat':
                    new_id, = struct.unpack('<I', payload)
                    if opcode == 0:
                        self.pointer = new_id
                        self.objects[new_id] = 'wl_pointer'
                    elif opcode == 1:
                        self.keyboard = new_id
                        self.objects[new_id] = 'wl_keyboard'
                        mapping = keymap()
                        size = len(mapping)
                        if self.scenario == 'keymap_truncated':
                            mapping = mapping[:16]
                        elif self.scenario == 'keymap_missing_nul':
                            mapping = mapping[:-1] + b'x'
                        with tempfile.TemporaryFile() as file:
                            file.write(mapping)
                            file.flush()
                            self.send(new_id, 0, uints(1, size), file.fileno())
                        self.send(new_id, 5, uints(0, 600))
                elif kind == 'wl_shm':
                    new_id, size = struct.unpack('<II', payload)
                    self.objects[new_id] = 'wl_shm_pool'
                    fd = self.fds.popleft()
                    try:
                        self.pools[new_id] = mmap.mmap(fd, size, access=mmap.ACCESS_READ)
                    finally:
                        os.close(fd)
                elif kind == 'wl_shm_pool':
                    if opcode == 0:
                        new_id, offset, width, height, stride, fmt = struct.unpack('<IIIIII', payload)
                        assert stride == width * 4 and fmt in (0, 1)
                        self.objects[new_id] = 'wl_buffer'
                        self.buffers[new_id] = (self.pools[target], offset, width, height, stride)
                elif kind == 'wl_surface':
                    if opcode == 1:
                        self.attached[target] = struct.unpack_from('<I', payload)[0]
                    elif opcode == 3:
                        self.surface_frames[target] = struct.unpack('<I', payload)[0]
                    elif opcode == 6 and target == self.surface:
                        if target not in self.attached:
                            if self.scenario == 'disconnect':
                                return
                            if self.scenario == 'protocol_error':
                                self.send(1, 0, uints(self.surface, 1) + string('test protocol error'))
                            else:
                                self.configure()
                        else:
                            self.commit()
                # Destroy requests and cursor updates need no events.
        except (EOFError, ConnectionResetError, BrokenPipeError):
            if not self.missing and self.scenario not in ('disconnect', 'protocol_error', 'keymap_truncated', 'keymap_missing_nul'):
                assert self.commits > 0, 'window never committed a buffer'
        finally:
            for fd in self.fds:
                os.close(fd)
            for mapping in self.pools.values():
                mapping.close()

    def commit(self):
        self.commits += 1
        assert self.ack == (78 if self.commits > 1 and self.scenario in ('resize', 'busy', 'decorations_client') else 77)
        buffer = self.attached[self.surface]
        mapping, offset, width, height, stride = self.buffers[buffer]
        image = bytes(mapping[offset:offset + stride * height])
        for old_buffer, old_pixels in self.held_buffers.items():
            old_mapping = self.buffers[old_buffer][0]
            assert bytes(old_mapping[:len(old_pixels)]) == old_pixels, 'client rewrote an unreleased buffer'
        self.images.append(image)
        self.requested_sizes.append((width, height))
        frame = self.surface_frames.pop(self.surface)
        self.send(frame, 0, uints(1000))
        self.send(1, 1, uints(frame))
        if self.scenario != 'busy':
            self.send(buffer, 0)
        else:
            self.held_buffers[buffer] = image
        if self.scenario.startswith('clipboard'):
            if self.commits == 1:
                offer = 0xff000001
                self.objects[offer] = 'wl_data_offer'
                self.send(self.data_device, 0, uints(offer))
                self.send(offer, 0, string('text/plain'))
                self.send(offer, 0, string('text/plain;charset=utf-8'))
                self.send(self.data_device, 5, uints(offer))
                self.send(self.keyboard, 1, uints(40, self.surface) + wire_array())
                self.cycle(15)  # Focus the field.
                self.send(self.keyboard, 4, uints(40, 4, 0, 0, 0))  # Control.
                self.cycle(30)  # Ctrl-A.
                self.cycle(47)  # Ctrl-V.
                self.send(self.keyboard, 4, uints(40, 0, 0, 0, 0))
            return
        if self.commits == 1 and self.scenario in ('resize', 'busy', 'decorations_client'):
            self.configure(400, 300, 78)
        elif self.commits == 1 and self.scenario == 'input':
            self.send(self.pointer, 0, struct.pack('<IIii', 40, self.surface, 20 * 256, 20 * 256))
            self.send(self.keyboard, 1, uints(40, self.surface) + wire_array())
            self.click(30, 30)
            self.cycle(15)  # Tab to checkbox.
            self.cycle(57)  # Space toggles checkbox.
            # Shift+Tab back to button using the compositor's modifier mask.
            self.send(self.keyboard, 4, uints(40, 1, 0, 0, 0))
            self.cycle(15)
            self.send(self.keyboard, 4, uints(40, 0, 0, 0, 0))
            self.key(28)  # Enter, repeated presses activate only once.
            self.key(28)
            self.key(28, False)
            self.key(28)
            self.key(28, False)
            self.motion(30, 120)
            self.send(self.pointer, 4, struct.pack('<IIi', 1000, 0, 10 * 256))
            self.send(self.pointer, 8, uints(0, 1))
            self.send(self.pointer, 5)
            self.send(self.top, 1)
        else:
            self.send(self.top, 1)


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux Wayland backend only')
class WaylandIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='ui-wayland-build-')
        cls.blank = compile_fixture('blank_window', cls.directory.name)
        cls.widgets = compile_fixture('wayland_window', cls.directory.name)
        cls.clipboard = compile_fixture('clipboard_window', cls.directory.name)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_compositor(self, scenario='close', widgets=False, override='auto', missing=False, inherited=False):
        errors = []
        with tempfile.TemporaryDirectory(prefix='ui-wayland-') as directory, socket.socket(socket.AF_UNIX) as server:
            path = str(Path(directory) / 'wayland-test')
            server.bind(path)
            server.listen(1)
            server.settimeout(8)
            driver = None

            def serve(connection=None):
                nonlocal driver
                try:
                    if connection is None:
                        connection, _ = server.accept()
                    with connection:
                        driver = Compositor(connection, scenario, widgets, missing)
                        driver.run()
                except BaseException as error:
                    errors.append(error)

            environment = {**os.environ, 'XDG_RUNTIME_DIR': directory, 'WAYLAND_DISPLAY': 'wayland-test',
                           'DISPLAY': ':59999', 'UI_BACKEND': override}
            environment.pop('WAYLAND_SOCKET', None)
            pass_fds = ()
            client = None
            if inherited:
                connection, client = socket.socketpair()
                environment['WAYLAND_SOCKET'] = str(client.fileno())
                environment.pop('WAYLAND_DISPLAY')
                environment.pop('XDG_RUNTIME_DIR')
                pass_fds = (client.fileno(),)
                thread = threading.Thread(target=serve, args=(connection,), daemon=True)
            else:
                thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            try:
                binary = self.clipboard if scenario.startswith('clipboard') else self.widgets if widgets else self.blank
                result = subprocess.run([str(binary)], env=environment,
                                        pass_fds=pass_fds, capture_output=True, text=True, timeout=10)
            finally:
                if client is not None:
                    client.close()
            thread.join(timeout=9)
            self.assertFalse(thread.is_alive(), 'compositor did not see client disconnect')
            if errors:
                errors[0].add_note(f'client exit={result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}')
                raise errors[0]
            return result, driver

    def test_auto_prefers_wayland_over_display_and_maps_blank_window(self):
        result, driver = self.run_compositor()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(driver.title, 'Native C3 window')
        self.assertEqual(driver.requested_sizes, [(800, 600)])
        self.assertEqual(driver.pongs, [123])
        self.assertEqual(set(driver.images[0]), {255})

    def test_resize_and_unreleased_buffer_are_handled(self):
        for scenario in ('resize', 'busy'):
            with self.subTest(scenario=scenario):
                result, driver = self.run_compositor(scenario, widgets=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(driver.title, 'Wayland C3 — 世界')
                self.assertEqual(driver.requested_sizes, [(321, 234), (400, 300)])
                self.assertGreater(len(set(driver.images[0])), 2)  # Glyph antialiasing and widget borders.
                self.assertEqual(json.loads(result.stdout)['width'], 400)

    def test_mouse_keyboard_modifiers_repeat_checkbox_and_scroll(self):
        result, driver = self.run_compositor('input', widgets=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        states = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([(s['clicks'], s['changes'], s['checked']) for s in states],
                         [(1, 0, False), (1, 1, True), (2, 1, True), (3, 1, True), (3, 1, True)])
        self.assertEqual(states[-1]['offset'], 40)  # axis + discrete must not double count.

    def test_inherited_socket_is_selected_without_wayland_display(self):
        result, _ = self.run_compositor(inherited=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_clipboard_utf8_selection_replacement_and_atomic_rejection(self):
        for scenario in ('clipboard', 'clipboard_invalid', 'clipboard_utf8', 'clipboard_large'):
            with self.subTest(scenario=scenario):
                result, driver = self.run_compositor(scenario, widgets=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(driver.clipboard_receives, ['text/plain;charset=utf-8'])
                final = json.loads(result.stdout.splitlines()[-1])
                self.assertEqual(final['text'], '世界' if scenario == 'clipboard' else 'aé👋z')
                self.assertEqual(final['changes'], 1 if scenario == 'clipboard' else 0)
                self.assertEqual((final['anchor'], final['caret']), (6, 6) if scenario == 'clipboard' else (0, 8))

    def test_requests_server_decorations_when_supported(self):
        result, driver = self.run_compositor('decorations')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(driver.decoration_modes, [2])

    def test_client_decoration_mode_keeps_borderless_resize_and_close_working(self):
        result, driver = self.run_compositor('decorations_client', widgets=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(driver.decoration_modes, [2])
        self.assertEqual(driver.requested_sizes, [(321, 234), (400, 300)])
        state = json.loads(result.stdout)
        self.assertEqual((state['width'], state['height']), (400, 300))

    def test_malformed_keymap_descriptors_return_protocol_error(self):
        for scenario in ('keymap_truncated', 'keymap_missing_nul'):
            with self.subTest(scenario=scenario):
                result, _ = self.run_compositor(scenario, widgets=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn('PROTOCOL_ERROR', result.stderr)

    def test_forced_wayland_does_not_fallback_when_required_globals_are_missing(self):
        result, _ = self.run_compositor(override='wayland', missing=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('DISPLAY_UNAVAILABLE', result.stderr)

    def test_connection_and_protocol_errors_release_resources_without_fallback(self):
        for scenario, error in [('disconnect', 'CONNECTION_FAILED'), ('protocol_error', 'PROTOCOL_ERROR')]:
            with self.subTest(scenario=scenario):
                result, _ = self.run_compositor(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertIn(error, result.stderr)


if __name__ == '__main__':
    unittest.main()
