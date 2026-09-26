# Docs accuracy review — pass 2 (2026-09-26)

Author: protocol-worker. Rolling pass. Pass 1 covered `docs/diag-proto` at
`accc75b` and `docs/wiki-features` at `bdcae3b`. Since then four more commits
landed, and this pass covers the new material plus the status of pass 1's three
corrections.

**Result: pass 1's three corrections are NOT yet addressed, one of them is now
worse (two documents on the same branch disagree), the new R3 debug-control
figure is accurate and already carries the subtlest claim in the whole fleet
correctly, and the WS2812 figure set is accurate on every number checked.**

## 1. Status of pass 1's corrections (owner: pw-diag-proto)

| # | correction | status at `d17e07a` |
| --- | --- | --- |
| C1 | stale `cpu_exec` expression | **NOT ADDRESSED, and now 4 sites** — the maps' three (`project-plan.puml:166`, `project-progress.puml:175`, `:297`) plus the NEW figure's "THE GATE" box (`proto-r3-debug-control.puml:105`), which states the same pre-repair form. Ground truth is still `pe_cpu.v:233`, `(dbg_step === 1'b1) \|\| (run && !(dbg_hold === 1'b1))` |
| C2 | the maps list 3 of 4 debug opcodes | **NOT ADDRESSED, and now self-contradictory**: `project-plan.puml:107` and `project-progress.puml:174` still read "0x21 STEP / 0x22 BP_SET / 0x23 BP_CLR", while the new figure `proto-r3-debug-control.puml:99` correctly gives all four with `0x24 DEBUG_STATUS -> … 10 words`. Two documents on one branch now disagree about how many debug opcodes exist |
| C3 | "the tick" is ambiguous | **NOT ADDRESSED** — `project-plan.puml:114`, `project-progress.puml:184` and `:198` still say "one 260-clock tick" beside a conclusion that is false for the 1 µs `I2C_TICKS` the SoC also has (`pe_soc.v:560`) |

C2 is the one to fix first: it is no longer an omission but a contradiction
inside a single branch, and the correct text already exists 200 lines away in the
worker's own new figure.

## 2. New material reviewed — `docs/diag-proto` `d17e07a`

**`diagrams/proto-r3-debug-control.puml` — accurate, including the hardest claim
in the fleet.** It states the two-routes subtlety correctly and explicitly warns
against generalising it: the free-running latch (`pe_ctrl.v:692`) is gated on
`!dbg_hold_r`, the **step** path is **not** (`pe_ctrl.v:1067` sets `bp_hit`
straight from `bp_en && dbg_next_pc == bp_addr`), so arming an already-held core
*is* legal via the step route — "BUT DO NOT GENERALISE IT" is in the figure. That
is the correction this reviewer made to `reviews/2026-09-25/R2-HELD-CORE-CHIP-SIDE.md`
earlier today, and the figure carries it without being told.

Everything checked against the RTL holds:

| claim | ground truth |
| --- | --- |
| `dbg_state = dbg_hold_r ? (bp_hit ? 3 : 2) : (run ? 1 : 0)`; `bp_flags = {bp_hit, bp_en}` | `pe_ctrl.v:553-555` |
| "a breakpoint at address 0 is legal, told from *disarmed* by `bp_flags` bit 0" | `bp_addr <= pay0[9:0]` (`:1085`), `bp_flags` bit0 = armed (`:555`) |
| "BP_CLR is the ONLY release; `dbg_hold_r` is cleared at exactly two places: reset, and the BP_CLR branch" | exactly 4 assignment sites (`:667` reset/clear, `:695` hit/set, `:1066` step/set, `:1104` BP_CLR/clear) — so cleared at exactly two |
| "STOP-BEFORE: the hit compares the LANDING address, and the instruction at `bp_addr` has NOT run" | `:690-696` compares `dbg_next_pc`; the core is held at that edge |
| "the fetch has three modes: `cpu_exec ? next_pc : dbg_hold ? pc : 0`" | `pe_cpu.v:251` |
| opcode response shapes: STEP 5, BP_SET 5, BP_CLR 5, DEBUG_STATUS 10 words | `pe_ctrl.v:1047`, `:1074`, `:1096`, `:1110-1119` |

One imprecision, not worth a correction on its own: the figure quotes the hit
condition as `run || dbg_step` where the RTL says `run || dbg_step_r` (a
register, not the input). In a box labelled "THE COMPARISON" a reader may expect
the verbatim line, but the meaning is unchanged and a reader tracing the source
will find the register.

## 3. New material reviewed — `docs/diag-timing` `7f849cf` (WS2812)

**Accurate on every number checked.** The set is three figures plus
`wiki/concepts/protocol-ws2812.md`, and it is the fleet's style exemplar, so the
arithmetic is worth stating as checked:

* 75 clocks = 1.250 µs, 48 = 800.0 ns, 27 = 450.0 ns, 1 clock = 16.6667 ns, all at
  60 MHz — exact, no remainder.
* frame 24 × 75 = 1800 clocks = **30.000 µs**; 47/49 clocks = 783/817 ns; a
  74-clock cell = 1.23 µs; the strip samples at +42 clocks = 0.700 µs.
* reset: `(n1-1)*(4*n2+7)+4` with n1=10, n2=99 = 3631 clocks = **60.52 µs**; the
  measured 3651/3737 clocks = **60.85/62.28 µs**; the "> 50 µs" floor holds.
* the frame bytes are **`0x9C 0xE0 0x8A`** — confirmed against
  `firmware/ws2812.pe:205,225-229`, and the 10-ones/14-zeros split follows from
  those bytes, as does the MSB-first cell order the figure draws.
* "48 was chosen over 50 on purpose … a 50-clock high gives **417 ns of low**,
  7 % under the nominal tLOW" — 75 − 50 = 25 clocks = 416.7 ns, which is 7.3 %
  under 450 ns. Correct, and the reasoning (hit both datasheet nominals exactly
  rather than maximise one side) is the act's own.

## 4. Not yet reviewed — stated rather than implied

* **`docs/diag-bus` `c5271ca`** (the I2C-advanced figure set, six figures) landed
  during this pass and is **not** covered above. I2C timing claims are among the
  most falsifiable in the fleet — `tLOW`/`tHIGH` floors, the 60 phase sweep, the
  1 µs tick — so this is the highest-value next target.
* **`docs/wiki-features` `f1a5038`, `1be78fd`** (the cold-start on-ramp and the
  index-as-map) are not covered; both are structural rather than numeric, which is
  why they went second.
* **A correction to record in the reviewer's favour:** `docs/wiki-features`
  `f069d4b` corrects the NEC half-period claim to "a range, not a 0.05-clock
  spread" — the same item pass 1 noted as *consistent but not independently
  re-measured*. They fixed it before this reviewer flagged it.

## 5. A pattern worth naming: three times the document was right and I was wrong

In this pass, three of my own suspicions were wrong and the documents were
correct: the dmem ceiling (`2 *` the word ceiling, so "30 bytes" is right), the
port numbers (the RTL uses named constants; the literals live in the firmware
comments), and "a 50-clock high gives 417 ns" (417 ns is the *remaining* low, not
the high). Each time the cost was one re-read, and each time the discipline that
caught it was the same: **check whether my own arithmetic is the thing that is
broken before publishing that a document is.** A reviewer who reports three
arithmetic errors as three document defects stops being read, and the one real
defect in this pass (C1) would have been lost in the noise.
