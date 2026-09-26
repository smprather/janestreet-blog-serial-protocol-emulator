# Wiki Index

> **The map of the whole wiki.** Every page, one line each, grouped by what it
> is for. Start with a reading path, not with this list.
> Last updated 2026-09-25.

This wiki is one repository's record of a Tiny Tapeout protocol-emulator
ASIC: a chip, a host stack, and — the part that is unusual — a verification
record detailed enough that most of its claims can be made to fail on
request. Read [[concepts/overview]] first if you have never seen the project;
read [[STATUS]] first if you are resuming after a context flush.

---

## Start here

- [[concepts/overview]] — **the on-ramp.** How the five layers fit (chip, host
  bus, firmware personas, host stack, verification culture), an hour-long
  reading order, and an explicit list of what is *not* true yet. **Read this
  one if you read nothing else.**
- [[STATUS]] — **milestone status, newest blockquote first**, plus the ordered
  next-steps list. This is the only place the current regression figure lives;
  do not quote a number from memory.
- [[SCHEMA]] — the rules this wiki follows: page types, the tag taxonomy, the
  provenance discipline, and the update policy.
- [[log]] — the append-only action log.

### Reading paths

Six ways in, depending on what you want. (`docs/demo-walkthrough.md` is in the
repo root, not a wiki page: it is the judge-facing act script.)

| you want… | read, in order |
|---|---|
| **the whole thing in an hour** | [[concepts/overview]] → `docs/demo-walkthrough.md` → [[plans/host-controller-gui]] → [[index]] |
| **why a protocol is a file here** | [[concepts/spi-as-firmware]] → [[concepts/i2c-on-the-matrix]] → [[concepts/ethernet-scope]] |
| **the silicon** | [[concepts/overview]] → [[decisions/adr-005-60mhz-turbo]] → [[reference/block-diagram]] → [[concepts/ethernet-receive-path]] |
| **the verification story** | [[concepts/overview]] (§ the verification culture) → [[reviews/2026-09-25/FORMAL-VERIFICATION|FORMAL-VERIFICATION]] → `regress/mutate_ctrl_tb.sh`'s header → [[reviews/2026-09-25/MERGE-FORENSICS-5B4731F]] |
| **the host bus and its tools** | [[plans/host-controller-gui]] → [[plans/pe-ctrl]] → [[concepts/overview]] (§ the host bus) |
| **what to build next** | [[plans/feature-brainstorm]] |

---

## Concepts — how the design works

### The architecture

- [[concepts/overview]] — **start here.** The five layers, the pad map, the
  4-bit port map and its three rules, why the ISA is 16 opcodes, the three
  implementation styles, what a persona actually is, and the six verification
  mechanisms with the lie each one closes.
- [[concepts/competition-overview]] — the challenge, the rules, the area
  budget and the timeline (blog-grounded, with the transcript corrections
  noted and the reason they were reversed).
- [[concepts/spi-as-firmware]] — SPI mode 0 as pure software on the shared
  8-bit port: the MSB-first/LSB-first asymmetry, the reset-value trap, and
  the mutations that were and were not catchable.
- [[concepts/pin-matrix]] — runtime per-pin direction, open-drain and
  read-back: the I2C gate. Why the OD bit exists, and the wire model that
  catches contention instead of hiding it.
- [[concepts/i2c-on-the-matrix]] — I2C with no I2C controller: START, bit cell
  and STOP as firmware. 83 kHz measured across all 60 tick phases, and the
  three timing traps that cost real rework.
- [[concepts/strobe-and-committing-edge]] — what the strobe (`bit_en`) and the
  committing edge are, and the sample-order trap they cause.
- [[concepts/factored-hardware-blocks]] — the shared RTL primitives (CDR,
  SerDes, stuffing, CRC LFSR) and why no 8b/10b is needed.

### Timing, clocks and the physical layer

- [[concepts/tx-timing-generation]] — exact-integer protocol timing at 60 MHz
  (ADR-005), the NCO for fractional bauds, and why 66 MHz is infeasible.
- [[concepts/cdr-oversampling]] — the 12× oversampled digital data-recovery
  unit for 10BASE-T (`SPB=12` at 60 MHz), why 4× is rejected, and the filter
  trap found while building it.
- [[concepts/clock-doubler]] — XOR delay-line doubler options: standard-cell
  plus PDN hardening, or full custom.
- [[concepts/physical-layer-gpio]] — CMOS-swing GPIO reality: what works
  natively and what needs a workaround.
- [[concepts/gpio-signoff-corners]] — FS/SF corners, SPICE bit-thinning
  extraction, SDC injection.
- [[concepts/pdk-toolchain]] — the local IHP PDK and EDA bring-up: paths,
  corners, SRAM macros, install workarounds.

### 10BASE-T, the one protocol in hardware

- [[concepts/ethernet-scope]] — what "10Mbit Ethernet" as a stretch goal
  actually asks for, and the arithmetic showing why the bit work cannot be
  firmware (48 instructions per byte; a software CRC-32 needs ~240).
- [[concepts/ethernet-receive-path]] — `pe_eth_mac` (914 cells in the block
  diagram; larger after the ownership fixes): SFD lock, byte assembly,
  FCS-against-the-catalogue-residue, store-and-forward. Where four
  previously-orphaned blocks become one signal path, and the
  preamble-is-not-an-octet trap.

### Protocol deep-dives

One page per protocol persona, written from the *measured* behaviour of the
real RTL rather than from the datasheet, each with its own figure set in
`diagrams/proto-*.puml` (state machine, field layout, timing). They land on
their own branches as the families are produced, so this section grows:

- [[concepts/protocol-ws2812]] — 800 kHz one-wire with **no clock on the
  wire**, where the value *is* a pulse width. The 48-clock high, the 75-cycle
  grid, and why a 74/76-clock cell passes every datasheet window in the world
  and is still wrong. The family's first member, and the one that made the
  design rules visible — read it first.
  *(from `docs/diag-timing`)*
- [[concepts/protocol-servo]] — servo PWM as *a protocol with nothing in it
  but a number*: no clock, no framing, no ACK, no checksum, just a 1–2 ms
  high once every 20 ms. The cleanest demonstration of the central claim,
  because if the pulse width is a count of instructions then "the chip is
  cycle-accurate" is a property of the **program** and not of the gates — and
  anyone can read the numbers out of the source and check them with a scope.
  *(from `docs/diag-timing`)*

*(Links to this family resolve as their branches merge; the rest of the family
is in progress — see **In flight** below.)*

---

## Reference — generated and measured facts

These pages are **generated from the source and drift-checked in
`regress/run_all.sh`**, so a port table cannot quietly go stale. Read them for
numbers; do not edit them by hand.

- [[reference/signal-names]] — every RTL port: direction, width, meaning,
  validity. Port tables generated from the Verilog.
- [[reference/protocol-pin-budget]] — per-protocol IO pin counts against the
  TT pad budget (26 pads, 24 usable; **19 committed**), and what the board
  must add per protocol.
- [[reference/sram-budget]] — SRAM capacity against the 6×4 die: every PDK
  macro's real size, what fits, and the area cost of 1–32 KB.
- [[reference/floorplan-feasibility]] — the actual two-macro plus logic fit on
  the real tile allocations, the blog-vs-template assumption difference, and
  the evidence a later floorplan run must produce (read-only; generated).
- [[reference/clock-arithmetic]] — every protocol constant at the locked
  60 MHz point: what is integer-exact and what is an approximation. `CLK_HZ`
  is read from the RTL.
- [[reference/crc-config]] — every CRC constant `pe_crc` is loaded with,
  derived and checked against the RevEng catalogue's published values.
- [[reference/block-diagram]] — the RTL block inventory: integrated blocks,
  standalone orphans, cell counts, testbenches (generated and drift-checked).
- [[reference/simulator-bakeoff]] — Icarus versus Verilator, measured: speed,
  build cost, and the `DIDNOTCONVERGE` blocker that decides it.

### Diagrams (in the repo, not in the wiki)

Editable PlantUML sources with colocated renders, in `diagrams/`:

- `project-plan.puml` — planned system topology, baseline and stretch
  protocol goals.
- `project-progress.puml` — implementation status by block; colour separates
  integrated, standalone and open work.
- `proto-*.puml` — the per-protocol figure families (state machine, field
  layout, timing), each with its `.png`/`.svg` render.
- `diagrams/README.md` — what each map is for and how to re-render it.

---

## Comparisons

- [[comparisons/clocking-options]] — external 80 MHz versus dual-edge at the
  core clock versus an internal doubler versus a full-custom doubler.

---

## Plans — forward-looking work, with a definition of done

Kept in place as they complete; a landed plan's durable findings move into
concepts/reference/decisions and the plan's status line records that it is
done.

- [[plans/feature-brainstorm]] — **33 novel features in seven themes** (time
  as a resource, the wire as data, breaking things on purpose, writing
  protocols instead of implementing them, conformance as the product, the lab
  and the room, and a wildcard tier), each with what it beats, how it lands on
  the blocks that exist, its effort shape, and what it proves. Plus a ranking,
  three tiers, a demo-versus-commitment self-audit, and a list of what not to
  build.
- [[plans/host-controller-gui]] — the host controller GUI and the PE
  host-control bus (R2 read ops, the golden package, the bridge and the GUI).
  The user's separate session owned its execution; the contract is here.
- [[plans/pe-ctrl]] — the chip side of that bus: the passive SPI load path and
  the framed host bus (LOAD/STATUS/READ/TARGET/CLEAR_FAULT), with its own
  test and mutation strategy.
- [[plans/pe-ctrl-readback]] — the evaluation of a MISO response from the
  loader (echo, status, or imem peek), with the pad mapping, the budget delta
  and the test/mutation plan. The A1 echo it chose is **retired** by the R0
  pad ruling; its commit-latched semantics live in the framed LOAD response.
- [[plans/demo-host-gui]] — the earlier draft GUI plan, superseded by
  [[plans/host-controller-gui]]. Kept because its operator-workflow and
  error-tier reasoning is still the best statement of the GUI's job.
- [[plans/serdes-integration]] — integrating `pe_serdes` and `pe_codec_mux`
  into `pe_soc`: an additive engine, DRU RX capture, two codec instances with
  encoded-cell enables, split payload enables, and a `0xF` indexed window.
- [[plans/eth-tx-frame-path]] — the 10BASE-T TX frame path: hardware
  preamble/SFD, FCS via a TX-dedicated `pe_crc`, 64-byte pad folded into the
  FCS, the 96-bit-time IFG, runt/jabber policy, eight scope groups, and the
  pad-level plus RX-loopback acceptance tests. **COMPLETE (Tasks 1-7).**
- [[plans/ethernet-soc]] — 10BASE-T SoC integration: `pe_dru` → `pe_manch` →
  `pe_eth_mac` with `pe_crc`/`pe_fbuf` inside `pe_soc`, RX on the pin matrix,
  and the firmware frame-buffer walk.
- [[plans/through-i2c]] — the plan to the I2C milestone, **complete** and kept
  for its findings. Its reasoning for *why two implementation styles coexist*
  is the reason the word engine and the bit-banged core were not unified.
- [[plans/i2c-transaction]] — the I2C transaction layer on the pin matrix,
  with its timing and arbitration cases.
- [[plans/spi-pads]] — exposing SPI MOSI and CS_N on `uio[2:3]`, with the
  budget delta and pad-level verification.

---

## Decisions — the ADRs, and what was rejected

- [[decisions/adr-001-8x-oversampling]] — target 8× oversampling for 10BASE-T
  receive.
- [[decisions/adr-002-latch-pair-det-flop]] — a standard-cell latch pair as
  the dual-edge flop; no custom DDR.
- [[decisions/adr-003-memory-plan]] — two `1P_1024x16` macros (instructions
  and frame buffer). A flop IMEM was 89% of the die and you cannot buy 1.5 KB.
  Instruction half implemented.
- [[decisions/adr-004-program-counter-width]] — the SRAM swap required
  widening the PC and the jump-target field in the same change; the memory
  alone delivered 128 usable words, not 1024.
- [[decisions/adr-005-60mhz-turbo]] — the turbo is **60 MHz, not 66**. 66
  provably fails the 10BASE-T TX jitter conformance window at every edge
  placement; 60 is exact for every hard protocol with a 50%-finer RX grid.
- [[decisions/adr-006-pin-matrix]] — the pin matrix is a runtime per-pin
  `{out,oe,od}` file and it lives **inside** the SoC. The plan's "wrapper
  instantiates the matrix" is unimplementable, because the CPU's IO bus never
  leaves `pe_soc`.
- [[decisions/adr-007-pe-ctrl-passive-slave]] — `pe_ctrl` is a **passive SPI
  slave** at the wrapper boundary (the host loads, `run` starts). A master
  would need a hardwired bootstrap FSM and a flash, because there is no ROM.

---

## Entities

- [[entities/tiny-tapeout]] — the fabrication platform and what it constrains:
  the tile geometry, the pad banks, the SRAM macros, and the flow the project
  uses (and the flow it deliberately does not run).

---

## Root reference (verbatim sources, immutable)

Corrections go in wiki pages, never in these. A superseding capture is a new
file, not an edit.

- [[raw/articles/janestreet-competition-blog-fulltext]] — **the competition
  blog, full verbatim text**, with the fetched bytes' `sha256` in the
  frontmatter. Primary source for every competition fact. It says 6×4 tiles and
  marks itself a living page that will change if 8×4 is offered.
- [[raw/articles/janestreet-protocol-emulator-competition]] — the original
  ingest of the announcement. **Its summary, not its text, is what caused a
  documented error**; see [[concepts/competition-overview]].
- [[raw/articles/tinytapeout-clock-spec]] — the platform's clock spec.
- [[raw/articles/tinytapeout-multiplexer]] — the pad/multiplexer doc: why
  `u_clk`, `u_rst_n` and `ui` are all just bits in one bus.
- [[raw/articles/ttihp0p2-loopback-skew-project]] — a prior loopback/skew
  project.
- [[raw/transcripts/gemini-asic-competition-discussion-2026-09]] — a
  discussion transcript. Superseded by the blog on competition facts, and the
  page that carries the "a source outranks another only if the capture is
  faithful" lesson.

---

## Reviews and evidence

Where the verification record lives. The generated pages above are
drift-checked, and these are the hand-written reviews they support. Host-side
reviews landed in this repo with the 2026-09-25 `host-controller-gui` merge, so
the R2 record is no longer across a repo boundary.

### Project-level

- [[reviews/2026-09-23/PROJECT-REVIEW]] — the project review: a claims audit,
  the E1/E2 findings, and the residual observations R1–R5.
- [[reviews/2026-09-25/MERGE-FORENSICS-5B4731F]] — how a merge shipped six
  red timing acts with every gate green a minute earlier, and what the merge
  gate that now exists is for.
- [[reviews/2026-09-25/ETH-TX-FRAME-PATH-REVIEW]] — the eth-tx close-out:
  mapped STA, the two mutation suites, hashes, and the plan status.
- [[reviews/2026-09-25/TIMING-PROTOCOLS-REVIEW]] — the three timing acts and
  the two input-capture blocks: fourteen and eighteen defects respectively, and
  the split between firmware and testbench.
- [[reviews/2026-09-25/CHIP-CODE-REVIEW]] — the chip-side code review.

### Verification and formal

- [[reviews/2026-09-25/FORMAL-VERIFICATION|FORMAL-VERIFICATION]] — the formal
  safety campaign: the proved claims, the **vacuity labels**, the instrumented
  targets, and findings **F1** (the `pe_eth_tx` TXLEN apply-window) and **F2**
  (the `pe_soc` owner SET-side guard).
- [[reviews/2026-09-25/FORMAL-STRENGTHENING]] — what the campaign was pushed
  to, and what stayed unproved.
- [[reviews/2026-09-22/REVIEW-2]] — the second review's seven failure cases
  and the fixes that closed them.
- [[reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW]] — the SERDES mapped-STA
  refresh and the codec mutation suite.
- [[reviews/2026-09-25/R2-READ-PATH-REVIEW]] and
  [[reviews/2026-09-25/R2-READ-VERIFICATION]] — the R2 host read path
  (`READ_CPU`/`READ_IMEM`/`READ_DMEM`/`DUMP_CORE`), the wait-word contract, the
  chip/host split, and the conformance evidence with the golden package.
- [[reviews/2026-09-25/R2-HELD-CORE-CHIP-SIDE]] — the chip side of the
  "held core" question, including the correction about arming a held core.
- [[reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT]] — the frozen R3 debug
  contract: the opcodes, the state encoding, and the once-held rule.
- [[reviews/2026-09-25/R3-CONFORMANCE-AND-RUN-LOCK]] — how the R3 golden
  steps were confirmed and how the run lock was proved to hold.
- [[reviews/2026-09-25/R3-STA]] and [[reviews/2026-09-25/R3-CHIP-CODE-REVIEW]]
  — R3's timing screen and code review.
- [[reviews/2026-09-23/E1-PUBLISHED-OWNERSHIP-REVIEW]] — the independent
  accounting audit that found a consume could release in-flight bytes.

### Host side

- [[reviews/2026-09-25/HOST-BRANCH-MERGE-NOTE]] — what the
  `host-controller-gui` merge brought into this repo.
- [[reviews/2026-09-25/HOST-GUI-R2-PREP]] and
  [[reviews/2026-09-25/HOST-GUI-R3-PREP]] — the host's preparation for each
  chip phase, including what is *not* chip-confirmed.
- [[reviews/2026-09-25/HOST-GUI-PHASE3-ACCEPTANCE]] — the acceptance runner
  and the fake-bridge beats.
- [[reviews/2026-09-25/HOST-BRIDGE-MICROPYTHON]] — the Pico-side bridge.
- [[reviews/2026-09-25/HOST-SOAK-API-FUZZ]] — the bounded soak and the
  protocol-fuzz campaign.
- [[reviews/2026-09-25/R3-HOST-CODE-REVIEW]] — the host side of R3.
- [[reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW]] — the audit that phased
  the host-control work into R0/R1/R2/R3.

### Layout, timing and process

- [[reviews/2026-09-24/DIAGRAM-SQUARER-LAYOUT]] — the map re-layout, including
  the finding that splitting by workstream made the aspect ratio *worse*.
- [[reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION]] — the full negative-slack
  inventory across every mapped screen, and the labelled ZERO/BOARD variants.
- [[reviews/2026-09-24/SERDES-INTEGRATION-REVIEW]] — the word engine's
  integration and its two bring-up defects.
- [[reviews/2026-09-23/REFACTOR-REVIEW]] — the module reorganisation, proved
  by matching token streams and identical firmware images.
- [[reviews/2026-09-23/I2C-TRANSACTION-REVIEW]] and
  [[reviews/2026-09-23/SPI-PAD-REVIEW]] — the two baseline protocol closes.

---

## Queries

None yet. A **query** page in this wiki is a question the wiki cannot yet
answer, kept as a page so the gap is visible rather than remembered. If you
find yourself reasoning around a hole, that is the signal to write one.

---

## Conventions

- File names are lowercase with hyphens. Every page starts with YAML
  frontmatter. Pages link with double-bracket wikilinks, at least two outbound.
  Every new page is added to this index, and every action is appended to
  [[log]].
- Review and evidence pages live at the repo root in `reviews/`, so a link
  to one is written as a double-bracketed path beginning `reviews/`; those
  files are in this repository, not under `wiki/`.
- **Provenance:** the Jane Street blog outranks the Gemini transcript on
  competition facts — but a source outranks another only if the *capture* is
  faithful, and that rule exists because a summary was once used to overrule a
  correct primary-adjacent source.
- **Raw sources are immutable**; a superseding capture is a new file.
- Page thresholds: create a page when a topic is central or appears in 2+
  sources; split a page past ~200 lines; archive rather than delete a
  superseded page.

---

## In flight

Documentation work currently landing on sibling branches, so a reader knows
where the next pages come from and does not mistake their absence for a
decision not to write them:

- **protocol deep-dives** — one `wiki/concepts/protocol-*.md` per persona,
  each with a `diagrams/proto-*.puml` figure set (state machine, field layout,
  timing). **Landed so far:** `protocol-ws2812` and `protocol-servo`, both from
  `docs/diag-timing`, both linked above. The rest of the family is in progress
  and follows the same `protocol-<name>` naming convention.
- **host-bus figures** — the framed SPI link (word/bit layout and the
  wait-word contract), the R2 bounded-read path, the R3 debug-control state
  machine with STOP-BEFORE and the `BP_SET` subtlety, and an I2C-advanced set.
  These are figures rather than prose pages, so they belong in the diagrams
  note above rather than in a page list.
- **project maps** — the plan and progress maps in `diagrams/`, with the
  topology and the per-block verification state.

Once a page lands on its branch it gets a line here; this section is deleted
when the family is complete.
