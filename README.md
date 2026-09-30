# ui.c3l

A small C3 library that opens a blank native window on Windows and Linux.
Requires C3 0.8.4 or newer.

```c3
import ui;

fn void main()
{
    ui::open_window("Hello", width: 800, height: 600)!!;
}
```

`open_window` runs the native event loop until the window is closed, then releases
its resources. Call it on the main thread. The window can be moved and resized;
there are no widgets or rendering APIs yet. Defaults are title `ui` and an
800 × 600 client area. Dimensions must be 1–65535 pixels; titles must be valid
UTF-8 without NUL bytes and at most 4096 bytes. Failures return a C3 optional
error; the example shows how to report it.

- **Windows:** Win32 (`user32` and `kernel32`), with a Unicode title and a normal
  desktop window. Build with the Windows SDK used by C3.
- **Linux:** direct X11 protocol over a local Unix socket, using `DISPLAY` and
  MIT-MAGIC-COOKIE-1 authentication from `XAUTHORITY` or `~/.Xauthority`. Supports
  `:0`, `:0.1`, `unix:0`, and `unix/:0` display names. Requires an X server or
  XWayland; native Wayland and remote TCP/SSH displays are not implemented.

There are no third-party library dependencies. Linux uses the system C library
and display server, without linking Xlib, XCB, SDL, GLFW, GTK, or Qt. Windows uses
its system APIs. The protocol follows the [X11 specification](https://www.x.org/releases/current/doc/xproto/x11protocol.html);
Windows uses the [Win32 window lifecycle](https://learn.microsoft.com/en-us/windows/win32/learnwin32/creating-a-window).

## Example

The [`window example`](examples/window) opens a blank native window and reports
startup errors. It depends on this local `ui.c3l` library.

From the repository root, on either supported platform:

```sh
c3c run --path examples/window
```

Close the window using the title-bar close button to exit.

## Tests

Run the C3 unit tests (no desktop required):

```sh
c3c test
```

Run the Linux protocol integration tests with Python 3. They build the example
and use a simulated X server, so no desktop or extra Python packages are needed:

```sh
python3 -m unittest discover -s tests -v
```

Opt in to the native desktop test to verify the Unicode title, client size,
close handling, and reopening in the same process. It briefly opens two windows:

```sh
# Linux: uses the current display, or run under xvfb-run -a.
UI_NATIVE_TESTS=1 python3 -m unittest discover -s tests -v
```

```powershell
# Windows, from a desktop session with C3, the Windows SDK, and Python on PATH:
$env:UI_NATIVE_TESTS = "1"
python -m unittest discover -s tests -v
```

The Linux native test driver uses system `libX11` through Python's `ctypes` to
inspect and close the windows; this is only a test dependency. Protocol tests
cover authentication, fragmented reads, window properties, close events,
connection loss, and malformed server responses.

## License

This project is licensed under the [BSD 2-Clause License](LICENSE) (SPDX: `BSD-2-Clause`).
