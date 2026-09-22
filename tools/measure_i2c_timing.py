#!/usr/bin/env python3
"""Measure I2C pin timing from the firmware's wire trace, and check the bus
grammar, against the standard-mode (100 kHz) table.

WHY THIS IS A SCRIPT AND NOT A ONE-OFF. The timing claim in firmware/i2c_pins.pe
("tLOW >= 4.7 us, tHIGH >= 4.0 us, period >= 10 us, worst case, across every
tick phase") is only as good as the search over phases. A single run at one
phase proves nothing about a free-running counter, and an eyeballed trace
proves less. So this runs ALL 60 phases and reports the WORST case of each
interval -- which is the number the spec is compared against.

WHY IT IS MORE THAN A TIMING CHECK. Timing alone cannot see a spurious bus
condition. An early draft of this firmware emitted TWO STARTs (it drove SDA low
while SCL was high on the way into the STOP) and every interval still cleared
its floor, so a timing-only gate passed on a broken bus. A spurious START is
exactly the class of bug that reaches tapeout, because the waveform "looks like
I2C". So this also asserts the GRAMMAR: exactly one START, then the bit cell,
then exactly one STOP.

Recording TRANSITIONS (from-state -> to-state) rather than bare levels is what
makes both checks correct. A START is a transition whose from-state has SCL
high and SDA high; a level list loses the from-state of the very first edge,
which is where the START usually is.

Exit code 0 if the intervals and the grammar both pass, across all phases.
"""
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
import peemu  # noqa: E402

# I2C standard mode, 100 kHz. Floors are minima; the 10 us period is the
# 100 kHz ceiling expressed as a minimum period.
FLOORS = {
    "tLOW":   4.7,
    "tHIGH":  4.0,
    "period": 10.0,
}
SDA_BIT, SCL_BIT = 4, 5


def assemble(pe_path: pathlib.Path, out: pathlib.Path) -> list[int]:
    r = subprocess.run(
        [sys.executable, str(REPO / "tools" / "peasm.py"), str(pe_path),
         "-o", str(out)],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"assemble failed:\n{r.stdout}{r.stderr}")
    return [int(tok, 16) for tok in out.read_text().split()]


def run_phase(words: list[int], phase: int) -> dict:
    """Run one tick phase; return transitions, dmem observables, and a verdict."""
    soc = peemu.Soc(words)
    soc.run = True
    soc.pin_in = 1                       # RX idle high
    soc.imem_rdata = soc.imem[0]         # the registered ROM read the harness sets
    soc.i2c_cnt = phase                  # the phase under test

    def bus() -> tuple[int, int]:
        w = soc.wire_bits()
        return (w >> SCL_BIT) & 1, (w >> SDA_BIT) & 1

    transitions = []                     # (cycle, from_state, to_state)
    prev = bus()
    initial = prev
    for _ in range(8000):
        soc.step()
        cur = bus()
        if cur != prev:
            transitions.append((soc.cycles, prev, cur))
        prev = cur
        # dmem[3] is set one instruction before dmem[4]; wait for both so the
        # final pin state is included.
        if soc.dmem[3] == 1 and soc.dmem[4] != 0:
            break

    return {
        "transitions": transitions,
        "initial": initial,
        "dmem0": soc.dmem[0], "dmem1": soc.dmem[1], "dmem2": soc.dmem[2],
        "dmem3": soc.dmem[3], "dmem4": soc.dmem[4],
    }


def classify(transitions: list, initial: tuple[int, int]) -> dict:
    """Split transitions into bus conditions and SCL edges.

    I2C defines exactly two conditions, and both are SDA moving while SCL is
    HIGH:
      START : SDA falls with SCL high   (1,1) -> (1,0)
      STOP  : SDA rises with SCL high   (1,0) -> (1,1)
    Every other SDA move must happen with SCL LOW -- that is the rule that makes
    data and conditions distinguishable, and violating it is what produced the
    spurious second START.
    """
    conds, data_edges = [], []
    for cyc, (s0, d0), (s1, d1) in transitions:
        if d0 == d1:
            continue                      # SCL moved; not a data change
        if s0 == 1 and s1 == 1:
            conds.append((cyc, "START" if (d0, d1) == (1, 0) else "STOP"))
        else:
            data_edges.append((cyc, s0, s1, d0, d1))

    # tLOW / tHIGH: walk the SCL edges in time order. A high period is bounded
    # by the rise and the following fall; a low period by a fall and the
    # following rise.
    scl_edges = [(cyc, s1) for cyc, (s0, _), (s1, _) in transitions if s0 != s1]
    lows, highs = [], []
    for (c1, v1), (c2, v2) in zip(scl_edges, scl_edges[1:]):
        if v1 == 0 and v2 == 1:
            lows.append((c2 - c1) / 60.0)
        elif v1 == 1 and v2 == 0:
            highs.append((c2 - c1) / 60.0)

    return {"conds": conds, "data_edges": data_edges,
            "lows": lows, "highs": highs}


def main() -> int:
    words = assemble(REPO / "firmware" / "i2c_pins.pe",
                     pathlib.Path("/tmp/i2c_pins_measured.hex"))

    runs = [run_phase(words, p) for p in range(60)]
    cls = [classify(r["transitions"], r["initial"]) for r in runs]

    all_lows = [x for c in cls for x in c["lows"]]
    all_highs = [x for c in cls for x in c["highs"]]
    # A period is a high period plus the low period that follows it.
    periods = [(h + l) for c in cls
               for h, l in zip(c["highs"], c["lows"][1:])]

    print(f"I2C pin timing, worst case over all {len(runs)} tick phases")
    print(f"  firmware: firmware/i2c_pins.pe  ({len(words)} words)")
    print()

    ok = True
    worst = {"tLOW": min(all_lows), "tHIGH": min(all_highs),
             "period": min(periods)}
    for name, floor in FLOORS.items():
        got = worst[name]
        margin = got - floor
        verdict = "OK" if margin >= 0 else "FAIL"
        ok &= margin >= 0
        print(f"  {name:<7} {got:7.3f} us   floor {floor:5.2f}   "
              f"margin {margin:+6.3f}  {verdict}")
    print()
    print(f"  period range      : {min(periods):.3f} .. {max(periods):.3f} us")
    print(f"  => bus rate       : {1000.0/max(periods):.2f} .. "
          f"{1000.0/min(periods):.2f} kHz   (standard mode: <= 100 kHz)")

    print()
    print("  dmem observables across phases (must be CONSTANT):")
    for key, name in (("dmem0", "SDA sampled while released"),
                      ("dmem1", "arbitration loss"),
                      ("dmem2", "SCL read back after release"),
                      ("dmem3", "pairs completed"),
                      ("dmem4", "last driven byte")):
        vals = sorted({r[key] for r in runs})
        ok &= len(vals) == 1
        shown = [f"0x{v:02X}" for v in vals] if len(vals) <= 4 else f"{len(vals)} values"
        print(f"    {'STABLE ' if len(vals) == 1 else 'VARIES '}{name:<28} {shown}")
    print("  (dmem[0] is the arbitration sample with the SDA mask applied, so")
    print("   0x10 = line still HIGH, no contention; 0x00 = another master won.)")

    # ---- grammar, across every phase ---------------------------------------
    print()
    print("  bus grammar (exactly one START, then the bit cell, then one STOP):")
    grammar_ok = True
    for p, c in enumerate(cls):
        names = [n for _, n in c["conds"]]
        if names != ["START", "STOP"]:
            print(f"    phase {p:>2}: conditions {names} -- expected ['START','STOP']")
            grammar_ok = False
        for cyc, s0, s1, d0, d1 in c["data_edges"]:
            # s0/s1 are the SCL level before and after this SDA move. Data may
            # only change while SCL is low, i.e. both ends low.
            if s0 == 1 or s1 == 1:
                print(f"    phase {p:>2}: SDA moved with SCL high at cycle {cyc} "
                      f"(SCL {s0}->{s1}, SDA {d0}->{d1})")
                grammar_ok = False
    if grammar_ok:
        print(f"    all {len(runs)} phases: [START, bit cell, STOP] with no stray edges")
    else:
        print("    a spurious condition or an SDA move under SCL-high was found")
    ok &= grammar_ok

    # ---- non-vacuity: the grammar check must be able to fail ----------------
    # Asserted structurally here rather than trusting the code path: if no
    # conditions were parsed at all, the loop above would pass by vacuity.
    n_conds = sum(len(c["conds"]) for c in cls)
    if n_conds != 2 * len(cls):
        print(f"    VACUOUS CHECK: parsed {n_conds} conditions across "
              f"{len(cls)} runs, expected {2 * len(cls)}")
        ok = False

    print()
    print(f"  RESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
