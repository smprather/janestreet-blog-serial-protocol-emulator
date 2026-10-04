"""VvpTTAdapter - the REAL chip behind the bridge's 6-method HAL.

Implements exactly the duck-typed contract of ``tools.host_bridge.tt_adapter.TTAdapter``
(the SPI-host-slave path), but routes framed SPI bytes to a ``vvp`` process
running the REAL ``tt_um_protocol_emulator`` - the wrapper where ``pe_ctrl``,
the SPI host-slave, actually lives - instead of a fake. That makes it possible to
run the REAL ``main.py`` bridge unmodified against the REAL chip RTL with no
board, which is what shrinks open item 11 from "trust the whole stack" to
"trust USB enumeration, SPI timing, board power and MicroPython".

WHAT THIS DOES NOT COVER, and it is not small: USB enumeration, real SPI timing
and setup, board power and clock configuration, and MicroPython itself. Those
four are genuinely hardware-only. This adapter is a complement to item 11, never
a substitute, and must never be reported as if it closed it.

THE SEAM IS ONE OBJECT. ``tools/host_bridge/tests/test_host_integration.py``
already drives the real bridge over ``LoopbackPort`` against ``FakeTTAdapter``
through a full connect/load/start/stop/dump round trip. Swapping in this adapter
is a one-line change in setUp. Everything above the HAL is exercised on both
sides of it, which is why this is the seam rather than re-testing the bridge.

THE BACKEND IS FILE-BASED, DELIBERATELY. The testbench ``tb_pe_soc_extspi.v``
reads a +script of events (reset, run pad, framed transfers) from a file,
replays it from power-on, and writes every transfer's captured MISO to a
response file. File handshake rather than VPI or a long-lived process on pipes,
because this is an acceptance/dev tool, not a gate, and a file handshake is
inspectable when a run goes wrong - which is the whole lesson of this project.
Chip state carries across calls by REPLAY: see host_spi_transfer.

PATHS ARE CONSTRUCTED UNDER AN EXPLICIT repo_root rather than discovered by
walking upward from arbitrary locations: this tool builds a simulator from a
named source list, and a source list resolved by accident is how you get a chip
silently missing pe_ctrl.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile

# The framed host bus on the wrapper (rtl/tt_um_protocol_emulator.v:61-64). These
# are the pad indices, NOT the SoC-as-master map in tb_pe_soc_spi3.v.
PAD_CS_N = 4
PAD_MOSI = 5
PAD_MISO = 6
PAD_SCK = 7
IRQ_UO_BIT = 1

PROJECT_CLK_HZ = 60_000_000

# tb_pe_soc_extspi.v's limits (MAX_WORDS, PATH_BYTES). The adapter refuses
# anything past them up front, so the error names the limit instead of being a
# FAIL line from deep inside a vvp run.
TB_MAX_WORDS = 512
TB_PATH_BYTES = 4096

# +script event codes (tb_pe_soc_extspi.v, "+script mode").
_EV_RST = 1
_EV_RUN = 2
_EV_XFER = 3


class VvpTTAdapterError(RuntimeError):
    pass


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


class VvpTTAdapter:
    """The 6-method HAL, backed by a vvp process running the real chip.

    Contract, identical to TTAdapter so it is a drop-in:
      enable_project(name), set_clock(hz), reset(active), set_run(active),
      configure_host_spi(sclk_hz), host_spi_transfer(data, read_words),
      irq_n().
    """

    def __init__(
        self,
        repo_root: str | None = None,
        *,
        tb: str = "tb_pe_soc_extspi",
        period_ns: int = 200,
        vvp_timeout_s: float = 30.0,
        compile_timeout_s: float = 300.0,
    ) -> None:
        # repo_root defaults to the repo this file lives in:
        # tools/host_bridge/vvp_adapter.py -> up three levels is the repo root.
        # Written out rather than nested inline because a four-deep
        # os.path.dirname chain is exactly where a dropped paren turns a module
        # that cannot be imported into one that looks fine.
        if repo_root:
            self.repo_root = repo_root
        else:
            self.repo_root = os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            )
        self.tb = tb
        # +period is in NANOSECONDS (tb_pe_soc_extspi.v, "TIMING"); the old name
        # period_ps was a 1000x unit error in the name. configure_host_spi()
        # derives it from the negotiated SCLK.
        self.period_ns = period_ns
        self.compile_timeout_s = compile_timeout_s
        self.vvp_timeout_s = vvp_timeout_s
        self._workdir = tempfile.mkdtemp(prefix="pe-vvp-")
        self._vvp_path: str | None = None
        self._configured = False
        self._irq_enabled = False
        self.calls: list[tuple] = []  # recorded for parity with FakeTTAdapter
        self.transfers: list[bytes] = []
        # The session so far as +script lines, and what each completed transfer
        # returned - see host_spi_transfer, "STATE CARRIES ACROSS CALLS".
        self._events: list[str] = []
        self._captures: list[list[int]] = []
        self.cleanup_error: OSError | None = None

    # ---- lifecycle ---------------------------------------------------------
    def _rtl_list(self) -> list[str]:
        """The SAME 16-file list run_all.sh uses for tt_um_protocol_emulator.

        Read from run_all.sh rather than hardcoded: if the wrapper's source list
        changes, this follows it instead of silently building a chip that is
        missing pe_ctrl - the exact failure the pin-map correction prevented.
        """
        run_all = os.path.join(self.repo_root, "regress", "run_all.sh")
        try:
            with open(run_all, "r", encoding="utf-8") as fh:
                for line in fh:
                    if line.strip().startswith('"tb_tt_um_protocol_emulator|'):
                        return line.strip().split("|")[1].split()
        except OSError as exc:
            raise VvpTTAdapterError(f"cannot read {run_all}: {exc}") from exc
        raise VvpTTAdapterError("could not find the wrapper source list in run_all.sh")

    def _sram_files(self) -> list[str]:
        sram = os.path.join(self.repo_root, "regress", "sram_model.sh")
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
        return res.stdout.split()

    def _start(self) -> None:
        if self._vvp_path is not None:
            return
        out = os.path.join(self._workdir, "sim.vvp")
        cmd = [
            "iverilog",
            "-g2012",
            "-s",
            self.tb,
            "-o",
            out,
            *self._rtl_list(),
            *self._sram_files(),
            os.path.join("..", "tb", f"{self.tb}.v"),
        ]
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
        if res.returncode != 0:
            raise VvpTTAdapterError(f"compile failed: {res.stderr[:400]}")
        self._vvp_path = out

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

    # ---- the 6-method HAL --------------------------------------------------
    def enable_project(self, name: str) -> None:
        self.calls.append(("enable_project", name))
        self._start()

    def set_clock(self, hz: int) -> int:
        # The testbench clock is fixed at PROJECT_CLK_HZ (tb CLK_HZ). The HAL
        # returns the clock actually running - as TTAdapter returns what the PWM
        # got - so the bridge never derives SCLK from a clock it did not get.
        self.calls.append(("set_clock", hz))
        return PROJECT_CLK_HZ

    def reset(self, active: bool) -> None:
        self.calls.append(("reset", bool(active)))
        self._events.append(f"{_EV_RST:X} {int(bool(active)):X}")

    def set_run(self, active: bool) -> None:
        self.calls.append(("set_run", bool(active)))
        self._events.append(f"{_EV_RUN:X} {int(bool(active)):X}")

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

    def irq_n(self):
        """IRQ is not modelled per-call by the testbench yet.

        Returns None implicitly, which is the honest answer the HAL already uses
        for "this adapter cannot report IRQ" (FakeTTAdapter with
        irq_supported=False does the same). Guessing a value here would
        manufacture a liveness signal that nothing measured, which is the
        failure mode this whole project keeps correcting.
        """

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
            try:
                shutil.rmtree(self._workdir, onexc=record)
            except OSError as exc:
                # Defensive: with onexc set, rmtree routes every OSError to the
                # callback, so this is unreachable today. It is here so the
                # method's promise - teardown never raises - holds even if a
                # future Python changes that, and so the static check sees it.
                if self.cleanup_error is None:
                    self.cleanup_error = exc

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()
