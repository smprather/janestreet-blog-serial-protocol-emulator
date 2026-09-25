"""Server/API fuzzer: hostile input against the host SERVER surface.

``fuzz_protocol.py`` stops at the wire: the two frame codecs and the FakePE
model. This tool attacks the layer a GUI client actually talks to:

  * the dependency-free ``Api`` handlers and the FastAPI routes over them;
  * the ``ControllerSession`` state machine under hostile request sequences
    (wrong-state requests, rapid connect/load/start/stop/reset);
  * a hostile or merely broken bridge on the other end of the transport
    (garbage lines, wrong ids, dropped replies, oversize lines, ``ok=false``);
  * concurrent/interleaved requests plus a websocket-style event poller -
    exactly what the real page does (status poll + CPU poll + user clicks).

Invariants (each violated case is a Finding with a reproducing seed):

  1. TYPED FAILURE - a refused request is an ``ApiError`` (HTTP 4xx) or a
     ``SessionError`` (HTTP 409). Any other exception type is a finding.
  2. STATE SANITY - the session state is always a ``SessionState`` member, and
     no call returns or raises while it is still ``LOADING`` (LOADING is
     in-flight only; a session left there is bricked until reconnect).
  3. POSTCONDITIONS - connect -> PREPARED, load -> LOADED/FAULTED,
     start -> RUNNING, stop -> STOPPED, disconnect -> DISCONNECTED.
  4. RECOVERY - after any hostile sequence the stack still completes a clean
     load/start/status/stop/dump cycle once the bridge is healthy again.
  5. FRESH IDS - every connection's request ids restart at 1 and are
     consecutive (a reused id after reconnect could be answered by a stale
     reply).
  6. HTTP SURFACE - no hostile body or sequence may produce a 5xx, and the
     server stays alive.
  7. CONCURRENCY - on a healthy bridge, concurrent non-mutating requests and a
     concurrent event poller must not corrupt the session (no stolen or
     crossed responses). The campaign forces frequent thread switches
     (``sys.setswitchinterval(1e-6)``) so the race is reproducible rather than
     luck-dependent; the pre-fix code failed this about 2-4% of requests.
  8. REPRODUCIBLE AND BOUNDED - the seed is printed, the iteration counts are
     fixed, and a wall-clock budget overrun is itself a finding.

Usage:
    python3 -m tools.host_gui.fuzz_server                    # default campaign
    python3 -m tools.host_gui.fuzz_server --seed 7 -n 2000 --rounds 50
    python3 -m tools.host_gui.fuzz_server --json             # machine-readable

Exit: 0 = no finding, 1 = a finding (printed with the reproducing input).
"""

from __future__ import annotations

import argparse
import functools
import json
import random
import sys
import threading
import time
from collections import deque
from types import SimpleNamespace

from tools.host_gui import fake_pe as F
from tools.host_gui import image as I
from tools.host_gui import server as SV
from tools.host_gui import session as S
from tools.host_gui import transport as T
from tools.host_gui.fuzz_protocol import Finding, Report

DEFAULT_SEED = 20260926
DEFAULT_ITERATIONS = 200
DEFAULT_ROUNDS = 20
DEFAULT_THREADS = 8
DEFAULT_BUDGET_S = 60.0
RECOVERY_EVERY = 25
HTTP_ALLOWED = {200, 400, 404, 405, 409, 422}
OVERSIZE_LINE = T.DEFAULT_MAX_LINE + 1


class FakeClock:
    """Deterministic clock+sleep so a dropped reply times out instantly."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


# ---- shared harness ---------------------------------------------------------
@functools.cache
def _image():
    """The real firmware image, assembled once (assembly is ~36 ms)."""
    config = SV.ServerConfig.default()
    path = SV.resolve_source("uart_echo.pe", config.sources_dir)
    return I.assemble_program(path, config.repo_root)


class RecordingPort:
    """Lean loopback to a bridge that records each request id per connection."""

    def __init__(self, bridge) -> None:
        self.bridge = bridge
        self.incoming: deque[bytes] = deque()
        self.ids: list[int] = []
        self.closed = False

    def write(self, data: bytes) -> int:
        line = data.decode("utf-8").strip()
        try:
            message = json.loads(line)
        except ValueError:
            message = None
        if isinstance(message, dict) and isinstance(message.get("id"), int):
            self.ids.append(message["id"])
        for reply in self.bridge.handle_line(line):
            self.incoming.append(reply.encode())
        return len(data)

    def readline(self) -> bytes:
        return self.incoming.popleft() if self.incoming else b""

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


class HostileBridge(F.FakeBridge):
    """FakeBridge with a switchable fault mode; healthy until switched."""

    MODES = ("garbage", "drop", "wrong-id", "error", "oversize", "bad-version")

    def __init__(self) -> None:
        super().__init__()
        self.mode = "healthy"

    def handle_line(self, line: str) -> list[str]:
        if self.mode == "healthy":
            return super().handle_line(line)
        request_id = None
        try:
            message = json.loads(line)
            if isinstance(message, dict):
                request_id = message.get("id")
        except ValueError:
            pass
        if self.mode == "garbage" or not isinstance(request_id, int):
            return ["this is not a JSON line\n"]
        if self.mode == "drop":
            return []
        if self.mode == "wrong-id":
            return [
                json.dumps(
                    {
                        "v": 1,
                        "id": request_id + 1000,
                        "ok": True,
                        "result": {},
                        "error": None,
                    }
                )
                + "\n"
            ]
        if self.mode == "error":
            return [
                json.dumps(
                    {
                        "v": 1,
                        "id": request_id,
                        "ok": False,
                        "result": None,
                        "error": "hostile bridge",
                    }
                )
                + "\n"
            ]
        if self.mode == "oversize":
            return ["x" * OVERSIZE_LINE + "\n"]
        if self.mode == "bad-version":
            return [
                json.dumps(
                    {"v": 99, "id": request_id, "ok": True, "result": {}, "error": None}
                )
                + "\n"
            ]
        raise AssertionError(self.mode)


def _stack(*, bridge=None, clock=None, sleep=None):
    """Fresh Api+session+transport over one bridge (one port per connect)."""
    bridge = bridge if bridge is not None else F.FakeBridge()
    ports: list[RecordingPort] = []

    def factory():
        port = RecordingPort(bridge)
        ports.append(port)
        kwargs = {}
        if clock is not None:
            kwargs = {"clock": clock, "sleep": sleep}
        return T.SerialTransport(port, **kwargs)

    session = S.ControllerSession(factory)
    api = SV.Api(session, SV.ServerConfig.default())
    return SimpleNamespace(api=api, session=session, bridge=bridge, ports=ports)


def _finding(
    report: Report, kind: str, detail: str, iteration: int, input_hex: str = ""
) -> None:
    report.findings.append(Finding(kind, detail, report.seed, iteration, input_hex))


def _unexpected(report: Report, where: str, exc: BaseException, iteration: int) -> None:
    _finding(
        report,
        "unexpected-exception",
        f"{where} raised {type(exc).__name__}: {exc}",
        iteration,
    )


def _campaign(report: Report, fn, *args, **kwargs) -> None:
    """Run one campaign; a crash is a finding, not a traceback."""
    try:
        fn(*args, **kwargs)
    except Exception as exc:  # noqa: BLE001 - the crash IS a finding
        _finding(
            report,
            "campaign/crashed",
            f"{fn.__name__} raised {type(exc).__name__}: {exc}",
            -1,
        )


def _check_state(report: Report, stack, iteration: int, where: str) -> None:
    state = stack.session.state
    if not isinstance(state, S.SessionState):
        _finding(
            report,
            "state/invalid",
            f"{where}: state {state!r} is not a SessionState",
            iteration,
        )
    elif state is S.SessionState.LOADING:
        _finding(
            report,
            "state/stuck-loading",
            f"{where}: the session is still LOADING after the call "
            f"returned/raised; it is bricked until reconnect",
            iteration,
        )


def _check_ids(report: Report, stack, iteration: int) -> None:
    for index, port in enumerate(stack.ports):
        expected = list(range(1, len(port.ids) + 1))
        if port.ids != expected:
            _finding(
                report,
                "ids/not-fresh",
                f"connection {index}: request ids {port.ids} are not "
                f"1..N consecutive (stale ids can be answered by a "
                f"dropped reply)",
                iteration,
            )


def _expect(report: Report, kind: str, ok: bool, detail: str, iteration: int) -> None:
    if not ok:
        _finding(report, kind, detail, iteration)


# ---- campaign 1: hostile state sequences ------------------------------------
STATE_OPS = (
    "connect",
    "load",
    "load",
    "start",
    "start",
    "stop",
    "stop",
    "status",
    "status",
    "status",
    "read_cpu",
    "read_cpu",
    "dump",
    "dump",
    "read_imem",
    "read_dmem",
    "clear_fault",
    "negotiate",
    "process_events",
    "sources",
    "health",
    "disconnect",
)

POSTCONDITIONS = {
    "connect": S.SessionState.PREPARED,
    "start": S.SessionState.RUNNING,
    "stop": S.SessionState.STOPPED,
    "disconnect": S.SessionState.DISCONNECTED,
}


def _apply_op(name: str, stack):
    if name == "connect":
        return stack.api.connect()
    if name == "load":
        return stack.session.load(_image())
    if name == "start":
        return stack.session.start()
    if name == "stop":
        return stack.session.stop()
    if name == "status":
        return stack.session.status()
    if name == "read_cpu":
        return stack.session.read_cpu()
    if name == "dump":
        return stack.session.dump_core()
    if name == "read_imem":
        return stack.session.read_imem(0, 4)
    if name == "read_dmem":
        return stack.session.read_dmem(0, 4)
    if name == "clear_fault":
        return stack.session.clear_fault()
    if name == "negotiate":
        return stack.session.negotiate_sclk(1_000_000)
    if name == "process_events":
        return stack.session.process_events()
    if name == "sources":
        return stack.api.sources()
    if name == "health":
        return stack.api.health()
    if name == "disconnect":
        return stack.session.disconnect()
    raise AssertionError(name)


def _recovery_cycle(report: Report, iteration: int, label: str) -> None:
    """A clean full cycle must still work after any hostility."""
    stack = _stack()
    steps = (
        ("connect", lambda: stack.session.connect()),
        ("load", lambda: stack.session.load(_image())),
        ("start", lambda: stack.session.start()),
        ("status", lambda: stack.session.status()),
        ("stop", lambda: stack.session.stop()),
        ("dump", lambda: stack.session.dump_core()),
    )
    for name, fn in steps:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - the failure IS the finding
            _finding(
                report,
                "recovery/step-failed",
                f"{label}: clean {name} failed after hostility: "
                f"{type(exc).__name__}: {exc}",
                iteration,
            )
            return
    _expect(
        report,
        "recovery/postcondition",
        stack.session.state is S.SessionState.STOPPED,
        f"{label}: recovery cycle ended in {stack.session.state}",
        iteration,
    )


def campaign_state_sequences(rng, report: Report, iterations: int) -> None:
    """Random op sequences against a fresh stack; typed outcomes only."""
    for iteration in range(iterations):
        stack = _stack()
        for step in range(rng.randrange(2, 12)):
            name = rng.choice(STATE_OPS)
            report.counters[f"state/{name}"] = report.counters.get(f"state/{name}", 0) + 1
            succeeded = False
            try:
                _apply_op(name, stack)
                succeeded = True
            except (SV.ApiError, S.SessionError):
                pass  # typed refusal: expected
            except Exception as exc:  # noqa: BLE001
                _unexpected(report, f"state/{name} (step {step})", exc, iteration)
            _check_state(report, stack, iteration, f"after state/{name}")
            if not succeeded:
                continue
            post = POSTCONDITIONS.get(name)
            if post is not None and stack.session.state is not post:
                # a successful op must land in its stated postcondition
                _finding(
                    report,
                    "postcondition/failed",
                    f"{name} succeeded but state is "
                    f"{stack.session.state}, expected {post}",
                    iteration,
                )
            if name == "load" and stack.session.state not in (
                S.SessionState.LOADED,
                S.SessionState.FAULTED,
            ):
                _finding(
                    report,
                    "postcondition/failed",
                    f"load succeeded but state is {stack.session.state}",
                    iteration,
                )
        _check_ids(report, stack, iteration)
        if iteration % RECOVERY_EVERY == 0:
            _recovery_cycle(report, iteration, "state-sequences")


# ---- campaign 2: a hostile/broken bridge, then recovery ---------------------
def campaign_hostile_bridge(rng, report: Report, iterations: int) -> None:
    """Every bridge fault mode must be a typed failure, never a brick."""
    for iteration in range(iterations):
        clock = FakeClock()
        bridge = HostileBridge()
        stack = _stack(bridge=bridge, clock=clock, sleep=clock.sleep)
        try:
            stack.session.connect()
        except Exception as exc:  # noqa: BLE001
            _unexpected(report, "hostile/connect", exc, iteration)
            continue
        pre_state = stack.session.state
        mode = rng.choice(HostileBridge.MODES)
        report.counters[f"hostile/{mode}"] = report.counters.get(f"hostile/{mode}", 0) + 1
        # Half the iterations load first (so start/stop/status run loaded).
        if rng.random() < 0.5:
            try:
                stack.session.load(_image())
            except Exception as exc:  # noqa: BLE001 - healthy! must work
                _unexpected(report, "hostile/preload", exc, iteration)
                continue
        bridge.mode = mode
        op = rng.choice(
            ("load", "load", "start", "stop", "status", "dump", "read_cpu", "read_imem")
        )
        try:
            _apply_op(op, stack)
        except (SV.ApiError, S.SessionError):
            pass
        except Exception as exc:  # noqa: BLE001
            _unexpected(report, f"hostile/{mode}/{op}", exc, iteration)
        _check_state(report, stack, iteration, f"after hostile {mode}/{op}")

        # Heal the bridge: the session must become usable again.
        bridge.mode = "healthy"
        try:
            if stack.session.state is S.SessionState.FAULTED:
                stack.session.clear_fault()
            stack.session.load(_image())
            stack.session.status()
            stack.session.dump_core()
        except Exception as exc:  # noqa: BLE001
            _finding(
                report,
                "recovery/after-hostile",
                f"mode {mode}, pre-state {pre_state}, op {op}: session "
                f"did not recover: {type(exc).__name__}: {exc}",
                iteration,
            )
            continue
        _expect(
            report,
            "recovery/postcondition",
            stack.session.state is S.SessionState.LOADED,
            f"mode {mode}: recovered load did not land LOADED "
            f"(state {stack.session.state})",
            iteration,
        )
        _check_ids(report, stack, iteration)


# ---- campaign 3: the HTTP surface -------------------------------------------
def _http_bodies() -> list[tuple[dict, str]]:
    big = "a" * 1_000_000
    return [
        ({}, "empty"),
        ({"source": None}, "null"),
        ({"source": 123}, "int"),
        ({"source": ["a.pe"]}, "list"),
        ({"source": {"a": 1}}, "dict"),
        ({"source": ""}, "empty-string"),
        ({"source": "nope.pe"}, "missing"),
        ({"source": "../firmware/uart_echo.pe"}, "traversal"),
        ({"source": "/etc/passwd"}, "absolute"),
        ({"source": "x\x00.pe"}, "nul"),
        ({"source": big}, "huge"),
        ({"source": "uart_echo.pe", "junk": [1] * 1000}, "extra-junk"),
        ({"source": "uart_echo.pe"}, "valid"),
    ]


HTTP_SEQUENCES = (
    (
        "wrong-state/status-dump",
        (("GET", "/api/status", None), ("POST", "/api/dump", None)),
    ),
    (
        "wrong-state/start-cpu",
        (("POST", "/api/start", None), ("GET", "/api/read_cpu", None)),
    ),
    ("double-connect", (("POST", "/api/connect", None), ("POST", "/api/connect", None))),
    (
        "load-while-running",
        (
            ("POST", "/api/connect", None),
            ("POST", "/api/load", {"source": "uart_echo.pe"}),
            ("POST", "/api/start", None),
            ("POST", "/api/load", {"source": "uart_echo.pe"}),
            ("POST", "/api/stop", None),
        ),
    ),
    ("stop-connect", (("POST", "/api/stop", None), ("POST", "/api/connect", None))),
    (
        "traversal-and-list",
        (
            ("POST", "/api/assemble", {"source": "../../etc/passwd"}),
            ("GET", "/api/sources", None),
        ),
    ),
)


def campaign_http(rng, report: Report, iterations: int) -> None:
    """Hostile bodies and wrong-state sequences must never 5xx."""
    if not SV.HAVE_FASTAPI:
        report.counters["http/skipped"] = 1
        return
    from fastapi.testclient import TestClient  # type: ignore[import-not-found]

    stack = _stack()
    client = TestClient(
        SV.create_app(stack.api, stack.api.config), raise_server_exceptions=False
    )
    bodies = _http_bodies()
    for iteration in range(iterations):
        body, label = rng.choice(bodies)
        route = rng.choice(("/api/assemble", "/api/load"))
        response = client.post(route, json=body)
        report.counters[f"http/{label}"] = report.counters.get(f"http/{label}", 0) + 1
        if response.status_code >= 500:
            _finding(
                report,
                "http/server-error",
                f"{route} with {label} body -> 5xx ({response.text[:200]!r})",
                iteration,
                str(body)[:200],
            )
        elif response.status_code not in HTTP_ALLOWED:
            _finding(
                report,
                "http/status",
                f"{route} with {label} body -> {response.status_code} "
                f"({response.text[:200]!r})",
                iteration,
                str(body)[:200],
            )
        health = client.get("/api/health")
        if health.status_code != 200 or not health.json().get("ok"):
            _finding(
                report,
                "http/not-alive",
                f"health after {route}/{label} -> "
                f"{health.status_code} {health.text[:120]!r}",
                iteration,
            )
            return

    # Raw/garbage content types and non-object JSON bodies.
    raw_cases = (
        ("raw-garbage", b"not json", {"content-type": "application/json"}),
        ("raw-list", b"[1,2,3]", {"content-type": "application/json"}),
        ("raw-string", b'"a string"', {"content-type": "application/json"}),
        ("raw-1mb", b"x" * (1 << 20), {}),
        ("empty-body", b"", {}),
    )
    for label, content, headers in raw_cases:
        for route in ("/api/assemble", "/api/load"):
            response = client.post(route, content=content, headers=headers)
            report.counters[f"http/{label}"] = report.counters.get(f"http/{label}", 0) + 1
            if response.status_code >= 500:
                _finding(
                    report,
                    "http/server-error",
                    f"{route} with {label} -> {response.status_code} "
                    f"({response.text[:200]!r})",
                    -1,
                )
            if not client.get("/api/health").json().get("ok"):
                _finding(report, "http/not-alive", f"health after raw {label}", -1)
                return

    # Directed wrong-state / interleaved sequences, then a clean recovery.
    for label, sequence in HTTP_SEQUENCES:
        for method, path, body in sequence:
            if method == "GET":
                response = client.get(path)
            else:
                response = client.post(path, json=body)
            report.counters[f"http-seq/{label}"] = (
                report.counters.get(f"http-seq/{label}", 0) + 1
            )
            if not (200 <= response.status_code < 500):
                _finding(
                    report,
                    "http/server-error",
                    f"sequence {label}: {method} {path} -> "
                    f"{response.status_code} ({response.text[:200]!r})",
                    -1,
                )
        stack.session.disconnect()
    recovery = (
        client.post("/api/connect"),
        client.post("/api/load", json={"source": "uart_echo.pe"}),
        client.post("/api/start"),
        client.get("/api/status"),
        client.post("/api/stop"),
        client.post("/api/dump"),
    )
    for index, response in enumerate(recovery):
        if response.status_code != 200:
            _finding(
                report,
                "http/recovery",
                f"clean HTTP recovery step {index} -> "
                f"{response.status_code} ({response.text[:200]!r})",
                -1,
            )
            break
    _check_state(report, stack, -1, "after HTTP recovery")


# ---- campaign 4: concurrent/interleaved requests ----------------------------
def _run_batch(threads: int, fn) -> list[object]:
    """Run ``fn`` in N threads released by one barrier; return outcomes."""
    results: list[object] = [None] * threads
    barrier = threading.Barrier(threads + 1)

    def worker(index: int) -> None:
        barrier.wait()
        try:
            fn(index)
            results[index] = "ok"
        except BaseException as exc:  # noqa: BLE001 - type is the finding
            results[index] = exc

    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for thread in pool:
        thread.start()
    barrier.wait()
    for thread in pool:
        thread.join()
    return results


def _classify_concurrency(report: Report, results, where: str, iteration: int) -> None:
    for outcome in results:
        if isinstance(outcome, str):
            continue
        if isinstance(outcome, (SV.ApiError, S.SessionError)):
            _finding(
                report,
                "concurrency/unserialized",
                f"{where}: a legal request on a healthy bridge failed "
                f"under concurrency: {type(outcome).__name__}: {outcome}",
                iteration,
            )
        else:
            _unexpected(report, where, outcome, iteration)


def campaign_concurrency(
    rng, report: Report, rounds: int, threads: int = DEFAULT_THREADS
) -> None:
    """Parallel requests + a websocket-style poller must not corrupt anything."""
    stack = _stack()
    try:
        stack.session.connect()
        stack.session.load(_image())
    except Exception as exc:  # noqa: BLE001
        _unexpected(report, "concurrency/setup", exc, -1)
        return
    previous_interval = sys.getswitchinterval()
    sys.setswitchinterval(1e-6)  # force the race, do not hope for it
    try:
        for round_no in range(rounds):
            report.counters["concurrency/round"] = (
                report.counters.get("concurrency/round", 0) + 1
            )
            # A: non-mutating requests from many threads, all legal in every
            # state -> every failure is wire corruption.
            _classify_concurrency(
                report,
                _run_batch(threads, lambda _i: stack.session.status()),
                f"round {round_no} status",
                round_no,
            )
            _classify_concurrency(
                report,
                _run_batch(
                    threads,
                    lambda _i: (
                        stack.session.dump_core() if _i % 2 else stack.session.read_cpu()
                    ),
                ),
                f"round {round_no} read",
                round_no,
            )
            # B: a websocket-style event poller spinning while requests fly.
            stop = threading.Event()

            def _poll(stop: threading.Event = stop) -> None:
                while not stop.is_set():
                    stack.session.process_events()

            poller = threading.Thread(target=_poll, daemon=True)
            poller.start()
            try:
                _classify_concurrency(
                    report,
                    _run_batch(threads, lambda _i: stack.session.status()),
                    f"round {round_no} poller",
                    round_no,
                )
            finally:
                stop.set()
                poller.join()
            # C: mutating ops interleaved; typed refusals are fine, anything
            # else is not, and the stack must recover afterwards.
            ops = [
                rng.choice(("status", "start", "stop", "load", "dump"))
                for _ in range(threads)
            ]

            def _mixed(index: int, ops: list[str] = ops) -> None:
                _apply_op(ops[index], stack)

            results = _run_batch(threads, _mixed)
            for outcome in results:
                if isinstance(outcome, str):
                    continue
                if isinstance(outcome, (SV.ApiError, S.SessionError)):
                    continue
                if isinstance(outcome, BaseException):
                    _unexpected(report, f"round {round_no} mixed", outcome, round_no)
            try:
                stack.session.disconnect()
                stack.session.connect()
                stack.session.load(_image())
                stack.session.start()
                stack.session.stop()
                stack.session.dump_core()
            except Exception as exc:  # noqa: BLE001
                _finding(
                    report,
                    "concurrency/recovery",
                    f"round {round_no}: no recovery after mixed ops: "
                    f"{type(exc).__name__}: {exc}",
                    round_no,
                )
                return
    finally:
        sys.setswitchinterval(previous_interval)
    _check_state(report, stack, -1, "after concurrency campaign")


# ---- campaign 5: reconnect storms -------------------------------------------
def campaign_reconnect_storm(rng, report: Report, iterations: int) -> None:
    """Rapid connect/disconnect cycles: fresh ids, then a full cycle works."""
    storms = max(1, iterations // 10)
    for storm in range(storms):
        bridges: list[F.FakeBridge] = []
        ports: list[RecordingPort] = []

        def factory(bridges: list = bridges, ports: list = ports):
            bridge = F.FakeBridge()
            port = RecordingPort(bridge)
            bridges.append(bridge)
            ports.append(port)
            return T.SerialTransport(port)

        session = S.ControllerSession(factory)
        cycles = rng.randrange(2, 8)
        try:
            for _ in range(cycles):
                session.connect()
                session.status()
                session.disconnect()
                session.disconnect()  # a double disconnect must be safe
            session.connect()
            session.load(_image())
            session.start()
            session.stop()
            session.dump_core()
        except Exception as exc:  # noqa: BLE001
            _finding(
                report,
                "storm/failed",
                f"storm {storm}: {type(exc).__name__}: {exc}",
                storm,
            )
            continue
        report.counters["storm/cycles"] = report.counters.get("storm/cycles", 0) + cycles
        for index, port in enumerate(ports):
            expected = list(range(1, len(port.ids) + 1))
            if port.ids != expected:
                _finding(
                    report,
                    "storm/ids",
                    f"storm {storm} connection {index}: ids {port.ids} "
                    f"are not 1..N (reconnect did not restart ids)",
                    storm,
                )
        if session.session_id != cycles + 1:
            _finding(
                report,
                "storm/session-id",
                f"storm {storm}: session_id {session.session_id} != "
                f"{cycles + 1} connections",
                storm,
            )


# ---- driver -----------------------------------------------------------------
def run(
    seed: int = DEFAULT_SEED,
    iterations: int = DEFAULT_ITERATIONS,
    rounds: int = DEFAULT_ROUNDS,
    budget_s: float = DEFAULT_BUDGET_S,
    threads: int = DEFAULT_THREADS,
) -> Report:
    """Run the campaign; returns a Report (never raises on a finding)."""
    started = time.monotonic()
    report = Report(seed=seed, iterations=iterations, seconds=0.0)
    rng = random.Random(seed)
    _campaign(report, campaign_state_sequences, rng, report, iterations)
    _campaign(report, campaign_hostile_bridge, rng, report, iterations)
    _campaign(report, campaign_http, rng, report, iterations)
    _campaign(report, campaign_concurrency, rng, report, rounds, threads)
    _campaign(report, campaign_reconnect_storm, rng, report, iterations)
    elapsed = time.monotonic() - started
    if elapsed > budget_s:  # bounded: report, do not extend
        _finding(
            report,
            "budget/exceeded",
            f"campaign took {elapsed:.1f}s (budget {budget_s:.0f}s)",
            -1,
        )
    report.seconds = elapsed
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=(__doc__ or "server fuzzer").split("\n")[0]
    )
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("-n", "--iterations", type=int, default=DEFAULT_ITERATIONS)
    parser.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS)
    parser.add_argument("--threads", type=int, default=DEFAULT_THREADS)
    parser.add_argument("--budget", type=float, default=DEFAULT_BUDGET_S)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    report = run(args.seed, args.iterations, args.rounds, args.budget, args.threads)
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, sort_keys=True))
    else:
        print(
            f"fuzz_server seed={report.seed} iterations={report.iterations} "
            f"cases={sum(report.counters.values())} "
            f"({report.seconds:.2f}s)"
        )
        for name, count in sorted(report.counters.items()):
            print(f"  {name:<28} {count}")
        for finding in report.findings:
            print(finding.render())
        print(
            "RESULT: PASS"
            if report.ok
            else f"RESULT: FAIL ({len(report.findings)} findings)"
        )
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
