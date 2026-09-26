# R3 debug control — independent cross-review of the chip RTL

**Reviewer:** `gui-worker` · **Date:** 2026-09-25 · **Type:** independent, read-only

I did not write this RTL. My bias is declared up front: I implemented the
**host** side of this same contract, so I was inclined to confirm it. To
counter that, every finding below is anchored to a line of RTL or to a command
I ran, and where the RTL and my belief disagreed the RTL won. Two of my own
initial readings turned out to be wrong and are recorded as such.

**Scope:** `rtl/pe_cpu.v` (dbg_hold / dbg_step / dbg_next_pc), `rtl/pe_ctrl.v`
(0x21–0x24 decode, breakpoint registers, response mux), `rtl/pe_soc.v`
routing, `rtl/tt_um_protocol_emulator.v` (top level), the frozen contract, and
the conformance evidence. **No chip file was modified.**

---

## Verdict

**No correctness defect was found between the RTL and the contract.** Every
response shape, the state encoding, the stop-before and step semantics, the
RANGE and NOT_READY rules, and the zero-wait-word claim check out against the
source. That is a real result, not a courtesy: the implementation is unusually
well-instrumented (formally-shaped proof ports, a 7-mutant gate, a strict
conformance gate) and the RTL holds up under reading.

What I did find are four **medium** and two **low** items, none of them an RTL
bug: two are contract/evidence-hygiene problems, one is an untested
compatibility surface, and one is an STA constraint gap. Two of my own first
readings were wrong and are corrected below, because that is the part of a
review worth trusting.

---

## Direction 1 — does the RTL match the contract?

Checked line by line. **All conformant.**

| Contract claim | RTL evidence | Verdict |
| --- | --- | --- |
| `dbg_hold` masks the run strap; `dbg_step` is a one-cycle pulse | `pe_cpu.v:217` `wire cpu_exec = dbg_step \|\| (run && !dbg_hold);` | conformant |
| S1: one instruction per step, one PC update | `pe_cpu.v:289-291` `else if (cpu_exec) begin pc <= next_pc;` — the *only* PC advance | conformant |
| S2: PC preserved in a hold; only the boot stop re-zeroes | `pe_cpu.v:319-322` `else if (!dbg_hold) pc <= '0;` / `// else: debug hold -- pc keeps its value` | conformant |
| Fetch mode `pc` while held (so `insn` is the landing instruction) | `pe_cpu.v:235-237` `imem_addr = cpu_exec ? next_pc : dbg_hold ? pc : 0` | conformant |
| state = `hold ? (hit ? 3 : 2) : (run ? 1 : 0)` | `pe_ctrl.v:538-539` | conformant |
| `bp_flags` = `{bp_hit, bp_en}` | `pe_ctrl.v:540` | conformant |
| 0x21/0x22/0x23/0x24 response shapes | `pe_ctrl.v:1026-1105`, each `resp_len` and `resp_buf[]` index matches the contract row | conformant |
| Wrong payload length → 1-word BAD_FRAME, no side effect | `pe_ctrl.v:775-778` raises `frm_len_bad`; `:829-831` answers a 1-word `ST_BADFRAME`; the op mux at `:790` is gated on `!frm_len_bad`, so no handler runs | conformant |
| `BP_SET` past IMEM → RANGE, **no** fault, no arming | `pe_ctrl.v:1064-1067` sets `resp_buf[0] <= ST_RANGE` and leaves `bp_addr`/`bp_en` alone; **no** `faults <=` in that branch | conformant |
| Step while free-running → NOT_READY, full 5-word prefix, no side effect | `pe_ctrl.v:1044-1049` overrides only `resp_buf[1,2,4]`, leaving `resp_len = 5`; the `else` at `:1050-1052` (which would step) is not taken | conformant |
| **Zero wait words** for all four debug ops | `pe_ctrl.v:493` `r_is_read = (frm_op == OP_RDIMEM) \|\| (frm_op == OP_RDMEM)` — only the two bounded reads enter the filler path | conformant |
| Debug ops are TARGET_HOST only; loopback answers UNSUPPORTED | the loopback branch handles only `OP_PING`/`OP_TARGET`, everything else falls to `default` → `ST_UNSUP` | conformant |

**Two subtleties I checked because they looked like bugs and are not:**

- **`frm_not_ready` cannot silently block a debug op.** It is set in exactly
  one place — `pe_ctrl.v:739-741`, `OP_LOAD && TARGET_HOST && run` — and the
  `ST_NOTREADY` override at `:925` is inside `OP_LOAD:` only, not a global mux.
  The debug ops have their own NOT_READY rule. Clean.
- **No multiple driver on `bp_hit` / `dbg_hold_r`.** Two places assign them
  (the live-hit latch at `:679-680` and the `DEBUG_STEP` decode at
  `:1050-1052`). I verified no `always` block *starts* between lines 679 and
  1052, so both live in the single `always_ff` opened at `:621` and the later
  assignment wins — the intended override (the comment at `:664-666` says so).
  The sequence works out because `dbg_step_r` is cleared each cycle at `:661`
  and `bp_hit` is re-evaluated from the landing address by the decode. Clean.

---

## Findings, by severity

### MEDIUM 1 — the FROZEN contract still carries the two superseded vector rows

The contract is titled *"draft-for-implementation, manager ruling"* and
"**FROZEN** for implementation", yet its §3 table still says, for row 11,
`(OK, 0, pc=0, …)`, and for row 13, `insn=imem[4]`. The manager has ruled the
vectors stand (pc is the PC **at the request**; insn is the **landing** word)
and the table is being corrected chip-side — but it is not corrected *in the
frozen document*. Anyone implementing, re-reviewing, or writing a second
conformance TB from that document alone would build the wrong thing, and the
document is the thing a reviewer is told to trust.

*Why it matters:* this is the "does the contract assume something the RTL does
not implement" question, and the honest answer is yes — the contract document
disagrees with the RTL in two rows. The RTL is right in both; the text is
stale. **Action (chip side):** correct rows 11 and 13 in the frozen contract
and note the ruling date, so the document and the RTL cannot both be cited.

### MEDIUM 2 — the conformance TB preloads internal debug registers, so a vector can encode an unreachable state

`tb_pe_ctrl_r3_conf.v:513` does `dut.bp_addr = bp; dut.bp_en = en; dut.hit;
dut.dbg_hold_r = hold;` — hierarchical assignment into the DUT, not a state
reached through the SPI pins. That is a legitimate and common technique, but it
means **a vector can assert a register combination the RTL cannot reach from
reset**, and such a vector passes without proving anything about the design.

This is not hypothetical: it is exactly what the pinned boundary step does.
`status_full_readback` requires `pc=4` with `a=0`, and the divergence record
observes that reaching address 4 means executing address 3 (`LDI A,0x0F`), so
`a=0` at `pc=4` is a state the chip cannot physically occupy. That case is
honestly documented — but it means the *mechanism* has been used, and the other
25 pre-states are not checked for the same property.

*Action (chip side):* either have the TB drive each pre-state through the pins
where reachable, or add a reachability assertion so an unreachable pre-state
must be declared as such (as the boundary step is). Otherwise "25/26
byte-exact" mixes 25 proven states with an unknown number of unproven ones.

> **UPDATE 2026-09-25 (manager): the boundary case is now CLOSED.** The chip
> worker proved the boundary pre-state (`pc=4` with `a=0`) is unreachable, so
> the question I raised for *that* step is answered: the pinned step is pinned
> for a demonstrated reason, not merely because it was awkward. The 25/26 tally
> stands with the step pinned. What remains open from this item is only the
> weaker form: whether the other 25 pre-states are each driven through the pins
> or hierarchically forced. I have not seen evidence either way, so I am
> leaving this MEDIUM open rather than marking it done on a summary.

### MEDIUM 3 — R2's confirmed STATUS / DUMP_CORE now carry state values 2 and 3, untested

`pe_ctrl.v:876` and `:898` report `dbg_state` in the **R2** `STATUS` and
`DUMP_CORE` responses. That is what the contract intends (*"R2's STATUS state
word carries THE SAME encoding"*), and it is not a bug. But it is a **behaviour
change to a chip-confirmed interface**, and the R2 golden vectors only ever
exercise 0 and 1, so the 2/3 values on two already-confirmed opcodes have no
test at all.

A host written against R1/R2 that reads `state` and branches on
`state == 1` for "running" will see `3` (BP_HIT, strap still high) and treat
the core as stopped — a defensible outcome, but one arrived at by accident
rather than by agreement.

*Action (chip side):* one directed case — `STATUS` while held returns 2, and
`STATUS` on a live-core hit returns 3 with `run=1` — so the compatibility
surface is pinned rather than merely documented.

### MEDIUM 4 — the R3 debug input is unconstrained at the `pe_soc` STA boundary

Every `pe_soc` STA report opens with:

```
Warning: there are 20 input ports missing set_input_delay.
     dbg_hold
     dbg_rd_addr[0] ... dbg_step ...
```

`dbg_hold` is one of them. At the **full-chip** level this is harmless — the
top level drives `dbg_hold` from `pe_ctrl`, so it is an internal net and needs
no input delay. But it means the **`pe_soc`-level** reports cannot be used to
claim the new debug input's timing is checked, and "the STA covers R3" is not
quite true at that boundary.

I also chased the alarming `worst slack min -0.87` in
`r3-sta/r3-debug-timing.txt` and it is **not** an R3 logic failure: those paths
are `library hold time 0.8692` on `u_imem.g_macro.u_sram/A_CLK
(RM_IHPSG13_1P_1024x16_c2_bm_bist)` with `data arrival time -0.0000` — a
SRAM-macro hold-model artefact. It is pre-existing and not R3's doing.

*Action (chip side):* add `set_input_delay` for `dbg_hold`/`dbg_step` on the
`pe_soc` STA, or state explicitly that the `pe_soc` boundary is intentionally
unconstrained and that only the top-level report is authoritative.

### LOW 1 — once held, the run strap can no longer stop or start the core

`cpu_exec = dbg_step || (run && !dbg_hold)`: while `dbg_hold` is asserted the
strap is ignored in **both** directions. Only `DEBUG_BP_CLR` releases the hold
(and a hardware reset, which clears `dbg_hold_r` at `pe_ctrl.v:652`).

This is the contract's design, not a defect — but it is an operational trap:
if a host dies mid-debug, **pulling `run` low will not recover the chip**; it
stays held with the PC preserved. The escape is `DEBUG_BP_CLR` or a reset.

*Action (chip side / bring-up):* the runbook's triage table should say so
explicitly. Worth adding to `docs/host-bridge-bringup.md` on the host side too —
my own acceptance demo depends on this behaviour.

> **DONE on the host side (2026-09-25).** `docs/host-bridge-bringup.md` now has
> both a triage row ("chip is stopped and will NOT restart, and the run strap
> looks correct") and a short section, *"If the chip will not restart: the run
> strap is not the answer"*, which states that the strap is masked in BOTH
> directions, that `DEBUG_BP_CLR` is the only release, and that a reset is the
> other escape — and that the host's own `r3_demo_6_clear_releases` beat
> depends on it. The judge-facing walkthrough carries the same warning. The chip
> side may still want it in its own runbook.

### LOW 2 — the host model's `advance_free_running` is a model-only driver

Recorded for completeness, not a defect. The host `FakePE` needs something to
clock it to a breakpoint; the chip self-advances. It is already excluded from
the golden vectors as a model-only obligation, and the acceptance act names the
shortcut in its own output line. No action.

---

## Two of my own readings were wrong

Recorded because a review that hides its own errors is not reviewable.

1. **"The top level does not connect the debug inputs."** I grepped
   `rtl/tt_um.v` — a filename that does not exist — got no match, and was one
   step from reporting a HIGH-severity X-at-reset defect. The real top is
   `rtl/tt_um_protocol_emulator.v`, which declares `wire dbg_hold, dbg_step;`
   at line 148, drives them from `u_ctrl` (`:165`) and routes them into the SoC
   (`:215-217`). The top level is **correct**. A false HIGH on a
   hardware-failure claim would have been expensive.
2. **"`tb_pe_ctrl.v` does not tie the debug ports (0 references) — another
   missed tie-off."** It instantiates `pe_ctrl`, whose `dbg_hold`/`dbg_step` are
   **outputs**. Zero references is the correct answer. The 13 TBs that
   instantiate `pe_cpu`/`pe_soc` — the ones that actually take debug *inputs* —
   all tie them low.

---

## Coverage: what I verified is clean

Stated explicitly so the absence of findings is legible rather than ambiguous.

- **X at reset:** every debug register is reset —
  `pe_ctrl.v:651-652` clears `bp_addr`, `bp_en`, `bp_hit`, `dbg_hold_r`,
  `dbg_step_r`; the wait-word machinery is reset from defined values at
  `:634-641` specifically so `r_filling` cannot start as X.
- **The 13-TB tie-offs:** all 13 TBs instantiating `pe_cpu`/`pe_soc` tie
  `dbg_hold`/`dbg_step` low with a comment; the two R3 TBs drive them
  deliberately. Verified by enumerating the TBs that instantiate either
  module, not by trusting the contract's claim.
- **Top-level routing:** all three wires reach the CPU.
- **Combinational loop risk:** `dbg_next_pc` feeds `pe_ctrl`'s response
  registers, but `pe_cpu` never reads `pe_ctrl`'s response, and `dbg_insn`
  derives from the *registered* ROM output, so the new cross-module path is
  flop-to-flop and not a loop.
- **STA netlists are current:** the `r3-sta` mapped netlists contain the new
  ports (`dbg_hold`, `dbg_next_pc`), so the reports were regenerated after R3.
- **No R3 timing regression:** R2's STA on the same corner shows **300**
  violated paths vs R3's **302** on `pe_soc/slow`, and R3 is *better* at the
  top level (592 vs 649). Whatever the hold-model noise is, R3 did not add to it.

## What I did not do

Did not modify any chip file, did not re-run the chip regression or the
mutation gate, and did not attempt to re-derive the chip's proof claims. Where
I had an opinion that conflicted with the RTL, the RTL is what I recorded.
