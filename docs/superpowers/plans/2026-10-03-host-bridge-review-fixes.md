# Host-bridge review fixes: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:executing-plans to
> implement this plan task by task, inline. Steps use checkbox (`- [ ]`) syntax
> for tracking. Do the tasks IN ORDER: later tasks call names that earlier tasks
> create.

## Progress checkpoint: read this first; update it at the end of EVERY task

This is the live state. Whoever executes the plan (the pi worker in tmux pane
`0:5.4`, or any agent that picks it up after it) updates this section and
commits it together with each task, so a lost session costs nothing.

| Task | State | Commit / note |
|---|---|---|
| 1 Harden VvpTTAdapter | DONE | `530496d` |
| 2 Testbench `+script` | BUILT, NOT COMMITTED. Stopped at Step 6 by a real chip defect; **resume with Amendment A** | files in tree: `tb/tb_pe_soc_extspi.v`, `vvp_adapter.py`, `test_vvp_adapter.py`, `test_vvp_integration.py` |
| 3 Session replay (#2 fix) | TODO, with Amendment A | |
| 4 Test hygiene | TODO | |
| 5 TTAdapter read budget (#1) | TODO, own commit, FLAGGED for the user | |
| 6 Docs | TODO, and must record Amendment A's defect | |
| 7 Final verification | TODO | |
| A2 RTL fix for the IMEM read defect | **NOT for the pi worker.** Needs a stronger agent and the user's sign-off; see Amendment A | |

Decisions on record:
- 2026-10-04: the user chose "unblock first, fix the chip separately" for the
  defect (Amendment A).
- #1 (Task 5) is the user's open decision; it is implemented as a revertable
  best effort.
- Accepted ruling (manager, 2026-10-04): Task 2 Step 5's only stdout difference
  was Icarus's `$finish called at <line>` trace; the captures were
  byte-identical, so the step passes.

**Goal:** Fix every open finding from the 2026-10-03 `/code-review max --fix` pass
on `tools/host_bridge`. The headline item is that the real-bridge-over-real-chip
round trip (`test_connect_load_start_status_stop_dump_round_trip`) fails on every
run, because each simulated exchange starts from a freshly reset chip.

**Architecture:** `VvpTTAdapter` keeps its file-based, one-vvp-run-per-exchange
backend. Each exchange now REPLAYS the whole session so far (every reset,
run-pad change and earlier transfer) from power-on, using a new `+script` mode
in `tb/tb_pe_soc_extspi.v`, and then performs the new transfer. Icarus is
deterministic, so the replayed chip is exactly the chip a long-lived simulation
would hold at that point. Every replay also re-captures the earlier transfers
and must reproduce them exactly; a mismatch is raised as a harness error.

Two other approaches were rejected:
- A persistent vvp process fed over stdin/stdout pipes. A blocking `$fgets`
  stalls the whole simulator, pipe deadlocks and read timeouts would need
  `select`, and the inspectable file handshake that `vvp_adapter.py`'s docstring
  defends would be lost.
- Weakening the test.

**Tech Stack:** Python ≥ 3.12, standard library only (`unittest`,
`unittest.mock`, `subprocess`). Icarus Verilog 13 (`iverilog -g2012`, `vvp`)
with the IHP PDK SRAM model (`regress/sram_model.sh`). Lint is `ruff`
(line-length 90).

**Spec:** this plan has no separate spec document. The source is the code-review
report, condensed in **Appendix A: findings map** at the end; every finding
there is either assigned to a task or excluded with a reason. The design
background is in `docs/design/VVPT-ADAPTER-DESIGN.md` and `docs/RESUME-V1.md`.

## Global Constraints

- **Indentation is spaces only, never tab characters.** Python uses 4 spaces;
  `tb/*.v` uses 2 spaces (match the file). Check before every commit:
  `grep -nP '\t' <files>` must print nothing.
- Python must pass `ruff check` and `ruff format --check` (line-length 90,
  target py312) on every touched `.py` file.
- Use no third-party Python dependencies. `tools/host_bridge/tt_adapter.py` and
  `tools/host_bridge/main.py` also run under MicroPython on the Pico, so keep
  their code to plain builtins (`bytearray`, `bytes`, `int`).
- Work directly on `main`; repo convention is that all real work lands on `main`.
  **Do not push. Do not create branches.**
- Stage files by explicit path only. **Never use `git add -A` or `git add .`**:
  `.gitignore` swallows `*.log` silently, and this repo has lost evidence that
  way before.
- Change only the files listed in a task's **Files** block. If an editor or
  formatter extension (pi-lens) reformats any other file, restore it with
  `git checkout -- <file>` before committing.
- **Never weaken, loosen, or delete an assertion to make a test pass.** If the
  real chip answers something other than what a step says to expect, STOP. Do
  not edit the expectation. Report the observed value, the raw response words,
  and which step it was.
- Never describe a simulation result as a hardware result. Everything here is
  simulation. Open item 11 (the real Pico/USB board run) stays open.
- **tmux:** never run `tmux kill-server`, `killall tmux`, or `pkill tmux`.
- Run every command from the repo root:
  `/home/mylesp/janestreet-blog-serial-protocol-emulator`.
- Test commands:
  - one module: `python3 -m unittest tools.host_bridge.tests.<module> -v`
  - one test: `python3 -m unittest tools.host_bridge.tests.<module>.<Class>.<test> -v`
  - the whole lane: `python3 -m unittest discover -s tools/host_bridge/tests -v`

## Review Focus

These are the failure modes most likely to bite, each with the task that pins
it:

1. **A replay that does not reproduce an earlier transfer** (non-determinism,
   X on MISO) must raise `VvpTTAdapterError("... diverged ...")`, never return
   stale bytes. Task 3 tests this with `test_a_replay_that_diverges_is_a_harness_error`.
2. **A transfer that fails** (vvp timeout, testbench `FAIL`) must not leak into
   later replays. Task 3 tests this with `test_a_failed_transfer_is_not_replayed_later`.
3. **A scratch path longer than 128 bytes** (a long `TMPDIR`) used to break
   every exchange silently. Task 2 tests this at the testbench level, and Task 4
   tests it through the adapter with `test_a_long_scratch_path_still_reaches_the_chip`.
4. **A request or read budget larger than the testbench holds** (512 words) used
   to be truncated silently. The adapter now refuses it up front (Task 3) and the
   testbench prints `FAIL` (Task 2).
5. **A hung or missing `iverilog`** used to hang the test forever or raise a raw
   `FileNotFoundError`. It now raises `VvpTTAdapterError` within a bound (Task 1).

---

### Task 1: Harden `VvpTTAdapter`'s harness edges

Covers: compile/SRAM-model timeouts, the 1000× `period_ps` naming error, the
ignored `sclk_hz`, an honest `set_clock`, and `close()` dropping its cleanup
error.

**Files:**
- Modify: `tools/host_bridge/vvp_adapter.py`
- Create: `tools/host_bridge/tests/test_vvp_adapter.py`

**Interfaces:**
- Produces:
  - `VvpTTAdapter.__init__(repo_root=None, *, tb="tb_pe_soc_extspi", period_ns=200, vvp_timeout_s=30.0, compile_timeout_s=300.0)`
  - attributes `period_ns: int` and `compile_timeout_s: float`
  - `set_clock(hz) -> PROJECT_CLK_HZ`
  - `configure_host_spi(sclk_hz)`, which sets `period_ns = max(1, round(1e9 / sclk_hz))` and raises `VvpTTAdapterError` for `sclk_hz <= 0`
  - `close()`, which is idempotent and records the first `OSError` in `cleanup_error`
- Rename: `period_ps` becomes `period_ns`. Nothing else in the repo passes it;
  confirm with `grep -rn period_ps tools`.

- [ ] **Step 1: Write the failing tests.** Create `tools/host_bridge/tests/test_vvp_adapter.py`:

```python
"""Unit tests for VvpTTAdapter that need no simulator.

The integration lane (test_vvp_integration.py) needs iverilog, vvp and the PDK
SRAM model, and skips without them. Everything here runs on python3 alone:
subprocess is replaced wherever a test needs a simulator's behaviour, so the
host gate checks the adapter's own logic on every host.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path
from unittest import mock

from tools.host_bridge import vvp_adapter as V

NO_REPO = "/nonexistent-repo"


class TestAdapterHarnessFaults(unittest.TestCase):
    """A broken simulator install is a HARNESS fault, reported in the adapter's
    own error type and within a bound - never a hang, never a raw OSError."""

    def setUp(self):
        self.adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(self.adapter.close)
        # _start() reads the source list from run_all.sh and the SRAM model from
        # sram_model.sh; neither is what these tests are about.
        for name in ("_rtl_list", "_sram_files"):
            patcher = mock.patch.object(self.adapter, name, return_value=[])
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_a_hung_compile_is_an_adapter_error(self):
        hang = subprocess.TimeoutExpired(cmd="iverilog", timeout=1)
        with mock.patch.object(V.subprocess, "run", side_effect=hang):
            with self.assertRaises(V.VvpTTAdapterError) as ctx:
                self.adapter.enable_project("tt_um_protocol_emulator")
        self.assertIn("iverilog did not complete", str(ctx.exception))

    def test_a_missing_iverilog_is_an_adapter_error(self):
        missing = FileNotFoundError(2, "No such file or directory", "iverilog")
        with mock.patch.object(V.subprocess, "run", side_effect=missing):
            with self.assertRaises(V.VvpTTAdapterError):
                self.adapter.enable_project("tt_um_protocol_emulator")

    def test_the_compile_is_bounded(self):
        done = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with mock.patch.object(V.subprocess, "run", return_value=done) as run:
            self.adapter.enable_project("tt_um_protocol_emulator")
        self.assertEqual(run.call_args.kwargs["timeout"], self.adapter.compile_timeout_s)


class TestSramModelFaults(unittest.TestCase):
    def test_a_hung_sram_model_is_an_adapter_error(self):
        adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(adapter.close)
        hang = subprocess.TimeoutExpired(cmd="sram_model.sh", timeout=1)
        with mock.patch.object(V.subprocess, "run", side_effect=hang):
            with self.assertRaises(V.VvpTTAdapterError):
                adapter._sram_files()


class TestAdapterClocking(unittest.TestCase):
    def setUp(self):
        self.adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(self.adapter.close)

    def test_set_clock_reports_the_clock_the_testbench_runs(self):
        # The testbench clock is fixed; the HAL returns the clock actually
        # running, exactly as TTAdapter returns what the board PWM got.
        self.assertEqual(self.adapter.set_clock(48_000_000), V.PROJECT_CLK_HZ)
        self.assertIn(("set_clock", 48_000_000), self.adapter.calls)

    def test_configure_host_spi_sets_the_bit_period_in_nanoseconds(self):
        self.adapter.configure_host_spi(5_000_000)
        self.assertEqual(self.adapter.period_ns, 200)
        self.adapter.configure_host_spi(1_000_000)
        self.assertEqual(self.adapter.period_ns, 1000)

    def test_configure_host_spi_refuses_a_non_positive_rate(self):
        with self.assertRaises(V.VvpTTAdapterError):
            self.adapter.configure_host_spi(0)


class TestAdapterCleanup(unittest.TestCase):
    def test_close_removes_the_scratch_directory_and_is_idempotent(self):
        adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        workdir = adapter._workdir
        adapter.close()
        self.assertFalse(os.path.exists(workdir))
        adapter.close()  # addCleanup and __exit__ may both call it
        self.assertIsNone(adapter.cleanup_error)

    @unittest.skipIf(
        hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores permissions"
    )
    def test_close_records_a_cleanup_error_instead_of_dropping_it(self):
        adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        workdir = adapter._workdir
        locked = Path(workdir, "locked")
        locked.mkdir()
        Path(locked, "file").touch()
        os.chmod(locked, 0o500)  # the file inside can no longer be unlinked

        def restore():
            os.chmod(locked, 0o700)
            shutil.rmtree(workdir, ignore_errors=True)

        self.addCleanup(restore)
        adapter.close()
        self.assertIsInstance(adapter.cleanup_error, PermissionError)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_adapter -v`

Expected failures:
- `test_a_hung_compile_is_an_adapter_error` raises `TimeoutExpired`, not `VvpTTAdapterError`.
- `test_a_missing_iverilog_is_an_adapter_error` raises `FileNotFoundError`.
- `test_the_compile_is_bounded` raises `KeyError: 'timeout'`.
- `test_set_clock_...` fails with 48000000 != 60000000.
- `test_configure_host_spi_...` raises `AttributeError: period_ns`.
- `test_close_records_...` fails because `cleanup_error` is `None`.

`test_a_hung_sram_model...` may also fail with a raw `TimeoutExpired`.

- [ ] **Step 3: Implement the changes in `tools/host_bridge/vvp_adapter.py`.**

3a. Replace the constructor signature and its two `period`/`timeout` lines:

```python
    def __init__(
        self,
        repo_root: str | None = None,
        *,
        tb: str = "tb_pe_soc_extspi",
        period_ns: int = 200,
        vvp_timeout_s: float = 30.0,
        compile_timeout_s: float = 300.0,
    ) -> None:
```

In the body, replace `self.period_ps = period_ps` with these two lines:

```python
        # +period is in NANOSECONDS (tb_pe_soc_extspi.v, "TIMING"); the old name
        # period_ps was a 1000x unit error in the name. configure_host_spi()
        # derives it from the negotiated SCLK.
        self.period_ns = period_ns
        self.compile_timeout_s = compile_timeout_s
```

3b. In `_sram_files`, bound the call and map the timeout:

```python
        try:
            res = subprocess.run(
                [sram],
                capture_output=True,
                text=True,
                check=True,
                timeout=self.compile_timeout_s,
            )
        except (
            OSError,
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
        ) as exc:
            raise VvpTTAdapterError(f"sram_model.sh failed: {exc}") from exc
```

3c. In `_start`, replace the `res = subprocess.run(...)` call for iverilog with:

```python
        try:
            res = subprocess.run(
                cmd,
                cwd=os.path.join(self.repo_root, "regress"),
                capture_output=True,
                text=True,
                check=False,
                timeout=self.compile_timeout_s,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            # A missing iverilog (FileNotFoundError) or a hung compile is a
            # harness fault: report it as one, in the adapter's own error type.
            raise VvpTTAdapterError(f"iverilog did not complete: {exc}") from exc
```

3d. In `_run_tb`, change `f"+period={self.period_ps}",` to
`f"+period={self.period_ns}",`.

3e. Replace `set_clock` and `configure_host_spi`:

```python
    def set_clock(self, hz: int) -> int:
        # The testbench clock is fixed at PROJECT_CLK_HZ (tb CLK_HZ). The HAL
        # returns the clock actually running - as TTAdapter returns what the PWM
        # got - so the bridge never derives SCLK from a clock it did not get.
        self.calls.append(("set_clock", hz))
        return PROJECT_CLK_HZ

    def reset(self, active: bool) -> None:
        self.calls.append(("reset", bool(active)))

    def set_run(self, active: bool) -> None:
        self.calls.append(("set_run", bool(active)))

    def configure_host_spi(self, sclk_hz: int) -> None:
        if sclk_hz <= 0:
            raise VvpTTAdapterError(f"sclk_hz must be positive, got {sclk_hz}")
        self.calls.append(("configure_host_spi", sclk_hz))
        # One testbench bit takes 1.5 x period_ns (bit_xchg: a full low phase,
        # then a half high phase). Real SPI timing is hardware-only territory
        # (item 11) either way; this keeps the period tied to the SCLK the
        # bridge negotiated instead of a constant that ignored it.
        self.period_ns = max(1, round(1_000_000_000 / sclk_hz))
        self._configured = True
```

(`reset` and `set_run` are unchanged here and are shown only for placement.
Task 3 changes them.)

3f. Replace `close`:

```python
    def close(self) -> None:
        """Release the scratch directory. Safe to call more than once.

        Teardown must not raise and mask the failure that caused it, so the
        FIRST error is recorded in ``cleanup_error`` rather than swallowed or
        re-raised. (``ignore_errors=True`` used to discard every error, so
        ``cleanup_error`` could never be set.)
        """

        def record(_function, _path, exc):
            if self.cleanup_error is None and isinstance(exc, OSError):
                self.cleanup_error = exc

        if os.path.isdir(self._workdir):
            shutil.rmtree(self._workdir, onexc=record)
```

- [ ] **Step 4: Run the tests and confirm they pass.**

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_adapter -v`
Expected: all OK. One skip is acceptable only if running as root.

Then run: `python3 -m unittest tools.host_bridge.tests.test_vvp_integration -v`
Expected: unchanged from before. 5 pass, 1 skip (IRQ), and 1 FAIL
(`test_connect_load_start_status_stop_dump_round_trip`, `0 is not true`). Task 3
fixes that failure.

- [ ] **Step 5: Lint and commit.**

```bash
ruff check tools/host_bridge && ruff format --check tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py
grep -nP '\t' tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py || echo no-tabs
git add tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py
git commit -m "fix(host_bridge): bound the vvp adapter's compile and make its clocking honest

iverilog and sram_model.sh now run under compile_timeout_s, and a missing
or hung compiler raises VvpTTAdapterError instead of hanging or raising a
raw OSError. period_ps is renamed period_ns (the testbench reads
nanoseconds) and configure_host_spi now derives it from sclk_hz.
set_clock returns the clock the testbench actually runs. close() is
idempotent and records the first cleanup error; ignore_errors had been
dropping it."
```

---

### Task 2: Testbench `+script` mode, with honest limits

Covers: the testbench side of the #2 fix (replaying a whole session in one
run), path registers that held only 128 bytes, and the silent truncation of a
request or read budget at 512 words.

**Files:**
- Modify: `tb/tb_pe_soc_extspi.v`
- Modify: `tools/host_bridge/vvp_adapter.py` (adds `parse_captures` only)
- Modify: `tools/host_bridge/tests/test_vvp_adapter.py` (parser unit tests)
- Modify: `tools/host_bridge/tests/test_vvp_integration.py` (testbench tests)

**Interfaces:**
- Produces, in `tb_pe_soc_extspi.v`:
  - plusarg `+script=<path>` (requires `+resp=<path>`)
  - event codes in HEX, one event per line:
    - `1 <level>`: RST; 1 asserts reset (`rst_n=0`), 0 releases it; then 20 clocks
    - `2 <level>`: RUN; drives `ui_in[1]`; then GAP_CLKS = 64 clocks
    - `3 <period_ns> <nresp> <nreq> <w0> … <w(nreq-1)>`: XFER; one CS-framed exchange, then 64 clocks
  - the `+resp` file holds, for each XFER in order, a line `@<n>` (decimal,
    0-based) followed by its captured words, one 4-hex-digit word per line (the
    settle word plus `nresp` words)
  - a successful run prints `PASS: script ran <n> transfer(s)`; any malformed
    or over-limit input prints `FAIL: …` and stops
- Produces, in `vvp_adapter.py`: `parse_captures(text: str) -> list[list[int]]`,
  which raises `VvpTTAdapterError` on a non-hex word, a word before any marker,
  or an out-of-order marker.

- [ ] **Step 1: Record the single-shot baseline before touching the testbench.**
The `+req` mode must behave byte-identically afterwards, because the WORKLOG's
hand-proof commands use it.

```bash
mkdir -p "$HOME/.cache/pe-tb-baseline" && B="$HOME/.cache/pe-tb-baseline"
python3 - <<'EOF'
from tools.host_bridge.vvp_adapter import VvpTTAdapter
a = VvpTTAdapter()
a._start()
print(a._vvp_path)
EOF
```

This prints a path such as `/tmp/pe-vvp-XXXX/sim.vvp`; use it as `SIM` below.
The scratch directory is deliberately left in place. Then:

```bash
printf 'A55A\n1010\n0007\n0000\n7DFE\n' > "$B/req.txt"
(cd regress && vvp "$SIM" +req="$B/req.txt" +resp="$B/resp.txt" +period=200 +nresp=21) > "$B/stdout.before"
cp "$B/resp.txt" "$B/resp.before"
grep -c . "$B/resp.before"   # expect 22 (1 settle + 21)
```

- [ ] **Step 2: Write the failing testbench tests.**

2a. In `tools/host_bridge/tests/test_vvp_integration.py`, add `import tempfile`
to the imports (keep them sorted: `json, shutil, subprocess, tempfile,
unittest`). Then add this class after `TestGoldenVectorsOnRealChip`:

```python
PING_WORDS = ("A55A", "1010", "0007", "0000", "7DFE")  # PING seq 7 (RESUME-V1)


def _xfer_line(frame: bytes, nresp: int, period_ns: int = 200) -> str:
    """One +script XFER event for ``frame`` (format: tb_pe_soc_extspi.v)."""
    words = F.bytes_to_words(frame)
    head = f"3 {period_ns:X} {nresp:X} {len(words):X} "
    return head + " ".join(f"{w:04X}" for w in words)


class TestExtspiTestbench(unittest.TestCase):
    """tb_pe_soc_extspi.v's own contract: +script replay and its limits."""

    @classmethod
    def setUpClass(cls):
        cls.adapter = VvpTTAdapter(repo_root=REPO)
        cls.addClassCleanup(cls.adapter.close)
        cls.adapter._start()  # compile once for the class

    def _scratch(self) -> Path:
        path = Path(tempfile.mkdtemp(prefix="pe-tb-"))
        self.addCleanup(shutil.rmtree, path, True)
        return path

    def _vvp(self, *plusargs: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["vvp", str(self.adapter._vvp_path), *plusargs],
            cwd=str(Path(REPO, "regress")),
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

    def test_a_one_transfer_script_captures_what_single_shot_mode_does(self):
        d = self._scratch()
        req = d / "req.txt"
        req.write_text("\n".join(PING_WORDS) + "\n")
        single = d / "single.txt"
        r1 = self._vvp(f"+req={req}", f"+resp={single}", "+period=200", "+nresp=21")
        self.assertIn("PASS:", r1.stdout)
        script = d / "script.txt"
        script.write_text("3 C8 15 5 " + " ".join(PING_WORDS) + "\n")
        replay = d / "replay.txt"
        r2 = self._vvp(f"+script={script}", f"+resp={replay}")
        self.assertIn("PASS: script ran 1 transfer(s)", r2.stdout, r2.stdout)
        lines = replay.read_text().split()
        self.assertEqual(lines[0], "@0")
        self.assertEqual(lines[1:], single.read_text().split())

    def test_chip_state_carries_from_one_transfer_to_the_next(self):
        """THE property the #2 fix needs: a LOAD is still there on the next
        transfer, because both run in ONE simulation."""
        d = self._scratch()
        load = F.encode_frame(F.OP_LOAD, 1, F.TARGET_HOST, F.words_to_bytes(WORDS))
        read = F.encode_frame(
            F.OP_READ_IMEM, 2, F.TARGET_HOST, F.words_to_bytes((1, 2))
        )
        script = d / "script.txt"
        script.write_text(_xfer_line(load, 6 + 15) + "\n" + _xfer_line(read, 6 + 2 + 15))
        resp = d / "resp.txt"
        r = self._vvp(f"+script={script}", f"+resp={resp}")
        self.assertIn("PASS: script ran 2 transfer(s)", r.stdout, r.stdout)
        captures = parse_captures(resp.read_text())
        self.assertEqual(len(captures), 2)
        second = F.words_to_bytes(captures[1])
        answer = F.decode_frame(F.strip_wait_words(second))
        self.assertEqual(answer.payload, (F.STATUS_OK, *WORDS[1:3]))

    def test_a_request_over_capacity_fails_loudly_in_both_modes(self):
        d = self._scratch()
        script = d / "script.txt"
        script.write_text("3 C8 15 201 " + " ".join(["0000"] * 0x201) + "\n")
        r = self._vvp(f"+script={script}", f"+resp={d / 'resp.txt'}")
        self.assertIn("FAIL", r.stdout)
        self.assertNotIn("PASS", r.stdout)
        req = d / "req.txt"
        req.write_text("\n".join(["0000"] * 513) + "\n")
        r = self._vvp(f"+req={req}", f"+resp={d / 'single.txt'}")
        self.assertIn("FAIL", r.stdout)
        self.assertNotIn("PASS", r.stdout)

    def test_a_read_budget_over_capacity_fails_loudly(self):
        d = self._scratch()
        script = d / "script.txt"
        script.write_text("3 C8 200 5 " + " ".join(PING_WORDS) + "\n")  # 512 + settle
        r = self._vvp(f"+script={script}", f"+resp={d / 'resp.txt'}")
        self.assertIn("FAIL", r.stdout)
        self.assertNotIn("PASS", r.stdout)

    def test_paths_longer_than_128_bytes_reach_the_testbench_intact(self):
        deep = self._scratch().joinpath(*(["d" * 50] * 4))  # well past 128 bytes
        deep.mkdir(parents=True)
        script = deep / "script.txt"
        script.write_text("3 C8 15 5 " + " ".join(PING_WORDS) + "\n")
        resp = deep / "resp.txt"
        r = self._vvp(f"+script={script}", f"+resp={resp}")
        self.assertIn("PASS: script ran 1 transfer(s)", r.stdout, r.stdout)
        self.assertTrue(resp.exists())
```

Also extend the existing import line to bring in the parser:
`from tools.host_bridge.vvp_adapter import VvpTTAdapter, VvpTTAdapterError, parse_captures`.

2b. Append these parser unit tests to `tools/host_bridge/tests/test_vvp_adapter.py`,
before the `if __name__` block:

```python
class TestParseCaptures(unittest.TestCase):
    def test_splits_captures_by_marker(self):
        text = "@0\nffff\na55a\n@1\n0001\n"
        self.assertEqual(V.parse_captures(text), [[0xFFFF, 0xA55A], [0x0001]])

    def test_an_undriven_word_is_a_harness_error(self):
        with self.assertRaises(V.VvpTTAdapterError):
            V.parse_captures("@0\nxxxx\n")

    def test_markers_must_count_up_from_zero(self):
        with self.assertRaises(V.VvpTTAdapterError):
            V.parse_captures("@1\nffff\n")

    def test_a_word_before_any_marker_is_a_harness_error(self):
        with self.assertRaises(V.VvpTTAdapterError):
            V.parse_captures("ffff\n@0\n")
```

- [ ] **Step 3: Run the new tests and confirm they fail.**

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_integration.TestExtspiTestbench tools.host_bridge.tests.test_vvp_adapter.TestParseCaptures -v`
Expected: an `ImportError` on `parse_captures` first. Add the parser (Step 4a)
and re-run; the testbench tests should then FAIL because `+script` is unknown
(stdout has no `PASS: script ran`).

- [ ] **Step 4: Implement.**

4a. In `tools/host_bridge/vvp_adapter.py`, add this module-level function after
`class VvpTTAdapterError`:

```python
def parse_captures(text: str) -> list[list[int]]:
    """Split a +script response file into one word list per XFER, in order.

    tb_pe_soc_extspi.v writes "@<n>" before each transfer's capture. Anything
    that is not a marker or a hex word - an "xxxx" from an undriven MISO, say -
    is a harness error, not data.
    """
    captures: list[list[int]] = []
    for token in text.split():
        if token.startswith("@"):
            if token[1:] != str(len(captures)):
                raise VvpTTAdapterError(f"capture marker {token} out of order")
            captures.append([])
        elif not captures:
            raise VvpTTAdapterError(f"capture word {token!r} before any marker")
        else:
            try:
                captures[-1].append(int(token, 16))
            except ValueError as exc:
                raise VvpTTAdapterError(f"capture word {token!r} is not hex") from exc
    return captures
```

4b. In `tb/tb_pe_soc_extspi.v` (2-space indent, spaces only):

(i) In the header comment, immediately after the paragraph that begins
`// FILES. +req=<path>` and ends `prints the captured words to stdout instead.`,
insert:

```verilog
//
// +script=<path>  (VvpTTAdapter's mode) a whole host session replayed from
// power-on in ONE run: reset and run-pad events and every framed exchange, one
// event per line (format: run_script, below). Each exchange's capture goes to
// +resp under an "@<n>" marker. Replaying the session is how chip state - a
// loaded IMEM, run - carries from one host exchange to the next.
//
// LIMITS, all FAIL loudly, never truncate: paths up to PATH_BYTES bytes; a
// request up to MAX_WORDS words; a read budget up to MAX_WORDS-1 (one capture
// slot is the settle word). The 50 ms wall-clock cap bounds a WHOLE script.
```

(ii) After `localparam int  MAX_WORDS  = 512;    // and on the capture` add:

```verilog
  localparam int  GAP_CLKS   = 64;     // idle clocks after a RUN or XFER event
  localparam int  PATH_BYTES = 4096;   // longest +req/+resp/+script path
```

(iii) Replace

```verilog
  reg [1023:0] req_path, resp_path;
  reg have_req, have_resp;
```

with

```verilog
  // Paths were 1024 BITS (128 bytes): a TMPDIR longer than ~100 characters
  // silently truncated every path and broke every exchange.
  reg [8*PATH_BYTES-1:0] req_path, resp_path, script_path;
  reg have_req, have_resp, have_script;
```

(iv) In the plusargs `initial` block, change `have_req = 0; have_resp = 0;
period_ns = 100;` to `have_req = 0; have_resp = 0; have_script = 0;
period_ns = 100;`. After the line
`if ($value$plusargs("resp=%s", resp_path)) have_resp = 1;`, add:

```verilog
    if ($value$plusargs("script=%s", script_path)) have_script = 1;
```

(v) Immediately after `reg [15:0] words [0:MAX_WORDS-1];`, and before the main
`initial begin`, insert both tasks. They must come after `words` is declared.

```verilog
  // ---- one CS-framed exchange: REQUEST, SETTLE, READ BUDGET -----------------
  //
  // THE HALF-DUPLEX SHARED-CLOCK CONTRACT, and why bite 1 saw all-0xFF.
  // pe_ctrl launches the response serializer when the last request word lands
  // (pe_ctrl.v:1132-1136) and shifts it out on the SAME rising SCLK edges that
  // carried the request. It RELEASES the pad on the CS RISING edge
  // (pe_ctrl.v:716-723, resp_active/resp_hold_oe -> 0). So the host must:
  //   CS low  -> clock the request words  -> KEEP CS LOW and keep clocking
  //            to read the response     -> raise CS to end the frame.
  // Bite 1 raised CS immediately after the request, which released the pad
  // before a single response bit was clocked, so every capture read idle. The
  // read budget is the one main.py:317-328 computes: 6 overhead words (sync,
  // header, sequence, length, CRC, one slack) + data + 15 worst-case wait
  // words. We read that many and let pe_frame.strip_wait_words drop the
  // leading 0xFFFF fillers, exactly as the host does.
  //
  // ONE settle word after the request, captured like any other. pe_ctrl launches
  // the response serializer on the rising edge that completes the last request
  // word (pe_ctrl.v:1132-1136, resp_active<=1), so the first read clock lands ON
  // the launch edge: resp_active and resp_idx are being assigned that same edge and
  // the pad has not yet presented the first RESPONSE bit. Sampling there captured
  // the launch transient (the first byte came back a5 - the real SYNC high byte -
  // followed by garbage, because the serializer had not yet shifted). A settle
  // word lets the launch complete; if the chip is genuinely answering, the first
  // settle word is a wait word (0xFFFF) that strip_wait_words removes, and if the
  // chip is NOT answering, the settle word is 0xFFFF too and the decode still
  // fails - so this costs correctness nothing and only removes a race.
  //
  // Clocks words[0..nreq-1], one settle word, then nresp read words, and leaves
  // the settle word plus every read word in cap_words[0..n_captured-1]. Callers
  // guarantee nreq <= MAX_WORDS and nresp + 1 <= MAX_WORDS.
  task do_xfer(input integer nreq, input integer nresp);
    integer k;
    reg [15:0] xw;
    begin
      n_clocked = 0;
      n_captured = 0;
      uio_in[CS_BIT] = 1'b0;              // CS low: select the slave
      #(period_ns);
      for (k = 0; k < nreq; k = k + 1) begin
        word_xchg(words[k], xw);
        n_clocked = n_clocked + 1;
      end
      word_xchg(16'h0000, xw);            // settle/launch clock, MOSI idle
      n_clocked = n_clocked + 1;
      cap_words[n_captured] = xw;         // the WHOLE word, not just its high byte
      n_captured = n_captured + 1;
      for (k = 0; k < nresp; k = k + 1) begin
        word_xchg(16'h0000, xw);          // MOSI idle during the read
        n_clocked = n_clocked + 1;
        cap_words[n_captured] = xw;
        n_captured = n_captured + 1;
      end
      uio_in[CS_BIT] = 1'b1;              // CS high ends the frame
      #(period_ns);
    end
  endtask

  // ---- +script mode: a whole session, replayed from power-on ---------------
  // One event per line, every field HEX:
  //   1 <level>                              RST  1 = reset asserted (rst_n=0)
  //   2 <level>                              RUN  ui_in[RUN_BIT] = level
  //   3 <period_ns> <nresp> <nreq> <w0> ...  XFER one CS-framed exchange
  // Each XFER's capture is written to +resp as "@<n>" (n = 0-based XFER index,
  // decimal) and then one 4-hex-digit word per line.
  integer s_fd, s_out, s_code, s_op, s_arg, s_nreq, s_nresp, s_period, s_n, s_k, s_ev;
  reg [15:0] s_word;

  task run_script;
    begin
      if (!have_resp) begin
        $display("FAIL: +script needs +resp");
        $finish;
      end
      s_fd = $fopen(script_path, "r");
      if (s_fd == 0) begin
        $display("FAIL: cannot open +script=%0s", script_path);
        $finish;
      end
      s_out = $fopen(resp_path, "w");
      if (s_out == 0) begin
        $display("FAIL: cannot open +resp=%0s for writing", resp_path);
        $finish;
      end
      // Power-on: the same defined idle and reset the single-shot path uses.
      uio_in[CS_BIT] = 1'b1;
      uio_in[SCK_BIT] = 1'b0;
      uio_in[MOSI_BIT] = 1'b0;
      rst_n = 1'b0;
      ui_in = 8'h00;
      #(20 * CLK_NS);
      rst_n = 1'b1;
      #(20 * CLK_NS);
      s_n = 0;
      s_ev = 0;
      s_code = $fscanf(s_fd, "%h", s_op);
      while (s_code == 1) begin
        case (s_op)
          1: begin
            if ($fscanf(s_fd, "%h", s_arg) != 1) begin
              $display("FAIL: script event %0d: RST without a level", s_ev);
              $finish;
            end
            rst_n = (s_arg == 0);
            #(20 * CLK_NS);
          end
          2: begin
            if ($fscanf(s_fd, "%h", s_arg) != 1) begin
              $display("FAIL: script event %0d: RUN without a level", s_ev);
              $finish;
            end
            ui_in[RUN_BIT] = (s_arg != 0);
            #(GAP_CLKS * CLK_NS);
          end
          3: begin
            if ($fscanf(s_fd, "%h %h %h", s_period, s_nresp, s_nreq) != 3) begin
              $display("FAIL: script event %0d: XFER header truncated", s_ev);
              $finish;
            end
            if (s_period <= 0 || s_nreq <= 0 || s_nreq > MAX_WORDS
                || s_nresp < 0 || s_nresp + 1 > MAX_WORDS) begin
              $display("FAIL: script event %0d: XFER period=%0d nreq=%0d nresp=%0d is outside 1..%0d words (read budget + settle <= %0d)",
                       s_ev, s_period, s_nreq, s_nresp, MAX_WORDS, MAX_WORDS);
              $finish;
            end
            for (s_k = 0; s_k < s_nreq; s_k = s_k + 1) begin
              if ($fscanf(s_fd, "%h", s_word) != 1) begin
                $display("FAIL: script event %0d: XFER has fewer than %0d request words", s_ev, s_nreq);
                $finish;
              end
              words[s_k] = s_word;
            end
            period_ns = s_period;
            do_xfer(s_nreq, s_nresp);
            $fdisplay(s_out, "@%0d", s_n);
            for (s_k = 0; s_k < n_captured; s_k = s_k + 1)
              $fdisplay(s_out, "%04h", cap_words[s_k]);
            s_n = s_n + 1;
            #(GAP_CLKS * CLK_NS);
          end
          default: begin
            $display("FAIL: script event %0d: unknown event code %0h", s_ev, s_op);
            $finish;
          end
        endcase
        s_ev = s_ev + 1;
        s_code = $fscanf(s_fd, "%h", s_op);
      end
      if (!$feof(s_fd)) begin
        $display("FAIL: script event %0d is not a hex event code", s_ev);
        $finish;
      end
      $fclose(s_fd);
      $fclose(s_out);
      $display("PASS: script ran %0d transfer(s)", s_n);
    end
  endtask
```

(vi) In the main `initial begin`, make these the FIRST statements, before the
two `$display` lines:

```verilog
    if (have_script) begin
      run_script;
      $finish;
    end
```

(vii) In the `+req` read, after `$fclose(fh);` and before the
`$display("tb_pe_soc_extspi: request %0d word(s) from %0s", ...)` line, add:

```verilog
      if (scan == 1) begin
        $display("FAIL: +req holds more than MAX_WORDS=%0d words", MAX_WORDS);
        $finish;
      end
```

(The loop exits with `scan == 1` only when a 513th word was read and had to be
dropped.)

(viii) Immediately before the `// ---- reset, then release ----` comment, add:

```verilog
    if (n_rsp + 1 > MAX_WORDS) begin
      $display("FAIL: read budget %0d + 1 settle word exceeds MAX_WORDS=%0d", n_rsp, MAX_WORDS);
      $finish;
    end
```

(ix) Replace the whole transaction section with a call to `do_xfer`. The section
starts at the comment line
`  // ---- the transaction: REQUEST, then READ BUDGET, all inside one CS-low ----`
and runs through the `#(period_ns);` that follows
`uio_in[CS_BIT] = 1'b1;               // CS high ends the frame`. Its two long
comment blocks now live on `do_xfer`. The replacement is:

```verilog
    // ---- the transaction (half-duplex contract and settle word: do_xfer) ---
    do_xfer(n_req, n_rsp);
```

Keep the `// ---- report ----` section unchanged. It still reads `n_clocked`,
`n_captured` and `cap_words`, which `do_xfer` fills.

- [ ] **Step 5: Prove the single-shot mode is byte-identical.** Recompile with
the Step 1 commands (a new `SIM` path), then:

```bash
(cd regress && vvp "$SIM" +req="$B/req.txt" +resp="$B/resp.txt" +period=200 +nresp=21) > "$B/stdout.after"
diff "$B/stdout.before" "$B/stdout.after" && diff "$B/resp.before" "$B/resp.txt" && echo IDENTICAL
```

Expected: `IDENTICAL`. If the diff is not empty, STOP and report it; do not
"fix" the baseline. Then delete the two Step-1 scratch directories (`B` and the
printed `/tmp/pe-vvp-*` directories).

- [ ] **Step 6: Run the new tests and confirm they pass.**

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_integration.TestExtspiTestbench tools.host_bridge.tests.test_vvp_adapter -v`
Expected: all OK. If `test_chip_state_carries_from_one_transfer_to_the_next`
fails, STOP and report its captures (`print(captures)`); that property is the
basis of Task 3.

Note: if a well-formed script ends in `FAIL: script event N is not a hex event
code`, this Icarus build does not set EOF the way `$feof` expects. Report it
rather than deleting the check.

- [ ] **Step 7: Run the whole lane, lint, and commit.** The adapter does not
use `+script` yet, so the lane result is unchanged: 1 FAIL (round trip), the
IRQ skip, and everything else OK.

```bash
python3 -m unittest discover -s tools/host_bridge/tests
ruff check tools/host_bridge && ruff format --check tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py tools/host_bridge/tests/test_vvp_integration.py
grep -nP '\t' tb/tb_pe_soc_extspi.v tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py tools/host_bridge/tests/test_vvp_integration.py || echo no-tabs
git add tb/tb_pe_soc_extspi.v tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py tools/host_bridge/tests/test_vvp_integration.py
git commit -m "feat(tb): tb_pe_soc_extspi +script mode - a whole session, replayed in one run

A +script run replays reset and run-pad events and every framed exchange
from power-on, and writes each exchange's capture under an @<n> marker.
This is what lets VvpTTAdapter carry chip state from one host exchange to
the next. The single-shot +req mode is byte-identical (stdout and capture
diffed against a pre-change baseline). Paths now hold 4096 bytes instead
of 128, and a request or read budget past MAX_WORDS FAILs instead of
being silently truncated."
```

---

### Task 3: `VvpTTAdapter` replays the session, so chip state carries over (the #2 fix)

Covers: the round-trip failure. After this task the real-chip round trip is
green, and the chip's own refusal of reads while running is tested over the
wire.

**Files:**
- Modify: `tools/host_bridge/vvp_adapter.py`
- Modify: `tools/host_bridge/tests/test_vvp_adapter.py`
- Modify: `tools/host_bridge/tests/test_vvp_integration.py`

**Interfaces:**
- Consumes: `parse_captures` (Task 2), `period_ns` and `compile_timeout_s`
  (Task 1), and the testbench `+script` format (Task 2).
- Produces:
  - module constants `TB_MAX_WORDS = 512` and `TB_PATH_BYTES = 4096`
  - `VvpTTAdapter._events: list[str]`, the session so far as `+script` lines
  - `VvpTTAdapter._captures: list[list[int]]`, what each completed transfer returned
  - `VvpTTAdapter._run_script(events: list[str]) -> list[list[int]]`
  - `reset()` and `set_run()` now append events
  - `host_spi_transfer()` replays, checks the replay for divergence, and rolls
    back on failure
  - `_run_tb` is removed
- In `test_vvp_integration.py`: a helper
  `_exchange(adapter, frame: bytes, read_words: int) -> F.Frame`.

- [ ] **Step 1: Write the failing unit tests.** Append to
`tools/host_bridge/tests/test_vvp_adapter.py`, before the `if __name__` block:

```python
class FakeReplay:
    """Stands in for VvpTTAdapter._run_script: a deterministic 'chip' whose
    n-th transfer always captures [0xFFFF, 0xA55A, n]."""

    def __init__(self):
        self.scripts: list[list[str]] = []
        self.fail_next = False
        self.diverge = False

    def __call__(self, events):
        self.scripts.append(list(events))
        if self.fail_next:
            self.fail_next = False
            raise V.VvpTTAdapterError("vvp did not complete: simulated")
        xfers = [event for event in events if event.startswith("3 ")]
        captures = [[0xFFFF, 0xA55A, index] for index in range(len(xfers))]
        if self.diverge and len(captures) > 1:
            captures[0] = [0xDEAD]
        return captures


class TestAdapterReplay(unittest.TestCase):
    def setUp(self):
        self.adapter = V.VvpTTAdapter(repo_root=NO_REPO)
        self.addCleanup(self.adapter.close)
        self.replay = FakeReplay()
        patcher = mock.patch.object(self.adapter, "_run_script", side_effect=self.replay)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.adapter.configure_host_spi(5_000_000)  # period_ns = 200 = 0xC8

    def test_every_transfer_replays_the_whole_session_in_order(self):
        self.adapter.reset(True)
        self.adapter.reset(False)
        self.adapter.set_run(False)
        self.adapter.host_spi_transfer(bytes.fromhex("a55a1010000700007dfe"), 21)
        self.adapter.set_run(True)
        self.adapter.host_spi_transfer(bytes.fromhex("a55a1010000800001234"), 21)
        first = ["1 1", "1 0", "2 0", "3 C8 15 5 A55A 1010 0007 0000 7DFE"]
        self.assertEqual(self.replay.scripts[0], first)
        self.assertEqual(
            self.replay.scripts[1],
            first + ["2 1", "3 C8 15 5 A55A 1010 0008 0000 1234"],
        )

    def test_a_transfer_returns_only_its_own_capture(self):
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        second = self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        self.assertEqual(second, bytes.fromhex("ffffa55a0001"))

    def test_a_replay_that_diverges_is_a_harness_error(self):
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        self.replay.diverge = True
        with self.assertRaisesRegex(V.VvpTTAdapterError, "diverged"):
            self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)

    def test_a_failed_transfer_is_not_replayed_later(self):
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        self.replay.fail_next = True
        with self.assertRaises(V.VvpTTAdapterError):
            self.adapter.host_spi_transfer(b"\x00\x01", read_words=2)
        self.adapter.host_spi_transfer(b"\xa5\x5a", read_words=2)
        xfers = [e for e in self.replay.scripts[-1] if e.startswith("3 ")]
        self.assertEqual(len(xfers), 2)
        self.assertNotIn("0001", " ".join(xfers))

    def test_a_transfer_past_the_testbench_capacity_is_refused_up_front(self):
        too_long = b"\x00\x00" * (V.TB_MAX_WORDS + 1)
        with self.assertRaisesRegex(V.VvpTTAdapterError, "capacity"):
            self.adapter.host_spi_transfer(too_long, read_words=1)
        with self.assertRaisesRegex(V.VvpTTAdapterError, "capacity"):
            self.adapter.host_spi_transfer(b"\x00\x00", read_words=V.TB_MAX_WORDS)
        self.assertEqual(self.replay.scripts, [])

    def test_an_empty_request_is_refused(self):
        with self.assertRaises(V.VvpTTAdapterError):
            self.adapter.host_spi_transfer(b"", read_words=2)
```

- [ ] **Step 2: Write the failing integration tests.** In
`tools/host_bridge/tests/test_vvp_integration.py`:

2a. Add this helper after `_bring_up`:

```python
def _exchange(adapter, frame, read_words):
    """One raw exchange through ``adapter``, decoded exactly as the bridge does."""
    raw = adapter.host_spi_transfer(frame, read_words=read_words)
    return F.decode_frame(F.strip_wait_words(raw))
```

2b. Add these two tests to `TestRealBridgeOverRealChip`, after
`test_memory_reads_are_gated_while_running_over_the_wire`:

```python
    # ---- state carries from one exchange to the next, over the real chip ----
    def test_a_load_is_still_there_on_the_next_exchange(self):
        _bring_up(self.adapter)
        load = F.encode_frame(F.OP_LOAD, 1, F.TARGET_HOST, F.words_to_bytes(WORDS))
        answer = _exchange(self.adapter, load, 6 + 15)
        self.assertEqual(answer.payload[:2], (F.STATUS_OK, len(WORDS)))
        read = F.encode_frame(
            F.OP_READ_IMEM, 2, F.TARGET_HOST, F.words_to_bytes((0, len(WORDS)))
        )
        answer = _exchange(self.adapter, read, 6 + len(WORDS) + 15)
        self.assertEqual(answer.payload, (F.STATUS_OK, *WORDS))

    # ---- the CHIP's own read gate, over the wire ----------------------------
    def test_the_chip_itself_refuses_memory_reads_while_running(self):
        """pe_ctrl answers a bounded read with NOT_READY while run=1
        (pe_ctrl.v, "Bounded reads. While run=1 they answer NOT_READY"). The
        session and the bridge refuse first, so only a direct exchange can
        reach this gate."""
        _bring_up(self.adapter)
        load = F.encode_frame(F.OP_LOAD, 1, F.TARGET_HOST, F.words_to_bytes(WORDS))
        self.assertEqual(_exchange(self.adapter, load, 6 + 15).payload[0], F.STATUS_OK)
        self.adapter.set_run(True)
        read = F.encode_frame(F.OP_READ_IMEM, 2, F.TARGET_HOST, F.words_to_bytes((0, 1)))
        answer = _exchange(self.adapter, read, 6 + 1 + 15)
        self.assertEqual(answer.payload[0], F.STATUS_NOT_READY)
        self.adapter.set_run(False)
        read = F.encode_frame(F.OP_READ_IMEM, 3, F.TARGET_HOST, F.words_to_bytes((0, 1)))
        self.assertEqual(
            _exchange(self.adapter, read, 6 + 1 + 15).payload, (F.STATUS_OK, WORDS[0])
        )
```

2c. In `test_connect_load_start_status_stop_dump_round_trip`, replace
`self.assertEqual(snapshot.pc, 0)` with:

```python
        # NOT 0, which the fake lane asserts because FakePE never executes. The
        # real core runs the image: 0x0041 LDI a,0x41; 0x1001 OUT 1,a; 0x4002
        # JMP 2 - a jump to itself (wiki/concepts/isa-and-soc.md). So a running
        # chip sits at pc 2.
        self.assertEqual(snapshot.pc, 2)
```

This corrects an assertion copied from the fake that a real core cannot
satisfy; it is not a weakening. If the chip reports any value other than 2,
STOP and report that value and the full STATUS payload. Do not edit the
expectation.

- [ ] **Step 3: Run and confirm the tests fail.**

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_adapter.TestAdapterReplay -v`
Expected: failures and errors, because there is no `_run_script` (the patch
fails with `AttributeError`) and no `TB_MAX_WORDS`.

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_integration.TestRealBridgeOverRealChip -v`
Expected: the round trip fails at `assertTrue(snapshot.run)` (`0 is not true`).
`test_a_load_is_still_there...` fails or errors, because the READ_IMEM runs on
a fresh chip whose IMEM is X, giving `cannot read the response` or a mismatch.
`test_the_chip_itself_refuses...` fails or errors similarly.

- [ ] **Step 4: Implement the replay in `tools/host_bridge/vvp_adapter.py`.**

4a. After `PROJECT_CLK_HZ = 60_000_000`, add:

```python
# tb_pe_soc_extspi.v's limits (MAX_WORDS, PATH_BYTES). The adapter refuses
# anything past them up front, so the error names the limit instead of being a
# FAIL line from deep inside a vvp run.
TB_MAX_WORDS = 512
TB_PATH_BYTES = 4096

# +script event codes (tb_pe_soc_extspi.v, "+script mode").
_EV_RST = 1
_EV_RUN = 2
_EV_XFER = 3
```

4b. In `__init__`, after `self.transfers: list[bytes] = []`, add:

```python
        # The session so far as +script lines, and what each completed transfer
        # returned - see host_spi_transfer, "STATE CARRIES ACROSS CALLS".
        self._events: list[str] = []
        self._captures: list[list[int]] = []
```

4c. Replace `reset` and `set_run`:

```python
    def reset(self, active: bool) -> None:
        self.calls.append(("reset", bool(active)))
        self._events.append(f"{_EV_RST:X} {int(bool(active)):X}")

    def set_run(self, active: bool) -> None:
        self.calls.append(("set_run", bool(active)))
        self._events.append(f"{_EV_RUN:X} {int(bool(active)):X}")
```

4d. Delete `_run_tb` entirely, and add `_run_script` in its place:

```python
    def _run_script(self, events: list[str]) -> list[list[int]]:
        """Replay ``events`` from power-on in ONE vvp run; return every capture."""
        self._start()
        script = os.path.join(self._workdir, "script.txt")
        resp = os.path.join(self._workdir, "resp.txt")
        for path in (script, resp):
            size = len(os.fsencode(path))
            if size > TB_PATH_BYTES:
                raise VvpTTAdapterError(
                    f"scratch path is {size} bytes; the testbench holds at most "
                    f"{TB_PATH_BYTES} (use a shorter TMPDIR)"
                )
        try:
            with open(script, "w", encoding="utf-8") as fh:
                fh.write("\n".join(events) + "\n")
            if os.path.exists(resp):
                os.remove(resp)
        except OSError as exc:
            raise VvpTTAdapterError(f"cannot stage the script: {exc}") from exc

        cmd = ["vvp", str(self._vvp_path), f"+script={script}", f"+resp={resp}"]
        try:
            res = subprocess.run(
                cmd,
                cwd=os.path.join(self.repo_root, "regress"),
                capture_output=True,
                text=True,
                check=False,
                timeout=self.vvp_timeout_s,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise VvpTTAdapterError(f"vvp did not complete: {exc}") from exc
        lines = res.stdout.splitlines()
        failed = [line for line in lines if line.startswith("FAIL")]
        passed = any(line.startswith("PASS: script ran") for line in lines)
        if res.returncode != 0 or failed or not passed:
            detail = "; ".join(failed) or res.stdout[-400:]
            raise VvpTTAdapterError(f"vvp run failed (exit {res.returncode}): {detail}")
        try:
            with open(resp, encoding="utf-8") as fh:
                return parse_captures(fh.read())
        except OSError as exc:
            raise VvpTTAdapterError(f"cannot read the response: {exc}") from exc
```

4e. Replace `host_spi_transfer` with:

```python
    def host_spi_transfer(self, data: bytes, read_words: int | None = None) -> bytes:
        """Exchange one framed request; return the RAW response byte stream.

        Mirrors TTAdapter: CS_N low for the whole frame, the request MSB-first,
        then ``read_words`` 16-bit words clocked out AFTER the request (the
        testbench adds one settle word first, and returns it too). The caller
        strips leading wait words with strip_wait_words - this deliberately does
        NOT strip them, because that is the host's job and doing it here would
        hide the wait-word contract this project already got wrong once.

        STATE CARRIES ACROSS CALLS. Every call replays the whole session so far
        - each reset() and set_run(), and every earlier transfer - from power-on
        in ONE vvp run, and then performs this transfer. The simulation is
        deterministic, so the chip this transfer meets is exactly the chip a
        long-lived simulation would hold at this point. The replay re-captures
        every earlier transfer, and a capture that differs from what that
        transfer returned the first time is a harness error, never trusted. A
        transfer that fails is dropped from the session, so it cannot leak into
        later replays. Cost grows with the session - each call replays all the
        earlier ones - which suits test lanes of tens of exchanges.
        """
        if not self._configured:
            raise VvpTTAdapterError("configure_host_spi() must run before a transfer")
        self.calls.append(("spi_transfer", len(data)))
        req_words = [(data[i] << 8) | data[i + 1] for i in range(0, len(data) - 1, 2)]
        if len(data) % 2:
            req_words.append(data[-1])  # defensive; frames are word-aligned
        if not req_words:
            raise VvpTTAdapterError("an empty request cannot be clocked")
        total = len(req_words) if read_words is None else max(1, read_words)
        if len(req_words) > TB_MAX_WORDS or total + 1 > TB_MAX_WORDS:
            raise VvpTTAdapterError(
                f"{len(req_words)} request word(s) and a {total}-word read budget "
                f"exceed the testbench capacity of {TB_MAX_WORDS} words (the read "
                "budget also carries one settle word)"
            )
        self.transfers.append(bytes(data))
        self._events.append(
            f"{_EV_XFER:X} {self.period_ns:X} {total:X} {len(req_words):X} "
            + " ".join(f"{w:04X}" for w in req_words)
        )
        try:
            captures = self._run_script(self._events)
            if len(captures) != len(self._captures) + 1:
                raise VvpTTAdapterError(
                    f"the replay returned {len(captures)} capture(s) for "
                    f"{len(self._captures) + 1} transfer(s)"
                )
            for index, (first, again) in enumerate(zip(self._captures, captures)):
                if first != again:
                    raise VvpTTAdapterError(
                        f"replay diverged at transfer {index}: the simulation did "
                        "not reproduce what it returned the first time"
                    )
        except VvpTTAdapterError:
            self._events.pop()  # this exchange never happened
            raise
        self._captures.append(captures[-1])
        out = bytearray()
        for w in captures[-1]:
            out += bytes(((w >> 8) & 0xFF, w & 0xFF))
        return bytes(out)
```

4f. In the module docstring, replace the paragraph that begins
`THE BACKEND IS FILE-BASED, DELIBERATELY.` with:

```text
THE BACKEND IS FILE-BASED, DELIBERATELY. The testbench ``tb_pe_soc_extspi.v``
reads a +script of events (reset, run pad, framed transfers) from a file,
replays it from power-on, and writes every transfer's captured MISO to a
response file. File handshake rather than VPI or a long-lived process on pipes,
because this is an acceptance/dev tool, not a gate, and a file handshake is
inspectable when a run goes wrong - which is the whole lesson of this project.
Chip state carries across calls by REPLAY: see host_spi_transfer.
```

- [ ] **Step 5: Run the tests and confirm they pass.**

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_adapter -v`
Expected: all OK.

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_integration -v`
Expected: every test OK except the IRQ skip. In particular,
`test_connect_load_start_status_stop_dump_round_trip` passes with `run` true,
`pc == 2`, `read_imem(1, 2) == WORDS[1:3]` and `dump.words_written == 3`.

The golden-vector test prints its report. Write the reproduced count and every
partial/not-reproduced line into your notes for Task 6. Expected: 3 reproduced
(ping, load_single, target_loopback); read_imem partial with STATUS_RANGE; the
two response-direction vectors partial with STATUS_UNSUPPORTED. If the count
differs, the vectors now run as one session, so an earlier vector can affect a
later one. Do not edit the test: record the exact report lines and carry them to
Task 6.

If any other expectation fails, STOP and report.

- [ ] **Step 6: Lint and commit.**

```bash
ruff check tools/host_bridge && ruff format --check tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py tools/host_bridge/tests/test_vvp_integration.py
grep -nP '\t' tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py tools/host_bridge/tests/test_vvp_integration.py || echo no-tabs
git add tools/host_bridge/vvp_adapter.py tools/host_bridge/tests/test_vvp_adapter.py tools/host_bridge/tests/test_vvp_integration.py
git commit -m "fix(host_bridge): VvpTTAdapter replays the session - chip state now carries

Each transfer replays every reset, run-pad change and earlier transfer
from power-on in one vvp run (+script), so the chip it meets is the chip
a long-lived simulation would hold. Each replay must reproduce every
earlier capture exactly, or the transfer raises 'replay diverged'. A
failed transfer is dropped from the session. Requests past the testbench
capacity are refused up front.

The real-bridge-over-real-chip round trip is now green: run=1 after
START, pc=2 (the image's JMP 2 is a jump to itself), and READ_IMEM and
DUMP_CORE see the LOAD. New direct tests cover a LOAD persisting to the
next exchange and pe_ctrl's own NOT_READY gate while run=1."
```

---

### Task 4: Integration-test hygiene

Covers: the read-gating test that never reaches the wire; the exact-once checks
the fake lane makes and this lane had weakened to `assertIn`; stale docstrings
about fresh simulations and `+nresp`; and the long-`TMPDIR` regression through
the adapter.

**Files:**
- Modify: `tools/host_bridge/tests/test_vvp_integration.py`

**Interfaces:**
- Consumes: `_bring_up`, `_exchange` (Task 3), and `VvpTTAdapter` (Task 3).

- [ ] **Step 1: Write the long-path regression test.** Add `from unittest import mock`
to the imports, then add this test to `TestRealBridgeOverRealChip`:

```python
    # ---- a long TMPDIR used to break EVERY exchange (128-byte path regs) -----
    def test_a_long_scratch_path_still_reaches_the_chip(self):
        base = Path(tempfile.mkdtemp(prefix="pe-deep-"))
        self.addCleanup(shutil.rmtree, base, True)
        deep = base.joinpath(*(["d" * 50] * 4))  # well past 128 bytes
        deep.mkdir(parents=True)
        with mock.patch.object(tempfile, "tempdir", str(deep)):
            adapter = VvpTTAdapter(repo_root=REPO)
        self.addCleanup(adapter.close)
        self.assertTrue(adapter._workdir.startswith(str(deep)))
        _bring_up(adapter)
        answer = _exchange(adapter, F.encode_frame(F.OP_PING, 7, F.TARGET_HOST), 6 + 15)
        self.assertEqual(answer.payload, (F.STATUS_OK,))
```

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_integration.TestRealBridgeOverRealChip.test_a_long_scratch_path_still_reaches_the_chip -v`
Expected: PASS. Task 2 already fixed this; the test pins the fix through the
adapter. To prove the test can fail, temporarily change `PATH_BYTES` in the
testbench back to `128`. The test should fail, and so should the adapter's
up-front guard if you also lower `TB_PATH_BYTES`. Then restore `4096` and
confirm `git diff tb/` is empty.

- [ ] **Step 2: Make the gating test say what it tests, and prove it never
reaches the wire.** Replace
`test_memory_reads_are_gated_while_running_over_the_wire` with:

```python
    # ---- memory reads while running: the HOST refuses before the wire -------
    def test_memory_reads_are_refused_by_the_host_while_running(self):
        """The session refuses a read while RUNNING before anything reaches the
        chip (the bridge carries the same guard, main.py _op_read_imem). That is
        the host half of the gate; the chip's own half is
        test_the_chip_itself_refuses_memory_reads_while_running."""
        self.session.connect()
        self.session.load(self.image)
        self.session.start()
        sent = len(self.adapter.transfers)
        self.assertRaises(SessionStateError, self.session.read_imem, 0, 1)
        self.assertEqual(len(self.adapter.transfers), sent, "a gated read reached the chip")
```

- [ ] **Step 3: Restore the fake lane's exact-once checks.** In the round-trip
test, replace

```python
        self.assertIn(("enable_project", PROJECT), recorded)
        self.assertIn(("set_clock", 60_000_000), recorded)
```

with

```python
        # Exactly once each, as the fake lane asserts (project_calls ==
        # [PROJECT], clock_calls == [60 MHz]): assertIn would pass a bridge that
        # re-selected the project or restarted the clock on every request.
        self.assertEqual(recorded.count(("enable_project", PROJECT)), 1)
        self.assertEqual(
            [call for call in recorded if call[0] == "set_clock"],
            [("set_clock", 60_000_000)],
        )
```

- [ ] **Step 4: Update the stale text.**

4a. In the module docstring, replace the third bullet (`* Every exchange is a
SEPARATE vvp run, …` through `… That is a limit of the backend, not a chip
result.`) with:

```text
  * Every exchange is a separate vvp run that REPLAYS the whole session from
    power-on - each reset, run-pad change and earlier transfer - before its
    own transfer (VvpTTAdapter.host_spi_transfer). The simulation is
    deterministic, so chip state (a loaded IMEM, run) carries exactly as on a
    long-lived chip, and each replay must reproduce every earlier capture or
    the exchange is a harness error. Each exchange costs a little more than
    the one before it.
```

4b. In `TestRealBridgeOverRealChip.setUp`, replace the comment's last clause
`each a FRESH simulation from reset (see the module docstring), not one
long-lived chip.` with `each REPLAYING the session from power-on (see the
module docstring), so the chip keeps its state like a long-lived one.`

4c. In `test_real_chip_ping_comes_back_with_a_verified_crc`, replace the comment
above `read_words = 2 * (6 + 15)` with:

```python
        # Twice the bridge's PING budget (6 + 15): if the read budget ever
        # stopped reaching the testbench (the XFER line's nresp field), the
        # capture would come back short, so the PING guards that plumbing too.
```

- [ ] **Step 5: Run the module, lint, and commit.**

Run: `python3 -m unittest tools.host_bridge.tests.test_vvp_integration -v`
Expected: all OK except the IRQ skip.

```bash
ruff check tools/host_bridge && ruff format --check tools/host_bridge/tests/test_vvp_integration.py
grep -nP '\t' tools/host_bridge/tests/test_vvp_integration.py || echo no-tabs
git add tools/host_bridge/tests/test_vvp_integration.py
git commit -m "test(bridge): the vvp lane says what it tests

The read-gating test is renamed for the host-side gate it actually
exercises, and now proves no transfer reached the chip; the chip-side
gate has its own direct test. enable_project and set_clock are checked
exactly once, as the fake lane checks them. A long-TMPDIR test pins the
128-byte path fix through the adapter. The docstrings describe the
replay instead of fresh simulations."
```

---

### Task 5: `TTAdapter` counts the read budget AFTER the request (#1, best effort, flagged for review)

> **Flag:** the user is still deciding the HAL contract here. Keep this task in
> its OWN commit so it can be reverted alone. Do not fold it into another task.

The defect: the real board adapter counted the request's own words inside
`read_words`, which contradicts its own docstring and `VvpTTAdapter`. `pe_ctrl`
is half-duplex on this bus (it answers after the last request word; MISO is
released while the request shifts in), and the bridge budgets 21 words for every
LOAD. So a LOAD of 8 to 10 words came back "response truncated", and 11 or more
gave "no frame after 15 wait words": every real-board LOAD of 8 or more words
failed, while the simulation lane passed it.

The fix: clock the request, discard what MISO carried during it, then clock
`read_words` words and return only those, matching `VvpTTAdapter` and the
docstring.

**Files:**
- Modify: `tools/host_bridge/tt_adapter.py`
- Modify: `tools/host_bridge/tests/test_tt_adapter.py`
- Modify: `tools/host_bridge/main.py` (one comment only)

**Interfaces:**
- Produces: `TTAdapter.host_spi_transfer(data, read_words)` returns exactly
  `max(1, read_words) * 2` bytes, all clocked after the request. When
  `read_words` is None it returns as many words as the request, also clocked
  after it.

- [ ] **Step 1: Make the fake SPI half-duplex, like `pe_ctrl`.** In
`tools/host_bridge/tests/test_tt_adapter.py`:

1a. Add `from tools.host_bridge import main as M` to the imports. Then add this
after `PINS = …`:

```python
# What a RELEASED MISO pad reads (the board pull-up; tb_pe_soc_extspi.v models
# the same MISO_IDLE). pe_ctrl drives MISO only while a response shifts.
MISO_IDLE = 0xFF


def _request_complete(rx) -> bool:
    """True once ``rx`` holds a whole request frame, by its length field - the
    same rule pe_ctrl uses to know the request is over and start answering."""
    if len(rx) < PF.HEADER_WORDS * 2:
        return False
    length = (rx[6] << 8) | rx[7]  # header word 3 is the length field
    return len(rx) >= (PF.HEADER_WORDS + length + PF.TRAILER_WORDS) * 2
```

1b. In `install_fake_sdk`, extend `state` with `rx=bytearray()` and
`responder=None`, and update the docstring's second paragraph to say the stream
is HALF-DUPLEX. Right after `state` is created, add:

```python
    class Pads(list):
        """uio_out, plus the one side effect a half-duplex slave needs: CS_N
        falling starts a new frame, so the chip forgets the previous request
        and answers this one from the start."""

        def __setitem__(self, index, value):
            super().__setitem__(index, value)
            if index == A.PAD_CS_N and value == 0:
                state.rx = bytearray()
                state.cursor = 0

    state.board.uio_out = Pads(state.board.uio_out)
```

1c. Replace the body of the fake `SPI.write_readinto` after the `boom` check
with:

```python
            # HALF-DUPLEX, like pe_ctrl: MISO is released (MISO_IDLE) while the
            # request shifts in; the chip answers once the request frame is
            # complete, and past the end of its answer MISO is released again.
            for index in range(len(received)):
                if not _request_complete(state.rx):
                    state.rx.append(data[index])
                    received[index] = MISO_IDLE
                    if state.responder is not None and _request_complete(state.rx):
                        state.response = state.responder(bytes(state.rx))
                        state.cursor = 0
                elif state.cursor < len(state.response):
                    received[index] = state.response[state.cursor]
                    state.cursor += 1
                else:
                    received[index] = MISO_IDLE
```

1d. Add `REQ = PF.encode_frame(PF.OP_STATUS, 1, PF.TARGET_HOST)` after
`MISO_IDLE`. A real request frame is now required, because the chip answers
only a complete frame. Then update the existing transfer tests:

- `test_host_spi_transfer_holds_cs_low_and_releases`: send `REQ` instead of
  `b"\x00" * 6`, and fix the comment to say the request is a 5-word STATUS frame.
- `test_host_spi_transfer_streams_beyond_the_request_length`: send `REQ` instead
  of `b"\x00" * 2`.
- `test_host_spi_transfer_skips_leading_wait_words`: send `REQ` instead of
  `b"\x00" * 2`.
- `test_host_spi_transfer_reads_past_the_end_of_a_short_reply`: send `REQ`
  instead of `b"\x00" * (words * 2)`, and change the trailing expectation to
  `b"\xff" * ((budget - words) * 2)`. In its docstring, change "this stub models
  exactly that as zeros" to "this stub models exactly that as MISO_IDLE (0xFF)".
- `test_a_budget_too_small_for_the_reply_is_reported_not_truncated`: send `REQ`
  instead of `b"\x00\x00"`. Replace its docstring's second sentence onwards with
  "The read budget counts words AFTER the request, so a short budget is short
  however long the request is - the request can no longer mask it."

1e. Add the regression test to `TestTTAdapter`:

```python
    def test_a_load_of_any_length_round_trips_through_the_real_bridge(self):
        """#1 regression: the bridge budgets 21 words for EVERY LOAD
        (main._response_words), counted after the request. When the adapter
        counted the request's own words inside the budget, a LOAD of 8-10
        words came back truncated and 11+ found no frame at all."""

        def chip(request):
            frame = PF.decode_frame(request)
            words = frame.payload
            reply = (PF.STATUS_OK, len(words), 0, words[-1] if words else 0)
            return PF.encode_frame(
                PF.OP_LOAD | PF.RESPONSE_BIT,
                frame.sequence,
                PF.TARGET_HOST,
                PF.words_to_bytes(reply),
            )

        self.state.responder = chip
        bridge = M.PicoBridge(
            A.TTAdapter(pins=PINS),
            project="tt_um_protocol_emulator",
            sleep=lambda _seconds: None,
        )
        for request_id, op in enumerate(("hello", "prepare"), start=1):
            self.assertTrue(bridge.handle(M.USBRequest(request_id, op)).ok, op)
        for n in range(1, 41):
            words = [(0x1000 + i) & 0xFFFF for i in range(n)]
            response = bridge.handle(M.USBRequest(100 + n, "load", {"words": words}))
            self.assertTrue(response.ok, f"LOAD of {n} words: {response.error}")
            self.assertEqual(response.result["words_written"], n)
```

- [ ] **Step 2: Run and confirm the regression test fails.**

Run: `python3 -m unittest tools.host_bridge.tests.test_tt_adapter -v`
Expected: `test_a_load_of_any_length…` FAILS with
`LOAD of 8 words: no PE response: response truncated …`. Several updated
transfer tests also fail, because the old adapter returns the request-time
`0xFF` bytes ahead of the frame.

- [ ] **Step 3: Implement in `tools/host_bridge/tt_adapter.py`.**

Replace `host_spi_transfer` with:

```python
    def host_spi_transfer(self, data: bytes, read_words: int | None = None) -> bytes:
        """Clock one framed request, then return what the chip sent AFTER it.

        pe_ctrl is half-duplex on this bus: it starts answering when the last
        request word lands, and MISO is released (meaningless) while the
        request shifts in. So the bytes clocked in during the request are
        discarded, and ``read_words`` 16-bit words are clocked out AFTER the
        request (None = as many as the request; the bridge always passes a
        budget). The response is NOT the request length: a bounded read (R2)
        may be preceded by up to 15 leading 0xFFFF wait words, so the caller
        bounds the budget and skips the wait words with
        ``pe_frame.strip_wait_words`` (chip review B1). VvpTTAdapter keeps the
        same contract, so the simulation lane and the board agree.
        """
        if self._spi is None:
            raise RuntimeError("configure_host_spi() must run before a transfer")
        board = self._board()
        total_words = (
            max(1, (len(data) + 1) // 2) if read_words is None else max(1, read_words)
        )
        received = bytearray()
        board.uio_out[PAD_CS_N] = 0  # CS_N low for the whole frame
        try:
            # The request; what MISO carried meanwhile is not a reply.
            self._spi.write_readinto(data, bytearray(len(data)))
            # MOSI during the read is irrelevant (the chip is a slave and
            # ignores it), so 0xFFFF filler is sent.
            while len(received) < total_words * 2:
                chunk = bytearray(2)
                self._spi.write_readinto(b"\xff\xff", chunk)
                received.extend(chunk)
        finally:
            board.uio_out[PAD_CS_N] = 1  # release even on error
        return bytes(received)
```

In the module docstring, change
`host_spi_transfer(data) -> bytes  # one CS-framed full-duplex transaction` to
`host_spi_transfer(data, read_words) -> bytes  # request, then read_words after it`.

In `tools/host_bridge/main.py`, change the comment line
`# Worst-case words to clock out for an opcode, given its request payload.` to
`# Worst-case words to clock out AFTER the request (the HAL contract,`
followed by the line `# tt_adapter.host_spi_transfer), given its request payload.`.

- [ ] **Step 4: Run and confirm the tests pass.**

Run: `python3 -m unittest tools.host_bridge.tests.test_tt_adapter -v`
Expected: all OK.

Run: `python3 -m unittest discover -s tools/host_bridge/tests`
Expected: OK, with 1 skip (IRQ).

If a `micropython` binary is available (`command -v micropython`, or the path
in `$MICROPYTHON`), run `python3 tools/host_bridge/micropython_check.py`, or the
step `run_host_tests.sh` uses. Expected: no new failures.

- [ ] **Step 5: Lint and commit, on its own.**

```bash
ruff check tools/host_bridge && ruff format --check tools/host_bridge/tt_adapter.py tools/host_bridge/tests/test_tt_adapter.py tools/host_bridge/main.py
grep -nP '\t' tools/host_bridge/tt_adapter.py tools/host_bridge/tests/test_tt_adapter.py tools/host_bridge/main.py || echo no-tabs
git add tools/host_bridge/tt_adapter.py tools/host_bridge/tests/test_tt_adapter.py tools/host_bridge/main.py
git commit -m "fix(host_bridge): TTAdapter counts the read budget after the request

FLAGGED FOR REVIEW: the HAL contract decision is still open. This commit
stands alone so it can be reverted alone.

pe_ctrl is half-duplex on the host bus, but TTAdapter counted the
request's own words inside read_words. Its docstring and VvpTTAdapter
both count them after the request. With the bridge's 21-word LOAD
budget, every real-board LOAD of 8 or more words failed: 8-10 came back
truncated, and 11+ found no frame. The adapter now discards what MISO
carried during the request and clocks read_words words after it. The
fake SPI is now half-duplex like the chip, and a 1..40-word LOAD sweep
through the real bridge pins the fix."
```

---

### Task 6: Record the work (design doc, RESUME-V1, WORKLOG)

**Files:**
- Modify: `docs/design/VVPT-ADAPTER-DESIGN.md`
- Modify: `docs/RESUME-V1.md`
- Modify: `WORKLOG.md`

- [ ] **Step 1: Design doc.** Append to `docs/design/VVPT-ADAPTER-DESIGN.md`:

```markdown

STATE ACROSS EXCHANGES (added 2026-10-03). The first adapter ran each exchange
as a fresh vvp simulation from reset, and set_run/reset only recorded the call,
so no chip state carried: a LOAD was gone by the next exchange and STATUS after
START read run=0. Each exchange now REPLAYS the whole session - every reset,
run-pad change and earlier transfer - from power-on in one run, through the
testbench's +script mode, and then performs its own transfer. Icarus is
deterministic, so the replayed chip is exactly the chip a long-lived simulation
would hold, and every replay must reproduce each earlier transfer's capture or
the exchange is a harness error ("replay diverged"). A failed transfer is
dropped from the session. The cost grows with the session, which suits test
lanes of tens of exchanges. A long-lived vvp process fed over stdin/stdout was
rejected: a blocking read stalls the simulator, pipe deadlocks and timeouts need
select(), and it would give up the inspectable file handshake.
```

- [ ] **Step 2: RESUME-V1.** In `docs/RESUME-V1.md`:
- Replace the paragraph beginning `Only one thing is unfinished:
  test_vvp_integration.py has an uncommitted post-commit edit` with a sentence
  saying that edit was a format-on-save `ruff format` reflow plus review fixes,
  committed at `56492b4`.
- Under "The number that is the deliverable", add a dated (2026-10-03) paragraph
  with the golden count from Task 3 Step 5: the exact numbers and the reason for
  each vector not reproduced. Say plainly that this is "accepted with STATUS_OK
  in SIMULATION", not byte-exact, because `golden_vectors.json` records no
  expected replies.
- Add a line saying the real-chip round trip is green over the session replay
  (Task 3), and that the TTAdapter read-budget change (Task 5) is committed but
  flagged for the user's decision.

- [ ] **Step 3: WORKLOG.** Append entries in the existing format
`YYYY-MM-DD HH:MM CDT | pi-worker | TAG | text` (get the time from `date`). Use
one CHECKPOINT entry per task, carrying the commit hash and the measured result,
and one GOLDEN-VECTOR-NUMBER entry with the exact count and reasons. Mark
Task 5's entry as FLAGGED FOR USER REVIEW.

- [ ] **Step 4: Check and commit.**

```bash
regress/check_wiki_links.sh 2>&1 | tail -3   # expect no dead links
grep -nP '\t' docs/design/VVPT-ADAPTER-DESIGN.md docs/RESUME-V1.md || echo no-tabs
git add docs/design/VVPT-ADAPTER-DESIGN.md docs/RESUME-V1.md WORKLOG.md
git commit -m "docs: record the session replay, the golden number and the flagged HAL change"
```

---

### Task 7: Final verification

- [ ] **Step 1:** `python3 -m unittest discover -s tools/host_bridge/tests -v`.
Expected: 0 failures, 0 errors, and exactly one skip
(`test_irq_liveness_is_skipped_because_irq_is_unmodelled`, which prints its
reason).
- [ ] **Step 2:** `ruff check tools/host_gui tools/host_bridge`, then
`ruff format --check` on every file this plan touched. Expected: clean.
- [ ] **Step 3:** `tools/host_gui/run_host_tests.sh`. Expected: exit 0.
- [ ] **Step 4:** `git status --short` is empty, and `git log --oneline -8` shows
the plan's commits on `main`, unpushed.
- [ ] **Step 5:** In the pi pane, print a final report:
  - each commit hash with its one-line subject
  - the golden-vector report lines
  - the round-trip result
  - every step whose expected result did not match, and what you did
  - an explicit line: "Task 5 (#1) is committed separately and awaits the
    user's decision; nothing was pushed."

---

## Amendment A (2026-10-04): the host IMEM read is one address stale

### What the lane found (verified independently by the manager)

After LOADing `0x0041 0x1001 0x4002`, `READ_IMEM(1, 2)` answers
`(STATUS_OK, 0x0041, 0x1001)`, not `(STATUS_OK, 0x1001, 0x4002)`. Every host IMEM
read returns the PREVIOUS address's word. The first word returned is whatever
the bus last addressed: the halted CPU's fetch at 0.

Root cause: `rtl/pe_soc.v:391-394` copies `imem_rdata` into `dbg_rd_data` on the
REQUEST edge. But `pe_imem`'s read is registered (its header says "READ LATENCY
IS ONE CYCLE", and both the SRAM macro and the `FLOP=1` array register it), so
on that edge `imem_rdata` still holds the previous address's word. The comment
right above the code says the answer "can only be captured on the next edge";
the code does not do that.

DMEM reads are correct, because `dmem_byte` is combinational.

It was never caught because:
- `tb/tb_pe_ctrl_r2.v` models the read port combinationally,
- every `tb_pe_soc_*.v` ties `dbg_rd_req` to 0,

so no test had ever read IMEM through the real SoC and memory. **The R2 "chip
confirmed" status does not cover this path.**

### A1: unblock the harness work (pi worker: do this now)

The user's choice is to finish Tasks 2–7 now and fix the chip separately. Do
NOT touch `rtl/`. Only the assertions about IMEM read VALUES change, and those
are kept as **defect-pinning** tests rather than deleted: each asserts the exact
stale answer and is named `test_known_defect_…`. Pinning the wrong value,
rather than using `@unittest.expectedFailure`, means the test cannot pass for
some unrelated reason. It fails the moment anything about the read changes,
including the RTL fix; the RTL fix then flips it to the correct answer. Every
other assertion stays strict.

In `tools/host_bridge/tests/test_vvp_integration.py`:

(a) After `_STATUS_NAMES = {…}`, add:

```python
# KNOWN CHIP DEFECT, found 2026-10-04 by this lane (plan Amendment A,
# docs/superpowers/plans/2026-10-03-host-bridge-review-fixes.md):
# rtl/pe_soc.v:391-394 copies imem_rdata on the REQUEST edge, but pe_imem's read
# is registered, so every host IMEM read returns the PREVIOUS address's word -
# READ_IMEM(1, 2) after loading 0x0041 0x1001 0x4002 answers (0x0041, 0x1001).
# The tests named test_known_defect_* pin that exact wrong answer; every other
# test leaves IMEM read VALUES to them. When the RTL is fixed, those tests fail:
# change their expectation to the correct answer given in each docstring.
```

(b) In `TestExtspiTestbench`, add this helper and rewrite
`test_chip_state_carries_from_one_transfer_to_the_next` to use it, then add the
pinning test:

```python
    def _load_then_read(self, address, count):
        """LOAD WORDS, then READ_IMEM(address, count), in ONE script; return the
        decoded answer to the read."""
        d = self._scratch()
        load = F.encode_frame(F.OP_LOAD, 1, F.TARGET_HOST, F.words_to_bytes(WORDS))
        read = F.encode_frame(
            F.OP_READ_IMEM, 2, F.TARGET_HOST, F.words_to_bytes((address, count))
        )
        script = d / "script.txt"
        script.write_text(
            _xfer_line(load, 6 + 15) + "\n" + _xfer_line(read, 6 + count + 15) + "\n"
        )
        resp = d / "resp.txt"
        r = self._vvp(f"+script={script}", f"+resp={resp}")
        self.assertIn("PASS: script ran 2 transfer(s)", r.stdout, r.stdout)
        captures = parse_captures(resp.read_text())
        self.assertEqual(len(captures), 2)
        return F.decode_frame(F.strip_wait_words(F.words_to_bytes(captures[1])))

    def test_chip_state_carries_from_one_transfer_to_the_next(self):
        """THE property the #2 fix needs: the LOAD is still there on the next
        transfer, because both run in ONE simulation. A fresh chip's IMEM is X,
        so its read could not even be captured. The read VALUES are the known
        defect's test, below."""
        answer = self._load_then_read(1, 2)
        self.assertEqual(answer.opcode, F.OP_READ_IMEM | F.RESPONSE_BIT)
        self.assertEqual(answer.sequence, 2)
        self.assertEqual(answer.payload[0], F.STATUS_OK)
        self.assertEqual(len(answer.payload), 1 + 2)

    def test_known_defect_host_imem_read_is_one_address_stale(self):
        """KNOWN CHIP DEFECT, pinned to its exact signature (see the note at the
        top of this module). The CORRECT answer is (STATUS_OK, *WORDS[1:3]).
        When the RTL fix makes this fail, change the expectation to that."""
        answer = self._load_then_read(1, 2)
        self.assertEqual(answer.payload, (F.STATUS_OK, WORDS[0], WORDS[1]))
```

(c) In Task 3, change three expectations, and add one pinning test to
`TestRealBridgeOverRealChip`:

- `test_a_load_is_still_there_on_the_next_exchange`: replace
  `self.assertEqual(answer.payload, (F.STATUS_OK, *WORDS))` with

  ```python
        # A decodable STATUS_OK read of the right length proves the LOAD carried
        # (a fresh chip's IMEM is X). The VALUES are the known defect's test.
        self.assertEqual(answer.payload[0], F.STATUS_OK)
        self.assertEqual(len(answer.payload), 1 + len(WORDS))
  ```

- `test_the_chip_itself_refuses_memory_reads_while_running`: replace the final
  `self.assertEqual(_exchange(…).payload, (F.STATUS_OK, WORDS[0]))` with

  ```python
        # Value deliberately not checked: with the known defect, address 0's
        # stale answer IS WORDS[0] (the halted CPU fetches 0), so it would pass
        # for the wrong reason. Status and length are the gate's business.
        answer = _exchange(self.adapter, read, 6 + 1 + 15)
        self.assertEqual(answer.payload[0], F.STATUS_OK)
        self.assertEqual(len(answer.payload), 2)
  ```

- In `test_connect_load_start_status_stop_dump_round_trip`, replace
  `self.assertEqual(words, WORDS[1:3])` with

  ```python
        # The read path works end to end; its VALUES are
        # test_known_defect_session_read_imem_is_one_address_stale.
        self.assertEqual(len(words), 2)
  ```

- Add:

  ```python
    def test_known_defect_session_read_imem_is_one_address_stale(self):
        """KNOWN CHIP DEFECT through the whole host stack (see the note at the
        top of this module). The CORRECT answer is WORDS[1:3]. When the RTL fix
        makes this fail, change the expectation to that."""
        self.session.connect()
        self.session.load(self.image)
        self.session.start()
        self.session.stop()
        self.assertEqual(self.session.read_imem(1, 2), (WORDS[0], WORDS[1]))
  ```

  If this returns anything other than `(0x0041, 0x1001)`, STOP and report the
  value. Do not adjust it to whatever comes back.

(d) Task 6 must record the defect: a WORKLOG `CHIP-DEFECT` line (the manager
has already written one; reference it), and a RESUME-V1 line saying the R2 host
IMEM read path is defective in RTL and pinned by the two `test_known_defect_*`
tests.

(e) Commit Task 2 with the testbench and its tests, as the plan says, with the
Amendment A changes (a)–(b) included. Then continue with Task 3, applying (c).

### A2: the RTL fix (NOT for the pi worker; it needs a stronger agent and the user's sign-off)

Proposed fix: keep the one-cycle host contract. In the `dbg_rd_valid` cycle,
present IMEM data straight from the registered macro output. `imem_addr` is
still the host's in that cycle, because `dbg_reading = dbg_rd_req |
dbg_rd_valid`. `pe_ctrl` samples `dbg_rd_data` in exactly that cycle
(`rtl/pe_ctrl.v:1223-1240`, `if (dbg_rd_valid) … <= dbg_rd_data`). So: capture
only the DMEM byte and a `dmem` flag on the request edge, and drive
`dbg_rd_data = dmem_q ? {8'h00, dmem_byte_q} : imem_rdata`.

Before calling it fixed:
1. Add a pe_soc-level testbench case that reads IMEM through the real `pe_imem`
   at addresses 0, 1, 2 and checks the exact words.
2. Flip both `test_known_defect_*` tests to the correct answers given in their
   docstrings.
3. Run `regress/tier.sh` T2, the formal proofs, the mutation suites, and the
   R2/R3 vector drift checks.
4. Confirm with the user whether the design was already submitted to a shuttle.
   If it was, this is a silicon erratum, not just an RTL fix, and the host would
   need a workaround. Read one EXTRA word from the same address and discard
   the first: `READ_IMEM(a, n+1)` answers `(stale, mem[a] … mem[a+n-1])`. That
   caps a useful read at 14 words.

## Appendix A: findings map

These are the findings from the 2026-10-03 review. The review's numbers are
kept; "D1/D2" are the two items the user was asked to decide on (D1 = the read
budget, review #3; D2 = the round trip, review #2).

| Finding | Where it goes |
|---|---|
| #1 golden loop counted refusals; `partial` never filled | fixed at `56492b4` |
| #2 / D2: round trip red (fresh simulation per exchange) | **Tasks 2–3** |
| #3 / D1: TTAdapter counts request words in the read budget | **Task 5** (flagged) |
| #4 IRQ test passed instead of skipping | fixed at `56492b4` |
| #5 PING checks passed on a rejected frame | fixed at `56492b4` |
| #6 missing simulator/PDK turned the host gate red | fixed at `56492b4` |
| #7 `+nresp` plumbing never exercised | fixed at `56492b4`; comment updated in Task 4 |
| #8 harness faults blamed on the chip | fixed at `56492b4` |
| #9 scratch dir leaked when setUp raised | fixed at `56492b4` |
| #10 `assertGreater(len(raw), 0)` could not fail | fixed at `56492b4` |
| #11 target_loopback comment wrong | fixed at `56492b4` |
| #12 stale "not patched" docstring | fixed at `56492b4` |
| #13 report only on stdout | fixed at `56492b4` |
| #14 `timeout_s=10` bounded nothing; iverilog untimed | **Task 1** (compile timeout) |
| #15 two hand-copied bring-ups | fixed at `56492b4` |
| sweep: gated-read test never reaches the wire | **Task 4** (+ chip-side test in Task 3) |
| sweep: exact-once checks weakened to `assertIn` | **Task 4** |
| adapter: `period_ps` passed as ns; sclk ignored | **Task 1** |
| adapter: `close()` never sets `cleanup_error` | **Task 1** |
| adapter: testbench silently caps at 512 words | **Task 2** (FAIL) + **Task 3** (refuse up front) |
| adapter: 128-byte path registers | **Task 2** + **Task 4** test |
| adapter: RESUME-V1 "work-in-progress" was a reflow | **Task 6** |

**Deliberately excluded**, each needing a separate decision or a repo-wide
change:
- **Byte-exact golden replies.** `golden_vectors.json` records no expected
  replies, so a byte-exact count cannot be measured. Choosing the golden replies
  is a decision for the user (the R2 conformance vectors are one possible
  source).
- **`__main__` entry points fail with ModuleNotFoundError.** Every test module
  in `tools/host_bridge/tests` shares this, and the supported invocation is
  `python3 -m unittest`. Fixing two files would split the convention.
- **The 13 sibling files not yet `ruff format`ted, and a formatting gate.** This
  is a repo-wide change.
- **Sharing one compile across tests, and deduplicating `WORDS` across lanes.**
  The first needs an adapter API change; the second couples the lanes.
- **IRQ modelling per exchange.** This is a new capability; the IRQ test skip
  stays honest.
- **The testbench's 1.5× bit time and its settle word**, which TTAdapter does
  not clock. Both are SPI-timing questions that only the board run (item 11)
  can settle.
