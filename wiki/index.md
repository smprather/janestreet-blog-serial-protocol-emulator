# Wiki Index

> Content catalog. Every wiki page listed under its type with a one-line summary.
> Last updated: 2026-09-20 | Total pages: 24

## Start here

- [[STATUS]] — **Milestone status + resume-here after a context flush.** Read first.

## Root reference (verbatim sources)

- [[raw/articles/janestreet-competition-blog-fulltext]] — **the competition blog, full verbatim text.** Primary source for every competition fact. Says 6x4 tiles; a living page that will change if 8x4 is offered.

## Entities

- [[entities/tiny-tapeout]] — Fabrication/tapeout platform and what constrains the design.

## Concepts

- [[concepts/competition-overview]] — Challenge, rules, area budget, timeline (blog-grounded; transcript corrections noted).
- [[concepts/physical-layer-gpio]] — CMOS-swing GPIO reality: what works natively, what needs workarounds.
- [[concepts/cdr-oversampling]] — 8x oversampled digital data-recovery unit for 10BASE-T; why 4x is rejected; BUILT (116 cells) and the filter trap found building it.
- [[concepts/clock-doubler]] — XOR delay-line doubler options: standard-cell + PDN hardening vs full custom.
- [[concepts/gpio-signoff-corners]] — FS/SF corners, SPICE bit-thinning extraction, SDC injection.
- [[concepts/factored-hardware-blocks]] — Shared RTL primitives (CDR, SerDes, stuffing, CRC LFSR); no 8b/10b needed.
- [[concepts/pdk-toolchain]] — Local IHP PDK + EDA bring-up: paths, corners, SRAM macros, install workarounds.
- [[concepts/tx-timing-generation]] — Exact-integer protocol timing at 40 MHz; NCO for fractional bauds; the forced-66MHz fallback.
- [[concepts/live-canvas]] — Side-quest tooling: agent→browser live diagram channel (dashboard plugin, file-write publish).
- [[concepts/ethernet-scope]] — what "10Mbit Ethernet" as a stretch goal actually asks for: the line layer, a 1.5 KB frame, and why 32 KB was never the requirement.
- [[concepts/strobe-and-committing-edge]] — What the strobe (`bit_en`) and the committing edge are, and the sample-order trap they cause.

## Reference

- [[reference/signal-names]] — Every RTL port: direction, width, meaning, validity. Port tables generated from the Verilog (drift-checked in `tb/run_all.sh`).
- [[reference/protocol-pin-budget]] — Per-protocol IO pin counts vs the TT pad budget (26 pads, 24 usable); what the board must add per protocol.
- [[reference/sram-budget]] — SRAM capacity vs the 8×4 die: every PDK macro's real size, what packs, and the area cost of 1–32 KB.
- [[reference/crc-config]] — every CRC constant `pe_crc` is loaded with, derived and checked against the RevEng catalogue's published values (generated).

## Comparisons

- [[comparisons/clocking-options]] — External 80 MHz vs dual-edge 40 MHz vs internal doubler vs full-custom doubler.

## Plans

- [[plans/through-i2c]] — Plan to the I2C milestone: definition of done, the three blockers, the tick/bit timings, test strategy, ordered work list.

## Decisions

- [[decisions/adr-001-8x-oversampling]] — ADR: target 8x oversampling for 10BASE-T receive.
- [[decisions/adr-002-latch-pair-det-flop]] — ADR: stdcell latch-pair dual-edge flop; no custom DDR.
- [[decisions/adr-003-memory-plan]] — ADR: two `1P_1024x16` macros (instructions + frame buffer); flop IMEM was 89% of the die, and you cannot buy 1.5 KB. Instruction half IMPLEMENTED.
- [[decisions/adr-004-program-counter-width]] — ADR: the SRAM swap required widening the PC and jump-target field; the memory alone delivered 128 usable words, not 1024.
- [[decisions/adr-005-60mhz-turbo]] — ADR: the turbo is **60 MHz, not 66** — 66 provably fails the 10BASE-T TX jitter conformance window at every edge placement; 60 is exact for every hard protocol with a 50%-finer RX grid.

## Queries

(none yet)
