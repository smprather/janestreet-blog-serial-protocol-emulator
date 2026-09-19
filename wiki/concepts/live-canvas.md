---
title: Live Canvas
created: 2026-09-18
updated: 2026-09-18
type: concept
tags: [tooling, verification]
sources: []
confidence: high
---

# Live Canvas

Side-quest tooling: a live diagram channel from the agent to a browser tab.
Built 2026-09-18; source in `tools/live-canvas/`, installed for Hermes via a
symlink at `~/.hermes/plugins/live-canvas`.

## What it is

A dashboard plugin for `hermes dashboard`. It watches one or more directories and
pushes any `.html`/`.svg` file written into them to a **Canvas** tab
(`http://127.0.0.1:9119/canvas`) over a WebSocket. `write file → ~1 s → rendered`,
with no reload and no interaction.

```
agent writes diagrams/foo.svg
   → watchfiles watcher diffs the slide set, bumps a monotonic rev
   → WS /api/plugins/live-canvas/events pushes {rev, slides, changed}
   → pane re-renders the newest slide in a sandboxed iframe
```

Relevant when discussing a design visually, reviewing synthesis/area results, or
explaining a block's timing without leaving the chat.

## Publishing

```bash
hermes dashboard                                   # start it (leave the tab open)
tools/live-canvas/canvas-publish.sh scratch.svg    # copy a file in
tools/live-canvas/canvas-publish.sh -n x.svg - < f # from stdin
python3 tools/live-canvas/gen_block_status.py      # generate from STATUS.md
```

A plain `cp`/`write` into `diagrams/` works too — the helper only adds
stage-then-rename so the pane never renders a half-written file. Prefer a
generator (`gen_block_status.py` is the worked example) over hand-written SVG:
the picture then cannot drift from its source.

## Design decisions

| Decision | Why |
|---|---|
| **Filesystem is the publish API** | Any agent, editor, or script can push with no credential. Avoids the alternative (a plugin tool with an HTTP call + token) for zero security gain: the trust boundary is "who can write your diagram dirs", which is already the local user. |
| **WebSocket push, not polling** | Sub-second latency and one watcher thread serves every open tab. |
| **`watchfiles` with a 1.5 s polling fallback** | `watchfiles` ships in the Hermes venv, but inotify instance exhaustion is a real failure mode; the fallback keeps the pane working. |
| **Sandboxed iframe (`allow-scripts`, no `allow-same-origin`)** | Slide HTML is arbitrary; opaque origin means it cannot reach the dashboard's DOM, storage or `__HERMES_SESSION_TOKEN__`. Verified with an escape-probe slide. |
| **Served through the dashboard's own auth** | No new auth surface: HTTP inherits core's `/api/` middleware, the WS upgrade calls core's canonical `_ws_auth_ok`. |
| **In the repo, symlinked into `~/.hermes/plugins/`** | Version-controlled with the project (build-in-public), still discovered by the dashboard. |

## Gotchas

- **Loopback is not the only dashboard mode.** Pane code must use
  `SDK.buildWsUrl` / `SDK.fetchJSON`, never a hand-built
  `?token=window.__HERMES_SESSION_TOKEN__` URL — in gated (OAuth) mode that token
  is not injected and such requests are rejected.
- **User plugin backends are allow-listed.** `dashboard/plugin_api.py` is
  imported only for plugins in `plugins.enabled` (`hermes plugins enable
  live-canvas`); otherwise no routes exist *and* the JS/CSS 404.
- **Backend import happens once at dashboard start** — editing `plugin_api.py`
  needs a dashboard restart; editing `dist/index.js` needs only a page reload.
- **The dashboard's plugin-asset route has a suffix allowlist** (`.js/.css/.json/
  .html/.svg/...`) and is unauthenticated by design, since `<script src>` cannot
  attach headers. A backend `.py` is never fetchable.
- Diagram dirs hold **rendered output, not source** — `diagrams/` is git-ignored
  for that reason.

## Alternatives considered

Documented in `tools/live-canvas/README.md` and the log entry: Hermes Desktop's
preview rail (`open_preview`/`drive_preview`, needs an Electron build and is a
second app), the `tldraw-offline` optional skill (AUR app, scriptable live
canvas, bidirectional — complementary rather than competing), and the community
Hermes browser extension (Chromium side panel, chat-oriented).

## Related

- [[concepts/pdk-toolchain]] — the other "local environment" page: exact commands
  and their gotchas.
- [[STATUS]] — tooling commands live there too.
