"""Live Canvas dashboard plugin — backend routes, mounted at /api/plugins/live-canvas/.

The publish API is the filesystem. A watcher thread (watchfiles, falling back to
mtime polling) keeps a registry of *slides*: HTML/SVG/diagram files under the
configured roots. The pane's WebSocket tails registry revisions and pushes
``{rev, slides, changed}`` to every connected browser; the pane renders the
newest slide, or whichever one the user pinned.

Security model:
  - Routes are gated by the dashboard's canonical auth (loopback session token /
    gated ticket) exactly like the bundled kanban plugin: HTTP routes inherit the
    /api/ auth middleware, the WS upgrade is checked with the same
    ``web_server_chat._ws_auth_ok`` helper so it can never drift from core.
  - Rendering is sandboxed on the client: slide HTML goes into an
    ``<iframe sandbox="allow-scripts">`` (no same-origin, no navigation), so a
    diagram file cannot reach the dashboard's DOM, cookies or session token.
  - File reads are confined to the configured roots (resolved-path containment
    plus an extension allowlist), so a crafted "name" cannot walk the filesystem.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Optional

from fastapi import APIRouter, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse

log = logging.getLogger(__name__)

router = APIRouter()

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

_PLUGIN_DIR = Path(__file__).resolve().parent
_ROOT_CONFIG_FILE = _PLUGIN_DIR.parent / "canvas_roots.json"
_STATE_DIR = Path.home() / ".hermes" / "live-canvas"

# Extensions the pane can render. `.excalidraw` is served as JSON metadata (the
# pane can offer a download / excalidraw.com link) but not iframed.
#
# Raster images matter here as much as vector: a layout render out of KLayout is
# a PNG, and refusing them would mean the one artifact class the flow actually
# produces could not be shown.
_RENDER_EXTS = frozenset({".html", ".htm", ".svg"})
_IMAGE_EXTS = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp"})
_TEXT_EXTS = frozenset({".md", ".txt", ".json", ".excalidraw", ".mmd"})
_ALLOWED_EXTS = _RENDER_EXTS | _IMAGE_EXTS | _TEXT_EXTS

# Files this large are almost certainly not diagrams; refuse rather than ship
# megabytes down a WS frame or into an iframe. Layout renders raise this: a
# 2x2 KLayout montage of a real block is ~10 MB, and it is exactly the kind of
# artifact this pane exists to show. Raster images are streamed by /raw (never
# through a WS frame), so they can afford the larger ceiling.
_MAX_SLIDE_BYTES = 4 * 1024 * 1024
_MAX_IMAGE_BYTES = 32 * 1024 * 1024

_DEFAULT_ROOTS = [str(Path.home() / ".hermes" / "live-canvas")]


def _load_roots() -> list[Path]:
    """Resolved, existing-or-creatable watch roots.

    ``canvas_roots.json`` sits beside the plugin (``~/.hermes/plugins/live-canvas/``)
    — not the machine's HOME only — so the same file works when the dashboard
    runs from a different profile home. Entries are absolute paths; ``~`` is
    expanded. Non-existent roots are created (a watched dir that does not exist
    yet is useless, and creating it is friendlier than silently dropping it).
    """
    raw: Any
    try:
        raw = json.loads(_ROOT_CONFIG_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raw = _DEFAULT_ROOTS
    except Exception as exc:  # malformed json — fall back, never crash the server
        log.warning("live-canvas: bad %s (%s); using defaults", _ROOT_CONFIG_FILE, exc)
        raw = _DEFAULT_ROOTS
    if not isinstance(raw, list):
        raw = _DEFAULT_ROOTS

    roots: list[Path] = []
    for entry in raw:
        if not isinstance(entry, str) or not entry.strip():
            continue
        p = Path(os.path.expanduser(entry.strip()))
        if not p.is_absolute():
            log.warning("live-canvas: ignoring non-absolute root %r", entry)
            continue
        try:
            p.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            log.warning("live-canvas: cannot create root %s (%s)", p, exc)
            continue
        roots.append(p.resolve())
    return roots


# --------------------------------------------------------------------------
# Registry
# --------------------------------------------------------------------------


def _rel_label(roots: list[Path], path: Path) -> str:
    """``<root-name>/<relative path>`` — a stable-ish display name for a slide."""
    for root in roots:
        try:
            rel = path.relative_to(root)
        except ValueError:
            continue
        return f"{root.name}/{rel.as_posix()}"
    return path.name


def _scan_roots(roots: list[Path]) -> dict[str, dict[str, Any]]:
    """Current on-disk slide set keyed by absolute path string.

    Unreadable entries are skipped rather than failing the scan — a diagram dir
    is user-managed and can contain anything.
    """
    found: dict[str, dict[str, Any]] = {}
    for root in roots:
        try:
            walker: Iterable[Path] = sorted(root.rglob("*"))
        except OSError as exc:
            log.warning("live-canvas: cannot scan %s (%s)", root, exc)
            continue
        for path in walker:
            try:
                if path.is_symlink() or not path.is_file():
                    continue
                if path.suffix.lower() not in _ALLOWED_EXTS:
                    continue
                stat = path.stat()
            except OSError:
                continue
            suffix = path.suffix.lower()
            limit = _MAX_IMAGE_BYTES if suffix in _IMAGE_EXTS else _MAX_SLIDE_BYTES
            if stat.st_size > limit:
                continue
            key = str(path.resolve())
            found[key] = {
                "key": key,
                "name": _rel_label(roots, path),
                "path": key,
                "ext": suffix[1:],
                "kind": (
                    "render" if suffix in _RENDER_EXTS
                    else "image" if suffix in _IMAGE_EXTS
                    else "text"
                ),
                "bytes": stat.st_size,
                "mtime": stat.st_mtime,
            }
    return found


class _Registry:
    """Slides + a monotonic revision counter, fanned out to WS subscribers.

    One background watcher thread (shared by every subscriber and HTTP route)
    keeps ``slides`` current; ``rev`` bumps only on an actual change, which is
    what the pane's WS loop tails. Watcher is deliberately process-global: the
    dashboard is a single server process, and N tabs sharing one thread is the
    whole point.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._slides: dict[str, dict[str, Any]] = {}
        self._rev = 0
        self._changed: Optional[dict[str, Any]] = None
        self._roots: list[Path] = []
        self._started = False
        self._stop = threading.Event()
        self._pending_reload = False
        self.last_error: str = ""

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        with self._lock:
            if self._started:
                return
            self._started = True
            self._roots = _load_roots()
            self._slides = _scan_roots(self._roots)
            self._rev = 1
        threading.Thread(target=self._watch_loop, name="live-canvas-watch", daemon=True).start()
        log.info("live-canvas: watching %s (%d slide(s))", [str(r) for r in self._roots], len(self._slides))

    def _watch_loop(self) -> None:
        """watchfiles when available; polling otherwise. Never dies."""
        try:
            from watchfiles import watch  # type: ignore

            def _gen():
                return watch(*[str(r) for r in self._roots], stop_event=self._stop, recursive=True)

        except Exception:  # pragma: no cover - depends on optional dep
            _gen = None  # type: ignore[assignment]

        while not self._stop.is_set():
            try:
                if _gen is not None:
                    for _changes in _gen():
                        if self._stop.is_set():
                            return
                        self._rescan()
                else:
                    self._rescan()
                    self._stop.wait(1.5)
            except Exception as exc:  # watcher backends can die (inotify limits, inode churn)
                self.last_error = f"{type(exc).__name__}: {exc}"
                log.warning("live-canvas: watcher error (%s); falling back to polling", exc)
                _gen = None  # type: ignore[assignment]
                self._stop.wait(1.5)

    def _rescan(self) -> None:
        """Re-read roots (cheap config reload) + diff the slide set into a revision."""
        roots = _load_roots()
        with self._lock:
            self._roots = roots
        found = _scan_roots(roots)
        with self._cond:
            old = self._slides
            changed_keys = sorted(
                (set(found) ^ set(old))
                | {
                    k for k in set(found) & set(old)
                    if (found[k]["mtime"], found[k]["bytes"]) != (old[k]["mtime"], old[k]["bytes"])
                }
            )
            if not changed_keys:
                return
            self._slides = found
            self._rev += 1
            newest = None
            if changed_keys:
                newest = max((found[k] for k in changed_keys if k in found), key=lambda s: s["mtime"], default=None)
            self._changed = {
                "keys": changed_keys,
                "names": [found[k]["name"] if k in found else os.path.basename(k) for k in changed_keys],
                "removed": [k for k in changed_keys if k not in found],
                "newest": newest["name"] if newest else None,
                "at": time.time(),
            }
            self._cond.notify_all()

    # -- queries -----------------------------------------------------------

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            slides = sorted(self._slides.values(), key=lambda s: s["mtime"], reverse=True)
            return {
                "rev": self._rev,
                "roots": [str(r) for r in self._roots],
                "slides": slides,
                "changed": self._changed,
                "last_error": self.last_error,
            }

    def wait_for_rev(self, since: int, timeout: float) -> dict[str, Any]:
        """Block until rev != since (or timeout). Returns the snapshot regardless."""
        with self._cond:
            if self._rev == since:
                self._cond.wait(timeout)
            return {
                "rev": self._rev,
                "slides": sorted(self._slides.values(), key=lambda s: s["mtime"], reverse=True),
                "roots": [str(r) for r in self._roots],
                "changed": self._changed if self._rev != since else None,
                "last_error": self.last_error,
            }

    def request_rescan(self) -> None:
        threading.Thread(target=self._rescan, name="live-canvas-rescan", daemon=True).start()

    def resolve_slide(self, key: str) -> Optional[Path]:
        """A slide path that is currently registered (never arbitrary filesystem)."""
        with self._lock:
            entry = self._slides.get(key)
        if entry is None:
            return None
        path = Path(entry["path"])
        for root in self._roots:
            try:
                path.relative_to(root)
            except ValueError:
                continue
            return path
        return None


REGISTRY = _Registry()


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


@router.get("/state")
async def state():
    """Slides + revision. First call also starts the watcher (cheap, idempotent)."""
    REGISTRY.start()
    return REGISTRY.snapshot()


@router.get("/slide")
async def slide(key: str = Query(..., description="Absolute slide path from /state")):
    """Slide payload for the pane: body text for HTML/SVG, or a download hint."""
    REGISTRY.start()
    path = REGISTRY.resolve_slide(key)
    if path is None:
        raise HTTPException(status_code=404, detail="slide not found")
    try:
        body = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"cannot read slide: {exc}") from exc
    return {"key": key, "name": path.name, "body": body, "bytes": path.stat().st_size}


@router.get("/raw")
async def raw(key: str = Query(..., description="Absolute slide path from /state")):
    """Raw bytes of a slide, for the pane's image viewer.

    Stays behind the dashboard's normal auth (the caller fetches it with
    ``SDK.authedFetch`` and turns the response into an object URL), so this
    needs no entry in core's public-path allowlist and no hole is opened for an
    <img src> that cannot carry a header. Confined to files the registry already
    holds under a configured root.
    """
    REGISTRY.start()
    path = REGISTRY.resolve_slide(key)
    if path is None:
        raise HTTPException(status_code=404, detail="slide not found")
    media = {
        ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".gif": "image/gif", ".webp": "image/webp",
        ".svg": "image/svg+xml",
    }.get(path.suffix.lower(), "application/octet-stream")
    return FileResponse(
        path,
        media_type=media,
        headers={"Cache-Control": "no-store, no-cache, must-revalidate"},
    )


@router.post("/rescan")
async def rescan():
    """Force a rescan (the pane's manual refresh)."""
    REGISTRY.start()
    REGISTRY.request_rescan()
    return {"ok": True}


@router.get("/config")
async def config():
    return {"roots_file": str(_ROOT_CONFIG_FILE), "state_dir": str(_STATE_DIR)}


# --------------------------------------------------------------------------
# WebSocket
# --------------------------------------------------------------------------

_WS_MAX_SLIDES_PER_FRAME = 60


def _ws_upgrade_authorized(ws: WebSocket) -> bool:
    """Canonical dashboard WS gate (?token= loopback / ?ticket= gated), same as kanban."""
    try:
        from hermes_cli import web_server_chat as _ws
    except Exception:
        return True
    try:
        return bool(_ws._ws_auth_ok(ws))
    except Exception:
        return False


@router.websocket("/events")
async def stream_events(ws: WebSocket):
    """Push slide-set revisions to the pane. Server->client only; ``ping`` optional."""
    if not _ws_upgrade_authorized(ws):
        await ws.close(code=1008)
        return
    REGISTRY.start()
    await ws.accept()

    try:
        since_raw = ws.query_params.get("since", "0")
        since = int(since_raw) if since_raw.isdigit() else 0
    except Exception:
        since = 0

    import asyncio

    loop = asyncio.get_running_loop()

    async def _receiver() -> None:
        """Drain client frames; returns when the socket closes (cancels the loop)."""
        try:
            while True:
                await ws.receive_text()
        except Exception:
            return

    rx = asyncio.create_task(_receiver())

    try:
        while not rx.done():
            # wait_for_rev blocks in a worker thread (threading.Condition), so the
            # event loop stays free for the receiver task and other requests. The
            # short timeout only bounds how long a stranded waiter can hold a pool
            # thread after the client vanishes; the receiver detects that first.
            waiter = loop.run_in_executor(None, REGISTRY.wait_for_rev, since, 5.0)
            done, _pending = await asyncio.wait({waiter, rx}, return_when=asyncio.FIRST_COMPLETED)
            if rx in done:
                return
            frame = waiter.result()
            if frame["rev"] == since:
                continue  # nothing changed; the receiver is the liveness signal
            since = frame["rev"]
            # Trim the inventory; the pane's slide list is a scrollback, not a
            # catalogue — 60 newest is plenty and keeps frames bounded.
            slides = frame["slides"][:_WS_MAX_SLIDES_PER_FRAME]
            await ws.send_text(
                json.dumps(
                    {
                        "type": "state",
                        "rev": frame["rev"],
                        "roots": frame["roots"],
                        "slides": slides,
                        "changed": frame.get("changed"),
                    }
                )
            )
    except WebSocketDisconnect:
        return
    except Exception as exc:  # never take the server down with us
        log.warning("live-canvas: WS loop ended: %s", exc)
        try:
            await ws.close()
        except Exception:
            pass
    finally:
        rx.cancel()
