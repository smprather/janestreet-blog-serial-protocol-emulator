"""GUI server skeleton: dependency-free request logic + optional FastAPI app.

Plan file map (Task 6) and Global Constraints: FastAPI/uvicorn and pyserial
are optional GUI dependencies; the core regression must stay dependency-free.
So the request logic lives in ``Api`` (plain dicts, no web framework), and
``create_app``/``serve`` lazily require FastAPI/uvicorn, raising
``ServerDependencyError`` with the install hint when they are absent.

Security posture (plan Task 6 Step 4): the server binds to loopback by default,
and neither arbitrary filesystem paths nor arbitrary serial-device paths are
reachable over HTTP. ``/api/assemble`` and ``/api/load`` take a bare ``.pe``
*name* resolved inside the configured sources directory; ``/api/connect``
takes no device argument (the transport factory is fixed at construction).
"""

from __future__ import annotations

import asyncio
from dataclasses import asdict, dataclass
from pathlib import Path

from tools.host_gui import image as I
from tools.host_gui import session as S
from tools.host_gui import transport as T

try:  # optional dependency
    from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
    from fastapi.responses import FileResponse  # noqa: F401
    from fastapi.staticfiles import StaticFiles

    HAVE_FASTAPI = True
except ImportError:  # pragma: no cover - exercised in the no-fastapi unit test
    HAVE_FASTAPI = False


class ServerDependencyError(RuntimeError):
    """FastAPI/uvicorn (or pyserial) is missing for the requested operation."""


class ApiError(Exception):
    """A request-level error with an HTTP-ish status code."""

    def __init__(self, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class ServerConfig:
    repo_root: Path
    sources_dir: Path
    web_dir: Path

    @classmethod
    def default(cls) -> ServerConfig:
        package = Path(__file__).resolve().parent
        repo_root = package.parents[1]
        return cls(
            repo_root=repo_root,
            sources_dir=repo_root / "firmware",
            web_dir=package / "web",
        )


def resolve_source(name: str, sources_dir: Path) -> Path:
    """Resolve a bare .pe name inside ``sources_dir``, rejecting traversal."""
    if (
        not isinstance(name, str)
        or not name
        or not name.endswith(".pe")
        or Path(name).name != name
        or "\x00" in name
    ):
        raise ApiError(
            f"invalid source name {name!r}; expected a .pe file name in the "
            f"sources directory",
            400,
        )
    root = Path(sources_dir).resolve()
    path = (root / name).resolve()
    if path.parent != root:
        raise ApiError(f"source {name!r} escapes the sources directory", 400)
    if not path.is_file():
        raise ApiError(f"source {name!r} not found", 404)
    return path


class Api:
    """Framework-free request handlers shared by FastAPI and the tests."""

    def __init__(self, session: S.ControllerSession, config: ServerConfig) -> None:
        self.session = session
        self.config = config

    def health(self) -> dict:
        return {
            "ok": True,
            "protocol_version": T.PROTOCOL_VERSION,
            "state": str(self.session.state),
            "session_id": self.session.session_id,
            "sclk_hz": self.session.negotiated_sclk_hz,
        }

    def connect(self) -> dict:
        self.session.connect()
        return {"state": str(self.session.state)}

    def sources(self) -> dict:
        root = Path(self.config.sources_dir)
        if not root.is_dir():
            raise ApiError(f"sources directory not found: {root}", 500)
        names = sorted(p.name for p in root.glob("*.pe") if p.is_file())
        return {"sources": names}

    def assemble(self, source: str) -> dict:
        path = resolve_source(source, self.config.sources_dir)
        image = I.assemble_program(path, self.config.repo_root)
        return {"manifest": image.manifest()}

    def load(self, source: str) -> dict:
        path = resolve_source(source, self.config.sources_dir)
        image = I.assemble_program(path, self.config.repo_root)
        result = self.session.load(image)
        return {"manifest": image.manifest(), "load": asdict(result)}

    def start(self) -> dict:
        self.session.start()
        return {"state": str(self.session.state)}

    def stop(self) -> dict:
        self.session.stop()
        return {"state": str(self.session.state)}

    def status(self) -> dict:
        return {"status": asdict(self.session.status())}

    def read_cpu(self) -> dict:
        return {"cpu": asdict(self.session.read_cpu())}

    def dump(self) -> dict:
        return {"dump": asdict(self.session.dump_core())}

    # ---- R3 debug control --------------------------------------------------
    # Thin wrappers over the session, which owns the state machine. The
    # responses carry the chip's own state word so the GUI can render
    # DEBUG_HOLD and BP_HIT as what they are, and `bp_flags` so "armed" and
    # "hit" are never inferred from the address (address 0 is a legal
    # breakpoint, told apart by bit0 only).
    def debug_status(self) -> dict:
        snapshot = self.session.debug_status()
        return {
            "debug": asdict(snapshot),
            "state_name": snapshot.state_name,
            "armed": snapshot.armed,
            "hit": snapshot.hit,
        }

    def debug_step(self) -> dict:
        result = self.session.debug_step()
        return {
            "step": asdict(result),
            "state_name": result.state_name,
            "hit": result.hit,
        }

    def bp_set(self, address) -> dict:
        # The value is validated by the session, which raises a typed
        # SessionError (-> 409) for a non-integer. Coercing here with int()
        # would raise ValueError out of the route instead, because guarded()
        # only catches ApiError and SessionError.
        result = self.session.bp_set(address)
        return {
            "breakpoint": asdict(result),
            "state_name": result.state_name,
            "armed": result.armed,
        }

    def bp_clr(self) -> dict:
        result = self.session.bp_clr()
        return {"breakpoint": asdict(result), "state_name": result.state_name}

    def resume_with_breakpoint(self, address) -> dict:
        """Step off, release, re-arm -- the contract's continue recipe.

        Returns the same shape as the other debug endpoints (state_name,
        armed, hit alongside the snapshot), so the GUI's one response handler
        can render any of them.
        """
        self.session.resume_with_breakpoint(address)
        snapshot = self.session.debug_status()
        return {
            "debug": asdict(snapshot),
            "state_name": snapshot.state_name,
            "armed": snapshot.armed,
            "hit": snapshot.hit,
        }


def create_app(api: Api, config: ServerConfig):
    """Build the FastAPI app, or fail loudly when FastAPI is not installed."""
    if not HAVE_FASTAPI:
        raise ServerDependencyError(
            "FastAPI is required for the GUI server; install the host-gui "
            "extra (pip install .[host-gui])"
        )

    app = FastAPI(title="PE Host Controller", version="0.1.0")

    def guarded(fn):
        def handler(*args, **kwargs):
            try:
                return fn(*args, **kwargs)
            except ApiError as exc:
                raise HTTPException(status_code=exc.status, detail=str(exc)) from exc
            except S.SessionError as exc:
                raise HTTPException(status_code=409, detail=str(exc)) from exc

        return handler

    @app.get("/api/health")
    def health():
        return api.health()

    @app.post("/api/connect")
    def connect():
        return guarded(api.connect)()

    @app.get("/api/sources")
    def sources():
        return guarded(api.sources)()

    @app.post("/api/assemble")
    def assemble(body: dict):
        return guarded(api.assemble)(str(body.get("source", "")))

    @app.post("/api/load")
    def load(body: dict):
        return guarded(api.load)(str(body.get("source", "")))

    @app.post("/api/start")
    def start():
        return guarded(api.start)()

    @app.post("/api/stop")
    def stop():
        return guarded(api.stop)()

    @app.get("/api/status")
    def status():
        return guarded(api.status)()

    @app.get("/api/read_cpu")
    def read_cpu():
        return guarded(api.read_cpu)()

    @app.post("/api/dump")
    def dump():
        return guarded(api.dump)()

    @app.get("/api/debug")
    def debug():
        return guarded(api.debug_status)()

    @app.post("/api/debug/step")
    def debug_step():
        return guarded(api.debug_step)()

    @app.post("/api/debug/bp_set")
    def bp_set(body: dict):
        return guarded(api.bp_set)(body.get("address", 0))

    @app.post("/api/debug/bp_clr")
    def bp_clr():
        return guarded(api.bp_clr)()

    @app.post("/api/debug/resume")
    def resume(body: dict):
        return guarded(api.resume_with_breakpoint)(body.get("address", 0))

    @app.websocket("/api/events")
    async def events(websocket: WebSocket):
        await websocket.accept()
        try:
            while True:
                for event in api.session.process_events():
                    await websocket.send_json(event)
                await asyncio.sleep(0.1)
        except WebSocketDisconnect:
            return

    app.mount("/", StaticFiles(directory=str(config.web_dir), html=True), name="web")
    return app


def serve(
    api: Api,
    config: ServerConfig | None = None,
    *,
    host: str = "127.0.0.1",
    port: int = 8000,
) -> None:
    """Run the GUI server on loopback (uvicorn optional)."""
    try:
        import uvicorn
    except ImportError as exc:
        raise ServerDependencyError(
            "uvicorn is required to serve the GUI; install the host-gui extra "
            "(pip install .[host-gui])"
        ) from exc
    config = config or ServerConfig.default()
    uvicorn.run(create_app(api, config), host=host, port=port)
