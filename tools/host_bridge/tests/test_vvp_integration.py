"""Bite 3: the REAL host bridge driving the REAL chip through VvpTTAdapter.

This is the payoff lane. ``test_host_integration.py`` already drives the real
``main.py`` bridge over ``LoopbackPort`` against ``FakeTTAdapter``; this module is
the same shape with ``VvpTTAdapter`` in the adapter seat, so the only thing that
changes is WHICH CHIP answers. Everything above the HAL - the framing, the codec,
the session state machine, the load/run/dump gating - is exercised unchanged on
both sides of the seam, which is what makes this a test of the seam rather than a
re-test of the bridge.

WHAT THIS ESTABLISHES, precisely. A PING is encoded by the real ``pe_frame``
codec, clocked onto the real chip's SPI host-slave, and the chip's response must
decode through the same codec with a VERIFIED CRC-16, RESPONSE_BIT set and
STATUS_OK. A frame with a deliberately corrupted CRC must FAIL to decode. Those two
together are what make this a test: a check that passed on garbage would satisfy
neither.

WHAT IT DOES NOT ESTABLISH, and this is the load-bearing caveat. USB
enumeration, real SPI timing and setup, board power and clock configuration, and
MicroPython itself remain hardware-only. This shrinks open item 11; it does not
close it, and no assertion here may be read as evidence about a board.

WHERE THE REAL CHIP AND FakePE GENUINELY DIFFER, stated rather than papered over:

  * ``FakePE.committed_words`` / ``FakePE.run`` / ``FakePE.dmem`` are plain Python
    attributes a test can read. The real chip has no such object, so the
    equivalent assertions are made against what the chip ACTUALLY returns over the
    wire - the STATUS response and the R2 reads - not against testbench internals.
    An assertion that could only be written against a fake is not carried over; it
    is replaced by the wire-visible equivalent, or skipped with a reason.
  * ``irq_n()`` returns None. Every IRQ- and liveness-dependent assertion is
    SKIPPED with an explicit reason. None is faked, and none is weakened to pass.
  * Every exchange is a separate vvp run that REPLAYS the whole session from
    power-on - each reset, run-pad change and earlier transfer - before its
    own transfer (VvpTTAdapter.host_spi_transfer). The simulation is
    deterministic, so chip state (a loaded IMEM, run) carries exactly as on a
    long-lived chip, and each replay must reproduce every earlier capture or
    the exchange is a harness error. Each exchange costs a little more than
    the one before it.

The two adapter defects this lane first reported (the testbench path missing
``../`` for the regress cwd, and ``+read_words=`` where the testbench reads
``+nresp=``) were fixed in vvp_adapter.py at 7de9775; see the WORKLOG entry.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from tools.host_bridge import main as M
from tools.host_bridge import pe_frame as F
from tools.host_bridge.vvp_adapter import VvpTTAdapter, VvpTTAdapterError, parse_captures
from tools.host_gui.session import (
    ControllerSession,
    SessionState,
    SessionStateError,
)
from tools.host_gui.tests.fakes import LoopbackPort
from tools.host_gui.transport import SerialTransport

REPO = str(Path(__file__).resolve().parents[3])
GOLDEN = Path(__file__).resolve().parent / "golden_vectors.json"

PROJECT = "tt_um_protocol_emulator"
# Same image the fake-chip test uses, so the two lanes are comparable.
WORDS = (0x0041, 0x1001, 0x4002)

# pe_frame's status codes by value, so a refusal is reported by name.
_STATUS_NAMES = {
    value: name for name, value in vars(F).items() if name.startswith("STATUS_")
}

# FIXED 2026-10-04 by plan Amendment A2. rtl/pe_soc.v:391-394 used to copy
# imem_rdata into dbg_rd_data on the REQUEST edge, but pe_imem's read is
# registered, so every host IMEM read returned the PREVIOUS address's word
# (READ_IMEM(1, 2) after loading 0x0041 0x1001 0x4002 answered 0x0041 0x1001).
# pe_soc now presents the macro output in the dbg_rd_valid cycle, and
# tb/tb_pe_soc_dbgread.v pins the port at the SoC level in the regression.
# Every IMEM read VALUE is asserted here, exactly.


def setUpModule():
    """Skip this lane, and say why, on a host that cannot run the simulator.

    tools/host_gui/run_host_tests.sh discovers this directory, and the host gate
    promises to need nothing but python3, so a missing simulator or PDK SRAM model
    is a SKIP that names what is missing (the convention the node-backed tests
    follow), never an ERROR that turns that gate red for a reason it says it does
    not cover. It is not a substitution: nothing here falls back to a fake chip,
    and the chip gate still fails loudly without the model.
    """
    missing = [tool for tool in ("iverilog", "vvp") if shutil.which(tool) is None]
    if missing:
        raise unittest.SkipTest(f"simulator not on PATH: {', '.join(missing)}")
    sram = subprocess.run(
        [str(Path(REPO, "regress", "sram_model.sh"))],
        capture_output=True,
        text=True,
        check=False,
    )
    if sram.returncode != 0:
        raise unittest.SkipTest("PDK SRAM model unavailable (regress/sram_model.sh)")


def _bring_up(adapter):
    """Run the bridge's own connect sequence - hello, then prepare - on ``adapter``.

    The direct-adapter tests bypass the session, so they must do this
    themselves: VvpTTAdapter refuses a transfer before configure_host_spi()
    (vvp_adapter.py:218), and that refusal is the adapter correctly enforcing the
    HAL contract rather than a defect. Driving PicoBridge's own handlers, rather
    than re-typing their HAL calls, keeps this exactly what main.py does on
    connect - prepare's reset pulse and its SCLK rule included - by construction
    instead of by copy.
    """
    bridge = M.PicoBridge(adapter, project=PROJECT, sleep=lambda _seconds: None)
    for request_id, op in enumerate(("hello", "prepare"), start=1):
        response = bridge.handle(M.USBRequest(request_id, op))
        if not response.ok:
            raise RuntimeError(f"bring-up {op!r} failed: {response.error}")


def _exchange(adapter, frame, read_words):
    """One raw exchange through ``adapter``, decoded exactly as the bridge does."""
    raw = adapter.host_spi_transfer(frame, read_words=read_words)
    return F.decode_frame(F.strip_wait_words(raw))


class TestRealBridgeOverRealChip(unittest.TestCase):
    """The mirror of TestHostOverRealBridge, with the real chip in the seat."""

    def setUp(self):
        # One adapter per test: it owns a scratch directory, and _start()
        # compiles the 16-file wrapper ONCE, so the second and later exchanges in
        # a test are vvp runs rather than compiles - each REPLAYING the session
        # from power-on (see the module docstring), so the chip keeps its state
        # like a long-lived one.
        self.adapter = VvpTTAdapter(repo_root=REPO)
        # Registered the moment the scratch directory exists: if a later setUp
        # step raises, tearDown never runs, and a cleanup still does.
        self.addCleanup(self.adapter.close)
        self.bridge = M.PicoBridge(
            self.adapter, project=PROJECT, sleep=lambda _seconds: None
        )
        self.port = LoopbackPort(self.bridge)
        self.transport = SerialTransport(self.port, timeout_s=10.0)
        self.session = ControllerSession(lambda: self.transport)
        self.image = SimpleNamespace(words=WORDS, word_count=len(WORDS), sha256="ab" * 32)

    # ---- the round trip, same steps and same assertions as the fake-chip lane --
    def test_connect_load_start_status_stop_dump_round_trip(self):
        self.session.connect()
        self.assertEqual(self.session.state, SessionState.PREPARED)
        self.assertEqual(self.session.negotiated_sclk_hz, 5_000_000)
        # NOT self.adapter.project_calls / .clock_calls: those are FakeTTAdapter
        # attributes, and borrowing them was how this test first asserted against
        # a name the real adapter does not have. VvpTTAdapter records ONE generic
        # `calls` list of (name, value) tuples, so the same fact is read from
        # there. A mirror of the fake lane is only a mirror if the assertions
        # survive the swap, not if they keep the fake's vocabulary.
        recorded = list(self.adapter.calls)
        # Exactly once each, as the fake lane asserts (project_calls ==
        # [PROJECT], clock_calls == [60 MHz]): assertIn would pass a bridge that
        # re-selected the project or restarted the clock on every request.
        self.assertEqual(recorded.count(("enable_project", PROJECT)), 1)
        self.assertEqual(
            [call for call in recorded if call[0] == "set_clock"],
            [("set_clock", 60_000_000)],
        )

        result = self.session.load(self.image)
        self.assertEqual(result.words_written, len(WORDS))
        self.assertEqual(result.echo, WORDS[-1])
        self.assertEqual(self.session.state, SessionState.LOADED)

        self.session.start()
        self.assertEqual(self.session.state, SessionState.RUNNING)

        snapshot = self.session.status()
        self.assertTrue(snapshot.run)
        # NOT 0, which the fake lane asserts because FakePE never executes. The
        # real core runs the image: 0x0041 LDI a,0x41; 0x1001 OUT 1,a; 0x4002
        # JMP 2 - a jump to itself (wiki/concepts/isa-and-soc.md). So a running
        # chip sits at pc 2.
        self.assertEqual(snapshot.pc, 2)

        self.session.stop()
        self.assertEqual(self.session.state, SessionState.STOPPED)

        # The R2 read path over the real chip: these are the reads the B1
        # wait-word fix is about, so they are the ones worth having.
        words = self.session.read_imem(1, 2)
        self.assertEqual(words, WORDS[1:3])

        dump = self.session.dump_core()
        self.assertEqual(dump.words_written, len(WORDS))

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
        self.assertEqual(
            len(self.adapter.transfers), sent, "a gated read reached the chip"
        )

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
        answer = _exchange(self.adapter, read, 6 + 1 + 15)
        self.assertEqual(answer.payload, (F.STATUS_OK, WORDS[0]))

    def test_session_read_imem_returns_the_requested_address(self):
        """READ_IMEM answers the words at the requested address, through the
        whole host stack (plan Amendment A2 fixed the one-address-stale
        capture; tb/tb_pe_soc_dbgread.v pins the read port itself)."""
        self.session.connect()
        self.session.load(self.image)
        self.session.start()
        self.session.stop()
        self.assertEqual(self.session.read_imem(1, 2), WORDS[1:3])

    # ---- THE ASSERTION THAT MATTERS: a real PING, a verified CRC-16 ----------
    def test_real_chip_ping_comes_back_with_a_verified_crc(self):
        """The chip's own answer, through the real codec, with a real CRC.

        Deliberately NOT going through the session: this asks whether the CHIP
        produces a decodable frame, so it uses the adapter directly and checks
        the bytes with pe_frame, which is the same codec the Pico bridge runs.
        """
        _bring_up(self.adapter)
        frame = F.encode_frame(F.OP_PING, 7, F.TARGET_HOST)
        # Twice the bridge's PING budget (6 + 15): if the read budget ever
        # stopped reaching the testbench (the XFER line's nresp field), the
        # capture would come back short, so the PING guards that plumbing too.
        read_words = 2 * (6 + 15)
        raw = self.adapter.host_spi_transfer(frame, read_words=read_words)
        self.assertGreaterEqual(
            len(raw), 2 * read_words, "the read budget never reached the testbench"
        )

        # Same rule the host uses: leading 0xFFFF wait words are the R2 contract,
        # so strip them before decoding and do NOT assume zero. A chip that does
        # not answer still fills the whole read budget (an idle pad reads 0xFFFF),
        # so it is the decode, not the byte count, that tells a silent chip apart.
        try:
            decoded = F.decode_frame(F.strip_wait_words(raw))
        except F.FrameError as exc:
            self.fail(f"the chip's answer did not decode: {exc}")
        self.assertEqual(
            decoded.opcode, F.OP_PING | F.RESPONSE_BIT, "not a response to the PING"
        )
        self.assertEqual(decoded.sequence, 7)
        self.assertEqual(decoded.target, F.TARGET_HOST)
        # A refusal is a CRC-valid response too: pe_ctrl echoes the opcode and
        # sequence of a request it REJECTS (BAD_FRAME, UNSUPPORTED), so only the
        # status word says the chip accepted the PING.
        self.assertEqual(decoded.payload, (F.STATUS_OK,), "the chip refused the PING")

    # ---- the negative: a corrupted frame must NOT decode --------------------
    def test_a_corrupted_frame_does_not_decode(self):
        """A frame with one bad CRC bit must be rejected, not tolerated.

        This is what makes the assertion above worth anything. decode_frame
        raising is the pass condition; if it ever stopped raising, the chip test
        would be validating a check that accepts garbage.
        """
        good = F.encode_frame(F.OP_PING, 7, F.TARGET_HOST)
        bad = bytearray(good)
        bad[-1] ^= 0x01  # flip one bit of the CRC
        with self.assertRaises(F.FrameError):
            F.decode_frame(F.strip_wait_words(bytes(bad)))

    # ---- and the wire really is the chip, not a stub -------------------------
    def test_a_frame_the_chip_never_saw_cannot_decode(self):
        """An all-wait-word capture is what a chip that is NOT answering looks
        like. Proving the negative distinguishes "the chip answered" from "the
        test would have been happy either way"."""
        with self.assertRaises(F.FrameError):
            F.decode_frame(F.strip_wait_words(b"\xff\xff" * 21))

    # ---- IRQ: SKIPPED WITH A REASON, never faked -----------------------------
    def test_irq_liveness_is_skipped_because_irq_is_unmodelled(self):
        if self.adapter.irq_n() is not None:
            self.skipTest("adapter now models IRQ; this skip is stale")
        # irq_n() is None because the testbench does not model IRQ per call.
        # Asserting liveness on it would manufacture a signal nothing measured.
        # The fake-chip lane covers the IRQ path against FakePE; that path is
        # BLOCKED-ON-A-REAL-CHIP-CAPABILITY here, not skipped for convenience.
        # skipTest, not an exception raised and caught inside assertRaises: that
        # form reported this test as a PASS and never showed the reason.
        self.skipTest(
            "IRQ_N is not modelled per-call by tb_pe_soc_extspi.v, so the "
            "chip.irq event and the liveness row are BLOCKED ON A REAL CHIP "
            "CAPABILITY, not proven and not faked"
        )


class TestGoldenVectorsOnRealChip(unittest.TestCase):
    """The project's own golden frames, sent to the real chip.

    This is the deliverable number of the whole effort: how many of the recorded
    frames the REAL RTL accepts IN SIMULATION. A vector is "reproduced" only when
    the chip answers THAT request - its opcode with RESPONSE_BIT, its sequence, its
    target - with a CRC-valid frame carrying STATUS_OK. A CRC-valid REFUSAL
    (STATUS_RANGE, STATUS_UNSUPPORTED, ...) is a decodable frame too, so it is
    reported under "partial" with its status named, never counted.
    golden_vectors.json records no expected replies, so this is not a byte-exact
    comparison of what the chip sends back. A precise partial result is worth far
    more than a green that hides it, so every vector reports its own outcome and
    the reasons for any mismatch are named.
    """

    def setUp(self):
        self.adapter = VvpTTAdapter(repo_root=REPO)
        self.addCleanup(self.adapter.close)  # the bring-up below can raise
        with open(GOLDEN, encoding="utf-8") as fh:
            self.golden = json.load(fh)["frames"]
        # The same bring-up the other class does: without it every vector fails
        # the adapter's own precondition (configure_host_spi before a transfer)
        # and the count reports a harness bug as a chip failure.
        _bring_up(self.adapter)

    def test_golden_vectors_against_the_real_chip(self):
        self.assertGreater(len(self.golden), 0, "no golden frames to run")
        reproduced, partial, failed = [], [], []

        for v in self.golden:
            frame = bytes.fromhex(v["frame_hex"])
            name = v["name"]
            try:
                raw = self.adapter.host_spi_transfer(frame, read_words=6 + 15)
            except VvpTTAdapterError as exc:
                # The lane could not run this vector at all (vvp timeout, no
                # response file, X on MISO): say so, rather than let it read as a
                # chip that answered nothing.
                failed.append((name, f"HARNESS, not a chip answer: {exc}"))
                continue
            try:
                answer = F.decode_frame(F.strip_wait_words(raw))
            except F.FrameError as exc:
                # No decodable frame. Every vector here is answered on the host
                # MISO - target_loopback too: it is an OP_TARGET request SENT to
                # TARGET_HOST - so this is a real miss, never an expected one.
                failed.append((name, f"no decodable frame: {exc}"))
                continue
            status = answer.payload[0] if answer.payload else None
            if (answer.opcode, answer.sequence, answer.target) != (
                v["opcode"] | F.RESPONSE_BIT,
                v["sequence"],
                v["target"],
            ):
                why = (
                    f"answered opcode 0x{answer.opcode:02X} sequence "
                    f"{answer.sequence} target {answer.target}, not this request"
                )
                partial.append((name, why))
            elif status != F.STATUS_OK:
                why = f"answered {_STATUS_NAMES.get(status, status)}, not STATUS_OK"
                if v["opcode"] & F.RESPONSE_BIT:
                    why += " (a RESPONSE frame sent as a request: refusing it is right)"
                elif name == "read_imem":
                    # Not a defect: the vector asks for 32 words and a bounded
                    # read answers at most 15 (pe_ctrl.v, R2 contract).
                    why += (
                        " (the CORRECT refusal: count 32 exceeds the 15-word"
                        " bounded-read limit, pe_ctrl.v)"
                    )
                partial.append((name, why))
            else:
                reproduced.append(name)

        lines = [
            "  golden vectors against the REAL chip:",
            f"    n vectors      : {len(self.golden)}",
            f"    reproduced     : {len(reproduced)}  {reproduced}",
            "      (a STATUS_OK answer to that request; not a byte-exact match)",
            f"    not reproduced : {len(failed)}",
        ]
        lines += [f"      - {name}: {why}" for name, why in failed]
        if partial:
            lines.append(f"    partial        : {len(partial)}")
            lines += [f"      - {name}: {why}" for name, why in partial]
        report = "\n".join(lines)
        # Flushed, so a redirected run keeps the report next to this test instead
        # of after the runner's summary; and carried in the failure message, so a
        # failing run states its reasons even when stdout is buffered away.
        print("\n" + report, flush=True)

        # The number is reported; the threshold is deliberately low so the test
        # proves the LANE runs end to end. Raising it is a judgement about what
        # the chip should do, not about whether this harness works.
        self.assertGreater(
            len(reproduced),
            0,
            "NO golden frame was reproduced - the lane is not proven\n" + report,
        )


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
        so its read could not even be captured. The read VALUES are checked
        here too, exactly."""
        answer = self._load_then_read(1, 2)
        self.assertEqual(answer.opcode, F.OP_READ_IMEM | F.RESPONSE_BIT)
        self.assertEqual(answer.sequence, 2)
        self.assertEqual(answer.payload, (F.STATUS_OK, WORDS[1], WORDS[2]))

    def test_host_imem_read_returns_the_requested_address(self):
        """READ_IMEM(1, 2) after LOADing WORDS answers exactly (WORDS[1],
        WORDS[2]), at the testbench level (plan Amendment A2)."""
        answer = self._load_then_read(1, 2)
        self.assertEqual(answer.payload, (F.STATUS_OK, WORDS[1], WORDS[2]))

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


if __name__ == "__main__":
    unittest.main()
