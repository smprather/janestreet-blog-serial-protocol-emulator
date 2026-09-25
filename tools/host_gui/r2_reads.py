"""R2 read-path obligations: the single source of truth for the host side.

R2 is chip-side work (plan Tasks 3-5): explicit full-width CPU debug ports, a
`pe_imem` host read port, a SoC read mux with no-wrap range rejection, and
chip-side read-while-running rejection. **None of it is on the chip yet**, so
every obligation below is `chip_confirmed=False` and every probe runs against
the host's `FakePE` model. When the RTL lands, the same probes run against the
real chip (via the acceptance runner) and the flag flips with evidence.

This module exists so the host model, the acceptance runner and (later) the
chip TBs cannot drift on *what the read path owes*. It is a contract, not
evidence: a green probe here is host-side evidence about a model, never about
silicon. Read the result doc next to it
(`reviews/2026-09-25/HOST-GUI-R2-PREP.md`).

Two contract questions are left to the chip side (logged as WORKLOG QUESTIONs)
and are therefore *parameterized* rather than silently decided here:

  * does an out-of-range **read** latch a sticky fault, or answer `RANGE` with
    no fault? The plan's read step (line 334) requires `RANGE` and "do not
    wrap" but is silent on the sticky fault; the model exposes both policies
    via ``FakePE(read_fault_policy=...)`` (``"latch"`` is the historical model
    default, kept so existing tests do not change).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from tools.host_gui import fake_pe as F
from tools.host_gui import protocol as P

NOT_CHIP_CONFIRMED = (
    "These probes run against the host FakePE model. They are NOT chip-"
    "confirmed: the R2 read path is chip-side work under the manager's "
    "dispatch and is unverified until it lands and passes the same probes "
    "on hardware."
)


@dataclass(frozen=True)
class Obligation:
    """One R2 read-path obligation and a probe that checks it on a model."""

    name: str
    description: str
    probe: Callable[[F.FakePE], bool]
    chip_confirmed: bool = False


def _read_imem_bounded(pe: F.FakePE) -> bool:
    pe.request(P.OP_LOAD, payload_words=(0x0041, 0x1001, 0x4002))
    return pe.request(P.OP_READ_IMEM,
                      payload_words=(1, 2)).payload == (P.STATUS_OK,
                                                        0x1001, 0x4002)


def _read_dmem_bounded(pe: F.FakePE) -> bool:
    pe.dmem[0:2] = b"\x0a\x0b"
    return pe.request(P.OP_READ_DMEM,
                      payload_words=(0, 2)).payload == (P.STATUS_OK, 0x0A0B)


def _dump_core_header(pe: F.FakePE) -> bool:
    pe.request(P.OP_LOAD, payload_words=(0x0041,))
    pe.pc, pe.a, pe.x, pe.y = 0x123, 0x456, 0x789, 0xABC
    return (pe.request(P.OP_DUMP_CORE).payload
            == pe.request(P.OP_STATUS).payload)


def _read_cpu_non_halting(pe: F.FakePE) -> bool:
    pe.run = True
    try:
        return pe.request(P.OP_READ_CPU).payload[0] == P.STATUS_OK
    finally:
        pe.run = False


def _read_while_running_rejected(pe: F.FakePE) -> bool:
    pe.run = True
    try:
        return all(
            pe.request(opcode, payload_words=payload).payload[0]
            == P.STATUS_NOT_READY
            for opcode, payload in ((P.OP_READ_IMEM, (0, 1)),
                                    (P.OP_READ_DMEM, (0, 1)),
                                    (P.OP_DUMP_CORE, ())))
    finally:
        pe.run = False


def _range_never_wraps(pe: F.FakePE) -> bool:
    return (pe.request(P.OP_READ_IMEM,
                      payload_words=(1023, 2)).payload[0] == P.STATUS_RANGE
            and pe.request(P.OP_READ_DMEM,
                           payload_words=(15, 2)).payload[0] == P.STATUS_RANGE)


def _full_width_debug_regs(pe: F.FakePE) -> bool:
    pe.pc, pe.a, pe.x, pe.y, pe.insn = (0x3FF, 0x1FFF, 0x2AA, 0x155, 0xFFFF)
    return pe.request(P.OP_READ_CPU).payload[1:6] == (0x3FF, 0x1FFF, 0x2AA,
                                                     0x155, 0xFFFF)


OBLIGATIONS: tuple[Obligation, ...] = (
    Obligation(
        "read_imem_bounded",
        "READ_IMEM returns the requested address..address+count words.",
        _read_imem_bounded),
    Obligation(
        "read_dmem_bounded",
        "READ_DMEM returns the requested byte range packed big-endian.",
        _read_dmem_bounded),
    Obligation(
        "dump_core_header",
        "DUMP_CORE while stopped equals the STATUS register header.",
        _dump_core_header),
    Obligation(
        "read_cpu_non_halting",
        "READ_CPU answers while run=1 (the only non-halting read).",
        _read_cpu_non_halting),
    Obligation(
        "read_while_running_rejected",
        "READ_IMEM/READ_DMEM/DUMP_CORE answer NOT_READY while run=1.",
        _read_while_running_rejected),
    Obligation(
        "range_never_wraps",
        "address+count past the memory end is RANGE, never a wrapped read.",
        _range_never_wraps),
    Obligation(
        "full_width_debug_regs",
        "READ_CPU exposes full-width PC/A/X/Y/insn (R2 removes the 8-bit "
        "dbg_pc/dbg_a truncation).",
        _full_width_debug_regs),
)


def by_name() -> dict[str, Obligation]:
    return {obligation.name: obligation for obligation in OBLIGATIONS}


def run_all_probes(pe: F.FakePE | None = None) -> dict[str, bool]:
    """Run every probe against a fresh (or supplied) model; name -> result."""
    model = pe if pe is not None else F.FakePE()
    return {obligation.name: bool(obligation.probe(model))
            for obligation in OBLIGATIONS}


def unconfirmed_names() -> list[str]:
    return [o.name for o in OBLIGATIONS if not o.chip_confirmed]
