"""Tests for tools/host_gui/server.py — GUI server skeleton and API logic.

The FastAPI/uvicorn/pyserial dependencies are optional (plan Global
Constraints): the request logic in ``Api`` is dependency-free and tested
directly, ``create_app`` raises ``ServerDependencyError`` when FastAPI is
absent, and the HTTP integration tests are skipped unless it is installed.
"""

from __future__ import annotations

import os
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


class TestOptionalDependencies(unittest.TestCase):
    def test_have_fastapi_flag_matches_import(self):
        try:
            import fastapi  # noqa: F401
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
        from fastapi.testclient import TestClient
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
