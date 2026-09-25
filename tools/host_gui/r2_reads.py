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

Manager RULINGs (2026-09-25, WORKLOG.md) settle both questions the plan left
open; the host tree now treats them as the contract:

  * **Read-range latches a sticky fault.** An out-of-range READ answers
    `RANGE` *and* latches sticky ``FAULT_RANGE`` (0x4), consistent with
    out-of-range writes; ``CLEAR_FAULT`` clears it. The model default is
    therefore ``"latch"`` (the parameter is kept only so the rejected
    ``"status-only"`` behavior stays reachable in a test).
  * **READ payload is low-word-first, ascending** — the same ascending stream
    LOAD uses, so ``READ_IMEM(a, n)`` returns words ``a, a+1, ... a+n-1`` in
    order and ``READ_DMEM(a, n)`` packs bytes ``a..a+n-1`` big-endian per
    word. Every read obligation below asserts this order explicitly.

Both rulings are contract, not evidence: they say what the chip must do when R2
lands, and are confirmed against the R2 RTL at that dispatch.
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
    # RULING: low word first, ascending - matches LOAD's stream.
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
    # RULING: an out-of-range read answers RANGE *and* latches sticky
    # FAULT_RANGE (the model default policy).
    over_imem = pe.request(P.OP_READ_IMEM, payload_words=(1023, 2)).payload[0]
    over_dmem = pe.request(P.OP_READ_DMEM, payload_words=(15, 2)).payload[0]
    latched = (pe.faults & F.FAULT_RANGE) == F.FAULT_RANGE
    return over_imem == P.STATUS_RANGE and over_dmem == P.STATUS_RANGE and latched


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
