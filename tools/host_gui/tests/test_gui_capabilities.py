"""The GUI's buttons must be exactly the operations the session accepts.

Two implementations of one policy live on either side of the HTTP boundary: the
Python session decides what is legal in a given state, and `app.js` decides
which buttons to enable. Nothing connected them, so they drift silently - and
they HAVE drifted, twice, in the same direction:

* `dump` was enabled only in `["PREPARED","LOADED","STOPPED"]`, but a core in a
  step-pause (`DEBUG_HOLD`, strap low) is a state the session WILL read: the
  chip gates `DUMP_CORE` on the run strap, and the strap is low. The button hid
  a read that works.
* the register poll ran only while `state === "RUNNING"`, so after the poll
  path learned to report `BP_HIT` the register view froze at its pre-hit values
  while the debug panel, one row down, showed the post-hit PC. Two views of one
  register, disagreeing - the same failure the chip-state readout had.

So this test asks BOTH sides the same question for the same six states and
requires the same answer. The session column is measured by calling the real
`ControllerSession` on a real `FakeBridge` (a fresh stack per operation, because
a successful call changes the state the next one would see - the first version
of this probe reported `start` as legal in PREPARED purely because `load` ran
first). The GUI column is measured by driving the page's own `renderHealth` in
Node against a DOM stub, the same technique `test_liveness_js.py` uses, because
a string-presence check cannot tell an enabled button from a disabled one.

No state in the table is hand-written: both columns are read at run time, so the
test fails when either side moves.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path

from tools.host_gui import fake_pe as F
from tools.host_gui import image as I
from tools.host_gui import session as S
from tools.host_gui import transport as T
from tools.host_gui.tests.fakes import FakeClock, LoopbackPort

REPO_ROOT = Path(__file__).resolve().parents[3]
APP_JS = REPO_ROOT / "tools" / "host_gui" / "web" / "app.js"
ECHO_PE = REPO_ROOT / "tools" / "host_gui" / "tests" / "fixtures" / "echo.pe"
NODE = shutil.which("node")
ECHO = I.assemble_program(ECHO_PE, REPO_ROOT)

# The four operations that have a button, named as the page names them.
BUTTON_OPS = {"load": "load", "start": "start", "stop": "stop", "dump": "dump_core"}

# The page polls this one, and it is not a button: READ_CPU is the NON-halting
# read, so the session answers it in every state.
POLLED_OP = "read_cpu"
CPU_POLL_MS = 1000

DRIVER = r"""
const fs = require('fs');
const source = fs.readFileSync(process.argv[1], 'utf8');

const elements = {};
const document = {
  getElementById: (id) => (elements[id] ||= { textContent: '', dataset: {},
                                              disabled: false, style: {},
                                              value: '', append() {} }),
  createElement: () => ({ textContent: '', dataset: '', style: {},
                          append() {}, appendChild() {} }),
};
const window = {};
const location = { host: 'localhost' };
const fetch = async () => ({ ok: true, json: async () => ({}) });
const WebSocket = function () { throw new Error('no socket in the test'); };

// Record the page's timers so a poll can be OBSERVED (started / not started)
// rather than inferred from a string in the source. A fresh process per state,
// so nothing carries over.
const timers = [];
const setInterval = (fn, ms) => { timers.push(ms); return timers.length; };
const clearInterval = (id) => { timers[Number(id) - 1] = null; };

const body = source.replace(/\nmain\(\);\s*$/, '') +
  '\nmodule.exports = { renderHealth };';
const module_shim = { exports: {} };
new Function('module', 'exports', 'require', 'document', 'window', 'location',
             'fetch', 'WebSocket', 'setInterval', 'clearInterval', body)(
  module_shim, module_shim.exports, require, document, window, location,
  fetch, WebSocket, setInterval, clearInterval);
const { renderHealth } = module_shim.exports;

const health = JSON.parse(process.argv[2]);
renderHealth(health);
const out = { buttons: {}, cpu_poll_ms: null };
for (const id of ['load', 'start', 'stop', 'dump']) {
  out.buttons[id] = !elements[id]?.disabled;
}
for (const ms of timers) if (ms === 1000) out.cpu_poll_ms = ms;
process.stdout.write(JSON.stringify(out));
"""


def gui_buttons(state):
    """What the page would enable for this session state, from the page itself."""
    if NODE is None:
        raise unittest.SkipTest("node not installed")
    result = subprocess.run(
        [NODE, "-e", DRIVER, str(APP_JS),
         json.dumps({"state": state, "session_id": "s", "sclk_hz": 60_000_000})],
        capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise AssertionError(f"node driver failed: {result.stderr[:400]}")
    return json.loads(result.stdout)


def _stack():
    clock = FakeClock()
    bridge = F.FakeBridge()
    transport = T.SerialTransport(LoopbackPort(bridge), clock=clock,
                                  sleep=clock.sleep)
    return S.ControllerSession(lambda: transport, clock=clock), bridge


def _prepared():
    session, bridge = _stack()
    session.connect()
    return session, bridge


def _loaded():
    session, bridge = _prepared()
    session.load(ECHO)
    return session, bridge


def _stopped():
    session, bridge = _loaded()
    session.start()
    session.stop()
    return session, bridge


def _running():
    session, bridge = _loaded()
    session.start()
    return session, bridge


def _debug_hold():
    # one step, breakpoint armed further ahead, strap low
    session, bridge = _stopped()
    session.bp_set(3)
    session.debug_step()
    return session, bridge


def _bp_hit():
    # the live hit: the core stops ON the breakpoint with the strap still high
    session, bridge = _running()
    session.bp_set(1)
    bridge.pe.advance_free_running()
    session.status()
    return session, bridge


STATES = {
    "PREPARED": _prepared,
    "LOADED": _loaded,
    "STOPPED": _stopped,
    "RUNNING": _running,
    "DEBUG_HOLD": _debug_hold,
    "BP_HIT": _bp_hit,
}

CALLS = {
    "load": lambda session: session.load(ECHO),
    "start": lambda session: session.start(),
    "stop": lambda session: session.stop(),
    "dump_core": lambda session: session.dump_core(),
    "read_cpu": lambda session: session.read_cpu(),
}


def session_accepts(state, operation):
    """One operation, on a FRESH stack in `state` - no ordering contamination."""
    session, _bridge = STATES[state]()
    try:
        CALLS[operation](session)
    except S.SessionStateError:
        return False
    return True


class TestGuiButtonsMatchTheSession(unittest.TestCase):
    def test_the_states_under_test_are_the_ones_the_chip_can_report(self):
        """The held states must be reachable, or the rest of this proves little."""
        for state in ("DEBUG_HOLD", "BP_HIT"):
            with self.subTest(state=state):
                self.assertEqual(str(STATES[state]()[0].state), state)

    def test_every_button_matches_what_the_session_accepts(self):
        for state in STATES:
            gui = gui_buttons(state)
            for button, operation in BUTTON_OPS.items():
                with self.subTest(state=state, button=button):
                    self.assertEqual(
                        gui["buttons"][button], session_accepts(state, operation),
                        f"{button} in {state}: the page and the session disagree")

    def test_the_register_poll_follows_the_non_halting_read(self):
        """READ_CPU answers in EVERY state, so the page must poll it always.

        A poll that stops is worse than no poll: the register view freezes at
        whatever it last read, which for BP_HIT is the core BEFORE the hit.
        """
        for state in STATES:
            with self.subTest(state=state):
                gui = gui_buttons(state)
                self.assertTrue(
                    session_accepts(state, POLLED_OP),
                    f"{state}: READ_CPU must be available for this test to mean "
                    f"anything")
                self.assertEqual(gui["cpu_poll_ms"], CPU_POLL_MS)

    def test_a_breakpoint_hit_keeps_both_views_of_the_pc_live(self):
        """The regression, stated as one assertion.

        The debug panel shows the post-hit PC from DEBUG_STATUS; the register
        view shows it from READ_CPU. If the register poll stops at BP_HIT, the
        page displays the pre-hit PC and the post-hit PC at the same time.
        """
        gui = gui_buttons("BP_HIT")
        self.assertEqual(gui["cpu_poll_ms"], CPU_POLL_MS)
        # and the dump path must NOT be offered: the strap is high, so the chip
        # answers NOT_READY (golden step dump_core_refused_the_strap_is_high)
        self.assertFalse(gui["buttons"]["dump"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
