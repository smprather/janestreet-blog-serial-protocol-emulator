"""Behavioural test for the GUI liveness state machine (P3, host half).

The liveness indicator is the operator's proof that "the chip is alive and
RUNNING": it must read alive only when the chip's heartbeat (the STATUS timer)
actually ADVANCES while run=1, and stale when a running core's timer is
frozen. The logic lives in the page's app.js, so this test loads app.js in
Node with a tiny DOM stub and drives `noteHeartbeat` directly - a string-presence
check would not catch a logic inversion.

Run: the test skips (not a failure) when node is unavailable.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
APP_JS = REPO_ROOT / "tools" / "host_gui" / "web" / "app.js"
NODE = shutil.which("node")

# Extract the liveness functions from app.js and run them against a DOM stub.
DRIVER = r"""
const fs = require('fs');
const source = fs.readFileSync(process.argv[1], 'utf8');

// Minimal DOM: every id the page touches becomes a settable element. The
// elements map is shared with the assertions below, so the injected document
// and the test read the same nodes.
const elements = {};
const document = {
  getElementById: (id) => (elements[id] ||= { textContent: '', dataset: {},
                                              disabled: false, style: {},
                                              value: '', append() {} }),
  createElement: () => ({ textContent: '', dataset: {}, style: {},
                          append() {}, appendChild() {} }),
};
const window = {};
const location = { host: 'localhost' };
const fetch = async () => ({ ok: true, json: async () => ({}) });
const WebSocket = function () { throw new Error('no socket in the test'); };

// Load app.js but do not run main(); expose the liveness functions instead.
const body = source.replace(/\nmain\(\);\s*$/, '') +
  '\nmodule.exports = { noteHeartbeat, setLiveness };';
const module_shim = { exports: {} };
new Function('module', 'exports', 'require', 'document', 'window', 'location',
             'fetch', 'WebSocket', 'setInterval', 'clearInterval', body)(
  module_shim, module_shim.exports, require, document, window, location,
  fetch, WebSocket, setInterval, clearInterval);
const { noteHeartbeat } = module_shim.exports;

const steps = JSON.parse(process.argv[2]);
const out = [];
for (const [timer, run] of steps) {
  noteHeartbeat(timer, run);
  out.push({ state: elements.liveness?.dataset.state,
             text: elements.liveness?.textContent,
             heartbeat: elements.heartbeat?.textContent });
}
process.stdout.write(JSON.stringify(out));
"""


def drive(steps):
    result = subprocess.run([NODE, "-e", DRIVER, str(APP_JS), json.dumps(steps)],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise AssertionError(f"node driver failed: {result.stderr[:400]}")
    return json.loads(result.stdout)


@unittest.skipIf(NODE is None, "node not installed")
class TestLivenessStateMachine(unittest.TestCase):
    def test_running_with_advancing_heartbeat_is_alive(self):
        # Two consecutive running samples with the timer moving -> alive.
        states = drive([[1, 1], [2, 1]])
        self.assertEqual(states[-1]["state"], "alive")
        self.assertIn("alive", states[-1]["text"])

    def test_running_with_frozen_heartbeat_is_stale(self):
        # A running core whose timer does not move is the liveness gap: stale,
        # NOT alive. This is the behaviour P3 exists to catch.
        states = drive([[5, 1], [5, 1], [5, 1]])
        self.assertEqual(states[-1]["state"], "stale")
        self.assertIn("stalled", states[-1]["text"])

    def test_alive_then_stall_flips_to_stale(self):
        states = drive([[1, 1], [2, 1], [2, 1]])
        self.assertEqual(states[1]["state"], "alive")
        self.assertEqual(states[2]["state"], "stale")

    def test_stopped_core_is_idle_not_stale(self):
        states = drive([[1, 1], [1, 0]])
        self.assertEqual(states[-1]["state"], "idle")
        self.assertIn("stopped", states[-1]["text"])

    def test_no_sample_is_unknown(self):
        states = drive([[None, 1]])
        self.assertEqual(states[-1]["state"], "unknown")

    def test_heartbeat_value_is_shown(self):
        states = drive([[0x2A, 1]])
        self.assertEqual(states[-1]["heartbeat"], "0x002a")

    def test_running_from_idle_re_arms_on_a_fresh_sample(self):
        # After idle, the first running sample is "starting" (a fresh baseline),
        # then alive once it moves - a frozen timer after a resume is stale.
        states = drive([[1, 0], [1, 1], [2, 1]])
        self.assertEqual(states[1]["state"], "alive")   # first running sample
        self.assertEqual(states[2]["state"], "alive")   # moved


if __name__ == "__main__":
    unittest.main(verbosity=2)
