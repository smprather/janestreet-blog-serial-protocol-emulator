# Formal verification campaign — chip side (2026-09-25)

> **STATUS AT THE END OF CAMPAIGN II (2026-09-25, after the manager's
> instrumented-target ruling).** Everything below Campaign-I history stands, but
> the results are SUPERSEDED by the "Campaign II" section at the bottom. Headline:
> targets 1 and 3a are proved and mutant-killed at a shallow depth; the IFG floor
> (3b) is proved INDUCTIVELY and unbounded with both gap mutants caught; target 2
> has 8 claims proved unbounded and 4 proved at gate depth only (labelled); target
> 4's existing guard is proved unbounded and its MISSING guard is refuted as
> finding F2. The two recorded findings (F1 the TXLEN window, F2 the owner
> switch) are RTL decisions for the manager, not worker calls. Every proof's
> shape, depth, peak RSS and mutant evidence is in `formal/results/`.

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

---

# Campaign II — the instrumented targets, the inductive rewrite, and the findings

Manager ruling that opened it (2026-09-25): the `ifdef FORMAL` observation ports
for targets 2 and 4 are APPROVED — guarded instrumentation only, must compile out
of every synthesis and regression path, with a gate check that FORMAL is never
defined during synthesis; minimal taps; re-run the full suite. Mid-campaign the
manager added the memory ruling: every yosys invocation runs under a hard cap and
a one-at-a-time flock, a cap-kill is a STRATEGY SIGNAL (go inductive / fix the
modelling, never retry deeper), and the ceiling plus every run's peak RSS are
part of the record.

## Toolchain — what changed, and the bugs it closed

| change | why |
|---|---|
| `formal/fv_run.sh` = the single proof entry point | every target runs the same flags; a flag cannot be present in one harness and missing from another |
| **`-set-assumes`** added | `sat` IGNORES `$assume` cells without it. Verified with a minimal design: `assume(1'b0)` changed nothing until the flag was added. The first campaign's reset-discipline assume was therefore DECORATION in every proof it ran. All results here are with it. |
| memory cap `ulimit -v 6 GB` + `flock` (the manager landed this) | two runs diverged past 6 GB and tripped the RAM brake; the cap makes a divergence die loudly and known |
| `FORMAL_SAT_MODE=induct` | temporal induction (base case + step) = UNBOUNDED proofs, the ruling's shape for deep claims |
| success/failure recognition fixed | a successful induction prints `Induction step proven: SUCCESS!`, not the BMC string — every successful induction run was reported ERROR (caught by bisecting 3b: the log said SUCCESS while the harness said ERROR) |
| `NOTPROVED` added as a distinct outcome | an induction failure is a MODELLING signal, not a counterexample witness |
| `tools/check_formal_ifdef.sh` (wired into `run_all.sh`) | the ruling's gate: no build script may define FORMAL, and a real synthesis elaboration must contain **0** `fv_*` wires |
| `formal/mutants.sh` (wired into `run_all.sh`) | every proof must kill its mutant, in the SAME proof shape as the claim (a BMC-depth mutant of an inductive claim survives vacuously — measured) |

## Per-property status (all shapes/depths/peaks machine-recorded)

`formal/results/summary.txt` is the machine-readable table; `formal/results/*.log`
are the logs. The gate runs in ~9 s.

| # | property | result | shape / depth | evidence |
|---|---|---|---|---|
| 1 | pe_pinmux OD never drives high | **PROVED** | bmc 16 | `pinmux_od_invariant.log`, mutant `pinmux_od_m1` CAUGHT |
| 3a | frame bounds: the APPLIED length is legal (P1a), completed frame legal (P1b) | **PROVED** | bmc 16 | `eth_tx_safety.log`; **runt and jabber mutants both CAUGHT at depth 16** |
| 3a-vacuity | "a frame is in flight" / "a frame completed" | live / **VACUOUS at 16** | reach targets | `eth_tx_reach_busy.log` REACHABLE, `eth_tx_reach_tx_done.log` VACUOUS (P1b cannot fire before ~576 cells — labelled, not hidden) |
| 3b | IFG floor >= 96 cells after every frame | **PROVED, UNBOUNDED** | induct, len <= 6 | `eth_tx_ifg_floor.log`; mutants `eth_tx_ifg90` and `eth_tx_skip_gap` both CAUGHT by induction |
| 3c | underrun abandons, no partial FCS | **PROVED** | bmc 16 | inside `eth_tx_safety` |
| 2 | pe_ctrl R2: 8 claims (walk non-zero, accept-bound, accept-slot, resp_len <= 16, index starts 0, sticky RANGE, frame starts at bit 0, index change = restart-or-word-end) | **PROVED, UNBOUNDED** | induct, len <= 6 | `pe_ctrl_r2_induct.log`; mutants `pe_ctrl_len_overflow`, `pe_ctrl_bit14`, `pe_ctrl_clear_uncond` CAUGHT |
| 2 | pe_ctrl R2: 4 claims (`r_slot != 0`, walk-sum stability, slot-sum non-growth, index-advance bound) | **PROVED at gate depth only; INDUCTION OPEN** | bmc 16 | `pe_ctrl_r2.log` (all 12 claims); the four are excluded from the induction target by `ifndef FV_INDUCT` and LABELLED in the wrapper |
| 4 | pe_soc owner: tx_path cannot be taken from a RUNNING frame engine | **PROVED, UNBOUNDED** | induct, len <= 3 | `pe_soc_owner_guard.log`; mutant `pe_soc_owner_guard_removed` CAUGHT |
| 4 | pe_soc owner: setting tx_path during a SERDES transmission | **REFUTED — finding F2** | induct | `pe_soc_owner_unguarded_refuted.log` |

**Peak RSS** (from `formal/results/summary.txt`; the ceiling is 6 GB per run and
one yosys at a time): pinmux 47 MB, eth_tx safety 110 MB, ifg induct 49 MB,
pe_ctrl BMC-16 317 MB, pe_ctrl induct 131 MB, pe_soc owner induct 368 MB. The
two `REFUTED`/`REACHABLE` targets end at their model without printing yosys's
summary line, so they show no peak — they are the CHEAPEST runs, not the most
expensive. The two cap-killed runs earlier in the day (a 700-step BMC and a
pe_ctrl tempinduct that escalated past 65 steps, both 6+ GB) are the reason the
ruling exists, and both are recorded in WORKLOG.

## Target 3a — the modelling gap, closed at SMALL depth

The first campaign's P1 shadow sampled `frame_len` on the `start` INPUT pulse,
one or more cycles before the engine applies it, so it could not see a TXLEN
rewrite in that window. The new shadow samples at the APPLY BOUNDARY (the edge
where `tx_busy` rises), which is exactly where the engine latches
`stored_bytes`. Split into:

* **P1a (rise guard, one-step, live at depth 16):** the applied length is legal.
  Kills the runt mutant and the jabber mutant at depth 16 (0.3 s each), where the
  old property's runt mutant survived even at depth 240 (11 min).
* **P1b (completion form):** the length of a COMPLETED frame is legal. Cannot
  fire before ~576 cells, so it is VACUOUS at the gate depth and is labelled by
  the `eth_tx_reach_tx_done` target.

**Finding F1 — the TXLEN window (reported, RTL deliberately unchanged per the
manager's "no RTL change" ruling for 3a).** The guard tests `len_ok` at the
start-pulse edge but latches `stored_bytes <= frame_len` at the NEXT cell
boundary (up to DIV-1 = 5 clocks = 83 ns later), and pe_soc feeds `frame_len`
straight from live `win_regs[24]/[25]` with no tx_busy gate. A host/firmware
rewrite of TXLEN inside that window transmits an unvalidated length. The proof
carries ONE labelled contract assumption (TXLEN held from frame_start until the
apply, per G1) and the assumption is enforced by a mutant: removing it makes the
property FAIL on the UNMODIFIED design with a 6-step counterexample
(`formal/results/mutant_eth_tx_len_window.log`). Manager's call: latch TXLEN at
the start pulse (RTL), document the contract, or accept the narrow window.

## Target 3b — the IFG floor, inductively (no deepening)

A frame needs ~576 cells and the gap closes ~672, so the old counter-style claim
was VACUOUS at every affordable depth: **measured** — the shortened-gap mutant
SURVIVES at depth 240 (11 min, 1.7 M vars) and the 700-step run died at the
memory cap. Per the ruling the floor is now stated over the structure that
enforces it (`formal/pe_eth_tx/formal_pe_eth_tx_ifg.v`, taps `fv_state`,
`fv_fcs_left`, `fv_ifg_cnt`, `fv_abort_pend`):

* T1 the FCS's last cell opens the gap with the counter reset;
* T1b the gap is MANDATORY after an un-aborted frame end;
* T2 the engine's counter and the shadow agree while the gap is open;
* T3 the gap closes only at the terminal count OR by the two documented
  abandonments (abort, enable loss);
* T4 no frame is applied while the gap is open.

Two modelling facts that took a real counterexample each to find: a
`tx_done`-keyed floor claim is NOT inductive (tx_done is a free register in an
arbitrary state), which is why T1/T1b key on the FSM state and FCS counter; and
an ABORT legitimately cuts the gap short (the engine's header documents "does NOT
run an IFG"), so the floor must NAME its abandonment exits or it is false on the
clean RTL.

## Target 2 — why some claims are unbounded and some are gate-depth only

The subject is internal (`resp_len/resp_idx/faults/rstate/r_addr/r_left/r_slot`),
so the claims are stated over the approved `ifdef FORMAL` taps. Two toolchain
facts decided the shape:

1. **BMC cannot reach the read engine.** Delivering a request frame costs ~230
   cycles (16 bits per word, two synchronizer stages per edge); a pe_ctrl BMC
   deep enough for that is a multi-million-variable SAT instance that dies at the
   cap. The claims are therefore transition-local and proved by induction.
2. **Clocked asserts are NOT inductive here.** After `clk2fflogic` a clocked
   assertion reads SAMPLED COPIES of its signals, and each copy is an independent
   state bit: yosys's own model dump for a failing attempt showed
   `resp_active#sampled = 1` beside `resp_active#sampled = 0` in the same initial
   state. Every clocked claim was non-inductive while BMC proved it. The fix is
   combinational asserts plus ONE explicit snapshot register per signal.

Eight claims close by induction. Four do not, and they are not hidden: they are
kept in the wrapper (proved at the gate depth) under `ifndef FV_INDUCT` with a
comment saying exactly that, and they are the ones whose induction step needs a
reachability coupling an arbitrary pre-state can violate (`r_slot`, the walk-sum
and slot-sum couplings, the index-advance bound). The walk bound itself IS
proved: as the pair (accept-bound, sum-preserved-by-the-increment), which is the
form that closes. **The 4 gate-depth claims are the honest label on this
target**; the next session can close them with an accept-sum coupling invariant
(one more snapshot register), and the wrapper documents the shape.

## Target 4 — the guard the RTL has, and the one it does not

The mux `eth_tx_owner = tx_path ? eth_tx_bit : ser_tx` makes "never two owners,
never a float" structural. The claim with content is the ownership CHANGE:

* **C1 PROVED (unbounded):** a falling `tx_path` is only possible while
  `eth_tx_busy` is low — the RTL's own guard (`else if (!eth_tx_busy)`).
* **Finding F2 REFUTED:** setting `tx_path` has NO `ser_tx_busy` term
  (`if (io_wdata[2]) tx_path <= 1'b1;`), so a TXCTRL write during a SERDES
  transmission steals the codec mid-frame — exactly the interleave the block's
  comment says cannot happen. The companion target
  `formal/pe_soc/formal_pe_soc_refute.v` states the missing guard; the induction
  step fails it, which is the machine-checked form of the finding. Not fixed:
  an RTL behaviour change is the manager's ruling, and the wrapper says so.

Both target-4 proofs run against a **formal-only SRAM stand-in**
(`formal/pe_soc/sram_model_formal.v`): the PDK macro's `specify`/`$setuphold`
block is not yosys-parseable, and with `FORMAL_MEMORY_MAP=1` the memories are
lowered for the SAT engine. The regression keeps using the real PDK model; no
target-4 claim reads memory contents.

## Mutant table (formal/results/mutants.txt; all run in the claim's own shape)

| mutant | target | shape | result |
|---|---|---|---|
| `pad_oe = reg_oe` (the real 18:43 m1) | 1 | bmc 16 | **CAUGHT** |
| runt accepted (`len_ok >= 0`) | 3a | bmc 16 | **CAUGHT** |
| jabber accepted (upper bound -> 4095) | 3a | bmc 16 | **CAUGHT** |
| TXLEN hold assumption removed (no RTL change) | 3a | bmc 16 | **CAUGHT** (F1's witness) |
| IFG shortened to 90 cells | 3b | induct | **CAUGHT** |
| the gap skipped entirely (FCS -> IDLE) | 3b | induct | **CAUGHT** |
| imem read count guard removed (`resp_len` overflow) | 2 | induct | **CAUGHT** |
| word end 15 -> 14 (15-bit words) | 2 | induct | **CAUGHT** |
| CLEAR_FAULT ignores its mask | 2 | induct | **CAUGHT** |
| tx_path clear guard removed | 4 | induct | **CAUGHT** |

## Limits and the continuation list

- Targets 1, 3a, 2's BMC-only four and all BMC targets are **bounded**: `sat -seq
  N` proves safety up to N cycles. 3b, target 2's inductive subset and target 4's
  C1 are **unbounded** (temporal induction), each with a documented induction
  length and a mutant that fails it.
- The four gate-depth pe_ctrl claims need an accept-sum coupling invariant to
  close (shape documented in the wrapper).
- Findings F1 (TXLEN window) and F2 (owner switch) are OPEN and need a manager
  ruling: latch/guard in RTL, document the contract, or accept.
- A directed simulation witness for F1 and F2 would make both findings readable
  to a board operator; the formal evidence (a 6-step model for F1, an induction
  counterexample for F2) is machine-checked but not a waveform.
- No physical flow, DRC or LVS; this is simulation/formal only.

---

# F1 and F2 — the manager's rulings, implemented (2026-09-25)

Both findings are now RTL fixes with mutant-checked proofs and TB-level
enforcement. The formal records above stay as the history that found them.

## F1 — the TXLEN window: VALIDATE-AND-LATCH

**Ruling:** validate and latch atomically at the start pulse; the frame consumes
exactly the validated length; a TXLEN write after the pulse affects only the
next frame. Discharge the proof's TXLEN-hold assumption.

**Implemented** (`rtl/pe_eth_tx.v`): the accepted start latches
`pend_len <= frame_len` at the pulse edge, and the cell boundary copies
`stored_bytes <= pend_len` (the FCS/pad logic already reads `stored_bytes`, so
the whole frame follows the validated value). Two guarded FORMAL-only taps were
added for the proof: `fv_pend_len` and `fv_stored_bytes`.

**Proof** (`formal/pe_eth_tx/formal_pe_eth_tx.v`): the contract assumption is
**DISCHARGED** — the wrapper has no assumption beyond the campaign's reset
discipline — and P1 is restated as the three claims that the fix makes true:

| claim | statement | shape | mutant |
|---|---|---|---|
| P1a | the length LATCHED at a start pulse is legal | one-step, bmc 16 | runt, jabber |
| P1b | the frame CONSUMES exactly what it latched | one-step, bmc 16 | `eth_tx_len_unlatch` |
| P1c | a completed frame's consumed length was legal | bmc 16 (vacuous < ~576 cells; labelled) | — |

The old 6-step counterexample (start with TXLEN=14, rewrite to 13 before the
boundary) can no longer exist. It is re-introduced as a mutant — `stored_bytes
<= frame_len` — and that mutant FAILS P1b at depth 16
(`formal/results/mutant_eth_tx_len_unlatch.log`). The runt and jabber mutants
still fail P1a at depth 16.

## F2 — the owner SET guard: SYMMETRY

**Ruling:** a TXCTRL `tx_path` SET while `ser_tx_busy` is REFUSED, exactly as
the CLEAR is refused while the frame engine is busy and `eth_start` is gated on
`!ser_tx_busy`; TXSTAT reflects the actual ownership; no new fault class.

**Implemented** (`rtl/pe_soc.v`): the SET arm is `if (!ser_tx_busy) tx_path <=
1'b1;` and the TXCTRL readback reports the ACTUAL owner (a refused set reads
back unclaimed). `ser_tx_busy`'s declaration moved above the window-write block
(Icarus binds in declaration order; the guard reads it there).

**Proof** (`formal/pe_soc/formal_pe_soc.v`): C1 (the clear-side guard) is
**PROVED UNBOUNDED** by induction and its removal mutant is caught. C2 (the
set-side guard) is stated and checked at the gate depth, but it is **NOT
INDUCTIVE on this toolchain** and is labelled so in the wrapper: the guard and
the observed busy value are separate sampling chains after `clk2fflogic`, the
same artifact that made pe_ctrl's clocked claims non-inductive. F2's
ENFORCEMENT is therefore the TB-level evidence the ruling asked for:

* **TB case** `run_owner_probe` in `tb/tb_pe_soc_eth_loop.v` with the new
  directed firmware `firmware/eth_tx_owner_probe.pe`: the SERDES owns the codec,
  a TXCTRL set is attempted while `ser_tx_busy` is high, and the case asserts
  `tx_path` never rose mid-transmission, the TXCTRL readback is unclaimed
  (`00`), the SERDES word completed, and `tx_path` is still 0 at the end.
  Measured on the fixed RTL: `readback=00 rose_mid=0 serdes_done=1 tx_path=0`.
* **Mutation** `owner-set-guard-removed` in
  `regress/mutate_eth_tx_loop_tb.sh` (guard removed). Clean TB: **PASS**;
  mutant: **FAIL** (`rose_mid=1`, `tx_path=1`) — a true differential, unlike a
  formal mutant run of the non-inductive C2 target (which is why that case is
  deliberately NOT in `formal/mutants.sh`; the reasoning is recorded there).

## Mutant evidence after the fixes (`formal/results/mutants.txt`)

Ten differential mutants, each in the claim's own proof shape: pinmux `m1`,
runt, jabber, **`eth_tx_len_unlatch`** (F1's re-introduction), IFG-90,
skip-the-gap, pe_ctrl len-overflow / bit-14 / unconditional-clear, and
`pe_soc_owner_clear_guard_removed`. Plus the TB-level
`owner-set-guard-removed` for F2 in the loop harness. All caught, 0 survivors.

## A process note worth keeping

While the F2 edit was being made, the full suite was running its own mutation
harnesses, which snapshot and restore `rtl/*.v`. One of them restored
`rtl/pe_soc.v` from a pre-edit snapshot and silently deleted the F2 guard. It
was caught immediately (the TB case failed on what should have been a fixed
design), re-applied, and the affected proofs were re-run. The rule this
re-learns is the project's own: **one run at a time, and never edit RTL while a
suite or mutation harness is in flight** — the per-worktree lock protects the
files, not a hand edit racing a restore.

## Final memory record (the manager's ceiling + per-run peaks)

Every proof runs through `formal/fv_run.sh` under `ulimit -v 6 GB` and a
one-yosys-at-a-time flock (the manager landed both after two 6+ GB divergences).
Peaks from the final gate run (`formal/results/summary.txt`):

| target | shape | peak RSS |
|---|---|---|
| pinmux_od_invariant | bmc 16 | 46.6 MB |
| eth_tx_safety (F1's P1a/P1b/P1c) | bmc 16 | 102.4 MB |
| eth_tx_ifg_floor | induct | 52.3 MB |
| pe_ctrl_r2 (all claims) | bmc 16 | 315.3 MB |
| pe_ctrl_r2_induct (subset) | induct | 131.9 MB |
| pe_soc_owner_gate_depth (C1+C2) | bmc 16 | 955.9 MB |
| pe_soc_owner_guard (C1) | induct | 366.6 MB |

Ceiling: 6 GB per run, one run at a time. The two runs that ended AT a model
(the reach target and the pre-fix refutation) print no yosys summary line, so
`summary.txt` labels them "MEMCAP-or-killed (no MEM line)" — that label is
COSMETICALLY wrong for them: they are the cheapest runs, not cap victims. The
label's intent is to flag a run that died without a summary; a future cleanup
can distinguish "ended at a model" from "hit the cap".

The two genuine cap deaths of the campaign were the 700-step BMC and a
pe_ctrl `-tempinduct` that escalated past 65 steps (both 6+ GB, both recorded in
WORKLOG). They are what turned "prove it deeper" into "prove it inductively".
