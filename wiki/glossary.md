---
title: Glossary — the terms of art
created: 2026-09-26
updated: 2026-09-26
type: reference
tags: [architecture, verification, tooling, protocol]
sources: [wiki/STATUS.md, wiki/SCHEMA.md, rtl/pe_ctrl.v, rtl/pe_cpu.v, regress/run_all.sh, regress/verify_merge.sh, regress/dep_guard.sh, diagrams/TOOLCHAIN.md, reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md, reviews/2026-09-25/MERGE-FORENSICS-5B4731F.md]
confidence: high
---

# Glossary

**What you'll learn here:** the vocabulary the rest of the wiki assumes. Every
entry is one line, and most link to the page that goes deeper.

**How to verify this page:** every claim here is checkable against a named
artefact — an RTL header, a harness header, or a gate you can run. Start at
[[getting-started]], which runs most of them.

## The hardware and its architecture

**persona** — a protocol written as a *program* rather than as gates. A persona
is a `.pe` file, a testbench that measures it on the pins, and a model of the
device at the other end. See [[concepts/spi-as-firmware]].

**act** — one demonstrable protocol, presented as a unit in the demo walkthrough
(`docs/demo-walkthrough.md`). There are baseline acts (UART, SPI, I2C), timing
acts, and input-capture acts.

**the pin matrix** (`pe_pinmux`) — a runtime per-pin `{out, oe, od}` register
file, 111 cells, inside `pe_soc`. It is what lets a *program* decide a pin's
direction and whether it is driven or released. See [[concepts/pin-matrix]].

**open drain** — driving low but *releasing* the line so a pull-up owns the high
level. I2C needs it, and a released pin reads back as whatever the bus is
actually doing, which is how arbitration is detected.

**the word engine** (`pe_serdes` + codec mux) — loads 1–32 bit words, paces them
with `bit_en`, and applies a line code chosen by *register*, not by gates. It
exists for protocols firmware cannot reach: 20 MHz half-cells, NRZI plus
stuffing.

**STOP-BEFORE** — a breakpoint semantics: the core stops on the address
*before* executing it, so the instruction at the breakpoint is still there to
be inspected and then single-stepped. From the R3 contract; see
[[concepts/debug-control]].

**T0H** — a WS2812/one-wire style high time: the width that *is* the bit value.
See [[concepts/protocol-ws2812]].

**MAB** — Micro-Aperture Bus: the iCE40 bitstream format, a Tiny Tapeout
artefact rather than a protocol. See [[entities/tiny-tapeout]].

**running status** — MIDI's rule that a repeated status byte on a channel may be
omitted from the stream, so a receiver must remember the last status per
channel. See [[concepts/protocol-midi]].

**counted-delay constant** — a named number in a firmware act that stands for a
delay in clocks, and which must be *fitted* (measured and adjusted) rather than
assumed. The assembler exposes `--const NAME=VALUE` so a mutation harness can
perturb one; see [[getting-started]] Step 3.

**the 75-clock grid** — the WS2812 bit cell at 60 MHz is exactly 75 clocks, so
every cell boundary lands on the same cycle. A cell of 74 or 76 still passes
every datasheet window but is off the grid, which is what the project checks.

## The host bus

**wait word** — a `0xFFFF` filler the chip drives on MISO while it fetches a
bounded read's data. The real frame starts at the first non-`0xFFFF` word, so a
host skips leading fillers and validates as normal. Filler can never be a
header, and the skip is leading-only so a `0xFFFF` in a payload is data. See
[[concepts/host-chip-protocol]].

**frame** — one request plus one response between CS_N low: `A55A` sync, a
`{version, opcode, target}` word, sequence, length, payload, CRC-16/CCITT-FALSE.

**the run strap** — a *pad* (`ui_in[1]`) that starts and stops the core. It is
a pin rather than a bus command because there is no ROM: the chip cannot load
itself. See [[decisions/adr-007-pe-ctrl-passive-slave]].

**the debug hold** — a R3 state where the core is stopped with its PC
*preserved*. Once held, the run strap is ignored in **both** directions; only
`DEBUG_BP_CLR` or a reset releases it. This is the trap that costs a bring-up
board a day, and it is documented in `rtl/pe_ctrl.v` and in
[[concepts/debug-control]].

**state 2 / state 3** — `DEBUG_HOLD` and `BP_HIT` in the two-bit debug state
word. State 3 means the core is held *with* the run strap still high, which is
the point: a breakpoint hit does not look like a plain stop.

**golden package** — a checked-in set of request/response byte pairs plus the
model image they assume, generated from a model and required to match. R2 and R3
are the two that exist. See [[concepts/host-chip-protocol]].

**chip-confirmed** — a step whose *response bytes* the chip reproduced exactly,
with a citation. A step that has not been confirmed is not failing; it is
unproven, and the two are different states.

## Verification

**mutation testing** — deliberately breaking the thing under test to prove the
test notices. 16 suites, e.g. `regress/mutate_ctrl_tb.sh`. A test that cannot
fail is the failure mode this exists to prevent.

**the negative control** — the suite that breaks things on purpose and requires
the gates to notice. Here it is `regress/test_check_wiki_pages.sh`. See
[[getting-started]] Step 4.

**the claim ledger** — the idea that a claim is only real once something can
prove it wrong. This project enforces it per-claim rather than in one file:
every mutation names the testbench that must catch it.

**vacuous proof** — a formal property that holds for the wrong reason (asserted
unconditionally, or over an unreachable state). The campaign labels such proofs
`VACUOUS` rather than hiding them.

**`<<wip>>`** — the marker in a testbench case spec meaning *this case is known
not to be passing*. It is marked rather than hidden, so a green suite cannot
quietly imply otherwise.

**KNOWN-WIP** — a feature that is built but whose acceptance is deliberately
outstanding. Distinguished from a failure: it is a decision, recorded, not an
oversight.

**the pinned baseline** — a file enumerating *known* violations a gate cannot
yet fail on, enforced in both directions: a new violation is red, and a pinned
one that has been *fixed* is also red so the pin cannot outlive its defect.
Three exist: `wiki/.known-rule-violations.txt`, `wiki/.known-stale-diagrams.txt`,
`wiki/.known-dead-links.txt`.

**STALE** — in a gate, a pinned entry that no longer fails. In a diagram, a
render that no longer matches its source. Same idea: the record has drifted from
the tree, and something must say so.

**inconclusive (exit 4)** — a run that could not reach a verdict, usually
because a dependency changed underneath it. Distinct from a failure, and never
to be reported as a pass. See [[STATUS]].

**the single-run lock** — `flock` on `/tmp/chip-run-all.lock`, taken by every
mutation-capable run, so two runs cannot mutate and restore the same RTL at
once. Exit 75 with the current holder named.

**MUTABLE** — a harness's declaration of which repository files it edits, read
by the merge gate to decide whether a narrowed run must include that suite. A
missing `MUTABLE` line is unmappable and escalates to running everything; an
empty one means the suite mutates nothing and is never skipped.

**the merge gate** (`regress/verify_merge.sh`) — maps a merge to the suites that
must run for it, and refuses to let a merge be pushed green when the affected
checks were not exercised. Motivated by
[[reviews/2026-09-25/MERGE-FORENSICS-5B4731F]].

**the drift gate** — a generated page compared against its generator, so a
documented number cannot quietly go stale.

**TOOLCHAIN.md** — the pinned renderer versions, read by the diagram gate. A
toolchain difference is reported *inconclusive* rather than as a failure you
cannot clear by editing a diagram.

## The repository

**the deliverable** — `rtl/tt_um_protocol_emulator.v` plus `info.yaml`: the
`tt_um_*` top level with a real pad interface that the foundry would see.

**SRAM macro** — the instruction memory: a hard macro supplied as GDS, not
synthesised. Simulating it needs a behavioural model from the PDK, which lives
outside this repository, and the harness **refuses** to substitute a flop
fallback because a testbench that quietly ran against the fallback would have
verified nothing about the memory.

**the three ways a protocol is implemented** — firmware bit-bang; the word
engine; or dedicated gates. The choice is arithmetic, not taste: at 10BASE-T
speeds the single-cycle core has 48 instructions per byte and a software CRC-32
needs about 240. See [[concepts/ethernet-scope]].

**`$readmemh` (and why CWD matters)** — Verilog's file-load directive. Paths in
it resolve against the *process* working directory, so testbenches are run from
`sim/`. The single most common newcomer confusion here; see
[[getting-started]] Step 5.

**act window / the sample point** — the interval in a bit cell during which a
receiver will read the line. Timing protocols are won or lost by whether the
transmitter's high time brackets it.

**COLD-START.md** — the orientation document for a fresh session or a new
worker. It carries the standing rules (the merge gate, the single-run lock, the
interrupt protocol) and is where merge discipline is recorded.
