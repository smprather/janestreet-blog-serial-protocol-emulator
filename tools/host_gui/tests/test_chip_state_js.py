"""Behavioural test for the GUI's chip-state readout (the R2 STATUS panel).

`renderStatus` filled the page's "Chip state" field with
`status.state === 1 ? "RUNNING" : "STOPPED"` - a two-way collapse of a FOUR
value word. R2's STATUS reports the chip's own state encoding, and R3 made two
of those values reachable: 2 (DEBUG_HOLD, a step-pause) and 3 (BP_HIT, a core
parked on a breakpoint, with the run strap still high). So the main panel read
**STOPPED** for a core that was in fact held at a breakpoint, on the same page
whose debug panel correctly showed `BP_HIT (3)` one row down. Two readouts of
the same register, disagreeing, on the field an operator looks at first.

The R2 golden steps `status_reports_the_hold` and `status_reports_the_hit` are
what make those two states real for R2, and they ship unconfirmed until the
chip re-runs them, so this test asserts the GUI does not MISREPORT them: a held
core may not be labelled with a state the chip did not report.

The logic lives in app.js, so the test loads app.js in Node with a tiny DOM stub
and calls `renderStatus` directly - a string-presence check would pass against
the old collapse.

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

DRIVER = r"""
const fs = require('fs');
const source = fs.readFileSync(process.argv[1], 'utf8');

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

const body = source.replace(/\nmain\(\);\s*$/, '') +
  '\nmodule.exports = { renderStatus };';
const module_shim = { exports: {} };
new Function('module', 'exports', 'require', 'document', 'window', 'location',
             'fetch', 'WebSocket', 'setInterval', 'clearInterval', body)(
  module_shim, module_shim.exports, require, document, window, location,
  fetch, WebSocket, setInterval, clearInterval);
const { renderStatus } = module_shim.exports;

const samples = JSON.parse(process.argv[2]);
const out = [];
for (const status of samples) {
  renderStatus(status);
  out.push({ chip_state: elements['chip-state']?.textContent,
             run_state: elements['run-state']?.textContent });
}
process.stdout.write(JSON.stringify(out));
"""


def drive(samples):
    if NODE is None:
        raise unittest.SkipTest("node not installed")
    result = subprocess.run([NODE, "-e", DRIVER, str(APP_JS), json.dumps(samples)],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise AssertionError(f"node driver failed: {result.stderr[:400]}")
    return json.loads(result.stdout)


def sample(state, run):
    return {"state": state, "run": run, "target": 0, "pc": 0, "a": 0, "x": 0,
            "y": 0, "timer": 0, "faults": 0, "words_written": 0}


class TestChipStateReadout(unittest.TestCase):
    def test_a_core_parked_on_a_breakpoint_is_not_labelled_stopped(self):
        """state=3, run=1 - the chip's own M3 case and golden step 21."""
        out = drive([sample(3, 1)])
        self.assertNotEqual(out[-1]["chip_state"], "STOPPED")
        self.assertIn("3", out[-1]["chip_state"])
        # the strap readout is separate and must not be laundered into the
        # state label: the hit holds the core, not the run strap
        self.assertEqual(out[-1]["run_state"], "on")

    def test_a_step_pause_is_not_labelled_a_plain_stop(self):
        """state=2, run=0 - golden step 19."""
        out = drive([sample(2, 0)])
        self.assertNotEqual(out[-1]["chip_state"], "STOPPED")
        self.assertIn("2", out[-1]["chip_state"])
        self.assertEqual(out[-1]["run_state"], "off")

    def test_the_two_ordinary_states_still_read_as_before(self):
        out = drive([sample(0, 0), sample(1, 1)])
        self.assertIn("STOPPED", out[0]["chip_state"])
        self.assertIn("RUNNING", out[1]["chip_state"])
        self.assertIn("0", out[0]["chip_state"])
        self.assertIn("1", out[1]["chip_state"])

    def test_an_unrecognised_state_is_shown_not_swallowed(self):
        """A word the page has no name for must not be reported as STOPPED.

        Collapsing an unknown value into a definite one is how a version skew
        between the host and a newer chip would read as a healthy stopped core.
        """
        out = drive([sample(7, 0)])
        self.assertNotEqual(out[-1]["chip_state"], "STOPPED")
        self.assertIn("7", out[-1]["chip_state"])
