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

if __package__ in (None, ""):      # direct script run: put the repo root on path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.host_gui.fake_pe import FAULT_LOAD
from tools.host_gui.image import ImageError, assemble_program
from tools.host_gui.session import (
    ControllerSession,
    SessionError,
    SessionState,
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
            lines.append(f"  {check.status:<4} {check.name:<{width}}  "
                         f"{check.detail}".rstrip())
        passes = sum(check.status == "PASS" for check in self.checks)
        skips = sum(check.status == "SKIP" for check in self.checks)
        lines += ["", "manifest: " + json.dumps(self.manifest, sort_keys=True)]
        lines.append(f"RESULT: {'PASS' if self.passed else 'FAIL'} "
                     f"({passes} PASS, {len(self.failures)} FAIL, {skips} SKIP)")
        return "\n".join(lines)


@dataclass
class Link:
    transport: object
    pe: object | None = None
    adapter: object | None = None
    bridge: object | None = None


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
    except TransportError as exc:      # missing pyserial
        raise TransportError(
            f"{exc} (install: pip install .[host-gui])") from exc
    except OSError as exc:
        raise TransportError(
            f"cannot open {device}: {exc} - is the Pico connected and the "
            f"desktop user in the 'dialout' group (sudo usermod -aG dialout "
            f"$USER, then re-login)?") from exc
    return Link(transport=SerialTransport(port))


def _observe_heartbeat(session, pe, *, tries=3, sleep=time.sleep):
    """A running core must move the STATUS timer. Fake mode scripts the move."""
    before = session.status().timer
    for _ in range(tries):
        if pe is not None:
            pe.timer = (pe.timer + 1) & 0xFF   # scripted running core
        current = session.status().timer
        if current != before:
            return True, f"timer {before} -> {current}"
        sleep(0.25)
    return False, f"timer stuck at {before}"


def run_acceptance(*, fake, device=None, project=DEFAULT_PROJECT, board=None,
                   repo_root=REPO_ROOT, link_factory=None):
    """Run the scripted acceptance; returns a report, never raises on FAIL."""
    report = AcceptanceReport(
        board=board or ("fake-adapter" if fake else "unknown"))
    if link_factory is None:
        if fake:
            link_factory = lambda: build_fake_link(project)
        else:
            link_factory = lambda: build_serial_link(
                device or DEFAULT_DEVICE)

    try:
        first = link_factory()
    except (TransportError, RuntimeError) as exc:
        report.record("open", False, str(exc))
        return report
    report.record("open", True,
                  "fake SDK adapter + fake PE; no serial device opened" if fake
                  else f"opened {device or DEFAULT_DEVICE}")

    try:
        hello = first.transport.request("hello")
    except TransportError as exc:
        report.record("hello", False, str(exc))
        return report
    report.record("hello",
                  hello.get("protocol_version") == 1
                  and isinstance(hello.get("pads"), dict),
                  f"v{hello.get('protocol_version')} "
                  f"clock={hello.get('clock_hz')} "
                  f"sclk_max={hello.get('sclk_hz_max')} pads={hello.get('pads')}")
    report.manifest.update({key: hello.get(key) for key in
                            ("protocol_version", "clock_hz", "sclk_hz_max",
                             "pads")})

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
    report.record("prepare", session.state == SessionState.PREPARED,
                  f"state={session.state} "
                  f"sclk<={session.negotiated_sclk_hz}")

    cap = session.negotiated_sclk_hz
    try:
        result = first.transport.request("set_sclk", {"hz": cap})
        report.record("sclk", result.get("sclk_hz") == cap,
                      f"negotiated {cap} Hz; bridge applied "
                      f"{result.get('sclk_hz')}")
    except TransportError as exc:
        report.record("sclk", False, str(exc))
    report.manifest["sclk_hz"] = cap

    try:
        image = assemble_program(Path(repo_root) / FIRMWARE, repo_root)
    except ImageError as exc:
        report.record("assemble", False, str(exc))
        return report
    report.manifest.update({"source": image.source,
                            "word_count": image.word_count,
                            "sha256": image.sha256,
                            "terminal_jump": image.terminal_jump})
    report.record("assemble", image.word_count > 0,
                  f"{image.source}: {image.word_count} words, sha256 "
                  f"{image.sha256[:16]}...")

    try:
        load = session.load(image)
    except SessionError as exc:
        report.record("load", False, str(exc))
        return report
    report.record("load",
                  load.words_written == image.word_count
                  and load.echo == image.words[-1] and load.faults == 0,
                  f"{load.words_written}/{image.word_count} words, "
                  f"echo=0x{load.echo:04X}, faults=0x{load.faults:04X}")

    try:
        words = tuple(session.read_imem(0, image.word_count))
    except SessionError as exc:
        report.record("readback", False, str(exc))
        return report
    report.record("readback", words == image.words,
                  f"{len(words)}/{image.word_count} words match the manifest")

    try:
        session.start()
        snapshot = session.status()
    except SessionError as exc:
        report.record("start", False, str(exc))
        return report
    report.record("start", bool(snapshot.run),
                  f"state={snapshot.state} run={snapshot.run}")

    heartbeat_ok, heartbeat_detail = _observe_heartbeat(session, first.pe)
    report.record("heartbeat", heartbeat_ok, heartbeat_detail)

    try:
        session.stop()
    except SessionError as exc:
        report.record("stop", False, str(exc))
        return report
    report.record("stop", session.state == SessionState.STOPPED,
                  f"state={session.state}")

    try:
        dump = session.dump_core()
    except SessionError as exc:
        report.record("dump", False, str(exc))
        return report
    report.record("dump", dump.words_written == image.word_count,
                  f"registers captured, words_written={dump.words_written}")

    chip_only = ("IRQ_N and sticky status faults do not exist until RTL "
                 "phase R1 (chip-side, under the chip-repo manager)")
    if first.pe is not None and first.adapter is not None \
            and first.bridge is not None:
        first.pe.faults |= FAULT_LOAD
        first.adapter.set_irq(True)
        irq_events = first.bridge.poll_irq()
        report.record("irq",
                      [event.get("event") for event in irq_events]
                      == ["chip.irq"] and first.pe.faults == FAULT_LOAD,
                      f"{len(irq_events)} chip.irq event(s); PE fault still "
                      f"set (0x{first.pe.faults:04X})")
        try:
            faulted = session.status()
        except SessionError as exc:
            report.record("fault", False, str(exc))
            return report
        session.process_events()
        report.record("fault",
                      faulted.faults == FAULT_LOAD
                      and session.state == SessionState.FAULTED,
                      f"faults=0x{faulted.faults:04X} state={session.state}")
        try:
            faults = session.clear_fault(FAULT_LOAD)
        except SessionError as exc:
            report.record("clear_fault", False, str(exc))
            return report
        report.record("clear_fault",
                      faults == 0 and session.state in
                      (SessionState.STOPPED, SessionState.PREPARED),
                      f"faults=0x{faults:04X} state={session.state}")
        first.adapter.set_irq(False)
    else:
        report.skip("irq", chip_only)
        report.skip("fault", chip_only)
        report.skip("clear_fault", chip_only)

    report.skip("uart",
                "no bridge op reports UART bytes; the Task 2 contract has "
                "none, so UART observation needs a bridge op (or operator "
                "scope) on the real run")

    session.disconnect()
    report.record("disconnect", session.state == SessionState.DISCONNECTED,
                  f"state={session.state}")

    try:
        session.connect()
    except SessionError as exc:
        report.record("reconnect", False, str(exc))
        return report
    report.record("reconnect",
                  session.state == SessionState.PREPARED
                  and session.session_id == 2,
                  f"fresh session id={session.session_id}, "
                  f"state={session.state}")
    session.disconnect()
    return report


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="acceptance.py",
        description="Host controller board-in-the-loop acceptance (plan Task 7).")
    parser.add_argument("--fake", action="store_true",
                        help="run against the fake SDK adapter and fake PE; "
                             "never opens a serial device")
    parser.add_argument("--device", default=None,
                        help=f"USB CDC device for the real run "
                             f"(default {DEFAULT_DEVICE})")
    parser.add_argument("--project", default=DEFAULT_PROJECT,
                        help="shuttle project name to enable on the Pico")
    parser.add_argument("--board", default=None,
                        help="board revision label recorded in the report")
    args = parser.parse_args(argv)
    if args.fake and args.device:
        parser.error("--fake and --device are mutually exclusive")
    return args


def main(argv=None, printer=print):
    args = parse_args(argv)
    report = run_acceptance(fake=args.fake, device=args.device,
                            project=args.project, board=args.board)
    for line in report.render().splitlines():
        printer(line)
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
