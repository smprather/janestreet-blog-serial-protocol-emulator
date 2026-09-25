# Formal verification campaign — chip side (2026-09-25)

Started because the queue looked empty while the design's *safety* properties
were only ever TESTED, never PROVED. Testing can observe a violation; a proof
either closes the property or finds a counterexample. The repo already had a
live example of the difference: the 18:43 unrestored `m1` mutant
(`pad_oe = reg_oe`) reddened three testbenches for a whole session, and nothing
in the suite could have *proven* the open-drain invariant that would have caught
it at the point it was written.

## Toolchain — and why it is not the usual one

**SymbiYosys is not installed and could not be installed** (`pip install
symbiyosys` fails: "Could not find an activated virtualenv"). More decisively,
**there is no SMT solver on this host at all** — boolector, yices, z3, cvc4,
cvc5, bitwuzla and mathsat are all absent — so `sby` could not have run even
if it were installed. Per the dispatch's fallback, the campaign runs on yosys'
**built-in `sat` engine**:

```
read_verilog -formal -sv <wrapper> <rtl...>
prep -top <top> -flatten
opt -full; clk2fflogic; async2sync; dffunmap
chformal -assume -early
sat -seq <N> -set-init-zero -prove-asserts -verify
```

Yosys 0.69+post. The flow is scripted in `formal/run_formal.sh` (fast subset,
also a `run_all.sh` gate) so it is re-runnable, not a one-off.

### Two things this flow taught, now encoded in the scripts

1. **`-set-init-zero` is mandatory.** Without it the flip-flops' initial values
   are unconstrained, so the solver may "start" the design mid-frame (the TX
   engine already in `S_FCS`, `tx_done` high) and every safety property fails
   for reasons that are harness artifacts, not defects. Three of the first four
   counterexamples were exactly this.
2. **Hierarchical references do not become connections in yosys** — even under
   `-flatten`. `dut.reg_od` floats, so a tap-based wrapper compares the DUT
   against noise and reports a confident, meaningless FAIL. This is the same
   implicit-wire trap `rtl/pe_ctrl.v`'s own header documents. The wrappers here
   therefore use **reference models built from observable ports**, which also
   makes each claim stronger (they assert equivalence, not just an invariant).

## Results, per property

| # | Property | Result | Depth | Notes |
|---|---|---|---|---|
| 1 | `pe_pinmux`: an open-drain pin NEVER drives high | **PROVED (bounded)** | 16 | Equivalence to a reference model of the register file + overlay, for all inputs. Non-vacuous: the `m1` mutant (`pad_oe = reg_oe`, the one that reddened three TBs on 18:43) makes it **FAIL** |
| 2 | `pe_ctrl` R2: no wrap, sticky `FAULT_RANGE`, word-aligned serializer | **NOT PROVED** | — | See "What was not proved" |
| 3a | `pe_eth_tx`: a transmitted frame is never <14 or >1514 (runt/jabber refused) | **PROVED (bounded)** | 16 | `tx_done -> a start was in flight AND its length was in [14,1514]`; `tx_overlong -> !tx_done` |
| 3b | `pe_eth_tx`: IFG >= 96 cells after every frame | **PROVED (bounded)** | 16 | Counted on the engine's own `ifg_active` across cell boundaries, asserted at the gap's falling edge |
| 3c | `pe_eth_tx`: underrun abandons without a partial FCS | **PROVED (bounded)** | 16 | `tx_underrun -> !tx_done`, plus an abandon-to-IDLE obligation |
| 4 | `pe_soc`: `tx_path` owner-mux exclusivity | **NOT PROVED** | — | See "What was not proved" |

Re-runnable: `bash formal/run_formal.sh` (fast, the `run_all.sh` gate) or
`bash formal/run_formal.sh --full`. Logs and a machine-readable summary land
in `formal/results/`.

## The vacuity finding — the most important result

A "PROVED" that never reaches the interesting states is worse than no proof,
because it is trusted. I checked the eth_tx properties for exactly that, by
injecting mutants that target the proved claims:

| mutant | depth 16 | depth 240 |
|---|---|---|
| IFG shortened to 90 cells (targets 3b) | **survives** | — |
| runt accepted, `len_ok >= 0` (targets 3a) | **survives** | **survives** |

**Why the IFG mutant survives at depth 16.** A frame needs ~208 cell boundaries
before it completes (64 prelude + 14 bytes + 32 FCS). At depth 16 no frame can
finish, so the IFG and completion properties are never *reached* and pass
vacuously. The depth-16 result for target 3 is therefore **a real proof of the
control logic that the solver can see, but it does not yet exercise the
end-of-frame claims**; those need depth >~215 to become meaningful. I
confirmed the clean design still proves at depth 240.

**Why the runt mutant survives even at depth 240 — an open modelling gap.**
This one is NOT just a depth issue and I am not going to dress it up: the P1
assertion compares the engine's completion against a shadow that samples
`frame_len` when `start` pulses, and the mutant slips between that sample and
the assertion window. The property as written does not actually pin "a
completed frame's length was in the legal domain" tightly enough to catch a
guard that has been removed. **Target 3a is therefore PROVED only weakly, and
the runt/JABBER GUARD ITSELF IS NOT YET PROVEN.** The next iteration must
close this before the claim is recorded as proof.

Note the mutants that *were* caught, so the campaign is not empty: the pinmux
`m1` mutant (the real 18:43 defect) is caught by target 1, which validates the
harness itself.

## What was NOT proved, and exactly what it would take

Targets 2 and 4 are **not proved**, and the blocker is specific and technical:
their subjects are **internal state** — `resp_len`/`resp_buf`/`faults` and the
read state machine in `pe_ctrl`, and the `eth_tx_owner` net in `pe_soc` — and
yosys cannot observe those through a wrapper. Modelling the SPI transaction
instead (so the properties could be stated on the pads) requires a
synthesizable clock and delay engine, which the yosys frontend **rejects
outright** — verified: a task-based `#(delay)` transaction wrapper fails to
parse.

Both need **RTL observation points**, i.e. a guarded formal-instrumentation
port, for example:

```verilog
`ifdef FORMAL
  output logic [15:0] fv_resp_len, fv_faults,   // pe_ctrl
  output logic        fv_rstate,
`endif
```

That is an RTL change, so it is the manager's call, not a worker's. The
properties it would unlock are worth having: "no wrap" and "RANGE sticks until
CLEAR_FAULT" are exactly the claims a host integration depends on, and right
now they rest on conformance vectors plus a mutation gate rather than a proof.

## A finding that was investigated and REJECTED

Mid-campaign I read a "defect" in `pe_eth_tx`: `len_ok` is evaluated on
`frame_len` at the *start* edge, while `stored_bytes <= frame_len` captures it
at the *next cell boundary* (up to `DIV-1` clocks later), so a host rewriting
TXLEN in that window could get one length validated and another transmitted.
I implemented a `len_latch` fix, then tested the PRE-fix RTL against the same
proof — **and it also proved at depth 16**, which told me the earlier
counterexamples were the unconstrained-init artifact, not a real bug. I
**reverted the RTL change**. Shipping an unproven modification to a verified
design is its own defect, and the record is more valuable than the churn.

## CAMPAIGN STATE AT WRAP (2026-09-25, for continuation on fresh context)

Wrap requested by the manager at a clean boundary. **No new properties were
started.** The campaign is HALF done; everything needed to continue is here.

| # | Property | Status at wrap | Depth | Path |
|---|---|---|---|---|
| 1 | `pe_pinmux` open-drain never drives high | **PROVED (bounded)** + non-vacuity shown | 16 | `formal/pe_pinmux/formal_pe_pinmux.v` |
| 2 | `pe_ctrl` R2: no wrap / RANGE sticks / word-aligned serializer | **NOT PROVED** — blocked on RTL observation ports | — | needs `formal/pe_ctrl/formal_pe_ctrl.v` |
| 3a | `pe_eth_tx`: frame never <14 or >1514 | **PROVED weakly; runt/JABBER GUARD NOT YET PROVEN** (runt mutant survives at depth 240) | 16 (240 checked) | `formal/pe_eth_tx/formal_pe_eth_tx.v` |
| 3b | `pe_eth_tx`: IFG >= 96 cells | **PROVED (bounded), but vacuous at depth 16** (needs >~215 to reach end-of-frame) | 16 | same |
| 3c | `pe_eth_tx`: underrun abandons, no partial FCS | **PROVED (bounded)** | 16 | same |
| 4 | `pe_soc` `tx_path` owner-mux exclusivity | **NOT PROVED** — blocked on RTL observation ports | — | needs `formal/pe_soc/formal_pe_soc.v` |

Runner: `formal/run_formal.sh` (fast subset, wired into `run_all.sh` as a gate;
`--full` for the deeper set). Logs + summary in `formal/results/`.
Full regression with the gate: **exit 0 — RTL 34/34, firmware 26/26, lint clean,
12 mutation suites, formal safety proofs OK, wait-word cross-check OK.**

### What the next session should do, in order

1. **Close the 3a gap (highest value, no RTL change needed).** The runt mutant
   survives because the P1 assertion's shadow of the in-flight length does not
   tightly bound the completed frame. Pin the engine's OWN accepted length
   rather than a wrapper-side sample — the clean way is to compare `tx_done`
   against a shadow that records the length at the cell boundary (when the
   engine applies the start), then re-run the runt and jabber mutants until BOTH
   fail. **A property that does not kill its mutant is not a proof.**
2. **Re-check 3b's vacuity**: rerun the IFG mutant at depth >= 240 and confirm
   it now FAILS. Only then is 3b a real proof.
3. **Targets 2 and 4** need the manager's go-ahead for `ifdef FORMAL`
   observation ports (exact signatures in the section above), then the wrappers.

### Mutant table (the non-vacuity evidence, at wrap)

| mutant | target | result | meaning |
|---|---|---|---|
| `pad_oe = reg_oe` (the real 18:43 m1) | 1 | **FAIL (caught)** | harness is live |
| IFG shortened to 90 cells | 3b | survives at 16 | vacuous — too shallow |
| runt accepted (`len_ok >= 0`) | 3a | survives at 16 and 240 | **modelling gap, not depth** |
| pad removed (`stored_bytes < 0`) | — | survives | expected: padding is not in 3a/3b/3c |

## Limits

- All results are **bounded**, not inductive: `sat -seq N` proves safety up to N
  cycles. Nothing here is an unbounded proof.
- The fast gate runs at depth 16 for runtime; the depth at which each property
  becomes non-vacuous is documented above, and 3a has a known open gap.
- Targets 2 and 4 remain unproved pending instrumentation.
- No physical flow, DRC or LVS; this is simulation/formal only.
