#!/usr/bin/env python3
"""Check native Wayland mapping on fresh headless Weston instances."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from build_support import compile_fixture


def wait_for(predicate, process, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'{description}: process exited with {process.returncode}')
        if predicate():
            return
        time.sleep(0.05)
    raise RuntimeError(f'{description}: timed out after {timeout} seconds')


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def frame_presented(log):
    attached = False
    committed = False
    for line in log.read_text(errors='replace').splitlines():
        if 'wl_surface' in line and '.attach(' in line:
            attached = True
        elif attached and 'wl_surface' in line and '.commit(' in line:
            committed = True
        elif committed and 'wl_callback' in line and '.done(' in line:
            return True
    return False


def check_window(weston, backend, binary, directory):
    socket_name = 'ui-native-wayland'
    runtime = directory / binary.name
    runtime.mkdir(mode=0o700)
    server_log = runtime / 'weston.log'
    client_log = runtime / 'client.log'
    environment = {**os.environ, 'XDG_RUNTIME_DIR': str(runtime), 'WAYLAND_DISPLAY': socket_name,
                   'UI_BACKEND': 'auto', 'DISPLAY': ':59999'}
    environment.pop('WAYLAND_SOCKET', None)
    server = client = None
    try:
        with server_log.open('wb') as log:
            server = subprocess.Popen([weston, f'--backend={backend}', '--shell=kiosk-shell.so',
                                       '--use-pixman', '--no-config', '--idle-time=0', f'--socket={socket_name}'],
                                      env=environment, stdout=log, stderr=log)
        wait_for(lambda: (runtime / socket_name).exists(), server, 10, 'Weston startup')
        with client_log.open('wb') as log:
            client = subprocess.Popen([str(binary)], env={**environment, 'WAYLAND_DEBUG': '1'},
                                      stdout=subprocess.DEVNULL, stderr=log)
        wait_for(lambda: frame_presented(client_log), client, 10, f'{binary.name} frame presentation')
        # A real compositor has configured, mapped, and presented the shm frame.
        # Protocol-driver tests cover graceful close. Here exercise disconnect.
        stop(server)
        if client.wait(timeout=5) != 1 or 'CONNECTION_FAILED' not in client_log.read_text(errors='replace'):
            raise RuntimeError('client did not report compositor disconnection')
        print(f'{binary.name}: configured, rendered, presented, disconnected', flush=True)
    except BaseException:
        for log in (server_log, client_log):
            if log.exists():
                print(log.read_text(errors='replace'), file=sys.stderr)
        raise
    finally:
        stop(client)
        stop(server)


def main():
    weston = shutil.which('weston')
    if not weston:
        raise SystemExit('Weston is required; install weston and the Wayland runtime libraries, then retry')
    version = subprocess.check_output([weston, '--version'], text=True)
    major = int(re.search(r'\b(\d+)\.', version)[1])
    backend = 'headless' if major >= 14 else 'headless-backend.so'
    with tempfile.TemporaryDirectory(prefix='ui-c3-wayland-') as directory:
        directory = Path(directory)
        for name in ('blank_window', 'wayland_window'):
            binary = compile_fixture(name, directory / 'build')
            check_window(weston, backend, binary, directory)


if __name__ == '__main__':
    main()
