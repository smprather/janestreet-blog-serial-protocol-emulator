# Wiki Index

> Content catalog. Every wiki page listed under its type with a one-line summary.
> Last updated: 2026-09-23 | 31 pages (30 content pages + STATUS; index/log/SCHEMA are meta, raw sources are catalogued under their own section)

## Start here

- [[STATUS]] — **Milestone status + resume-here after a context flush.** Read first.

## Root reference (verbatim sources)

- [[raw/articles/janestreet-competition-blog-fulltext]] — **the competition blog, full verbatim text.** Primary source for every competition fact. Says 6x4 tiles; a living page that will change if 8x4 is offered.

## Entities

- [[entities/tiny-tapeout]] — Fabrication/tapeout platform and what constrains the design.

## Concepts

- [[concepts/competition-overview]] — Challenge, rules, area budget, timeline (blog-grounded; transcript corrections noted).
- [[concepts/physical-layer-gpio]] — CMOS-swing GPIO reality: what works natively, what needs workarounds.
- [[concepts/cdr-oversampling]] — 12x oversampled digital data-recovery unit for 10BASE-T (SPB=12 at 60 MHz); why 4x is rejected; BUILT (116 cells) and the filter trap found building it.
- [[concepts/clock-doubler]] — XOR delay-line doubler options: standard-cell + PDN hardening vs full custom.
- [[concepts/gpio-signoff-corners]] — FS/SF corners, SPICE bit-thinning extraction, SDC injection.
- [[concepts/factored-hardware-blocks]] — Shared RTL primitives (CDR, SerDes, stuffing, CRC LFSR); no 8b/10b needed.
- [[concepts/pdk-toolchain]] — Local IHP PDK + EDA bring-up: paths, corners, SRAM macros, install workarounds.
- [[concepts/tx-timing-generation]] — Exact-integer protocol timing at 60 MHz (ADR-005); NCO for fractional bauds; why 66 MHz is infeasible.
- [[concepts/ethernet-scope]] — what "10Mbit Ethernet" as a stretch goal actually asks for: the line layer, a 1.5 KB frame, and why 32 KB was never the requirement.
- [[concepts/ethernet-receive-path]] — `pe_eth_mac` (914 cells): SFD lock, byte assembly, FCS-against-the-catalogue-residue, store-and-forward. Where four orphaned blocks become one signal path. The preamble-is-not-an-octet trap.
- [[concepts/strobe-and-committing-edge]] — What the strobe (`bit_en`) and the committing edge are, and the sample-order trap they cause.
- [[concepts/spi-as-firmware]] — SPI mode 0 as a pure-software master on the shared 8-bit port; the MSB-first/LSB-first asymmetry, the reset-value trap, and the mutations that were (and were not) catchable.
- [[concepts/pin-matrix]] — runtime per-pin direction, open-drain and read-back: the I2C gate. Why the OD bit exists, and the wire model that catches contention instead of hiding it.
- [[concepts/i2c-on-the-matrix]] — I2C with no I2C controller: START/bit cell/STOP as firmware on the matrix. 83 kHz measured across all 60 tick phases, and the three timing traps that cost real rework.

## Reference

- [[reference/signal-names]] — Every RTL port: direction, width, meaning, validity. Port tables generated from the Verilog (drift-checked in `regress/run_all.sh`).
- [[reference/protocol-pin-budget]] — Per-protocol IO pin counts vs the TT pad budget (26 pads, 24 usable); what the board must add per protocol.
- [[reference/sram-budget]] — SRAM capacity vs the 8×4 die: every PDK macro's real size, what packs, and the area cost of 1–32 KB.
- [[reference/floorplan-feasibility]] — the actual two-macro + logic fit on the real tile allocations, the blog-vs-template assumption differences, and the evidence a later floorplan run must produce (read-only; generated).
- [[reference/crc-config]] — every CRC constant `pe_crc` is loaded with, derived and checked against the RevEng catalogue's published values (generated).
- [[reference/clock-arithmetic]] — every protocol constant at the LOCKED 60 MHz operating point: what is integer-exact and what is an approximation. `CLK_HZ` is read from the RTL (generated).
- [[reference/block-diagram]] — RTL block inventory: integrated blocks, standalone orphans, cell counts, and testbenches (generated and drift-checked).
- `diagrams/project-plan.puml` — planned system topology, including baseline and stretch protocol goals.
- `diagrams/project-progress.puml` — implementation status by block; colors distinguish integrated, standalone, and open work.
- [[reference/simulator-bakeoff]] — Icarus vs Verilator, measured (speed, build cost, X)

## Comparisons

- [[comparisons/clocking-options]] — External 80 MHz vs dual-edge at the core clock vs internal doubler vs full-custom doubler.

## Plans

- [[plans/through-i2c]] — Plan to the I2C milestone: definition of done, the three blockers, the tick/bit timings, test strategy, ordered work list.
- [[plans/spi-pads]] — Plan: expose SPI MOSI/CS_N on `uio[2:3]` (SCLK/MISO already share the UART pads), with the budget delta and pad-level verification.
- [[plans/pe-ctrl-readback]] — Plan: evaluate a MISO response from the loader (echo vs status vs imem peek), with the pad mapping, budget delta, and test/mutation plan. No RTL change yet.
- [[plans/serdes-integration]] — Plan: integrate `pe_serdes` + `pe_codec_mux` into `pe_soc` (additive engine, DRU RX capture, two codec instances with encoded-cell enables, split `pe_serdes` payload enables, `0xF` indexed window) with tests, hardening risks and pad implications. Amended after two review rounds; scope decisions remain open.

## Decisions

- [[decisions/adr-001-8x-oversampling]] — ADR: target 8x oversampling for 10BASE-T receive.
- [[decisions/adr-002-latch-pair-det-flop]] — ADR: stdcell latch-pair dual-edge flop; no custom DDR.
- [[decisions/adr-003-memory-plan]] — ADR: two `1P_1024x16` macros (instructions + frame buffer); flop IMEM was 89% of the die, and you cannot buy 1.5 KB. Instruction half IMPLEMENTED.
- [[decisions/adr-004-program-counter-width]] — ADR: the SRAM swap required widening the PC and jump-target field; the memory alone delivered 128 usable words, not 1024.
- [[decisions/adr-005-60mhz-turbo]] — ADR: the turbo is **60 MHz, not 66** — 66 provably fails the 10BASE-T TX jitter conformance window at every edge placement; 60 is exact for every hard protocol with a 50%-finer RX grid.
- [[decisions/adr-006-pin-matrix]] — ADR: the pin matrix is a runtime per-pin `{out,oe,od}` file and it lives **inside** the SoC — the plan's "wrapper instantiates the matrix" is unimplementable, since the CPU's IO bus never leaves `pe_soc`.
- [[decisions/adr-007-pe-ctrl-passive-slave]] — ADR: `pe_ctrl` is a **passive SPI slave** at the wrapper boundary (host loads, `run` starts); a master would need a hardwired bootstrap FSM and a flash, because there is no ROM.

## Queries

(none yet)
