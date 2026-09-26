"""Tests for tools/host_gui/server.py — GUI server skeleton and API logic.

The FastAPI/uvicorn/pyserial dependencies are optional (plan Global
Constraints): the request logic in ``Api`` is dependency-free and tested
directly, ``create_app`` raises ``ServerDependencyError`` when FastAPI is
absent, and the HTTP integration tests are skipped unless it is installed.
"""

from __future__ import annotations

import importlib
import os
import re
import shutil
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


def make_api(sources_dir: Path):
    clock = FakeClock()
    bridge = F.FakeBridge()
    port = LoopbackPort(bridge)
    transport = T.SerialTransport(port, clock=clock, sleep=clock.sleep)
    session = S.ControllerSession(lambda: transport, clock=clock)
    config = SV.ServerConfig(repo_root=REPO_ROOT, sources_dir=sources_dir,
                             web_dir=WEB)
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
        for key in ("status", "cpu", "dump", "debug", "step", "breakpoint",
                    "manifest", "load", "sources", "state"):
            with self.subTest(key=key):
                self.assertIn(key, self.keys)

    def test_every_key_the_page_reads_is_one_the_api_sends(self):
        page = (REPO_ROOT / "tools" / "host_gui" / "web" / "app.js").read_text(
            encoding="utf-8")
        read = set(re.findall(r"result\.([a-z_]+)", page))
        self.assertGreaterEqual(len(read), 5,
                                f"the page read almost nothing: {read}")
        missing = sorted(read - self.keys)
        self.assertEqual(
            missing, [],
            f"the page reads {missing}, which no API response carries")


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
        self.assertEqual(cpu["state"], 1)          # running
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
        TestClient = importlib.import_module(
            "fastapi.testclient").TestClient
        self.api, _, _ = make_api(FIXTURES)
        client = TestClient(SV.create_app(self.api, self.api.config))
        self.assertTrue(client.get("/api/health").json()["ok"])
        self.assertEqual(client.post("/api/connect").json()["state"], "PREPARED")
        self.assertEqual(client.post("/api/load", json={"source": "echo.pe"})
                         .json()["load"]["words_written"], 3)
        client.post("/api/start")
        self.assertIn("insn", client.get("/api/read_cpu").json()["cpu"])


class TestHostGateHarness(unittest.TestCase):
    """The one-command host gate exists so a re-verify is one command, not a
    remembered list (a green run on the wrong tree proves nothing)."""

    SCRIPT = Path(__file__).resolve().parents[3] / "tools" / "host_gui" / \
        "run_host_tests.sh"

    def test_gate_script_exists_and_is_executable(self):
        self.assertTrue(self.SCRIPT.is_file(), f"missing {self.SCRIPT}")
        self.assertTrue(os.access(self.SCRIPT, os.X_OK),
                        f"{self.SCRIPT} is not executable")

    def test_gate_script_covers_every_host_gate(self):
        text = self.SCRIPT.read_text(encoding="utf-8")
        for gate in ("tools/host_gui/tests", "tools/host_bridge/tests",
                     "ruff check tools/host_gui tools/host_bridge",
                     "compileall", "acceptance.py --fake"):
            with self.subTest(gate=gate):
                self.assertIn(gate, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
