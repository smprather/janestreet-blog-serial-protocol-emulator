"""The event stream: the one path with a socket on BOTH ends and no test.

The page opens a WebSocket to `/api/events` and renders what arrives; the
server drains the bridge's event queue into that socket. Two implementations of
one protocol, in two languages, joined only by a message shape - and nothing
tests either side of it.

That matters because the page half was changed today: `eventSocketUrl()` now
derives the scheme from the page's own protocol (a hard-coded `ws://` cannot
open on a page served over TLS, and it fails silently), and the polling
fallback now hangs off `error`/`close` as well as the synchronous throw,
because a socket to a dead endpoint does not throw - it fires an event. Both
changes are only meaningful if the endpoint exists and the shapes agree, and
"it looked right" is how the silent-failure version shipped.

So this file pins the join from both sides:
  * the server delivers a queued bridge event over the socket, with the shape the
    page reads (`event` and `data`), and the receive is BOUNDED - the endpoint
    loops forever by design, so an endpoint that stops delivering would hang a
    test rather than fail one, and a hanging test in a gate is worse than a
    missing one;
  * the page's handler renders a server-shaped event, and flags a `chip.irq` as
    an error - driven in Node against a DOM stub, because a string-presence check
    cannot tell a rendered event from a rendered `undefined`.
"""

from __future__ import annotations

import importlib
import json
import shutil
import subprocess
import threading
import unittest
from pathlib import Path
from queue import Empty, Queue

from tools.host_gui import fake_pe as F
from tools.host_gui import server as SV
from tools.host_gui import session as S
from tools.host_gui import transport as T
from tools.host_gui.tests.fakes import FakeClock, LoopbackPort

REPO_ROOT = Path(__file__).resolve().parents[3]
APP_JS = REPO_ROOT / "tools" / "host_gui" / "web" / "app.js"
WEB = Path(SV.__file__).resolve().parent / "web"
NODE = shutil.which("node")

PAGE_DRIVER = r"""
const fs = require('fs');
const source = fs.readFileSync(process.argv[1], 'utf8');
// A classList that actually tracks: a stub whose `contains` always answers
// false would make the "is this flagged as an error" assertion pass for any
// implementation, including one that never flags anything.
const classList = () => {
  const on = new Set();
  return { toggle: (c, v) => (v ? on.add(c) : on.delete(c)),
           contains: (c) => on.has(c) };
};
const elements = {};
const document = {
  getElementById: (id) => (elements[id] ||= { textContent: '', dataset: {},
                                              disabled: false, style: {},
                                              classList: classList(),
                                              value: '', prepend() {},
                                              append() {} }),
  createElement: () => ({ textContent: '', dataset: {}, style: {},
                          classList: classList(), append() {},
                          appendChild() {}, prepend() {} }),
};
const window = {};
const location = { host: 'localhost', protocol: 'http:' };
const fetch = async () => ({ ok: true, json: async () => ({}) });
const WebSocket = function () { throw new Error('no socket in the test'); };
const body = source.replace(/\nmain\(\);\s*$/, '') +
  '\nmodule.exports = { pushEvent };';
const module_shim = { exports: {} };
new Function('module', 'exports', 'require', 'document', 'window', 'location',
             'fetch', 'WebSocket', 'setInterval', 'clearInterval', body)(
  module_shim, module_shim.exports, require, document, window, location,
  fetch, WebSocket, setInterval, clearInterval);
const { pushEvent } = module_shim.exports;
const events = JSON.parse(process.argv[2]);
const prepended = [];
const realDocument = document.getElementById('events');
realDocument.prepend = (node) => prepended.push(node.textContent);
for (const event of events) pushEvent(event);
process.stdout.write(JSON.stringify({ prepended,
                                      message: elements.message?.textContent,
                                      isError: elements.message?.classList
                                                ?.contains('error') ?? false }));
"""


def render_events(events):
    if NODE is None:
        raise unittest.SkipTest("node not installed")
    result = subprocess.run(
        [NODE, "-e", PAGE_DRIVER, str(APP_JS), json.dumps(events)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"node driver failed: {result.stderr[:400]}")
    return json.loads(result.stdout)


def make_api():
    clock = FakeClock()
    bridge = F.FakeBridge()
    port = LoopbackPort(bridge)
    transport = T.SerialTransport(port, clock=clock, sleep=clock.sleep)
    session = S.ControllerSession(lambda: transport, clock=clock)
    config = SV.ServerConfig(
        repo_root=REPO_ROOT,
        sources_dir=REPO_ROOT / "tools" / "host_gui" / "tests" / "fixtures",
        web_dir=WEB,
    )
    return SV.Api(session, config), session, bridge, port


def test_client_class():
    """FastAPI's TestClient, imported DYNAMICALLY because it is an extra.

    `pip install .[host-gui]` provides it. Where it is absent, the whole
    FastAPI surface is untested - the API tests skip for the same reason - so
    this returns None rather than letting a skipped test read as coverage.
    A static `from fastapi.testclient import TestClient` would also be a lie
    at import time: the module genuinely may not exist.
    """
    try:
        return importlib.import_module("fastapi.testclient").TestClient
    except ImportError:
        return None


def receive_within(socket, seconds=5.0) -> dict:
    """Receive one message within a bound, or fail saying it never came.

    The endpoint loops forever by design, so a socket that stops delivering would
    block a plain `receive_json()` forever, and a test that HANGS in the gate is
    worse than one that fails. A Queue is the right primitive for the handoff:
    `get(timeout=)` is a real bounded wait, so there is no thread to join and
    no shared state to reason about - and the bound lives in the helper, which
    also keeps the Optional out of every call site.
    """
    box: Queue = Queue(maxsize=1)

    def take():
        try:
            box.put_nowait(socket.receive_json())
        except (AssertionError, RuntimeError, ValueError) as exc:
            box.put_nowait({"__error__": str(exc)})

    threading.Thread(target=take, daemon=True).start()
    try:
        message = box.get(timeout=seconds)
    except Empty:
        raise AssertionError(
            f"no event within {seconds}s: the socket stayed open and silent"
        ) from None
    if "__error__" in message:
        raise AssertionError(f"the socket failed: {message['__error__']}")
    return message


class TestTheServerDeliversEventsOverTheSocket(unittest.TestCase):
    """The server half: a queued bridge event reaches the socket.

    SKIPPED wherever fastapi is absent, which is a pre-existing property of
    this environment rather than of this test: the whole FastAPI surface
    (create_app, every route, this endpoint) is untested without the extra, and
    the API tests skip for the same reason.

    The first execution of this test, with the extra installed, FAILED - and it
    failed because the test never connected the session. `process_events`
    short-circuits on `self._transport is None`, so the endpoint ticked away
    faithfully delivering nothing, and the test would have "passed" a delivery
    path it never exercised. Worth recording: a test that skips everywhere can
    hide a hole in itself, and the hole was only visible once something ran it.
    """

    def setUp(self):
        client_class = test_client_class()
        if client_class is None:
            self.skipTest("fastapi is not installed in this environment")
        self.api, self.session, self.bridge, self.port = make_api()
        # The session must be CONNECTED: the endpoint drains
        # `session.process_events()`, which returns [] for a session with no
        # transport. Without this the socket is genuinely silent and the test
        # measures nothing.
        self.api.connect()
        self.client = client_class(SV.create_app(self.api, self.api.config))

    def test_a_queued_event_is_delivered_with_the_shape_the_page_reads(self):
        # Queue an event BEFORE connecting, so the endpoint's next tick has
        # something to send and the test does not depend on a race.
        self.port.incoming.append(
            json.dumps({"v": 1, "event": "chip.status", "data": {"status": 0}}).encode()
        )
        with self.client.websocket_connect("/api/events") as socket:
            message = receive_within(socket)
        # the page reads `event.event` and `event.data`; a payload that does not
        # carry both renders as `undefined` in the GUI's event list
        self.assertEqual(message["event"], "chip.status")
        self.assertIn("data", message)

    def test_the_endpoint_exists_on_the_path_the_page_opens(self):
        """The page's URL is a claim about the server; check it is one."""
        with self.client.websocket_connect("/api/events"):
            pass  # a 404 or a rejection raises here, by name


class TestThePageRendersWhatTheServerSends(unittest.TestCase):
    """The page half: a server-shaped event becomes a visible line."""

    def test_an_event_renders_its_name_and_data(self):
        out = render_events([{"event": "chip.status", "data": {"status": 0}}])
        self.assertEqual(len(out["prepended"]), 1)
        line = out["prepended"][0]
        self.assertIn("chip.status", line)
        self.assertIn("status", line)
        self.assertNotIn(
            "undefined", line, "a shape mismatch renders as undefined in the GUI"
        )

    def test_a_chip_fault_is_flagged_as_an_error(self):
        out = render_events([{"event": "chip.irq", "data": {"faults": 1}}])
        self.assertIn("chip fault asserted", out["message"] or "")
        self.assertTrue(
            out["isError"], "a chip fault must be marked as an error, not a note"
        )

    def test_an_event_without_data_still_renders(self):
        """`data` is optional in the page; a bare event must not read undefined."""
        out = render_events([{"event": "board.reset"}])
        self.assertNotIn("undefined", out["prepended"][0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
