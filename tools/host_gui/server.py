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
        return cls(repo_root=repo_root, sources_dir=repo_root / "firmware",
                   web_dir=package / "web")


def resolve_source(name: str, sources_dir: Path) -> Path:
    """Resolve a bare .pe name inside ``sources_dir``, rejecting traversal."""
    if (not isinstance(name, str) or not name or not name.endswith(".pe")
            or Path(name).name != name or "\x00" in name):
        raise ApiError(
            f"invalid source name {name!r}; expected a .pe file name in the "
            f"sources directory", 400)
    root = Path(sources_dir).resolve()
    path = (root / name).resolve()
    if path.parent != root:
        raise ApiError(f"source {name!r} escapes the sources directory", 400)
    if not path.is_file():
        raise ApiError(f"source {name!r} not found", 404)
    return path


class Api:
    """Framework-free request handlers shared by FastAPI and the tests."""

    def __init__(self, session: S.ControllerSession,
                 config: ServerConfig) -> None:
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

    def dump(self) -> dict:
        return {"dump": asdict(self.session.dump_core())}


def create_app(api: Api, config: ServerConfig):
    """Build the FastAPI app, or fail loudly when FastAPI is not installed."""
    if not HAVE_FASTAPI:
        raise ServerDependencyError(
            "FastAPI is required for the GUI server; install the host-gui "
            "extra (pip install .[host-gui])")

    app = FastAPI(title="PE Host Controller", version="0.1.0")

    def guarded(fn):
        def handler(*args, **kwargs):
            try:
                return fn(*args, **kwargs)
            except ApiError as exc:
                raise HTTPException(status_code=exc.status,
                                    detail=str(exc)) from exc
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

    @app.post("/api/dump")
    def dump():
        return guarded(api.dump)()

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

    app.mount("/", StaticFiles(directory=str(config.web_dir), html=True),
              name="web")
    return app


def serve(api: Api, config: ServerConfig | None = None, *, host: str = "127.0.0.1",
          port: int = 8000) -> None:
    """Run the GUI server on loopback (uvicorn optional)."""
    try:
        import uvicorn
    except ImportError as exc:
        raise ServerDependencyError(
            "uvicorn is required to serve the GUI; install the host-gui extra "
            "(pip install .[host-gui])") from exc
    config = config or ServerConfig.default()
    uvicorn.run(create_app(api, config), host=host, port=port)
