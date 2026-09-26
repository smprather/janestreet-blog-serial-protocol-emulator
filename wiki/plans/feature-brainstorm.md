---
title: Feature brainstorm — what this architecture makes possible next
created: 2026-09-25
updated: 2026-09-25
type: plan
tags: [plan, architecture, verification, tooling, protocol]
sources: [rtl/pe_ctrl.v, rtl/pe_cpu.v, rtl/pe_soc.v, rtl/pe_pinmux.v, rtl/pe_serdes.v, rtl/pe_eth_tx.v, rtl/pe_eth_mac.v, rtl/pe_dru.v, tools/fw/peasm.py, tools/fw/peemu.py, tools/host_gui/fake_pe.py, tools/host_gui/session.py, tools/host_gui/vectors.py, tools/host_gui/fuzz_protocol.py, tools/host_gui/soak_host.py, tools/host_bridge/acceptance.py, tools/live-canvas/gen_vcd_view.py, tb/r2-vectors/manifest.json, tb/r3-vectors/manifest.json, formal/results/summary.txt, reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md, wiki/STATUS.md, docs/demo-walkthrough.md, wiki/concepts/competition-overview.md, wiki/reference/protocol-pin-budget.md, wiki/reference/sram-budget.md, wiki/reference/floorplan-feasibility.md, wiki/decisions/adr-005-60mhz-turbo.md]
confidence: medium
---

# Feature brainstorm — cool and novel things this architecture makes possible

## What this page is, and what it is not

This is a **forward-looking inventory of features**, written from the outside
in: what a person could build on top of what is already here that they could
not build on top of anything else. It is not a work list and it makes no
schedule claim. It is the input to choosing a work list.

Every idea answers the same five questions, because the five are what a judge
will ask:

1. **What it is** — in one paragraph, concretely.
2. **What it beats** — the existing tool it is *better than*, and the specific
   mechanism of the beating. An idea with no named incumbent is a toy.
3. **How it lands here** — which blocks it attaches to, by name. An idea that
   cannot be attached to a block that exists is a wish.
4. **Effort shape** — not an estimate. Effort shape says whether it is a
   firmware-shaped change (a `.pe` file and a testbench), a host-shaped change
   (Python), an RTL-shaped change (cells, a formal property, a mutation suite),
   or a paper change (a contract, a manifest, a page).
5. **What it proves for the competition** — which competition claim it makes
   true that is not true today.

### The marks

- **C** = creativity, 1–5. 1 is "we could do this if we wanted to". 5 is "no
  competitor in this competition has this, and it is not obvious you could".
- **F** = feasibility **at the tapeout milestone**, 1–5. 5 is "a week and no
  new pads". 1 is "needs a second shuttle, a board, and luck".
- **F∞** = feasibility in *simulation* (where every idea here is provable
  eventually). The gap between F and F∞ is the interesting number: it is
  exactly "what cannot be shown until there is silicon", which is the honest
  limit of a competition entry.

The marks are **my judgement, and the judgement is the arguable part.** Where
an idea's value depends on a number I could not measure, I say so rather than
inventing one.

### The standing rule this page obeys

The project's own culture is the reason this page has a self-audit section at
the bottom: *a gate claiming to catch a no-op is the same error as a check that
cannot fail* — the rule that made two benign mutants get deleted rather than
tolerated ([[STATUS]], timing-protocol block). So every idea here is separated
into **the demo** (what a judge sees) and **the commitment** (what the repo
would then have to be able to fail at). An idea with a demo and no commitment
is entertainment, and this repo is not interested in entertainment alone.

---

## The ground every idea leans on

Six blocks exist. Everything below attaches to one or more of them, so it is
worth naming them once, precisely.

| block | what it is | the property that makes ideas possible |
|---|---|---|
| **`pe_cpu`** | 16-opcode, 16-bit-instruction, **single-cycle** core. `A/X/Y` are 8-bit; `PCW` is `clog2(IMEM_WORDS)` (10 bits at 1,024 words). Jumps are `JMP/JZ/JNZ`; there is no shift-**left**, no call/return, no multiply. | It is **deterministic and single-cycle**, so an instruction stream is a *time series* and a program is *replayable exactly*. Every time-oriented idea below rests on that one fact. |
| **`pe_soc`** | the CPU plus the pin matrix, a 1 µs `I2CTICK` (port `0x4`), a free-running `TIMER` (port `0x5`), the 10BASE-T RX window (ports `0x8`–`0xE`) and the word-engine window (port `0xF`). The whole IO space is **4 bits wide**. | A **4-bit port space** means firmware can discover hardware by reading it, and a **free-running 1 µs tick** means a program can measure itself. |
| **`pe_pinmux`** | 111 cells. Per-pin `{out, oe, od}` with real open-drain release and read-back of the *pad* when released. | A released pin **reads the wire**, so a program can be a *receiver* and a *contention detector* in the same instruction. |
| **`pe_ctrl`** | the framed host bus. Mode-0 SPI slave, `A55A` sync, CRC-16/CCITT-FALSE, sticky faults, `IRQ_N`. R1 = load/status. R2 = `READ_CPU`/`READ_IMEM`/`READ_DMEM`/`DUMP_CORE` with the `0xFFFF` wait-word rule. R3 = `DEBUG_STEP`/`DEBUG_BP_SET`/`DEBUG_BP_CLR`/`DEBUG_STATUS`, one breakpoint (`bp_addr`/`bp_en`/`bp_hit`), and `cpu_exec = dbg_step \|\| (run && !dbg_hold)`. **A `target` field already selects an internal target: target 1 is a deterministic loopback on the same MISO, consuming no pad, clock or external MISO.** | The host can **stop, step and read the machine mid-flight over a wire protocol**, and there is already a **no-pad hook for a second, different target** that costs nothing. |
| **the word engine** | `pe_serdes` + two `pe_codec_mux` + `pe_nrzi`/`pe_manch`/`pe_bitstuff`, driven through the port-`0xF` window. 1–32-bit words, runtime line code, disabled at reset. | Line code and word length are **registers, not gates**, and the engine exists exactly where firmware *cannot* reach (20 MHz half-cells, NRZI + stuffing). |
| **the golden packages** | `tb/r2-vectors/` and `tb/r3-vectors/`: request/response `.hex` pairs plus the **model image each vector assumes**, a manifest with `chip_confirmed` and a `chip_evidence` block, and a **pinned divergence list** that turns red if the observed divergence set ever changes. | A **contract is an artifact two independent implementations must both satisfy**, and a step is chip-confirmed only by citation. The same machinery would work for anything with a wire. |

Plus the cultural substrate, which several ideas directly extend: **16
mutation harnesses** (every claim must be able to fail), a **formal campaign**
(10 properties / 5 modules / 14 mutants, with vacuity labels), a **dep-guard
pre-flight** (a run may not report a verdict from scripts that changed under
it), a **single-run lock**, and a **merge gate** that maps a merge to the suites
it must run. And a `peasm` with `--const NAME=VALUE`, which was added so a
mutation could perturb a *fitted counted delay* — a hook that is currently
used to break things and could obviously be used to sweep them.

---

## Theme A — Time made into a resource

The `pe_cpu` is single-cycle and the breakpoint hardware already exists. That
combination is unusual: most cores are not single-cycle, and most cheap debug
hardware is one address and no history. Time is the resource this chip already
has and its competitors do not.

### A1. Reverse execution — step *backwards*

- **What it is.** The host records the machine's architectural state at every
  instruction boundary — `pc/a/x/y/timer` — into a host-side ring, seeded at
  load. When the user asks to go *back*, the host resets, re-loads the identical
  image, and replays forward with `DEBUG_STEP` to the target PC, then forces
  the recorded `a/x/y/timer` back in through... nothing. It cannot. So the
  honest version is: **replay to the boundary, and report the recorded
  registers as the rewind answer**, with a hardware-free fast path. The *real*
  version adds 3 shadow registers to `pe_cpu` (PC, A, X, Y — Y is not even
  wired as a debug output today) so a single `DEBUG_STEP` with a direction bit
  genuinely un-executes the last instruction from a one-deep shadow.
- **What it beats.** **J-Link / Renesas E1 / OpenOCD checkpointing** and every
  simulator's "rewind" (Verilator's, Questa's). They do it with a trace buffer
  or a full re-simulation; the cheap-JTAG world does not do it at all. The
  beating mechanism is *one extra register file instead of a trace buffer*,
  which is why a 130 nm, 24-tile die can afford it and a $40 debugger cannot be
  assumed to have it.
- **How it lands here.** `pe_ctrl`'s R3 block (add a direction bit to `0x21`,
  or a new `0x25 DEBUG_STEP_BACK`), `pe_cpu`'s execute gate and register file
  (three shadow flops + one mux on the `A/X/Y` write enables), the R3 golden
  package (`r3_vectors` needs only a new vector list — the framework is
  already generic), and the `formal/pe_cpu` harness (the shadow registers are
  four new invariants: "a rewound register equals the value the forward step
  wrote").
- **Effort shape.** RTL-shaped and small: ~30 cells, one new opcode in a frame
  the host already speaks, one mutation suite entry ("the shadow is written
  even when the step was a hit" is a plausible mutant, and the suite must catch
  it), one formal property. The *host* side is the bigger job: the replay
  driver, and a GUI affordance that makes "back" feel instant rather than like
  a 400-step march.
- **Proves.** That the architecture is not just cheap, it is **a different kind
  of machine**: reprogrammable protocol logic whose debugger can be designed
  from first principles instead of inherited from a vendor's trace buffer. The
  competition explicitly welcomes AI-assisted verification; a machine whose
  debug story is *this* auditable is the strongest possible answer to "how do
  you know it works".
- **Mark.** **C4 / F3 / F∞4.** Feasibility is gated by one honest constraint —
  Y is not a debug output today, so the first version has two shadowed
  registers and a *documented* asymmetry, or three wires added to `pe_soc`.
  The documented asymmetry is worse than the wire: an asymmetry in a debugger
  is the kind of thing that costs somebody an afternoon, which is precisely
  the trap `pe_ctrl.v`'s header already documents for the debug hold.

### A2. Protocol flight recorder

- **What it is.** Not a CPU trace — a **wire** trace. A ring buffer in the SoC
  that records, per entry: a timestamp from the 1 µs `I2CTICK`, a direction
  (from the pin matrix's `oe`), a level, and for `OUT` writes the *port* and
  the *value* the firmware wrote. The host drains it with `READ_DMEM` when the
  core is stopped and replays it as a real protocol transcript. The recorder is
  a *firmware* job in the first version: a persona that sits in a tight loop
  reading `PIN` and appending to a scratch buffer, arms itself from the bus.
- **What it beats.** **Wireshark-on-a-logic-analyzer** and every "I added
  printf() to the driver" debugging story. Those give you a transcript with no
  *timing*; a Saleae gives you timing with no *intent*. This gives you both,
  and it gives you the firmware's own view of what it *meant* to do at each
  edge, which is the half a logic analyzer structurally cannot have.
- **How it lands here.** The pin matrix already distinguishes driven from
  released (`oe`), so direction is free. `DMEM` is 16 bytes and too small, so
  the ring lives in the **frame buffer** (2 KB, `pe_fbuf`, already dual-ported
  byte-wise and already read by firmware through `BUFBYTE`) with the MAC's
  writer temporarily starved, or in a persona-specific region. `0x4 I2CTICK` is
  the timestamp. `READ_DMEM` is the drain. Zero new RTL in version 1; version
  2 (a hardware recorder in the pin-matrix path) is ~200 cells and a formal
  property that the buffer cannot overwrite a live entry.
- **Effort shape.** Firmware + host shaped in v1 (a persona, a drain, a
  renderer). RTL + a formal property in v2. The renderer is the risky part and
  the fun part: `tools/live-canvas/gen_vcd_view.py` already renders a VCD
  window to SVG as a *teaching* diagram with a stated refusal to lie (it draws
  the sampled value on every clock edge it can find). A flight-recorder view is
  the same renderer with a different source.
- **Proves.** The competition's core claim — *a protocol persona is a program* —
  made visible. You can watch `servo_sweep.pe` decide to emit a 1750 µs pulse,
  and see the pin do it, from one artifact, with the program as the caption.
- **Mark.** **C5 / F4 / F∞5.** The most demo-shaped idea in this document, and
  the risk is exactly the risk `gen_vcd_view.py` already names: a recorder that
  samples at 1 µs cannot see a 250 ns `half_phase` edge, and **a diagram that
  lies about resolution is worse than no diagram**. The v1 recorder must
  declare its sample period on the face of the render.

### A3. R4: watchpoints, hit counters and trigger conditions

- **What it is.** The one honest gap the demo walkthrough states out loud:
  *"a breakpoint is one PC address — there is no watchpoint and no data
  breakpoint in R3."* R4 generalises the one `bp_addr`/`bp_en`/`bp_hit` triple
  into an N-entry table whose entries can be **PC matches**, **data matches**
  (an address plus a value or a mask), or **IO-port matches** (a port number
  and a value) — and every entry carries a **hit counter** and an **ignore
  count** and a **condition field**. `DEBUG_STATUS` grows a "which entry fired"
  index. The host gains a trigger list.
- **What it beats.** **`printf`-based logging and hardware watchpoints in a
  $4 MCU.** The MCU watchpoint is the honest incumbent: it exists, and it is
  the thing a judge who has debugged firmware will compare against. The
  beating mechanism is not "we have watchpoints" — it is **the condition field
  and the counter**, so the chip can express "stop on the *fourth* `PINOUT`
  write of `0x2` to port `0x1`", which is the actual question you ask when a
  UART echo drops a byte, and which no 8-bit-budget watchpoint unit can ask.
  Software breakpoints cost the firmware a compare-and-branch per write; this
  costs the host a frame.
- **How it lands here.** `pe_ctrl.v` already owns the decode, the compare
  against `dbg_next_pc`, the flags word and the hold. It needs `dbg_a/x/y`,
  the port write strobe and the written value as *observation* inputs — all
  three already cross the module boundary for R2 (`dbg_a`, `dbg_x`, `dbg_y` are
  inputs at the top of the file) except the port write, which needs one new
  wire from `pe_soc`. The response format grows the way R2 grew `STATUS` from
  stubbed to eleven words, and the golden-package machinery
  (`tools/host_gui/vectors.py` + `r3_vectors`) is a configuration plus a
  vector list, so R4 is a new configuration, not new infrastructure.
- **Effort shape.** RTL-shaped with a wide verification tail: 4–8 entries is
  roughly 150–300 cells; the *real* cost is the golden package (hundreds of
  vectors, because the combinatorics of entry-select × condition × ignore-count
  are the whole risk) and a mutation suite that must catch "the ignore counter
  decrements on the wrong edge".
- **Proves.** "This is a debugging platform, not a loader" — and it makes the
  R3 bring-up trap (a hold released only by `BP_CLR` or reset) *less* of a
  liability, because with four entries you stop needing the clear/re-arm dance
  to keep a breakpoint armed.
- **Mark.** **C2 / F3 / F∞3.** Deliberately the lowest-creativity item in
  Theme A, because it is the obvious next phase and the wiki should say so
  plainly rather than dress it up. High value, low surprise.

### A4. Execution coverage harvested from the debug path

- **What it is.** A 1,024-bit bitmap — one bit per IMEM address — that the chip
  sets as the PC passes each address, plus an 8-bit × 8-bit matrix of
  "port `p` was written/read" and a per-opcode hit count. The host reads it with
  two `READ_IMEM`-shaped frames and renders "your firmware exercised 61% of
  itself; the `JNZ` at 0x1C2 never ran; port `0xD` was never read". The bitmap
  is 128 bytes — it fits the frame buffer, not DMEM, so it is a windowed read.
- **What it beats.** **Simulation-only coverage.** The beating mechanism is the
  whole point and it is unusually strong for this project: *the coverage comes
  out of hardware that already exists for a different reason.* There is no
  coverage engine, no VCD, no simulator, and no instrumentation build — the
  PC is already being compared against a value every cycle for the breakpoint,
  and a second compare is nearly free. So the chip reports its own coverage on
  the same bus it is loaded over, at run time, from the *real* pin activity.
  Nobody else in this competition can do this, because nobody else has a chip
  whose debugger is a deliverable.
- **How it lands here.** The same `pe_ctrl` compare datapath as A1/A3, feeding
  a `host_we`-shaped write into a window in the frame buffer. The word engine's
  port-`0xF` window pattern (index-write-then-burst-write) is *exactly* the
  shape a bitmap dump wants, and it already auto-increments.
- **Effort shape.** RTL-shaped but small (a PC-equality write-enable plus an
  address-muxed byte port), with a host-shaped renderer that is where the value
  is. The *interesting* verification problem is the trap A2's generator also
  has: a coverage bit that is set for a PC that was *about to execute* rather
  than *did*, which is precisely the `dbg_next_pc`-vs-`dbg_pc` distinction
  `pe_ctrl.v`'s R3 header spells out at length. A coverage map with that off by
  one is a beautiful lie, and the mutation suite must contain that exact mutant.
- **Proves.** The competition's verification emphasis, answered in hardware:
  Jane Street "explicitly welcomes formal methods, constrained-random tests, and
  AI-assisted verification". A chip that measures its own coverage is a
  *third* category, and it is checkable by a judge by loading a program and
  reading one frame.
- **Mark.** **C5 / F2 / F∞5.** The creativity is maximal and the feasibility at
  tapeout is genuinely poor, because the 128 bytes of bitmap want SRAM and the
  frame buffer is shared with the MAC. Two honest routes: a *coarse* 128-byte
  coverage in the frame buffer, or a 16-bit PC-high nibble counter (16 bytes,
  in DMEM, almost free) which answers the question that actually matters —
  *which 1/16th of my program never ran?*

### A5. A persona that debugs itself

- **What it is.** A `.pe` program whose job is to run *another* persona's
  protocol, sample its own pins, check every interval against a table of
  constants in its own image, and **report a pass/fail bitmask and the worst
  measured margin in the frame buffer** — which the host reads with the
  ordinary read path. The protocol becomes self-certifying: `ws2812_selfcert.pe`
  emits the 24 cells and then tells you the 1-cell high was 48 clocks, the reset
  was 62.3 µs, and the grid was clean.
- **What it beats.** **The post-hoc measurement script.** Every claim in
  `docs/demo-walkthrough.md` is currently measured by a *testbench* — a
  simulator artifact. This moves the measurement **into the artifact that will
  actually be on the board**, so a claim proven in simulation is *also*
  verifiable on silicon by the same code that will be running the protocol.
  The incumbent is genuinely weak here: a Saleae measurement is a human
  reading a screen.
- **How it lands here.** All of it is already there: the 1 µs tick for
  timestamps, the pin matrix for sampling, `peasm --const` for the tolerance
  table, the frame buffer for the result, and — this is the neat part — the
  golden-vector discipline transfers, because a persona's self-cert is just
  *another* conformance vector with a different subject.
- **Effort shape.** Firmware-shaped, one persona per protocol, and a
  TB-shaped acceptance (the TB asserts the persona's *own* verdict is TRUE,
  and then that a mutation makes it FALSE — which is the strongest form of
  this project's mutation discipline, because the mutant and the detector are
  the same code).
- **Proves.** "Cycle-accurate" as a *shipped property* rather than a claim
  about a simulation. On a board, a judge can be handed the persona and the
  chip will grade itself.
- **Mark.** **C4 / F5 / F∞5.** The cheapest high-value item in this document.
  Do it first.

---

## Theme B — The wire becomes data

Every persona is a **waveform**, and the repo already measures waveforms on the
pads better than a cheap analyzer would. The only thing missing is getting that
measurement to a human, on a board, as a picture.

### B1. Live waveform in the browser, over the existing bus

- **What it is.** A ring buffer of pin samples (direction, level, timestamp)
  in the frame buffer; a persona or a tiny hardware sampler fills it; the GUI
  polls `READ_DMEM`/the frame window while the core runs — which is legal,
  because `READ_CPU` is the one non-halting read and the read window is a
  `host_rd` port the core never sees — and draws a scrolling multi-channel
  waveform in the browser next to the disassembled persona.
- **What it beats.** **Saleae / Rigol DSLogic / Bus Pirate**, decisively on
  price and on *integration*, weakly on bandwidth: at a 1 µs sample you see
  I2C, WS2812 (one sample per bit cell), servo and NEC envelopes, and you do
  **not** see 10BASE-T Manchester. The honest pitch is therefore not "a
  logic analyzer" but **"a protocol *persona* viewer"**: the thing a logic
  analyzer is bought for is usually a protocol nobody has decoded, and this
  chip decodes by construction because it is running the decoder.
- **How it lands here.** `pe_soc`'s windowed reads, the port-`0xF` index/burst
  pattern, the GUI's existing WebSocket (`tools/host_gui/server.py` already
  serves a local page and has an liveness JS test), and `gen_vcd_view.py` for
  the rendering grammar.
- **Effort shape.** Host-shaped, one persona, plus a 200-cell sampler if you
  want it off the critical path. The hard part is not the drawing; it is the
  **sample-rate honesty** and the `0xFFFF` wait-word contract not being
  confused with data.
- **Proves.** The demo, live, in a browser, with a chip that is doing something
  a judge has never seen a chip do.
- **Mark.** **C4 / F4 / F∞5.** Bandwidth honesty is the whole credibility of
  this one; state the sample period in the UI.

### B2. Golden waveforms as a regression gate

- **What it is.** The R2/R3 golden packages prove the *bus* byte-exact. Extend
  the same idea one layer out: each persona's pad-level capture is a checked-in
  artifact, and a regression step fails if a persona's waveform changes in any
  way a human did not sanction — including changes in *timing* that still pass
  every datasheet window.
- **What it beats.** **Pass/fail testbenches.** The incumbent failure mode is
  visible three times in this project's own record: a carrier that alternated
  788/782 clocks passed every window; a two-`always`-block race turned 75
  clocks into alternating 74/76 while every assertion still passed; a 32-bit
  overflow changed a measured interval. A golden capture catches all three,
  because it asserts the *shape*, not a derived property.
- **How it lands here.** The manifest/`--check`/drift-gate machinery of
  `tools/host_gui/vectors.py` and the `regress/` generated-doc drift checks,
  pointed at a `.json`/`.vcd` capture instead of a bus frame. The TBs already
  record narrow VCD scopes and edge-triggered recorders.
- **Effort shape.** Test-shaped, and it is the kind of gate that will be
  *annoying*, which is why it must come with the sanctioned-update path
  (`--accept` that records why) or it will be routed around. The failure mode
  to design against is a golden that gets regenerated automatically and stops
  meaning anything.
- **Proves.** That this project's claims are pinned to *artifacts*, not to
  prose — which is the single most differentiating thing about how it works.
- **Mark.** **C2 / F5 / F∞5.** Low creativity, very high value, and it composes
  with everything else in this document (a golden-wire corpus is the substrate
  for B1, E1, E2).

### B3. Timing-margin maps across the tick phase

- **What it is.** The I2C work already sweeps **all 60 clock phases** of the
  1 µs tick and found 83.2–83.6 kHz across all of them
  (`tools/checks/i2c_xfer_check.py`, 60 phases). Generalise that into a
  rendered **2-D margin map** for every persona: phase × protocol event, each
  cell coloured by how much datasheet margin was left. A cell that is nearly
  red is a firmware that works on the golden tick phase and is one clock from
  not working.
- **What it beats.** **Datasheet-window assertions**, which are the industry's
  default and which this project's own records show are insufficient (the
  788/782 benign mutant; the 74/76 race). A window assertion says "inside
  spec"; a margin map says "**how far** inside spec, everywhere", which is the
  question that predicts field failure.
- **How it lands here.** The existing 60-phase sweep harness, the `.pe` images
  the sweep already runs, and the mutation suites' `--const` hook for sweeping a
  *fitted* delay rather than perturbing it.
- **Effort shape.** Host/tooling-shaped. Almost all of the work is a renderer
  and a heat-map legend. A hardware version (a persona that sweeps its own
  timing against a live peer) is firmware-shaped too.
- **Proves.** "Cycle-accurate" quantified rather than asserted: a picture of
  the whole timing envelope, not a single number.
- **Mark.** **C3 / F4 / F∞5.** Cheap, and it is the one idea here that
  immediately retires a class of latent bug rather than adding a capability.

### B4. The chip as a cheap logic analyzer, using hardware it already has

- **What it is.** Not a sampler in new RTL: a persona that polls `PIN` (port
  `0x0`) in a counted loop and uses the free-running `TIMER` (port `0x5`, one
  increment per half UART bit) and `I2CTICK` (port `0x4`) as the sample clock,
  storing edge timestamps. Because the loop's own length is the sample period
  and it is straight-line counted code, the sample rate is *exact and known* —
  which is the property a $30 analyzer does not give you.
- **What it beats.** **Bus Pirate and the cheapest logic analyzers**, on
  resolution *and* on determinism; and it beats a *host* sampler on latency,
  because the round trip through USB is 100 µs and the 250 ns Manchester
  half-cell is 400× faster than that.
- **How it lands here.** The 16-port map, the pin matrix's read-back-when-
  released, `peasm --const` to parameterise the loop length, and the frame
  buffer as the sink.
- **Effort shape.** Pure firmware. One persona. The measurement is
  `while (IN PIN) == last: pass` plus a tick, and the pitfall is the one this
  project has already written down: `run` raised at a clock edge silently
  drops the first instruction, and `PINOE`/`TXPIN` are **whole registers** so
  two writes clear each other. Both cost a real firmware author a day once.
- **Proves.** That the *general-purpose* claim means it: a chip that ships
  twenty protocols also ships a measuring instrument, with no protocol-specific
  gates.
- **Mark.** **C4 / F5 / F∞5.** Do it. It is one afternoon and it makes A2 and
  B1 unnecessary for a first demo.

### B5. Self-timing: the persona grades its own timing

- **What it is.** A5's measurement, applied to *time* rather than to protocol
  correctness: a persona samples the free-running timer around its own delay
  loops, computes worst-case error against its nominal constants (which are
  already `peasm --const` symbols), and publishes a signed margin in the frame
  buffer. The GUI shows a green/red per-act margin bar, live, on the board.
- **What it beats.** **Static timing analysis of software.** STA analyses gates;
  nothing in the industry analyses *the timing of a counted delay loop on a
  specific core* and reports the answer on the device.
- **How it lands here.** `I2CTICK`/`TIMER`, the frame buffer, the read path.
  And the honest limit is already documented in the repo: the 1 µs tick's
  phase residual is up to a full microsecond, which is **80% of a WS2812 bit
  cell** — so a persona that measures against `I2CTICK` alone will report a
  false failure, and must measure against counted cycles (which is why the
  48-clock claim is a claim about *clocks*). Getting this distinction right is
  the whole content of the idea.
- **Effort shape.** Firmware-shaped, small, and it needs one honest new
  concept page because "which clock did you measure against" is the question
  every timing claim in this repo silently depends on.
- **Proves.** "We know our timing to the clock, and we can show it to you from
  the device."
- **Mark.** **C3 / F4 / F∞4.**

---

## Theme C — Breaking things on purpose

This project has a mutation-testing culture nobody else in the competition has.
Every one of the ideas below is that culture aimed *outward* — at the toolchain
rather than at the RTL.

### C1. The adversary target — turn the existing `target` field into a weapon

- **What it is.** `pe_ctrl` already has a `target` field, and **target 1 is a
  deterministic internal loopback on the same MISO that consumes no pad, clock
  or external MISO** — hardware built for testing, currently used for `PING`.
  Extend it: **target 1 becomes a configurable misbehaving peer.** A frame
  selects which misbehaviour: answer `BAD_FRAME` to a good request, corrupt
  the CRC, truncate mid-frame, emit 16 wait words when 15 is the contract,
  echo a stale sequence, assert `IRQ_N` and stay asserted, accept a write and
  silently drop it, answer `OK` to an out-of-range read, go silent for 40
  frames. The chip can then attack its own host, on demand, over the real
  framed bus, with the real CRC and the real wait-word rule.
- **What it beats.** **Every host test suite that mocks the device.** The
  incumbent is the mock: `FakePE` is a *model*, so a host bug that only appears
  against a device with slightly different timing (a frame that arrives a
  microsecond late, a MISO that releases a nanosecond after `CS_N` rises) is
  invisible in every test the host can write. The beating mechanism is exactly
  this: **the adversary is silicon-shaped, so the host's frame handling is
  tested against a peer whose edges the host cannot predict** — and the host's
  existing `fuzz_protocol.py` campaign (which already attacks both decoders and
  the model with random and single-byte mutations, truncation, wait-word edges
  and concatenation) can be pointed at it instead of at a Python object.
- **How it lands here.** `pe_ctrl.v`'s existing target mux and loopback
  responses. The misbehaviour set is a small register file selected by a
  `TARGET` payload word (target 0x20 currently answers `UNSUPPORTED` and takes
  no pad). Verification: a new golden package configuration (the machinery is
  generic), a `FakePE` that grows the same behaviours so the host tests both,
  and — the point — **a differential test that the two agree**, which is
  exactly the `chip_confirmed` discipline applied to a target that is *meant*
  to be wrong.
- **Effort shape.** Small RTL (a response-shaping mux and a few
  deliberately-wrong values), large verification value. The subtlety worth
  naming: a misbehaving target that is *too* wrong tests only the host's
  error path, and one that is *subtly* wrong tests the part that matters.
  Each misbehaviour needs a stated intent, or it becomes a random fault
  injector, and the repo's own record is unambiguous about that being a
  different (and less valuable) thing.
- **Proves.** The host bus is a *product interface* with a conformance suite,
  not a private conversation between two pieces of code that were written on
  the same afternoon. **This is my single strongest recommendation in this
  document.**
- **Mark.** **C5 / F4 / F∞5.** The feasibility is high because the hardware is
  already there and unused; the creativity is high because the unused thing is
  *exactly* the shape of the need. This is the "the feature is already half
  built and nobody noticed" tier, which is the best tier.

### C2. A fault-injection playground in the GUI

- **What it is.** The host GUI grows a "misbehave" panel: buttons and a
  scripted timeline for every fault the chip can be made to exhibit — bad CRC,
  out-of-range read, `NOT_READY` while running, a sticky `FAULT_RANGE` that
  survives until `CLEAR_FAULT`, a breakpoint hold that ignores the run strap in
  both directions, a wait-word response at the ceiling. Each one links to the
  page that documents the trap, because the demo walkthrough's own advice is
  that these traps "cost a bring-up board a long time if nobody has written
  them down".
- **What it beats.** **A datasheet's error table.** Nobody ships a GUI that
  lets you *feel* their error handling.
- **How it lands here.** C1, plus `tools/host_gui/session.py`'s state machine
  (which already turns a timeout into a typed fault rather than a fake success,
  and already models `DISCONNECTED/PREPARED/LOADING/LOADED/RUNNING/STOPPED/
  FAULTED`), plus the existing `UserWarning`-on-held-core behaviour that was
  built specifically to warn without refusing.
- **Effort shape.** Host-shaped, thin, entirely a presentation of C1's
  register file. The discipline is to keep every button honest about what the
  *chip* does, not what the model does — the session already reads `self.state`
  from the chip's own state word for exactly this reason, and there is a
  model-free test pinning it.
- **Proves.** "We built the thing to be debugged, including the parts that
  are inconvenient."
- **Mark.** **C3 / F5 / F∞5.** Presentation on top of C1. Ship C1 first.

### C3. Margin hunting: transmit *near* the spec on purpose

- **What it is.** Personas that deliberately transmit at the *edge* of a
  datasheet — the 1-cell high at 48 clocks when 48 is nominal and 47 passes; a
  DHT11 sample taken 1 µs after the sensor's latest permitted response; an
  I2C bit stretched to just inside the clock-stretch window; a MIDI running
  status at 31,251 baud when 31,250 is nominal. Each ships with a peer model
  that answers, and the act is *does my peer still recover?*
- **What it beats.** **The datasheet's own assumption that anyone will transmit
  in the middle.** Real interop bugs live at the edges, and the industry's
  test practice is to test the middle.
- **How it lands here.** `peasm --const NAME=VALUE` — the hook that was added
  for a mutation is exactly the hook a margin sweep needs. The existing
  per-phase sweeps. The existing sensor/slave models (DHT11, DS18B20, SR04,
  NEC, the I2C slave FSM).
- **Effort shape.** Firmware + testbench, per protocol, and it is a *matrix*
  (persona × margin × peer) so it wants a generator, not a hand-written TB.
  The `0xF`/window conventions and the mutation suites' private-copy discipline
  are the reusable parts.
- **Proves.** The timing is not merely inside spec; the *interoperability* is.
  And it converts the project's existing "14 firmware mutants, 14 detected"
  machinery from a gate into an *instrument*.
- **Mark.** **C4 / F4 / F∞5.** The synthesis of two things the repo already
  has, which is the cheapest kind of novelty.

### C4. Mutant firmware as a shipped demo mode

- **What it is.** A build target that produces a *deliberately defective but
  otherwise valid* persona — WS2812 at 74 clocks instead of 75, a servo frame
  at 20.5 ms, an I2C NACK that never arrives — assembles it, and ships it
  beside the good one. The GUI can load either. A judge watches the good one
  work and the bad one fail *on the same board, in the same second*, with the
  failure printed by the same testbench that catches the mutation in CI.
- **What it beats.** **A CI log.** Mutation testing's output is normally a
  number in a report nobody outside the team reads. This puts the number on
  the podium: *this chip's timing claim is not an assertion, it is a difference
  you can watch.*
- **How it lands here.** `regress/mutate_timing_tb.sh` (48 mutants, 48
  detected), `peasm --const`, the private-copy discipline, and the demo
  walkthrough's existing structure of "each claim is backed by a checked-in
  artifact".
- **Effort shape.** A Makefile-ish target plus a small registry. Almost free.
  The only design work is the curation rule: **which mutants are pedagogically
  honest?** A mutant that produces a difference nobody can see teaches the
  wrong lesson, and a mutant whose failure is a hang teaches nothing. The repo
  has already learned to *delete* benign mutants rather than tolerate them;
  this idea is the place that rule has to be written down.
- **Proves.** More than any single claim: it proves the *methodology* is real.
- **Mark.** **C5 / F5 / F∞5.** The highest ratio of perceived value to effort in
  this document.

### C5. Chaos mode on the live host

- **What it is.** Point the existing `fuzz_protocol.py` campaign and
  `soak_host.py` at a *live* bridge instead of a `FakeBridge`: the GUI gains a
  "chaos" switch that drops, duplicates, delays and reorders responses and
  fires asynchronous events (`board.reset`, `chip.irq`, `chip.status`,
  `protocol.error`) at a configurable rate, and the session must degrade into
  a typed fault every time.
- **What it beats.** **Happy-path integration testing**, and it beats it in the
  only way that counts: on a *real* transport, where the failure modes are the
  ones a `FakeBridge` cannot produce (a partial line, a stalled read, an event
  interleaved into a response).
- **How it lands here.** `FakeBridge` (the exact seam to replace),
  `SerialTransport`, the async event surface the bridge already emits, and the
  typed-fault contract.
- **Effort shape.** Host-shaped, medium. The one thing that needs discipline:
  chaos mode must be *visibly* on and must be impossible to leave on by
  accident, because a chaos-enabled demo that silently reports a pass is the
  worst artifact this repo could ship.
- **Proves.** The host is a real program that survives a real environment.
- **Mark.** **C3 / F4 / F∞4.**

---

## Theme D — Writing protocols instead of implementing them

The competition asks for a general-purpose protocol emulator. The furthest
logical step is not "another protocol" but "**a way to make protocols**".

### D1. One description, three consumers

- **What it is.** A small protocol-description DSL — line timing, frame
  structure, pin roles, edge rules — that emits **all three** of: (a) a `.pe`
  persona, (b) a Verilog peer model for the testbench, and (c) the wiki page.
  Today those three are written by hand and can disagree: the I2C work's
  "three timing traps that cost real rework" and the timing block's "five
  defects in the testbenches" are exactly the signature of three hand-written
  artifacts describing one protocol.
- **What it beats.** **Datasheet-driven code generation** in the narrow sense,
  and more importantly it beats **this repo's own status quo** — which has
  demonstrably cost defects, in the firmware *and* in the TBs, in roughly
  equal measure.
- **How it lands here.** `peasm` (target A), the peer models the TBs already
  contain (I2C slave FSM, DHT11, DS18B20, SR04, NEC carrier — five of them
  already exist as hand-written models, which is the evidence that a
  description language is the right abstraction), and the wiki generator
  pattern already established by `tools/gen/`.
- **Effort shape.** Tooling-shaped and *large* in the way that matters: the DSL
  is easy, and the hard part is that a generated persona must still pass the
  same cycle-exact measurement a hand-written one does. That constraint is
  free — it is the existing TB, reused unchanged.
- **Proves.** That the architecture's generality is a *toolchain* property, not
  a slogan. A judge who watches a new protocol appear in an afternoon, from a
  page of description, with its conformance test written by the same tool, is
  watching the actual thesis.
- **Mark.** **C4 / F2 / F∞3.** Ambitious and the least certain, because "what
  subset of a protocol fits a 16-opcode core and a 4-bit port space" is an
  open question the DSL forces into the open. That is a *feature*: the DSL is
  also the project's sharpest statement of its own limits.

### D2. Natural language → persona, gated by measurement

- **What it is.** D1's generator driven by a language model, with the
  acceptance test being the existing measurement harness: an LLM-written
  `servo_sweep.pe` is not accepted because it assembles, but because
  `tb_pe_soc_servo` measures 19,999.95 µs and five widths within 0.15 µs of
  nominal *and* a mutation proves the TB can fail.
- **What it beats.** **Every "AI wrote the firmware" claim in this competition.**
  The beating mechanism is structural: the project's verification culture is
  already a machine-checkable acceptance test, so an LLM is just another
  generator feeding an existing gate. The competition blog explicitly invites
  AI-assisted verification; this is the same sentence aimed at AI-assisted
  *implementation*.
- **How it lands here.** Everything. `peasm`, the TBs, the mutation suites,
  the 1 µs tick, `--const`.
- **Effort shape.** Prompt-and-gate shaped; the *interesting* engineering is
  the loop: generate, assemble, measure, and on failure feed the *measurement*
  (not a stack trace) back. A measure-and-retry loop over the actual
  acceptance criterion is a small piece of code and a very large effect.
- **Proves.** The verification culture is the asset, demonstrated by pointing a
  stochastic generator at it and watching the gate reject bad firmware.
- **Mark.** **C5 / F4 / F∞5.** The novelty is the *coupling*; either half
  alone is a 2021 demo.

### D3. A datasheet table as a conformance matrix

- **What it is.** A parameter table (min/nom/max per interval) is *data*. Feed
  it to the sweep harness and it becomes a matrix of conformance runs:
  every persona × every parameter at min, nom and max, with the peer's
  behaviour checked at each corner. The DS18B20's presence pulse is already
  asserted against a datasheet range (60–240 µs measured 120.0); this makes
  that a framework instead of a habit.
- **What it beats.** **Datasheet conformance suites** (USB-IF, and every
  protocol's own certification suite), which are large, licensed, and only
  testable against a real device.
- **How it lands here.** The existing per-phase sweeps, `--const`, the
  measured-not-nominal discipline (every persona TB measures the pin rather
  than trusting a constant), and the mutation suites' private-copy restore.
- **Effort shape.** Tooling-shaped, moderate, and it has one beautiful
  property: **the corner cases are generated, so nobody has to remember
  them.**
- **Proves.** "Cycle-accurate" at the datasheet corners, generated.
- **Mark.** **C3 / F4 / F∞5.**

### D4. The chip assembles its own next persona

- **What it is.** A `.pe` program — `shmini.pe`, maybe 200 words — that
  implements a *subset* of the assembler's syntax (labels, `LDI`/`OUT`/`IN`/
  jumps) and, over the framed bus, **compiles a source stream into IMEM and
  then jumps to it**. The chip becomes a machine that can be told what to
  become, at run time, without a host toolchain in the loop.
- **What it beats.** **The loader's own assumptions.** Today a persona is
  assembled by a Python tool on a Linux box and shipped as `.hex`; this makes
  the *chip* the assembler, which is the logical end of "reprogrammability
  after fabrication is the point" — reprogrammability by the artifact, from
  text, with nothing but the chip.
- **How it lands here.** The ISA is 16 opcodes and `peasm` is one pass with a
  two-pass label resolver — a *very* small program in this ISA, because there
  is no call, no stack and no recursion needed. The bus already streams words
  in. The frame buffer is the source-text scratch.
- **Effort shape.** Firmware-shaped, and the honest cost is that a two-pass
  assembler needs either a fixed-point pass (labels forward-referenced) or a
  second pass over a buffered source — with 1,024 words of IMEM and 16 bytes
  of DMEM this is a real memory problem, and solving it *is* the project. The
  D2 measure-and-retry loop is how you debug a compiler you wrote in a
  16-instruction ISA.
- **Proves.** The thesis, maximally: the chip is not a device that runs
  firmware, it is a device that **is** whatever you last told it to be.
- **Mark.** **C5 / F1 / F∞3.** Lowest feasibility in this document and the
  highest ceiling. Ship it *after* A1, because with reverse execution you can
  debug a compiler running on the thing it is compiling for.

---

## Theme E — Conformance as the product

### E1. A golden **wire** corpus, not just a golden bus corpus

- **What it is.** The R2/R3 packages pin the framed bus byte-exact, with a
  model image, a manifest, `chip_confirmed` with cited evidence, and a pinned
  divergence list. The identical machinery, pointed at the *personas*: each
  persona's expected pad-level behaviour, as vectors, generated from a model
  and required to match the chip.
- **What it beats.** **Every "it works on the bench" protocol emulator.** The
  incumbent for a firmware-only emulator is a README and a video.
- **How it lands here.** `tools/host_gui/vectors.py` is already a *framework*
  with phases as configurations (the docstring says exactly this, and the R2
  artifacts are deliberately left byte-identical across the refactor so the
  extraction is proven not to perturb them). A new phase module for the wire is
  a configuration plus a vector list. The TB side already replays request files
  and compares word for word; the wire version compares *edges*.
- **Effort shape.** Test/tooling-shaped, moderate, and it reuses the single
  most carefully built piece of the host.
- **Proves.** That "chip-confirmed" is a property of the *protocol*, not only
  of the loader. And the manifest is the artifact a judge can read.
- **Mark.** **C3 / F4 / F∞5.** The most *reusable* idea here — it is the
  substrate for E2, E3 and half of Theme B.

### E2. Differential conformance against a real-device model, auto-minimized

- **What it is.** Run one persona two ways: against a model of the real device
  (the DHT11 model, the I2C slave FSM, the Ethernet frame source) and against
  the chip. Diff the two **pin-level captures**. When they differ, minimize the
  diff automatically to the shortest input that still produces it.
- **What it beats.** **Conformance suites with a device in the loop** (you
  need the device, and you need a human to bisect). The beating mechanism is
  the minimizer plus the fact that the "golden" side is a *model of the
  device*, so the harness tests **the protocol**, and the chip is the
  implementation under test.
- **How it lands here.** Existing models, existing TBs, and the existing
  edge-triggered recorders and narrow VCD scopes; plus the project's own
  discipline of checking "is this check able to fail", which a differential
  harness inherits for free.
- **Effort shape.** Test-shaped, medium, with a classic hazard: a differential
  test that compares two things built by the same author proves less than it
  looks. The mitigation is the repo's own rule — the *peer* model must be
  written from the datasheet, and the mutation suite must be able to make the
  diff light up.
- **Proves.** Interoperability, not self-consistency.
- **Mark.** **C4 / F4 / F∞4.**

### E3. Self-conformance: one persona against another, in one chip

- **What it is.** The pin matrix has bidirectional, open-drain, read-back pins
  and there are eight of them. Run a transmitter persona on one pin and a
  receiver persona on another **in the same image**, and let the chip test
  itself: no host, no model, no testbench. `ws2812_tx` and `ws2812_rx` in one
  program, checking each other's timing.
- **What it beats.** **The single-ended demo**, which proves the chip can emit
  but not that it can *listen* — and listening is half the value of a
  general-purpose protocol emulator.
- **How it lands here.** The pin matrix (two pins, one TX one RX, no conflict
  because the matrix is a per-pin register file), the two word-engine
  instances, the frame buffer for the verdict, and the read path for the
  result. This is the strongest argument the repo has for why the matrix being
  *inside* the SoC (ADR-006, and the reason the plan's "wrapper instantiates
  the matrix" was unimplementable) is an architectural win rather than a
  workaround.
- **Effort shape.** Firmware-shaped; the scheduler question is real (two
  personas, one core, one 1 µs tick) and is itself a nice demonstration that
  the architecture multiplexes.
- **Proves.** Round-trip conformance on the device, unattended, forever.
- **Mark.** **C4 / F4 / F∞4.**

### E4. The claim ledger

- **What it is.** A machine-readable file where every *claim* in the wiki and
  the demo walkthrough is one row: the claim's text, the artifact that proves
  it, the mutation that would falsify it, the testbench check that catches it,
  the formal property that closes it, and the measured number. A gate asserts
  the ledger is **total** — no claim without all three, no mutation without a
  catcher — and a renderer turns it into a page and into a *judge-facing
  index* of what is proven, how, and at what cost.
- **What it beats.** **The README's "verified" section**, and — this is the
  sharp version — the project's own current state, where a number lives in a
  STATUS blockquote and the thing that would falsify it lives in a shell
  comment. The repo's own record is that this is where the failures live: false
  published numbers, a false ALERT, a manifest count derived with a Set that
  was counting pairs. **A count is an assertion**, and a claim whose falsifier
  is not written down is a claim that cannot be checked.
- **How it lands here.** The 16 mutation harnesses' headers already enumerate
  "each mutation is a plausible implementation choice, the matching TB must
  notice every one" — that text is a ledger in prose. `formal/results/mutants.txt`
  is a ledger in TSV. The generator/drift-gate pattern in `tools/gen/`. The
  mutation-list coverage gate (`check_mutation_lists.sh`) is already a
  totality check in miniature.
- **Effort shape.** Tooling-shaped, and the *cultural* work is the real cost:
  it means every claim gets a falsifier written before it gets a number. That
  is the discipline the project has been practising by hand; this makes it
  mechanical.
- **Proves.** That the project's central asset is a **verification method**,
  and it is legible. For a competition that says "we welcome formal methods and
  constrained-random tests", this is the entry's best sentence.
- **Mark.** **C5 / F5 / F∞5.** The highest-value-per-hour idea in this
  document, and the least glamorous.

### E5. Formal properties distilled into a runnable suite

- **What it is.** Ten properties across five modules are proved, and two
  vacuous ones are *labelled* rather than hidden — which is a practice almost
  nobody does. Turn each proved property into a **simulation assertion** the
  TBs also check, so the property is checked twice by two different engines and
  the vacuity label becomes a test result.
- **What it beats.** **The usual division of labour** where formal and
  simulation are separate worlds that disagree silently. The beating mechanism:
  a vacuous property shows up as a *failing simulation check*, which is
  exactly the finding the label was protecting against.
- **How it lands here.** `formal/` (`fv_run.sh` with its explicit
  BMC-vs-induction success spellings and its `assume`-is-a-constraint
  discipline, `mutants.sh`, `formal/results/summary.txt` with its `VACUOUS`
  and `REACHABLE` rows), the instrumented `FORMAL`-only observation ports in
  `pe_ctrl` (which are *aliases of existing signals*, guarded, and proven
  absent from synthesis), and the TBs.
- **Effort shape.** Test-shaped, and it needs one honest decision: an
  assertion derived from a proved property can be *too strong* for simulation
  (the property holds for all inputs; the TB only explores some), so the
  mapping has to be stated per property rather than automated blindly.
- **Proves.** Verification depth, and the vacuity discipline is a story worth
  more than another proved property.
- **Mark.** **C3 / F4 / F∞5.**

---

## Theme F — The lab and the room

### F1. A remote lab node

- **What it is.** The host GUI binds loopback by default today, and that
  default is correct. Add an explicit, *opt-in*, lease-based **read-mostly
  remote mode**: a judge or a collaborator drives a chip in someone else's lab
  over a websocket, with a lease, a heartbeat, an expiry, and a hard
  restriction — reads and debug only, no `LOAD`, or `LOAD` only into a scratch
  image.
- **What it beats.** **Shipping hardware to reviewers**, which is the actual
  bottleneck in every hardware competition. And "a recorded video", which is
  the current fallback and cannot be questioned.
- **How it lands here.** `server.py`'s existing loopback-only posture and its
  stated rule that neither arbitrary filesystem paths nor arbitrary serial
  devices are reachable over HTTP (a security posture already written down,
  which is half the design). The framed bus is already a request/response
  protocol with sequence numbers and CRC — it is a network protocol in
  miniature.
- **Effort shape.** Host-shaped, and the risk is *entirely* a security risk,
  not a technical one. Needs a threat model written down before code, and the
  read-only default.
- **Proves.** The entry is a *platform*, not a submission.
- **Mark.** **C3 / F3 / F∞3.**

### F2. Classroom mode: one chip, many students

- **What it is.** A lease queue where each student loads their own persona on a
  shared chip, watches their own waveform, and gets a 60-second slot with a
  visible countdown; the chip arbitrates because the bus already serialises
  frames and `LOAD` is refused while `run=1` (`BUSY` exists in the status
  codes for exactly this).
- **What it beats.** **A lab booking sheet.** The competition's stated models
  are the RP2040 PIO and the TI PRU — both *teaching* devices. This is the
  feature that makes the entry a teaching device, which is what those models
  are.
- **How it lands here.** `session.py`'s state machine and its `BUSY` status,
  the persona-as-a-file model, the frame buffer window per student (or a
  re-load per student), and the read path.
- **Effort shape.** Host-shaped, moderate, and it needs one honest answer to
  "what does student N see of student N-1's data" — which is a *policy*
  question, and the read-only/debug-only split from F1 answers it.
- **Proves.** Reprogrammability as pedagogy, which is the competition's
  framing, made literal.
- **Mark.** **C4 / F3 / F∞3.**

### F3. The demo as a stream

- **What it is.** The GUI's WebSocket already carries status events. Add a
  "cast" mode: every framed request/response, every persona's sampled
  waveform, every breakpoint hit and step, published as a live event stream, so
  a demo is watchable and *askable* by a remote audience without a camera.
- **What it beats.** **A screen share**, because the stream is *data*: an
  audience member can grep it, replay it, or diff two runs.
- **How it lands here.** `server.py`, the async event surface
  (`board.reset`/`chip.irq`/`chip.status`/`protocol.error` already exist), the
  bridge's newline-JSON event shape, and the recorder from A2.
- **Effort shape.** Host-shaped, small. The privacy/pacing question is the
  real one: a stream of the bus contains the firmware image.
- **Proves.** Nothing about the chip; a lot about the presentation. Included
  because a competition is partly a demo, and because it is nearly free once
  the recorder exists.
- **Mark.** **C2 / F5 / F∞5.**

### F4. The protocol chord

- **What it is.** One persona that runs **four protocols simultaneously** off
  the 1 µs tick: a UART echo, an I2C transaction, a servo frame and a WS2812
  refresh, scheduled from one timer, each with a measured budget. The pins are
  free (8 pins, `uio[0:3]` are reserved for personas, and the timing acts are
  all on pin 6 today — so this needs a pin-map change, not new silicon).
- **What it beats.** **Every dedicated protocol peripheral**, on the axis that
  matters: a fixed-logic chip has a *fixed set* of protocols, and adding a
  fifth is a respin. This has an unbounded set, and the chord is the proof —
  the composition is what no peripheral set offers.
- **How it lands here.** The 1 µs tick and the counted loops that make the
  timing exact; the pin matrix for direction; the word engine for the one
  protocol that needs it; the frame buffer for each persona's verdict. The
  timing budget arithmetic is the *interesting* part and it is honest: the repo
  already records that the tick's phase residual is up to a full microsecond
  and that this is 80% of a WS2812 bit cell, so a chord needs either
  clock-counted loops (the discipline the timing block already adopted) or
  per-persona tick-phase discipline.
- **Effort shape.** Firmware-shaped, large, and the TBs are the cost (four
  models, four measurement sets, one scheduler's worth of interference checks
  — and *interference* is the actual claim, so a chord TB must show that
  persona A's timing is unchanged by persona B running).
- **Proves.** The competition thesis better than any single protocol does.
- **Mark.** **C4 / F2 / F∞3.** The most valuable thing to *demo* and one of the
  more expensive to *prove*, which is exactly the trade the entry should make
  deliberately rather than accidentally.

---

## Theme G — Wildcard

### G1. A self-describing chip: the persona names itself

- **What it is.** A reserved word at the top of the image (`imem[1023]`, say)
  holds a magic plus a persona ID plus a parameter block; the host reads it
  with `READ_IMEM` and knows what it just loaded *without being told*. The
  GUI's protocol picker is populated by the chip, not by a filename, and a
  persona can carry its own baud rate, pin map and expected timing so the UI
  can configure itself.
- **What it beats.** **A filename convention**, which is what every loader
  protocol has, and which is wrong the moment a chip is loaded by something
  that is not the GUI.
- **How it lands here.** `READ_IMEM` (already there, already bounds-checked,
  already returns a `RANGE` fault rather than a wrapped read), the header
  contract in `pe_ctrl.v`, and the golden-package manifest discipline, which
  is the *same idea applied to the chip* — a shipped manifest with cited
  evidence. A persona header is a tiny manifest.
- **Effort shape.** Tiny, and it is the kind of 30-line change that every later
  idea in this document gets cheaper because of it.
- **Proves.** The chip describes itself, over the same bus, with no new pads.
- **Mark.** **C4 / F5 / F∞5.**

### G2. Remote attestation of the running image

- **What it is.** G1 plus a hash: the host reads the whole 1,024-word image
  back (`READ_IMEM`, 15 words per round trip, ~69 frames) and verifies it
  against what it sent. The chip can also compute a running CRC of IMEM during
  execution and report it, so "the chip is executing *this* image" is a
  checkable claim.
- **What it beats.** **Bare-metal flashing**, where "what is on the chip" is a
  question answered by faith. And for a demo, it is a genuinely satisfying
  beat: *load, read back, prove the chip is what you think it is, then run it.*
- **How it lands here.** `READ_IMEM`'s bounds contract and the wait-word rule
  are already exactly this traffic; the word engine has a `pe_crc` sitting
  right there (a TX-dedicated instance, 5/8/15/16/32-bit widths) and the
  catalogue-checked constants.
- **Effort shape.** Host-shaped (the read-back and compare is easy), RTL-shaped
  only if the chip computes it live, and the live version is interesting
  because a 32-bit CRC over 1,024 words at 1 word/cycle is ~1,024 cycles —
  17 µs, which is a *fast* self-check.
- **Proves.** Trust in a reprogrammable device, which is the whole premise of
  the competition.
- **Mark.** **C3 / F4 / F∞5.**

### G3. A protocol synthesiser on the chip

- **What it is.** D4 plus a description: the host sends a *description* (frame
  layout, line levels, bit periods) rather than an assembled program, and the
  chip's own assembler plus a small code generator produces and installs the
  persona. The chip becomes a device that manufactures protocol emulators.
- **What it beats.** **Every firmware-based protocol tool**, which assume a
  build host exists. And the blog's own framing: a device that can be *given
  a protocol at the desk* is the endpoint of the "reprogrammability after
  fabrication is the point" sentence.
- **How it lands here.** D4's assembler, the framed bus's streaming `LOAD`, the
  frame buffer as scratch, the `0xF` window for the generator's own variables.
- **Effort shape.** Firmware-shaped and *large* — this is D4 plus a code
  generator in a 16-opcode ISA, which means the generated code has to be
  straight-line and counted-delay, because that is what this core can do
  precisely. That constraint is not a limitation to work around; it is the
  design rule the whole timing block is built on, and a generator that
  *respects* it is a strong argument for the architecture.
- **Proves.** The thesis, at its most extreme.
- **Mark.** **C5 / F1 / F∞2.** Wild. Build it if there is time after A1, C1 and
  E4, and do not let it delay a tapeout.

### G4. The chip as its own peer

- **What it is.** A persona that opens a protocol conversation with *itself*:
  a mini loopback engine where one pin-matrix pin talks to another, the chip
  acts as master and slave in turn, and the transcript is compared against a
  golden capture. Unattended, on the board, forever.
- **What it beats.** **A bench loopback test**, which needs a human and a
  scope.
- **How it lands here.** E3's mechanism; the difference is that E3 tests two
  *different* protocols against each other and this tests one protocol against
  itself with the golden capture as the oracle.
- **Mark.** **C3 / F4 / F∞4.** Cheap, and the natural thing to leave running
  on a bench overnight — which is also how you find the bug that only appears
  when the room is warm.

### G5. The chip as an *analyser* rather than a generator

- **What it is.** The inverse persona. Because a protocol is a *program*, the
  chip can host the *decoder* for a protocol it is not transmitting: a UART
  analyser that counts frames and reports baud error in the frame buffer, an
  I2C analyser that decodes START/address/ACK and flags a NACK, a WS2812
  decoder that reports the 24-bit colour it just received. The chip becomes a
  bus monitor, over the same 8 pads, with the same bus to report through.
- **What it beats.** **A $200 USB protocol analyzer**, and — for the NEC IR
  act, which already has to *receive* a 38 kHz burst and time the gaps — the
  chip already does the hard half of this today. It just does not *report* it.
- **How it lands here.** The DS18B20 and NEC acts are already receivers
  (`nec_ir.pe` measures 38,049 Hz off the pin, +0.128% off the 38 kHz nominal,
  with the eight bursts' half periods landing in 787.95–794.95 clocks around
  a nominal 788.95). The frame buffer is the sink. The read path is the
  report. The pin matrix is the tap.
- **Effort shape.** Firmware-shaped, and it is the cheapest demonstration of
  generality available: a protocol persona that only *listens* is a different
  program with the gates unchanged, which is the entire thesis in one line.
- **Mark.** **C4 / F5 / F∞5.** Do this before F4. It is the best
  proof-per-hour in this document.

### G6. The persona that argues with its own datasheet

- **What it is.** Wildcard-tier, cheap, slightly unhinged, and a very good
  demo: a persona that transmits a protocol *and* decodes its own transmission
  *and* compares both against the constants in its own image, publishing the
  diff. When it disagrees, it has found a real bug. Run all twenty of them
  overnight.
- **What it beats.** **Nothing** — there is no incumbent for a chip auditing
  itself. That is the point.
- **Mark.** **C4 / F4 / F∞5.**

---

## Ranking

Ordered by (value to the competition) ÷ (effort), with the caveats from each
idea's own mark.

| rank | idea | C | F | why it is here |
|---|---|---|---|---|
| 1 | **E4 claim ledger** | 5 | 5 | makes the real asset legible; nearly free |
| 2 | **C4 mutant firmware as a demo mode** | 5 | 5 | turns a CI number into a stage beat |
| 3 | **C1 adversary target** | 5 | 4 | the hook is already built and unused |
| 4 | **A5 self-certifying persona** | 4 | 5 | moves every timing claim onto the device |
| 5 | **G5 analyser personas** | 4 | 5 | best proof-per-hour of the whole thesis |
| 6 | **B2 golden waveforms** | 2 | 5 | closes a defect class this repo hit three times |
| 7 | **B3 margin maps** | 3 | 4 | turns "in spec" into "how far in spec" |
| 8 | **A2 flight recorder** | 5 | 4 | the best live demo; the sample-rate honesty is the risk |
| 9 | **E1 golden wire corpus** | 3 | 4 | substrate for five other ideas |
| 10 | **B4 chip as analyzer** | 4 | 5 | one afternoon, no new RTL |
| 11 | **G1 self-describing chip** | 4 | 5 | 30 lines; makes everything after it cheaper |
| 12 | **D2 NL → persona, gated** | 5 | 4 | the competition explicitly invites this |
| 13 | **C2 fault playground** | 3 | 5 | presentation over C1 |
| 14 | **E5 formal → simulation** | 3 | 4 | makes vacuity visible |
| 15 | **A1 reverse execution** | 4 | 3 | the flagship; needs a Y debug output |
| 16 | **A3 R4 watchpoints** | 2 | 3 | the obvious next phase; say so plainly |
| 17 | **B1 live waveform** | 4 | 4 | the demo, in a browser |
| 18 | **A4 coverage in hardware** | 5 | 2 | spectacular, area-hungry |
| 19 | **E2 differential conformance** | 4 | 4 | interoperability, not self-consistency |
| 20 | **C3 margin hunting** | 4 | 4 | the sweep harness, used as an instrument |
| 21 | **F4 protocol chord** | 4 | 2 | best demo, most expensive proof |
| 22 | **G2 image attestation** | 3 | 4 | satisfying, cheap |
| 23 | **E3 self-conformance** | 4 | 4 | round-trip on the device |
| 24 | **D3 datasheet matrix** | 3 | 4 | generated corner cases |
| 25 | **F3 demo stream** | 2 | 5 | free once the recorder exists |
| 26 | **C5 live chaos** | 3 | 4 | real transport, real faults |
| 27 | **G6 self-auditing persona** | 4 | 4 | cheap, slightly unhinged |
| 28 | **G4 chip as its own peer** | 3 | 4 | overnight soak, no human |
| 29 | **F2 classroom mode** | 4 | 3 | the PRU/PIO framing, made literal |
| 30 | **F1 remote lab** | 3 | 3 | security work, not technical work |
| 31 | **D1 one description, three consumers** | 4 | 2 | ambitious; also the sharpest limit statement |
| 32 | **D4 chip assembles itself** | 5 | 1 | the memory problem *is* the project |
| 33 | **G3 on-chip synthesiser** | 5 | 1 | wild; do not let it delay a tapeout |

---

## Three tiers, and why the tiers are not the ranking

The ranking is about value per hour. The tiers are about **what a first
silicon run can carry**, which is a different question and the one that
matters for a competition with a shuttle date.

**Tier 1 — no new silicon, ship before anything else.** G1, B4, A5, C4, C2,
E4, E5, B2, B3, G5, G6, F3, D3, C3, E1, G2.
Every one of these is a `.pe` file, a Python file, a testbench, or a page.
Together they are the difference between an entry that *describes* its
verification and one that *performs* it in front of you.

**Tier 2 — small RTL, decide against the area and pad budget.** A1 (reverse
execution, ~30 cells plus a `pe_soc` wire), A3 (R4, 150–300 cells), C1
(already there, unused), G2-live (a `pe_crc` tap), A4-coarse (16 bytes in
DMEM).
The budget question is real and the pages that answer it are
[[reference/protocol-pin-budget]] (19 of 24 pads committed) and
[[reference/floorplan-feasibility]] (two `1P_1024x16` macros at 159,347 µm²
against a 1002×432 µm die at the template's tile size, with the routed
`tt_um_top` at 138,817 µm² mapped). There is *area* headroom on the logic;
there is very little *SRAM* headroom, which is what kills the ambitious
versions of A4 and F4.

**Tier 3 — the shape-of-the-thing experiments.** D1, D4, G3, F4.
All four are firmware-shaped, all four are large, and all four are worth doing
*after* a tapeout rather than before one, with one exception: **D4 and G3 are
the only ideas in this document that would change what the chip is**, and the
competition's stated thesis is that reprogrammability is the point. If there is
ever a second shuttle, D4 is the thing to spend it on.

---

## The self-audit: demo vs commitment

Per the rule at the top: each idea's demo needs a commitment, and a commitment
that cannot fail is not a commitment. The three columns are the honest state
of each *tier-1* idea as of this writing.

| idea | the demo a judge sees | the commitment the repo must be able to fail at | status today |
|---|---|---|---|
| G1 self-describing | the chip names its own protocol over the bus | a `READ_IMEM` golden vector, plus a mutant that returns the wrong header | not started; the read path to build it on is proved |
| B4 chip-as-analyzer | a persona that times its own pin | a TB that measures the pin, plus the 74/76-class mutant | the measurement half exists in every timing TB |
| A5 self-certifying | the chip prints its own timing verdict | the persona's verdict must go FALSE under a `--const` mutation | not started; the gate is `mutate_timing_tb.sh`'s shape |
| C4 mutant demo | good firmware vs broken firmware on one board | **both images must be checked in and both TBs must exist**, or the demo is a rigged comparison | not started; the mutants exist in CI only |
| C1 adversary | the host survives a misbehaving peer | each misbehaviour needs a stated intent **and** a host-side case; and `FakePE` must grow the same behaviour so the two can be diffed | target 1 exists and answers only `PING`/`TARGET` |
| C2 playground | buttons that make the chip misbehave | every button must be pinned to a chip-observed effect, not a model one | the session already reads the chip's own state word for the warning |
| E4 claim ledger | a page of claims with their falsifiers | a totality gate that **fails on an incomplete row**, and a negative control proving it can fail | the shape exists in `check_mutation_lists.sh` |
| E5 formal→sim | a vacuous property shows up as a red check | the vacuity labels must be re-derived, not copied | 10 properties / 5 modules / 14 mutants, 2 labelled vacuous/reachable |
| B2 golden waveforms | a waveform diff in CI | an `--accept` path that records *why*, or the goldens rot silently | drift-gate pattern exists for the generated pages |
| B3 margin maps | the 60-phase heat map | the map must be generated by running the personas, not by hand | the 60-phase sweep exists for I2C |
| G5 analyser | the chip decodes what it hears | a golden capture of what it decoded | DS18B20/NEC already receive; they do not report |
| D3 datasheet matrix | min/nom/max conformance | every generated corner must be *run*, and the matrix must fail on a mutant | per-protocol assertions exist by hand |
| C3 margin hunting | a near-miss transmission that still works | the peer model must be datasheet-derived and the mutant must break the *peer*, not the transmitter | `--const` exists for exactly this |
| E1 wire corpus | a conformance manifest for the personas | a `chip_confirmed` flip requires a citation, and a divergence that *changes* must go red | the R2/R3 manifests are the template |
| G2 attestation | read back and prove the chip is what you sent | the read-back must be compared against the *sent* bytes including a wrapped-address case | `READ_IMEM` + `RANGE` already exist |
| F3 demo stream | a watchable demo | the stream must not leak the image without saying so | event surface exists |

The pattern across the column is worth stating once: **in fifteen of sixteen
cases the missing commitment is a mutation or a totality check, not a
feature.** That is a real finding about this project's shape — the ideas are
cheap because the verification infrastructure already exists, and the
expensive part is always proving the new thing can fail.

---

## What I would NOT build, and why

Naming the rejected ideas is as useful as naming the accepted ones, and this
project's culture (two benign mutants deleted rather than tolerated; a check
that cannot fail treated as an error) demands the same discipline here.

- **Multi-breakpoint in silicon without conditions or counters** (A3, the
  boring version). It is what a competitor would build, it is a superset of
  what exists, and on its own it proves nothing a judge cannot get from a $4
  MCU. The interesting part is the condition field and the counter; a bigger
  table without them is plumbing.
- **A new protocol as a new RTL block.** The thesis is that a protocol is a
  program. Every hour spent adding a peripheral is an hour arguing against the
  entry's own argument. The exception is a protocol that genuinely cannot be
  firmware — the repo already has the rule (the 10BASE-T arithmetic: 48
  instructions per byte, a software CRC-32 needs ~240) and it should be applied
  without renegotiation.
- **Anything requiring a new pad.** 19 of 24 are committed and the host row
  (`uio[4:7]`) is load-bearing. Every idea above was chosen partly because it
  needs none.
- **Anything requiring a second shuttle to demonstrate.** The tie-breaker
  should be: *can a judge see this on the shuttle board they already have?* If
  not, it is Tier 3, and Tier 3 happens after the tapeout.
- **A "self-testing" gate that cannot fail.** The repo has already shipped one
  and deleted it. The claim ledger (E4) and the totality gate inside it are
  the direct answer: every row must name its falsifier, and the totality check
  itself gets a negative control.

---

## See also

- [[concepts/overview]] — how the pieces fit, for a reader landing cold
- [[plans/host-controller-gui]] — the host bus contract these ideas extend
- [[plans/pe-ctrl]] — the chip side of that bus
- [[concepts/spi-as-firmware]] — why a protocol is a program here
- [[concepts/tx-timing-generation]] — the exactness that A5, B3, C3 and D3 measure
- [[concepts/pin-matrix]] — the per-pin file that C1, E3 and G5 attach to
- [[decisions/adr-005-60mhz-turbo]] — why 60 MHz, which every timing claim inherits
- [[decisions/adr-006-pin-matrix]] — why the matrix is inside the SoC
- [[reference/protocol-pin-budget]] — the 19-of-24 pad arithmetic
- [[reference/sram-budget]] — why A4's ambitious version is expensive
- [[STATUS]] — what is actually landed, and what is only claimed
- [[SCHEMA]] — the rules this page follows
