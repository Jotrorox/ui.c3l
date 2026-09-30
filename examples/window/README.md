This counter builds its text and button once. Clicking **Increment** or focusing
the button with **Tab** and pressing **Enter**/**Space** changes the state; the
text binding updates the existing label automatically.

From the repository root:

```sh
c3c run --path examples/window
```

Requires a Windows desktop or a local X11/XWayland display on Linux. Close the
window to exit and release its widgets and bindings.

This example is covered by the repository's [BSD 2-Clause License](../../LICENSE).
