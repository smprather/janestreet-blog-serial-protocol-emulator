# live-canvas — Hermes dashboard live diagram pane

A dashboard tab (`hermes dashboard` → **Canvas**) that renders diagram files the
instant they are written to disk. The filesystem is the publish API: any agent,
editor, or script that can write a file can push a diagram into an open browser
tab — no credentials, no API calls, no reload.

    write a file  →  watcher bumps a revision  →  WebSocket push  →  pane renders

## Install state

Source of truth is **this directory**; `~/.hermes/plugins/live-canvas` is a
symlink to it, so the repo stays the single copy:

```bash
ln -s "$REPO/tools/live-canvas" ~/.hermes/plugins/live-canvas
hermes plugins enable live-canvas      # user plugin backends only import when enabled
hermes dashboard                       # open http://127.0.0.1:9119/canvas
hermes dashboard --status              # is it already running?
hermes dashboard --no-open             # start it without launching a browser
```

## Publishing a diagram

Write an `.html` or `.svg` file into a watched directory. That is the whole API.

```bash
cp template.svg ~/janestreet-blog-serial-protocol-emulator/diagrams/foo.svg
```

The pane follows the newest file by default. Click any slide in the left list to
pin it (clicking turns "Follow latest" off); "Rescan" forces a directory rescan if
something was written by a process the watcher could not see.

Supported: `.html`, `.htm`, `.svg` (rendered in a sandboxed iframe),
`.md`, `.txt`, `.json`, `.excalidraw`, `.mmd` (shown as text). Files over 4 MB are
ignored.

### Checked-in generators

Both follow the same rule — *render from a single source of truth, never
hand-maintain the picture* — and both write atomically (stage + rename) so the
pane never renders a half-written file.

```bash
python3 gen_block_status.py                  # STATUS.md table -> block-status.svg
python3 gen_flowchart.py                     # flowcharts/rx-path.json -> serdes-rx-flow.svg
python3 gen_flowchart.py flowcharts/x.json   # any spec
python3 gen_vcd_view.py --vcd ../../sim/tb_pe_uart.vcd \
    --signals clk,bit_en,tx_busy,tx_ser,line \
    --from 200000 --to 2100000 --strobe bit_en \
    --title "…" -o ../../diagrams/uart-byte.svg
```

`gen_vcd_view.py` renders a window of any VCD as a labelled timing diagram so a
testbench's actual behaviour can be shown instead of described. Two things it
does deliberately: the **clock is drawn from its real transitions** (sampling a
clock at its own rising edges always reads a constant 1 and teaches nothing),
and every other signal is **sampled at each rising edge**, so a signal that is
only valid mid-cycle is visibly so. `--strobe signal[=label]` and
`--commit signal[=label]` draw labelled vertical markers; `--window lo,hi`
highlights a region. Times are VCD ticks (the TBs run 1 ns).

`gen_flowchart.py` lays out a flowchart from a JSON spec (grid `row`/`col`
placement, `w`/`h` optional) and routes every edge from geometry. It also
**checks its own output**: every routed segment is tested against every node box,
and a line that would pass through a shape makes the build exit 3 with the
crossing listed. Use `--allow-crossings` only when you have looked at it and
decided the overlap reads fine.

Spec routing hints (usually unnecessary — `auto` handles it):

| `route` | Use for |
|---|---|
| `auto` (default) | same row → straight across; same column → straight down; otherwise drop, across, into the target's **facing** side vertex |
| `loop-left` / `loop-right` | a back-edge: out the side, along a gutter lane, back in. A **self-loop** becomes a small local hook beside its own node |
| `into-left` / `into-right` | accepted, but resolved to whichever side faces the source, so the approach never cuts through the target |

Why the checker exists: the first build of this diagram drew a loop-back edge as
a single line straight across the whole chart and entered side-branch targets
through the far vertex, so the arrow crossed the box to reach it. Both are
invisible in a small preview and obvious in a rendered one — test with
`rsvg-convert -w 1500 -f png` (available on this machine) and look at it.


## Watched directories

Edit `canvas_roots.json` next to this README (a JSON array of absolute paths).
Currently:

    ~/janestreet-blog-serial-protocol-emulator/diagrams
    ~/.hermes/live-canvas

Add or remove an entry and it takes effect on the next rescan (watcher tick, or
the pane's Rescan button) — no server restart. Roots that do not exist are
created.

## Architecture

| Piece | File | Role |
|---|---|---|
| Watcher + registry | `dashboard/plugin_api.py` | `watchfiles` watcher (1.5 s polling fallback) diffs the slide set into a monotonic `rev` |
| HTTP | `dashboard/plugin_api.py` | `GET /state`, `GET /slide?key=`, `POST /rescan`, `GET /config` under `/api/plugins/live-canvas/` |
| Push channel | `dashboard/plugin_api.py` | `WS /api/plugins/live-canvas/events?since=<rev>` — pushes `{rev, slides, changed}` |
| Pane | `dashboard/dist/index.js` | slide list, sandboxed iframe stage, follow-latest, WS reconnect w/ backoff |
| Roots config | `canvas_roots.json` | publish directories |
| Agent surface | `__init__.py` | deliberately empty — the filesystem is the API |

## Security

- All `/api/plugins/live-canvas/*` routes sit behind the dashboard's own auth
  (loopback session token; OAuth ticket when the dashboard is gated). Verified:
  an unauthenticated request gets 401 from core middleware.
- The WS upgrade is checked with the dashboard's canonical helper
  (`web_server_chat._ws_auth_ok`) so it cannot drift from core auth.
- Slide HTML renders in `<iframe sandbox="allow-scripts">` — **no**
  `allow-same-origin`, so a diagram cannot touch the dashboard's DOM, storage, or
  session token. Verified with an escape-probe slide: `blocked (SecurityError) +
  token blocked`.
- `/slide` serves only paths the registry currently holds, which are resolved
  under a configured root (extension allowlist + containment). `/etc/passwd`
  returns 404.
- Publishing needs no credential because it is a filesystem write — the trust
  boundary is "who can write to your diagram directories", which is already your
  local user.

## Verified behaviour (2026-09-18, dashboard 0.21.3, port 9119)

- Write a new file → pane lists it and renders it in ~1 s, no interaction.
- Edit a file in place → the open iframe re-renders in ~1 s.
- `GET /state` without a token → 401; `GET /slide?key=/etc/passwd` → 404.
- Sandbox escape probe from slide HTML → blocked, no token leak.
- WS reconnect after server restart; backoff 1 s → 30 s cap.

## Gotchas found while building this

- **Loopback is not the only mode.** The pane must never read
  `window.__HERMES_SESSION_TOKEN__` directly — in gated (OAuth) mode that token is
  not injected, and hand-built WS URLs are rejected. Use `SDK.buildWsUrl` /
  `SDK.fetchJSON`, which handle both modes and the base-path prefix.
- **User plugin backends are allow-listed.** `dashboard/plugin_api.py` is only
  imported when the plugin is in `plugins.enabled`; an installed-but-disabled
  plugin gets no routes at all (its JS/CSS also 404). `hermes plugins enable
  live-canvas` is what turns it on.
- **The plugin-asset route has a suffix allowlist** and serves only
  `.js/.css/.json/.html/.svg/.png/...` — a backend `.py` is never fetchable, and
  the route is unauthenticated by design (a `<script src>` cannot attach headers).
- **The stage is paper-white, the dashboard is dark-theme.** Never let stage text
  inherit color — it arrives light-grey and renders light-on-light (this shipped
  broken once). Every element inside `.lc-stage` / `.lc-empty` must set `color`
  and `background` explicitly. Contrast audit: body `#1f2328` 15.8:1, muted
  `#57606a` 6.4:1, warn `#9a6700` 4.9:1 on `#fff`.
- **SVGs fit the width and scroll vertically**, not letterboxed into the pane —
  fitting both dimensions shrinks a tall flowchart until its labels are
  unreadable. Diagrams read top-down, so scrolling is the natural gesture.
- **Non-ASCII must be numeric character references in generated SVG.** The pane
  delivers markup through `srcdoc`; a byte-level encoding disagreement turns `—`
  into `â€"`. `gen_flowchart.esc()` exists for exactly this — route every text
  emission through it (`html.escape` alone is not enough).
- **Verify a generated diagram by rasterizing it**, not by looking at a small
  preview: `rsvg-convert -w 1500 -f png -o /tmp/x.png file.svg` and inspect at
  full size. Geometry bugs (a line through a box, a label over text) are
  invisible at thumbnail scale.
- **Backend import is once at startup** — editing `plugin_api.py` needs a
  dashboard restart; editing `dist/index.js` only needs a page reload (the SPA
  re-injects the bundle with a cache-busting query).
- **`watchfiles` is present in the Hermes venv**, but the watcher falls back to
  1.5 s polling if the import fails (e.g. exhausted inotify instances), so the
  pane keeps working on constrained hosts.
- Diagram dirs are for **presentation output**, not source. Don't put anything in
  `diagrams/` you'd mind being rendered as-is in a browser tab.
- **The stock Python `.gitignore` section swallows `dist/`.** This plugin's bundle
  is hand-written source with no build step, so `.gitignore` carries an explicit
  un-ignore for `tools/live-canvas/dashboard/dist/`. Same idea for `diagrams/*`
  (rendered output, deliberately untracked; `diagrams/README.md` is kept).

## Not chosen (considered first)

- **Hermes Desktop preview rail** — `open_preview`/`drive_preview` tools already
  exist, but need the Electron app built and put the diagram in a second app
  window rather than a browser tab.
- **`tldraw-offline` optional skill** — a real product for agent-driven live
  canvases (AUR `tldraw-offline-bin`, local API on :7236). Complementary: it is
  bidirectional drawing, this is one-way presentation from files.
- **Community browser extension** — Chromium side panel for the Hermes runtime;
  chat-oriented, not a diagram surface.
