#!/usr/bin/env python3
"""Run firmware/i2c_xfer.pe against an independent I2C slave model and check
every defined outcome: the happy transaction, the three unexpected-NACK aborts,
arbitration loss, and a clock-stretching slave.

WHY THE EMULATOR DOES THIS AND THE RTL TB DOES IT AGAIN. The emulator is the
fast loop (seconds versus a minute for iverilog) and it is where the firmware's
logic is debugged. The RTL TB is the independent acceptance test on real
hardware. They must agree byte-for-byte, and disagreeing once is a signal, not
an inconvenience ([[STATUS]] gotcha 11).

WHAT "INDEPENDENT" MEANS HERE. The slave model decodes the wire -- START/STOP,
bits on SCL rises, the 9th clock as ACK -- and is never told what the firmware
intends. The checker asserts on the slave's records AND on the firmware's own
dmem observables, so a firmware bug and a model bug have to coincide to pass.

dmem contract under test:
  dmem[0..2] per-byte ACK samples    dmem[3] the read byte
  dmem[4] NACK sent                  dmem[5] 0xA5 success / 0x55 aborted
  dmem[6] outcome: 0 clean, 1 arbitration, 2 write-addr NACK, 3 data NACK,
          4 read-addr NACK           dmem[7] arbitration-loss count

Exit 0 if every case passes in every swept phase; 1 otherwise.
"""
import argparse
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "tools" / "fw"))
sys.path.insert(0, str(REPO / "tools" / "checks"))
import peemu  # noqa: E402
import i2c_timing  # noqa: E402  (its FLOORS and classify, one source of truth)

ADDR = 0x50
WRITE_ADDR = (ADDR << 1) | 0     # 0xA0
READ_ADDR = (ADDR << 1) | 1      # 0xA1
WRITE_DATA = 0xA5
READ_DATA = 0x5A
SUCCESS, ABORTED = 0xA5, 0x55

MAX_CYCLES = 200_000

# name, slave kwargs, expected dict
CASES = [
    ("clean", {}, dict(outcome=0, done=SUCCESS, addrs=[WRITE_ADDR, READ_ADDR],
                       writes=[WRITE_DATA], acks=[1], starts=2, stops=1,
                       read_byte=READ_DATA)),
    ("write-addr NACK", dict(nack_address=True),
     dict(outcome=2, done=ABORTED, addrs=[WRITE_ADDR], writes=[], acks=[],
          starts=1, stops=1, read_byte=0x00)),
    ("data NACK", dict(nack_data=True),
     dict(outcome=3, done=ABORTED, addrs=[WRITE_ADDR], writes=[WRITE_DATA],
          acks=[], starts=1, stops=1, read_byte=0x00)),
    ("read-addr NACK", dict(nack_read_address=True),
     dict(outcome=4, done=ABORTED, addrs=[WRITE_ADDR, READ_ADDR],
          writes=[WRITE_DATA], acks=[], starts=2, stops=1, read_byte=0x00)),
    ("stretch", dict(stretch_fall=3, stretch_cycles=600),
     dict(outcome=0, done=SUCCESS, addrs=[WRITE_ADDR, READ_ADDR],
          writes=[WRITE_DATA], acks=[1], starts=2, stops=1,
          read_byte=READ_DATA, min_max_low_us=8.0)),
]


def assemble() -> list[int]:
    out = pathlib.Path("/tmp/i2c_xfer_check.hex")
    r = subprocess.run(
        [sys.executable, str(REPO / "tools" / "fw" / "peasm.py"),
         str(REPO / "firmware" / "i2c_xfer.pe"), "-o", str(out)],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"assemble failed:\n{r.stdout}{r.stderr}")
    return [int(tok, 16) for tok in out.read_text().split()]


def run_phase(words: list[int], phase: int, **slave_kwargs) -> dict:
    soc = peemu.Soc(words)
    soc.run = True
    soc.imem_rdata = soc.imem[0]
    soc.i2c_cnt = phase
    slave = peemu.I2CSlaveModel(address=ADDR, read_byte=READ_DATA, **slave_kwargs)

    transitions = []
    prev = ((soc.wire_bits() >> 5) & 1, (soc.wire_bits() >> 4) & 1)
    initial = prev
    for _ in range(MAX_CYCLES):
        soc.step()
        slave.poll(soc)
        w = soc.wire_bits()
        cur = ((w >> 5) & 1, (w >> 4) & 1)
        if cur != prev:
            transitions.append((soc.cycles, prev, cur))
        prev = cur
        if soc.dmem[5] in (SUCCESS, ABORTED):   # terminal, pass or abort
            break

    cls = i2c_timing.classify(transitions, initial)
    lows = cls["lows"]
    return {
        "transitions": transitions, "classify": cls,
        "done": soc.dmem[5] in (SUCCESS, ABORTED),
        "dmem": list(soc.dmem),
        "wire_final": soc.wire_bits() & (0x30),
        "address_bytes": list(slave.address_bytes),
        "writes": list(slave.writes), "acks": list(slave.acks),
        "starts": slave.starts, "stops": slave.stops,
        "max_low_us": max(lows) if lows else 0.0,
        "cycles": soc.cycles,
    }


def run_arb_phase(words: list[int], phase: int) -> dict:
    """Arbitration loss against TRANSIENT CONTENTION.

    A second device pulls SDA low through the master's first transmitted 1 and
    releases it on a countdown. The master must release both lines, record
    outcome 1, park (flag 0x55) and NOT issue a STOP. The source's own release
    under SCL high is a wire STOP, and the source's pull is a wire START, so no
    wire-condition or timing-floor assertions are made here -- the firmware's
    own dmem and drive state are the contract. This does not model a winner's
    continuing transaction or its STOP.
    """
    soc = peemu.Soc(words)
    soc.run = True
    soc.imem_rdata = soc.imem[0]
    soc.i2c_cnt = phase
    slave = peemu.I2CSlaveModel(address=ADDR, read_byte=READ_DATA)

    prev_sda, prev_scl = 1, 1
    armed = active = False
    elapsed = 0
    for _ in range(MAX_CYCLES):
        soc.step()
        slave.poll(soc)
        w = soc.wire_bits()
        sda, scl = (w >> 4) & 1, (w >> 5) & 1
        if not armed and prev_scl and scl and prev_sda and not sda:
            armed = True                       # the master's START
        elif armed and not active and not prev_scl and scl:
            active = True                      # the first data-1 high phase
            elapsed = 0
            soc.i2c_pull_low |= 0x10           # the "winner" pulls SDA low
        if active:
            elapsed += 1
            if elapsed >= 900:                 # 15 us, well past the sample
                soc.i2c_pull_low &= ~0x10
                active = False
            else:
                # slave.poll() reassigns the whole pull mask every cycle, so
                # the contention pull must be re-asserted each time
                soc.i2c_pull_low |= 0x10
        prev_sda, prev_scl = sda, scl
        if soc.dmem[5] in (SUCCESS, ABORTED):
            break
    return {
        "done": soc.dmem[5] in (SUCCESS, ABORTED),
        "dmem": list(soc.dmem),
        "master_oe": soc.pad_oe() & 0x30,
        "slave_addrs": list(slave.address_bytes),
        "slave_writes": list(slave.writes),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--phases", type=int, default=60,
                    help="tick phases to sweep (the residual is phase-dependent)")
    args = ap.parse_args()

    words = assemble()
    print(f"firmware/i2c_xfer.pe: {len(words)} words, "
          f"{args.phases} phases, {len(CASES)} cases\n")

    ok = True
    for name, kwargs, want in CASES:
        runs = [run_phase(words, p, **kwargs) for p in range(args.phases)]
        r0 = runs[0]
        case_ok = True

        def ck(cond, msg):
            nonlocal case_ok, ok
            if not cond:
                case_ok = False
                ok = False
                print(f"  FAIL {name}: {msg}")

        # terminal state
        ck(all(r["done"] for r in runs), "firmware never reached a terminal flag")
        ck(r0["dmem"][5] == want["done"],
           f"dmem[5]={r0['dmem'][5]:02x} want {want['done']:02x}")
        ck(r0["dmem"][6] == want["outcome"],
           f"dmem[6]={r0['dmem'][6]:02x} want {want['outcome']:02x}")

        # independent slave decode
        ck(r0["address_bytes"] == want["addrs"],
           f"address bytes {r0['address_bytes']} want {want['addrs']}")
        ck(r0["writes"] == want["writes"],
           f"writes {r0['writes']} want {want['writes']}")
        ck(r0["acks"] == want["acks"],
           f"read ACK bits {r0['acks']} want {want['acks']}")
        ck(r0["starts"] == want["starts"],
           f"STARTs {r0['starts']} want {want['starts']}")
        ck(r0["stops"] == want["stops"],
           f"STOPs {r0['stops']} want {want['stops']}")
        ck(r0["dmem"][3] == want["read_byte"],
           f"read byte {r0['dmem'][3]:02x} want {want['read_byte']:02x}")

        # an aborted transaction must leave the bus released
        ck(r0["wire_final"] == 0x30,
           f"bus not released at the end (wire bits {r0['wire_final']:02x})")

        # timing floors, on the cells that actually ran
        worst_low = min((l for r in runs for l in r["classify"]["lows"]),
                        default=0.0)
        worst_high = min((h for r in runs for h in r["classify"]["highs"]),
                         default=0.0)
        ck(worst_low >= i2c_timing.FLOORS["tLOW"],
           f"tLOW {worst_low:.3f} < {i2c_timing.FLOORS['tLOW']}")
        ck(worst_high >= i2c_timing.FLOORS["tHIGH"],
           f"tHIGH {worst_high:.3f} < {i2c_timing.FLOORS['tHIGH']}")

        # grammar: the expected condition sequence, and no stray SDA edge under
        # SCL high. Stretch adds low time, never a condition.
        conds = [n for r in runs for _, n in r["classify"]["conds"]]
        per_run = [tuple(n for _, n in r["classify"]["conds"]) for r in runs]
        if want["starts"] == 2:
            want_conds = ("START", "START", "STOP")
        else:
            want_conds = ("START", "STOP")
        ck(all(pc == want_conds for pc in per_run),
           f"condition sequence {sorted(set(per_run))} want {want_conds}")
        ck(len(conds) == len(want_conds) * len(runs),
           f"parsed {len(conds)} conditions, want {len(want_conds)*len(runs)}")
        for r in runs:
            for cyc, s0, s1, d0, d1 in r["classify"]["data_edges"]:
                if s0 == 1 or s1 == 1:
                    ck(False, f"SDA moved under SCL high at cycle {cyc}")

        # the stretch case must show the slave actually holding SCL low and the
        # master waiting for it (not merely a longer constant)
        if "min_max_low_us" in want:
            ck(r0["max_low_us"] >= want["min_max_low_us"],
               f"max SCL low {r0['max_low_us']:.3f} us < "
               f"{want['min_max_low_us']} (the master did not wait?)")

        # every phase must agree on the outcome and the transaction
        keys = ("address_bytes", "writes", "acks", "starts", "stops")
        varying = [i for i, r in enumerate(runs)
                   if tuple(r[k] for k in keys) != tuple(r0[k] for k in keys)
                   or r["dmem"][5] != r0["dmem"][5] or r["dmem"][6] != r0["dmem"][6]]
        ck(not varying, f"result varies across phases: {varying[:8]}")

        print(f"  {'OK  ' if case_ok else 'FAIL'} {name:<16} "
              f"outcome={r0['dmem'][6]}, flag={r0['dmem'][5]:02x}, "
              f"starts/stops={r0['starts']}/{r0['stops']}, "
              f"max tLOW={r0['max_low_us']:.2f} us, "
              f"min tLOW/tHIGH={worst_low:.2f}/{worst_high:.2f} us")

    # ================= arbitration loss (transient contention) =============
    # Kept separate from CASES: the contention source's pull and release are
    # wire-visible conditions a real slave would misread, so only the
    # firmware's outcome and drive state are asserted. See run_arb_phase.
    print("\narbitration loss (transient contention):")
    arb = [run_arb_phase(words, p) for p in range(args.phases)]
    a0 = arb[0]
    arb_ok = True

    def ack(cond, msg):
        nonlocal ok, arb_ok
        if not cond:
            ok = False
            arb_ok = False
            print(f"  FAIL arbitration: {msg}")

    ack(all(r["done"] for r in arb), "never reached a terminal flag")
    ack(a0["dmem"][6] == 0x01, f"outcome={a0['dmem'][6]:02x} want 01")
    ack(a0["dmem"][5] == ABORTED, f"flag={a0['dmem'][5]:02x} want 55")
    ack(a0["dmem"][7] > 0, "loss not counted")
    ack(a0["master_oe"] == 0,
        f"master still driving after the abort (oe={a0['master_oe']:02x})")
    ack(a0["slave_addrs"] == [] and a0["slave_writes"] == [],
        "a complete address/data byte was recorded after the abort")
    varying = [i for i, r in enumerate(arb)
               if (r["dmem"][5], r["dmem"][6]) != (a0["dmem"][5], a0["dmem"][6])]
    ack(not varying, f"outcome varies across phases: {varying[:8]}")
    print(f"  {'OK  ' if arb_ok else 'FAIL'} arbitration     "
          f"outcome={a0['dmem'][6]}, flag={a0['dmem'][5]:02x}, "
          f"loss={a0['dmem'][7]}")

    print(f"\nRESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
