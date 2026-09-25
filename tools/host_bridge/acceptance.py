"""Scripted board-in-the-loop acceptance runner (plan Task 7).

Two modes, same script:

    python3 tools/host_bridge/acceptance.py --fake
        the whole host stack (SerialTransport + ControllerSession) talks to
        the real bridge over the fake SDK adapter and the fake PE model.
        No serial device is opened.

    python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0 --board revB
        the same script against a real Pico bridge. Needs the Pico, and the
        chip-side RTL phases R1/R2 for the fault/readback steps.

The runner never synthesizes a PASS: a step the current contract cannot
observe (UART bytes, and IRQ/faults before RTL phase R1 on hardware) is
reported SKIP with the reason.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

if __package__ in (None, ""):  # direct script run: put the repo root on path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.host_gui import protocol as P
from tools.host_gui.fake_pe import FAULT_LOAD, FAULT_RANGE, IMEM_WORDS
from tools.host_gui.image import ImageError, assemble_program
from tools.host_gui.session import (
    ControllerSession,
    SessionError,
    SessionState,
    TransportLike,
)
from tools.host_gui.transport import TransportError

REPO_ROOT = Path(__file__).resolve().parents[2]
FIRMWARE = "firmware/uart_echo.pe"
DEFAULT_DEVICE = "/dev/ttyACM0"
DEFAULT_PROJECT = "tt_um_protocol_emulator"
PE_CLOCK_HZ = 60_000_000


@dataclass
class Check:
    name: str
    status: str
    detail: str = ""


@dataclass
class AcceptanceReport:
    board: str = "unknown"
    checks: list[Check] = field(default_factory=list)
    manifest: dict = field(default_factory=dict)

    def record(self, name, ok, detail=""):
        self.checks.append(Check(name, "PASS" if ok else "FAIL", detail))
        return bool(ok)

    def skip(self, name, detail):
        self.checks.append(Check(name, "SKIP", detail))

    @property
    def failures(self):
        return [check for check in self.checks if check.status == "FAIL"]

    @property
    def passed(self):
        return not self.failures

    def render(self):
        lines = [f"Host controller acceptance - board: {self.board}", ""]
        width = max((len(check.name) for check in self.checks), default=0)
        for check in self.checks:
            lines.append(
                f"  {check.status:<4} {check.name:<{width}}  {check.detail}".rstrip()
            )
        passes = sum(check.status == "PASS" for check in self.checks)
        skips = sum(check.status == "SKIP" for check in self.checks)
        lines += ["", "manifest: " + json.dumps(self.manifest, sort_keys=True)]
        lines.append(
            f"RESULT: {'PASS' if self.passed else 'FAIL'} "
            f"({passes} PASS, {len(self.failures)} FAIL, {skips} SKIP)"
        )
        return "\n".join(lines)


# The roles a link plays, as Protocols. `Link` used to type every field as
# `object`, which told a type checker nothing while the script went on to call
# `first.transport.request(...)`, `first.pe.faults` and
# `first.adapter.set_irq(...)` unchecked. These say what each side must offer,
# and they are structural, so the real FakePE / PicoBridge / TTAdapter satisfy
# them without inheriting anything. Stdlib only, as this module must stay.
class _PEModel(Protocol):
    faults: int
    dmem: bytearray
    timer: int
    run: bool
    read_fault_policy: str


class _Adapter(Protocol):
    # Positional-only: TTAdapter spells this `active` and FakeTTAdapter spells
    # it `asserted`, and this script only ever calls it positionally. A
    # name-based protocol would demand one spelling and reject the other,
    # which says nothing useful about the capability.
    def set_irq(self, asserted: bool, /) -> None: ...

    def set_run(self, active: bool, /) -> None: ...


class _Bridge(Protocol):
    def poll_irq(self) -> list[dict]: ...


@dataclass
class Link:
    transport: TransportLike
    pe: _PEModel | None = None
    adapter: _Adapter | None = None
    bridge: _Bridge | None = None


def build_fake_link(project=DEFAULT_PROJECT):
    """Real bridge plus the fake SDK adapter and fake PE; no serial device."""
    from tools.host_bridge import main as M
    from tools.host_bridge.tests.fakes import FakeTTAdapter
    from tools.host_gui import fake_pe as F
    from tools.host_gui.tests.fakes import LoopbackPort
    from tools.host_gui.transport import SerialTransport

    pe = F.FakePE()
    adapter = FakeTTAdapter(pe, irq_supported=True)
    bridge = M.PicoBridge(adapter, project=project, sleep=lambda _seconds: None)
    transport = SerialTransport(LoopbackPort(bridge), timeout_s=1.0)
    return Link(transport=transport, pe=pe, adapter=adapter, bridge=bridge)


def build_serial_link(device):
    """Open the real USB CDC device; never touches board pins by itself."""
    from tools.host_gui.transport import SerialTransport, open_serial

    try:
        port = open_serial(device)
    except TransportError as exc:  # missing pyserial
        raise TransportError(f"{exc} (install: pip install .[host-gui])") from exc
    except OSError as exc:
        raise TransportError(
            f"cannot open {device}: {exc} - is the Pico connected and the "
            f"desktop user in the 'dialout' group (sudo usermod -aG dialout "
            f"$USER, then re-login)?"
        ) from exc
    return Link(transport=SerialTransport(port))


def _r2_detail(text: str) -> str:
    """Tag every R2 read-path line with its evidence status.

    Chip R2 is landed and chip-confirmed IN SIMULATION (chip repo
    `tb_pe_ctrl_r2`: all 15 golden steps byte-exact, see
    `R2-READ-PATH-REVIEW.md`). The hardware run — this script against a real
    Pico and shuttle — is still unexecuted, so the tag says exactly that.
    """
    return (
        f"{text} [chip-confirmed in simulation (tb_pe_ctrl_r2, 15/15 "
        f"byte-exact); hardware acceptance not yet run]"
    )


def _r3_detail(text: str) -> str:
    """Tag every R3 debug-control line with its evidence status.

    The R3 contract is IMPLEMENTED chip-side (pe_ctrl.v opcodes 0x21-0x24, and
    the chip's own tb_pe_ctrl_r3 with a 7-mutant gate). This script, however,
    is a HOST script: these cases check the host's session/API path against the
    FakePE model, and the host's own golden vectors in
    `reviews/2026-09-25/R3-DEBUG-VERIFICATION.json` are still
    chip_confirmed=false -- no step has been run against tb_pe_ctrl_r3 yet.
    The tag says exactly that, and does not borrow the chip's evidence.
    """
    return (
        f"{text} [host-side only: R3 vectors NOT yet chip-confirmed "
        f"(tb_pe_ctrl_r3 has not run them); hardware acceptance not run]"
    )


def _observe_heartbeat(session, pe, *, tries=3, sleep=time.sleep):
    """A running core must move the STATUS timer. Fake mode scripts the move."""
    before = session.status().timer
    for _ in range(tries):
        if pe is not None:
            pe.timer = (pe.timer + 1) & 0xFF  # scripted running core
        current = session.status().timer
        if current != before:
            return True, f"timer {before} -> {current}"
        sleep(0.25)
    return False, f"timer stuck at {before}"


def run_acceptance(
    *,
    fake,
    device=None,
    project=DEFAULT_PROJECT,
    board=None,
    repo_root=REPO_ROOT,
    link_factory=None,
):
    """Run the scripted acceptance; returns a report, never raises on FAIL."""
    report = AcceptanceReport(board=board or ("fake-adapter" if fake else "unknown"))
    if link_factory is None:
        if fake:
            link_factory = lambda: build_fake_link(project)
        else:
            link_factory = lambda: build_serial_link(device or DEFAULT_DEVICE)

    try:
        first = link_factory()
    except (TransportError, RuntimeError) as exc:
        report.record("open", False, str(exc))
        return report
    report.record(
        "open",
        True,
        "fake SDK adapter + fake PE; no serial device opened"
        if fake
        else f"opened {device or DEFAULT_DEVICE}",
    )

    try:
        hello = first.transport.request("hello")
    except TransportError as exc:
        report.record("hello", False, str(exc))
        return report
    report.record(
        "hello",
        hello.get("protocol_version") == 1 and isinstance(hello.get("pads"), dict),
        f"v{hello.get('protocol_version')} "
        f"clock={hello.get('clock_hz')} "
        f"sclk_max={hello.get('sclk_hz_max')} pads={hello.get('pads')}",
    )
    report.manifest.update(
        {
            key: hello.get(key)
            for key in ("protocol_version", "clock_hz", "sclk_hz_max", "pads")
        }
    )

    links = [first]
    uses = 0

    def transport_factory():
        nonlocal uses
        uses += 1
        if uses == 1:
            return links[0].transport
        link = link_factory()
        links.append(link)
        return link.transport

    session = ControllerSession(transport_factory)
    try:
        session.connect()
    except SessionError as exc:
        report.record("prepare", False, str(exc))
        return report
    report.record(
        "prepare",
        session.state == SessionState.PREPARED,
        f"state={session.state} sclk<={session.negotiated_sclk_hz}",
    )

    cap = session.negotiated_sclk_hz
    try:
        result = first.transport.request("set_sclk", {"hz": cap})
        report.record(
            "sclk",
            result.get("sclk_hz") == cap,
            f"negotiated {cap} Hz; bridge applied {result.get('sclk_hz')}",
        )
    except TransportError as exc:
        report.record("sclk", False, str(exc))
    report.manifest["sclk_hz"] = cap

    try:
        image = assemble_program(Path(repo_root) / FIRMWARE, repo_root)
    except ImageError as exc:
        report.record("assemble", False, str(exc))
        return report
    report.manifest.update(
        {
            "source": image.source,
            "word_count": image.word_count,
            "sha256": image.sha256,
            "terminal_jump": image.terminal_jump,
        }
    )
    report.record(
        "assemble",
        image.word_count > 0,
        f"{image.source}: {image.word_count} words, sha256 {image.sha256[:16]}...",
    )

    try:
        load = session.load(image)
    except SessionError as exc:
        report.record("load", False, str(exc))
        return report
    report.record(
        "load",
        load.words_written == image.word_count
        and load.echo == image.words[-1]
        and load.faults == 0,
        f"{load.words_written}/{image.word_count} words, "
        f"echo=0x{load.echo:04X}, faults=0x{load.faults:04X}",
    )

    # A bounded read carries at most MAX_READ_WORDS=15 data words per frame
    # (the chip rejects a larger count with RANGE), so the readback is split
    # into ceiling-sized chunks - the host's documented obligation.
    chunk = min(image.word_count, 15) or 1
    words = []
    try:
        for offset in range(0, image.word_count, chunk):
            words.extend(session.read_imem(offset, min(chunk, image.word_count - offset)))
    except SessionError as exc:
        report.record("readback", False, str(exc))
        return report
    words = tuple(words)
    report.record(
        "readback",
        words == image.words,
        f"{len(words)}/{image.word_count} words match the manifest "
        f"in {chunk}-word chunks",
    )

    try:
        session.start()
        snapshot = session.status()
    except SessionError as exc:
        report.record("start", False, str(exc))
        return report
    report.record(
        "start", bool(snapshot.run), f"state={snapshot.state} run={snapshot.run}"
    )

    # READ_CPU is the one read that must answer while the core runs (R2).
    # Driven through the session state machine (not the raw transport) so the
    # whole host read path is exercised.
    try:
        cpu = session.read_cpu()
        cpu_ok = True
        cpu_detail = (
            f"pc=0x{cpu.pc:04X} insn=0x{cpu.insn:04X} state={cpu.state} while running"
        )
    except SessionError as exc:
        cpu_ok, cpu_detail = False, str(exc)
    report.record("r2_read_cpu", cpu_ok, _r2_detail(cpu_detail))

    heartbeat_ok, heartbeat_detail = _observe_heartbeat(session, first.pe)
    report.record("heartbeat", heartbeat_ok, heartbeat_detail)

    try:
        session.stop()
    except SessionError as exc:
        report.record("stop", False, str(exc))
        return report
    report.record("stop", session.state == SessionState.STOPPED, f"state={session.state}")

    try:
        dump = session.dump_core()
    except SessionError as exc:
        report.record("dump", False, str(exc))
        return report
    report.record(
        "dump",
        dump.words_written == image.word_count,
        f"registers captured, words_written={dump.words_written}",
    )

    # ---- R2 read path (plan Tasks 3-5; chip-side, NOT chip-confirmed) ----
    # These are the end-to-end expectations the chip read path must meet the
    # moment R2 lands. On hardware before R2 they fail, which is the point:
    # they are the gate, not decoration.
    last = image.word_count - 1
    try:
        tail = tuple(session.read_imem(last, 1))
        report.record(
            "r2_read_imem",
            tail == (image.words[last],),
            _r2_detail(f"address={last} count=1 -> {tail[0] if tail else 'no word'}"),
        )
    except SessionError as exc:
        report.record("r2_read_imem", False, _r2_detail(str(exc)))

    if first.pe is not None:
        first.pe.dmem[0:4] = b"\x0a\x0b\x0c\x0d"
    try:
        dmem = session.read_dmem(0, 4)
        if first.pe is None:
            report.record(
                "r2_read_dmem",
                len(dmem) <= 16,
                _r2_detail(
                    f"{len(dmem)} bytes; content is firmware-dependent on hardware"
                ),
            )
        else:
            report.record(
                "r2_read_dmem",
                dmem == b"\x0a\x0b\x0c\x0d",
                _r2_detail(f"model-seeded pattern read back: {dmem.hex()}"),
            )
    except SessionError as exc:
        report.record("r2_read_dmem", False, _r2_detail(str(exc)))

    # Initialised here so the invariant does not depend on which branch of the
    # try/except below runs.
    range_latched = False
    try:
        session.read_imem(IMEM_WORDS - 1, 2)  # must be RANGE, never wrap
        report.record(
            "r2_range", False, _r2_detail("read past the end returned data (wrapped)")
        )
        range_latched = False
    except SessionError as exc:
        ok = f"status {P.STATUS_RANGE}" in str(exc)
        detail = str(exc)
        if first.pe is not None:
            range_latched = bool(first.pe.faults & FAULT_RANGE)
            detail += (
                f"; sticky FAULT_RANGE "
                f"{'latched' if range_latched else 'NOT latched'} "
                f"(policy={first.pe.read_fault_policy})"
            )
        report.record("r2_range", ok, _r2_detail(detail))

    # Manager RULING: an out-of-range READ latches sticky FAULT_RANGE and
    # CLEAR_FAULT clears it. Prove the whole lifecycle over the session:
    # bad read -> fault visible in STATUS -> FAULTED -> CLEAR_FAULT -> clear.
    lifecycle_detail = "no model to observe a latched read fault"
    lifecycle_ok = True
    if range_latched:
        try:
            faulted = session.status()
            seen = bool(faulted.faults & FAULT_RANGE)
            state_when_faulted = session.state
            became_faulted = state_when_faulted == SessionState.FAULTED
            cleared = session.clear_fault(FAULT_RANGE)
            healed = session.state in (SessionState.STOPPED, SessionState.PREPARED)
            lifecycle_ok = seen and became_faulted and cleared == 0 and healed
            lifecycle_detail = (
                f"bad read latched FAULT_RANGE (status.faults=0x"
                f"{faulted.faults:04X}, session state={state_when_faulted}); "
                f"CLEAR_FAULT -> 0x{cleared:04X}, cleared and state="
                f"{session.state}"
            )
        except SessionError as exc:
            lifecycle_ok, lifecycle_detail = False, str(exc)
    elif first.pe is not None:
        lifecycle_ok = False
        lifecycle_detail = "policy is status-only: no sticky fault to observe"
    report.record("r2_range_fault_lifecycle", lifecycle_ok, _r2_detail(lifecycle_detail))

    try:
        dump_again = session.dump_core()
        status_again = session.status()
        same = all(
            getattr(dump_again, field) == getattr(status_again, field)
            for field in (
                "state",
                "run",
                "pc",
                "a",
                "x",
                "y",
                "timer",
                "faults",
                "words_written",
            )
        )
        report.record(
            "r2_dump_header",
            same,
            _r2_detail("dump_core header == status header while stopped"),
        )
    except SessionError as exc:
        report.record("r2_dump_header", False, _r2_detail(str(exc)))

    # ---- R3 debug control (implemented chip-side; host cases only) ---------
    # The scripted debug walk a real board-in-the-loop run would perform. The
    # expectations are the contract's, but the EVIDENCE is host-side: the
    # golden vectors in the R3 package are still chip_confirmed=false.
    def r3(name, fn):
        try:
            ok, detail = fn()
        except SessionError as exc:
            ok, detail = False, str(exc)
        report.record(name, ok, _r3_detail(detail))

    def debug_status_case():
        snapshot = session.debug_status()
        return True, (
            f"state={snapshot.state_name} pc={snapshot.pc} "
            f"a=0x{snapshot.a:02X} armed={snapshot.armed} "
            f"hit={snapshot.hit}"
        )

    def debug_step_case():
        step = session.debug_step()
        return True, (
            f"one instruction retired -> pc_next={step.pc_next} "
            f"state={step.state_name} (session {session.state})"
        )

    def bp_arm_case():
        armed = session.bp_set(2)
        return True, (
            f"armed at {armed.bp_addr} flags=0x{armed.bp_flags:02X} "
            f"state={armed.state_name}"
        )

    def bp_hit_case():
        session.bp_set(2)  # arm, then step onto it
        seen = []
        for _ in range(4):
            seen.append(session.debug_step())
            if seen[-1].hit:
                break
        if not any(step.hit for step in seen):
            return False, "never reported a hit (states: " + ",".join(
                step.state_name for step in seen
            ) + ")"
        hit = next(step for step in seen if step.hit)
        return True, (
            f"stepped onto the armed address: pc_next={hit.pc_next} "
            f"state={hit.state_name} flags=0x{hit.bp_flags:02X} "
            f"(stop-before: the instruction there has NOT run)"
        )

    def bp_release_case():
        released = session.bp_clr()
        after = session.debug_status()
        return (
            True,
            (
                f"cleared: state={released.state_name}, then "
                f"{after.state_name} pc={after.pc} armed={after.armed}"
            ),
        )

    def step_while_running_case():
        # Raise the strap WITHOUT telling the session, so the session's own
        # guard does not mask the chip's refusal: the chip must answer
        # NOT_READY. This is the one case that drives the run strap directly.
        first.transport.request("start")
        try:
            session.debug_step()
        except SessionError as exc:
            return (
                f"status {P.STATUS_NOT_READY}" in str(exc),
                f"free-running core refused the step ({exc})",
            )
        finally:
            first.transport.request("stop")
        return False, "a free-running core accepted a step"

    for name, case in (
        ("r3_debug_status", debug_status_case),
        ("r3_debug_step", debug_step_case),
        ("r3_bp_set", bp_arm_case),
        ("r3_bp_hit_stop_before", bp_hit_case),
        ("r3_bp_clr_releases", bp_release_case),
        ("r3_step_while_running", step_while_running_case),
    ):
        r3(name, case)

    chip_only = (
        "IRQ_N and sticky status faults do not exist until RTL "
        "phase R1 (chip-side, under the chip-repo manager)"
    )
    if first.pe is not None and first.adapter is not None and first.bridge is not None:
        first.pe.faults |= FAULT_LOAD
        first.adapter.set_irq(True)
        irq_events = first.bridge.poll_irq()
        report.record(
            "irq",
            [event.get("event") for event in irq_events] == ["chip.irq"]
            and first.pe.faults == FAULT_LOAD,
            f"{len(irq_events)} chip.irq event(s); PE fault still "
            f"set (0x{first.pe.faults:04X})",
        )
        try:
            faulted = session.status()
        except SessionError as exc:
            report.record("fault", False, str(exc))
            return report
        session.process_events()
        report.record(
            "fault",
            faulted.faults == FAULT_LOAD and session.state == SessionState.FAULTED,
            f"faults=0x{faulted.faults:04X} state={session.state}",
        )
        try:
            faults = session.clear_fault(FAULT_LOAD)
        except SessionError as exc:
            report.record("clear_fault", False, str(exc))
            return report
        report.record(
            "clear_fault",
            faults == 0
            and session.state in (SessionState.STOPPED, SessionState.PREPARED),
            f"faults=0x{faults:04X} state={session.state}",
        )
        first.adapter.set_irq(False)
    else:
        report.skip("irq", chip_only)
        report.skip("fault", chip_only)
        report.skip("clear_fault", chip_only)

    report.skip(
        "uart",
        "no bridge op reports UART bytes; the Task 2 contract has "
        "none, so UART observation needs a bridge op (or operator "
        "scope) on the real run",
    )

    session.disconnect()
    report.record(
        "disconnect", session.state == SessionState.DISCONNECTED, f"state={session.state}"
    )

    try:
        session.connect()
    except SessionError as exc:
        report.record("reconnect", False, str(exc))
        return report
    report.record(
        "reconnect",
        session.state == SessionState.PREPARED and session.session_id == 2,
        f"fresh session id={session.session_id}, state={session.state}",
    )
    session.disconnect()
    return report


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="acceptance.py",
        description="Host controller board-in-the-loop acceptance (plan Task 7).",
    )
    parser.add_argument(
        "--fake",
        action="store_true",
        help="run against the fake SDK adapter and fake PE; never opens a serial device",
    )
    parser.add_argument(
        "--device",
        default=None,
        help=f"USB CDC device for the real run (default {DEFAULT_DEVICE})",
    )
    parser.add_argument(
        "--project",
        default=DEFAULT_PROJECT,
        help="shuttle project name to enable on the Pico",
    )
    parser.add_argument(
        "--board", default=None, help="board revision label recorded in the report"
    )
    args = parser.parse_args(argv)
    if args.fake and args.device:
        parser.error("--fake and --device are mutually exclusive")
    return args


def main(argv=None, printer=print):
    args = parse_args(argv)
    report = run_acceptance(
        fake=args.fake, device=args.device, project=args.project, board=args.board
    )
    for line in report.render().splitlines():
        printer(line)
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
