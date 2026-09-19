# diagrams/

Presentation output for the live-canvas dashboard pane (`tools/live-canvas/`).

Drop an `.html` or `.svg` file here and it appears in the dashboard **Canvas**
tab (`hermes dashboard` → http://127.0.0.1:9119/canvas) within about a second —
no reload, no interaction. The pane follows the newest file; click any entry in
its list to pin that one instead.

```bash
hermes dashboard                                   # start it (once)
tools/live-canvas/canvas-publish.sh scratch.svg    # publish a file
```

Everything in here is scratch: these are rendered files, not sources, and the
directory is git-ignored on purpose (it churns on every regeneration, and a
rendered diagram is a reproducible artifact, not a checked-in one). Generate the
diagram from a checked-in source — a script under `tools/` or an RTL-derived
view — and treat the output as disposable.

Notes:
- `.svg` and `.html` render; `.md/.txt/.json/.excalidraw/.mmd` show as text.
- HTML runs sandboxed (no same-origin, no access to the dashboard's session).
- Files over 4 MB are ignored.
