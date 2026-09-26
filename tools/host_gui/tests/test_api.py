"""Tests for tools/host_gui/server.py — GUI server skeleton and API logic.

The FastAPI/uvicorn/pyserial dependencies are optional (plan Global
Constraints): the request logic in ``Api`` is dependency-free and tested
directly, ``create_app`` raises ``ServerDependencyError`` when FastAPI is
absent, and the HTTP integration tests are skipped unless it is installed.
"""

from __future__ import annotations

import importlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.host_gui import fake_pe as F
from tools.host_gui import server as SV
from tools.host_gui import session as S
from tools.host_gui import transport as T
from tools.host_gui.tests.fakes import FakeClock, LoopbackPort

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
WEB = Path(SV.__file__).resolve().parent / "web"
APP_JS = REPO_ROOT / "tools" / "host_gui" / "web" / "app.js"
NODE = shutil.which("node")


def make_api(sources_dir: Path):
    clock = FakeClock()
    bridge = F.FakeBridge()
    port = LoopbackPort(bridge)
    transport = T.SerialTransport(port, clock=clock, sleep=clock.sleep)
    session = S.ControllerSession(lambda: transport, clock=clock)
    config = SV.ServerConfig(repo_root=REPO_ROOT, sources_dir=sources_dir, web_dir=WEB)
    return SV.Api(session, config), session, bridge


class TestThePageAndTheApiAgreeOnResponseKeys(unittest.TestCase):
    """The page and the API are joined by response KEYS as well as by paths.

    The route pin checks that every path the page calls is one the server
    registers. This checks the other half: every key the page reads off a
    response is one the API actually sends. A rename on either side — an
    envelope key changed in `server.py`, or a field the page starts reading —
    leaves the page rendering `undefined` at runtime, on a board, with every
    other gate green.

    The API side is measured by CALLING the methods, not by reading their
    source: a text scan of `server.py` would be a fourth scanner of mine today,
    and every one of those has been wrong at least once. So the keys come from
    a real session driven through the same sequence the acceptance run uses,
    which is why this needs no fastapi and runs in this environment.
    """

    @classmethod
    def setUpClass(cls):
        # only the Api is needed: the session and bridge are what make it work
        api = make_api(FIXTURES)[0]
        cls.keys = set()
        for response in cls._drive(api):
            cls.keys.update(response)

    @staticmethod
    def _drive(api):
        """Every API response a page can see, in the order the GUI gets them."""
        api.connect()
        yield api.sources()
        yield api.assemble("echo.pe")
        loaded = api.load("echo.pe")
        yield loaded
        yield api.start()
        yield api.status()
        yield api.read_cpu()
        yield api.debug_status()
        yield api.stop()
        yield api.dump()
        yield api.bp_set(3)
        yield api.debug_step()
        yield api.bp_clr()
        yield api.resume_with_breakpoint(3)
        yield api.health()

    def test_the_drive_reached_every_response_shape(self):
        """A drive that returned nothing would pass the test below."""
        for key in (
            "status",
            "cpu",
            "dump",
            "debug",
            "step",
            "breakpoint",
            "manifest",
            "load",
            "sources",
            "state",
        ):
            with self.subTest(key=key):
                self.assertIn(key, self.keys)

    def test_every_key_the_page_reads_is_one_the_api_sends(self):
        page = (REPO_ROOT / "tools" / "host_gui" / "web" / "app.js").read_text(
            encoding="utf-8"
        )
        read = set(re.findall(r"result\.([a-z_]+)", page))
        self.assertGreaterEqual(len(read), 5, f"the page read almost nothing: {read}")
        missing = sorted(read - self.keys)
        self.assertEqual(
            missing, [], f"the page reads {missing}, which no API response carries"
        )


class TestARefusalReachesTheOperatorAsText(unittest.TestCase):
    """The leg that makes a refusal legible: exception -> status -> page text.

    A `SessionStateError` carries the reason — "a fault is latched; clear it
    before stepping the core" — and the page shows the server's `detail` field,
    falling back to a bare status line when it is missing. So the mapping from
    exception to `(status, detail)` is load-bearing: map it wrong and the
    operator reads "Internal Server Error" instead of the sentence that tells
    them what to do.

    It lived inside `create_app` as a closure over fastapi's `HTTPException`, so
    it could only be tested with the optional extra installed — and this
    environment does not have it, which means the refusals added earlier today
    (step before a load, step while faulted, dump refused under a live hit)
    were never checked on the one path that shows them to a user.
    """

    def test_an_api_error_keeps_its_own_status(self):
        status, detail = SV.error_response(SV.ApiError("no such source", 404))
        self.assertEqual((status, detail), (404, "no such source"))

    def test_a_session_refusal_is_a_conflict_with_its_reason_intact(self):
        status, detail = SV.error_response(
            S.SessionStateError("a fault is latched; clear it first"))
        self.assertEqual(status, 409)
        self.assertIn("clear it first", detail)

    def test_a_genuine_bug_is_not_disguised_as_a_user_error(self):
        """Anything else must PROPAGATE.

        A blanket `except Exception` here would turn a real defect into a tidy
        409 with a confusing message, and the operator would go looking for
        their own mistake. This is the assertion that keeps the mapper narrow.
        """
        for boom in (ValueError("a real bug"), KeyError("missing"), TypeError()):
            with self.subTest(exc=type(boom).__name__), \
                    self.assertRaises(type(boom)):
                SV.error_response(boom)

    def test_each_refusal_the_session_can_raise_stays_readable(self):
        """The three rules added today, end to end through the mapper."""
        api, session, _bridge = make_api(FIXTURES)
        api.connect()
        messages = []
        # 1. a step before a load
        messages.append(self._refusal(session.debug_step))
        api.load("echo.pe")
        # 2. a step while faulted
        _api2, _s2, bridge = make_api(FIXTURES)
        _api2.connect()
        _api2.load("echo.pe")
        bridge.pe.faults = F.FAULT_PROTOCOL
        _s2.status()
        messages.append(self._refusal(_s2.debug_step))
        # 3. a dump under a live hit: the strap is high, so it is refused
        _api3, s3, bridge3 = make_api(FIXTURES)
        _api3.connect()
        _api3.load("echo.pe")
        _api3.start()
        bridge3.pe.bp_addr, bridge3.pe.bp_en = 1, True
        bridge3.pe.advance_free_running()
        s3.status()
        messages.append(self._refusal(s3.dump_core))
        self.assertEqual(len([m for m in messages if m]), 3, messages)
        for message in messages:
            with self.subTest(refusal=message[:30]):
                status, detail = SV.error_response(
                    S.SessionStateError(message))
                self.assertEqual(status, 409)
                self.assertEqual(detail, message,
                                 "the reason must survive the mapping intact")

    @staticmethod
    def _refusal(call):
        try:
            call()
        except S.SessionError as exc:
            return str(exc)
        raise AssertionError("expected a refusal and got none")

    def test_the_page_shows_the_servers_detail_and_not_a_bare_status(self):
        """The last leg: what the page puts in front of the operator.

        `api()` throws `body.detail || "<status> <statusText>"`, so a response
        that carries no `detail` degrades to a bare status line. Driven with a
        stubbed fetch, because a string-presence check on app.js would pass
        against a page that had stopped using the detail at all.
        """
        if NODE is None:
            self.skipTest("node not installed")
        driver = r"""
        const fs = require('fs');
        let source = fs.readFileSync(process.argv[1], 'utf8');
        const body = JSON.parse(process.argv[2]);
        // `status`/`statusText` live on the RESPONSE, not in the body - the
        // page's fallback reads response.status, so the stub has to model an
        // HTTP response rather than a decoded payload.
        const fetch = async () => ({ ok: false, status: body.status,
                                     statusText: body.statusText || 'Conflict',
                                     json: async () => ({ detail: body.detail }) });
        const document = { getElementById: () => ({ textContent: '',
                                                   classList: { toggle() {} } }),
                           createElement: () => ({}) };
        const location = { host: 'localhost', protocol: 'http:' };
        const WebSocket = function () { throw new Error('no socket'); };
        source = source.replace(/\nmain\(\);\s*$/, '') +
          '\nmodule.exports = { api };';
        const m = { exports: {} };
        new Function('module','exports','require','document','window','location',
                     'fetch','WebSocket','setInterval','clearInterval', source)(
          m, m.exports, require, document, {}, location, fetch, WebSocket,
          setInterval, clearInterval);
        m.exports.api('/api/debug/step', { method: 'POST' })
          .then(() => process.stdout.write('NO ERROR'))
          .catch((e) => process.stdout.write(e.message));
        """
        with_detail = subprocess.run(
            [NODE, "-e", driver, str(APP_JS),
             json.dumps({"status": 409,
                         "detail": "a fault is latched; clear it first"})],
            capture_output=True, text=True, check=False)
        self.assertEqual(with_detail.returncode, 0, with_detail.stderr[:300])
        self.assertEqual(with_detail.stdout.strip(),
                         "a fault is latched; clear it first")
        without = subprocess.run(
            [NODE, "-e", driver, str(APP_JS),
             json.dumps({"status": 409, "statusText": "Conflict"})],
            capture_output=True, text=True, check=False)
        self.assertEqual(without.returncode, 0, without.stderr[:300])
        self.assertIn("409", without.stdout,
                      "with no detail the page must still say something")


class TestSourceResolution(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy(FIXTURES / "echo.pe", self.root / "echo.pe")

    def test_allows_pe_file_in_root(self):
        self.assertEqual(SV.resolve_source("echo.pe", self.root).name, "echo.pe")

    def test_rejects_path_traversal(self):
        with self.assertRaises(SV.ApiError):
            SV.resolve_source("../firmware/uart_echo.pe", self.root)

    def test_rejects_absolute_path(self):
        with self.assertRaises(SV.ApiError):
            SV.resolve_source("/etc/passwd", self.root)

    def test_rejects_non_pe_extension(self):
        (self.root / "notes.txt").write_text("hello")
        with self.assertRaises(SV.ApiError):
            SV.resolve_source("notes.txt", self.root)

    def test_missing_file_is_a_404(self):
        with self.assertRaises(SV.ApiError) as ctx:
            SV.resolve_source("missing.pe", self.root)
        self.assertEqual(ctx.exception.status, 404)


class TestApi(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy(FIXTURES / "echo.pe", self.root / "echo.pe")
        self.api, self.session, self.bridge = make_api(self.root)

    def test_health_before_connect(self):
        health = self.api.health()
        self.assertTrue(health["ok"])
        self.assertEqual(health["protocol_version"], 1)
        self.assertEqual(health["state"], "DISCONNECTED")

    def test_sources_lists_only_pe_files(self):
        (self.root / "notes.txt").write_text("x")
        self.assertEqual(self.api.sources()["sources"], ["echo.pe"])

    def test_connect_load_start_stop_end_to_end(self):
        self.assertEqual(self.api.connect()["state"], "PREPARED")
        manifest = self.api.assemble("echo.pe")["manifest"]
        self.assertEqual(manifest["word_count"], 3)
        self.assertEqual(len(manifest["sha256"]), 64)
        loaded = self.api.load("echo.pe")
        self.assertEqual(loaded["load"]["words_written"], 3)
        self.assertEqual(loaded["load"]["faults"], 0)
        self.assertEqual(self.api.status()["status"]["words_written"], 3)
        self.assertIn("pc", self.api.dump()["dump"])
        self.assertEqual(self.api.start()["state"], "RUNNING")
        self.assertEqual(self.api.status()["status"]["run"], 1)
        self.assertEqual(self.api.stop()["state"], "STOPPED")

    def test_load_unknown_source_raises(self):
        with self.assertRaises(SV.ApiError) as ctx:
            self.api.load("nope.pe")
        self.assertEqual(ctx.exception.status, 404)

    def test_read_cpu_route_returns_registers_while_running(self):
        self.api.connect()
        self.api.load("echo.pe")
        self.api.start()
        cpu = self.api.read_cpu()["cpu"]
        for field in ("pc", "a", "x", "y", "insn", "state"):
            self.assertIn(field, cpu)
        self.assertEqual(cpu["state"], 1)  # running
        self.assertEqual(self.api.status()["status"]["run"], 1)

    def test_load_traversal_raises_before_any_io(self):
        with self.assertRaises(SV.ApiError):
            self.api.load("../../etc/passwd.pe")

    def test_assemble_does_not_change_session_state(self):
        self.api.connect()
        self.api.assemble("echo.pe")
        self.assertEqual(self.session.state, S.SessionState.PREPARED)


class TestWebAssets(unittest.TestCase):
    def test_first_page_has_load_progress_and_status(self):
        html = (WEB / "index.html").read_text(encoding="utf-8")
        self.assertIn("load-progress", html)
        self.assertIn("status", html)
        self.assertIn("/api/load", (WEB / "app.js").read_text(encoding="utf-8"))
        self.assertTrue((WEB / "style.css").read_text(encoding="utf-8").strip())

    def test_page_shows_the_live_cpu_header_from_read_cpu(self):
        html = (WEB / "index.html").read_text(encoding="utf-8")
        for element in ("cpu-pc", "cpu-a", "cpu-x", "cpu-y", "cpu-insn"):
            self.assertIn(element, html)
        app = (WEB / "app.js").read_text(encoding="utf-8")
        self.assertIn("/api/read_cpu", app)
        self.assertIn("cpu-pc", app)

    def test_page_polls_status_while_connected_so_idle_faults_surface(self):
        # The Pico bridge samples IRQ_N only when a host request unblocks its
        # read loop, so a session that sends nothing never sees a chip fault
        # (phase-2 record: "IRQ latency while idle"). The page must keep a
        # light poll running while connected - not only while running.
        app = (WEB / "app.js").read_text(encoding="utf-8")
        self.assertIn("pollStatus", app)
        self.assertIn("/api/status", app)
        self.assertIn("setInterval", app)

    def test_page_surfaces_chip_liveness_from_the_heartbeat(self):
        """P3 (host half): the user must see "the chip is alive and RUNNING".

        The chip's heartbeat is the STATUS `timer`; a RUNNING core whose timer
        stops advancing is exactly the liveness gap P3 describes. The page must
        show the heartbeat value and an explicit alive/stale/idle indicator
        driven by whether the timer actually moves.
        """
        html = (WEB / "index.html").read_text(encoding="utf-8")
        self.assertIn("liveness", html)
        self.assertIn("heartbeat", html)
        app = (WEB / "app.js").read_text(encoding="utf-8")
        self.assertIn("heartbeat", app)
        self.assertIn("noteHeartbeat", app)
        for state in ("alive", "stale", "idle", "unknown"):
            with self.subTest(state=state):
                self.assertIn(state, app)
        # liveness is driven by the timer moving, not by run alone
        self.assertIn("timer", app)


class TestOptionalDependencies(unittest.TestCase):
    def test_have_fastapi_flag_matches_import(self):
        # Imported DYNAMICALLY, not as a static `import fastapi`: the extra is
        # optional, so a static import is a claim that it exists. This is the
        # same reasoning as the dynamic TestClient lookup in
        # test_event_stream.py — the two places in the tree that touch the
        # optional server stack both resolve it the same way.
        try:
            importlib.import_module("fastapi")
        except ImportError:
            self.assertFalse(SV.HAVE_FASTAPI)
        else:
            self.assertTrue(SV.HAVE_FASTAPI)

    @unittest.skipIf(SV.HAVE_FASTAPI, "fastapi installed; the missing path is dead")
    def test_create_app_without_fastapi_raises(self):
        self.api, _, _ = make_api(FIXTURES)
        with self.assertRaises(SV.ServerDependencyError):
            SV.create_app(self.api, self.api.config)

    @unittest.skipUnless(SV.HAVE_FASTAPI, "fastapi not installed")
    def test_fastapi_routes_when_installed(self):
        TestClient = importlib.import_module("fastapi.testclient").TestClient
        self.api, _, _ = make_api(FIXTURES)
        client = TestClient(SV.create_app(self.api, self.api.config))
        self.assertTrue(client.get("/api/health").json()["ok"])
        self.assertEqual(client.post("/api/connect").json()["state"], "PREPARED")
        self.assertEqual(
            client.post("/api/load", json={"source": "echo.pe"}).json()["load"][
                "words_written"
            ],
            3,
        )
        client.post("/api/start")
        self.assertIn("insn", client.get("/api/read_cpu").json()["cpu"])


class TestHostGateHarness(unittest.TestCase):
    """The one-command host gate exists so a re-verify is one command, not a
    remembered list (a green run on the wrong tree proves nothing)."""

    SCRIPT = (
        Path(__file__).resolve().parents[3] / "tools" / "host_gui" / "run_host_tests.sh"
    )

    def test_gate_script_exists_and_is_executable(self):
        self.assertTrue(self.SCRIPT.is_file(), f"missing {self.SCRIPT}")
        self.assertTrue(
            os.access(self.SCRIPT, os.X_OK), f"{self.SCRIPT} is not executable"
        )

    def test_gate_script_covers_every_host_gate(self):
        text = self.SCRIPT.read_text(encoding="utf-8")
        for gate in (
            "tools/host_gui/tests",
            "tools/host_bridge/tests",
            "ruff check tools/host_gui tools/host_bridge",
            "compileall",
            "acceptance.py --fake",
        ):
            with self.subTest(gate=gate):
                self.assertIn(gate, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
