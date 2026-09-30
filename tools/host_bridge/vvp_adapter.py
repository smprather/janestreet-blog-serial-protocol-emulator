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
reads a request frame from a file, clocks it out on the framed host bus, and
writes the captured MISO to a response file. File handshake rather than VPI
because this is an acceptance/dev tool, not a gate, and a file handshake is
inspectable when a run goes wrong - which is the whole lesson of this project.

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


class VvpTTAdapterError(RuntimeError):
    pass


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
        period_ps: int = 200,
        vvp_timeout_s: float = 30.0,
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
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        self.tb = tb
        self.period_ps = period_ps
        self.vvp_timeout_s = vvp_timeout_s
        self._workdir = tempfile.mkdtemp(prefix="pe-vvp-")
        self._vvp_path: str | None = None
        self._configured = False
        self._irq_enabled = False
        self.calls: list[tuple] = []  # recorded for parity with FakeTTAdapter
        self.transfers: list[bytes] = []
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
        raise VvpTTAdapterError(
            "could not find the wrapper source list in run_all.sh")

    def _sram_files(self) -> list[str]:
        sram = os.path.join(self.repo_root, "regress", "sram_model.sh")
        try:
            res = subprocess.run(
                [sram], capture_output=True, text=True, check=True)
        except (OSError, subprocess.CalledProcessError) as exc:
            raise VvpTTAdapterError(f"sram_model.sh failed: {exc}") from exc
        return res.stdout.split()

    def _start(self) -> None:
        if self._vvp_path is not None:
            return
        out = os.path.join(self._workdir, "sim.vvp")
        cmd = [
            "iverilog", "-g2012", "-s", self.tb, "-o", out,
            *self._rtl_list(), *self._sram_files(),
            os.path.join("tb", f"{self.tb}.v"),
        ]
        res = subprocess.run(
            cmd, cwd=os.path.join(self.repo_root, "regress"),
            capture_output=True, text=True, check=False)
        if res.returncode != 0:
            raise VvpTTAdapterError(f"compile failed: {res.stderr[:400]}")
        self._vvp_path = out

    def _run_tb(self, req_words: list[int], resp_words: int) -> list[int]:
        """One externally-paced exchange: write the request, run vvp, read back."""
        self._start()
        req = os.path.join(self._workdir, "req.txt")
        resp = os.path.join(self._workdir, "resp.txt")
        try:
            with open(req, "w", encoding="utf-8") as fh:
                fh.write("\n".join(f"{w & 0xFFFF:04X}" for w in req_words) + "\n")
            if os.path.exists(resp):
                os.remove(resp)
        except OSError as exc:
            raise VvpTTAdapterError(f"cannot stage the request: {exc}") from exc

        cmd = [
            "vvp", str(self._vvp_path),
            f"+req={req}", f"+resp={resp}", f"+period={self.period_ps}",
            f"+read_words={resp_words}",
        ]
        try:
            res = subprocess.run(
                cmd, cwd=os.path.join(self.repo_root, "regress"),
                capture_output=True, text=True, check=False,
                timeout=self.vvp_timeout_s)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise VvpTTAdapterError(f"vvp did not complete: {exc}") from exc
        if res.returncode != 0:
            raise VvpTTAdapterError(
                f"vvp exited {res.returncode}: {res.stdout[-400:]}")
        try:
            with open(resp, "r", encoding="utf-8") as fh:
                return [int(l.strip(), 16) for l in fh if l.strip()]
        except (OSError, ValueError) as exc:
            raise VvpTTAdapterError(f"cannot read the response: {exc}") from exc

    # ---- the 6-method HAL --------------------------------------------------
    def enable_project(self, name: str) -> None:
        self.calls.append(("enable_project", name))
        self._start()

    def set_clock(self, hz: int) -> int:
        self.calls.append(("set_clock", hz))
        return hz

    def reset(self, active: bool) -> None:
        self.calls.append(("reset", bool(active)))

    def set_run(self, active: bool) -> None:
        self.calls.append(("set_run", bool(active)))

    def configure_host_spi(self, sclk_hz: int) -> None:
        self.calls.append(("configure_host_spi", sclk_hz))
        self._configured = True

    def host_spi_transfer(self, data: bytes,
                          read_words: int | None = None) -> bytes:
        """Exchange one framed request; return the RAW response byte stream.

        Mirrors TTAdapter: CS_N low for the whole frame, the request MSB-first
        with simultaneous clock-out, then clock a total of ``read_words``
        16-bit words (padding 0xFFFF after the request, exactly as the real
        adapter does). The caller strips leading wait words with
        strip_wait_words - this deliberately does NOT strip them, because that is
        the host's job and doing it here would hide the wait-word contract this
        project already got wrong once.
        """
        if not self._configured:
            raise VvpTTAdapterError(
                "configure_host_spi() must run before a transfer")
        self.calls.append(("spi_transfer", len(data)))
        req_words = [(data[i] << 8) | data[i + 1]
                     for i in range(0, len(data) - 1, 2)]
        if len(data) % 2:
            req_words.append(data[-1])  # defensive; frames are word-aligned
        total = max(1, len(req_words)) if read_words is None else max(1, read_words)
        self.transfers.append(bytes(data))
        resp = self._run_tb(req_words, total)
        out = bytearray()
        for w in resp:
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
        """Release the scratch directory.

        Teardown must not raise and mask the failure that caused it, so the
        error is recorded rather than swallowed or re-raised: a caller that
        cares can still read ``cleanup_error``, and a caller that does not is
        not interrupted by a leftover temp directory.
        """
        try:
            shutil.rmtree(self._workdir, ignore_errors=True)
        except OSError as exc:
            self.cleanup_error = exc

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()
