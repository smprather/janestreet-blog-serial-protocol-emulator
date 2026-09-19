# Wiki Index

> Content catalog. Every wiki page listed under its type with a one-line summary.
> Last updated: 2026-09-18 | Total pages: 17

## Start here

- [[STATUS]] — **Milestone status + resume-here after a context flush.** Read first.

## Entities

- [[entities/tiny-tapeout]] — Fabrication/tapeout platform and what constrains the design.

## Concepts

- [[concepts/competition-overview]] — Challenge, rules, area budget, timeline (blog-grounded; transcript corrections noted).
- [[concepts/physical-layer-gpio]] — CMOS-swing GPIO reality: what works natively, what needs workarounds.
- [[concepts/cdr-oversampling]] — 8x oversampled digital data-recovery unit for 10BASE-T; why 4x is rejected.
- [[concepts/clock-doubler]] — XOR delay-line doubler options: standard-cell + PDN hardening vs full custom.
- [[concepts/gpio-signoff-corners]] — FS/SF corners, SPICE bit-thinning extraction, SDC injection.
- [[concepts/factored-hardware-blocks]] — Shared RTL primitives (CDR, SerDes, stuffing, CRC LFSR); no 8b/10b needed.
- [[concepts/pdk-toolchain]] — Local IHP PDK + EDA bring-up: paths, corners, SRAM macros, install workarounds.
- [[concepts/tx-timing-generation]] — Exact-integer protocol timing at 40 MHz; NCO for fractional bauds; the forced-66MHz fallback.
- [[concepts/live-canvas]] — Side-quest tooling: agent→browser live diagram channel (dashboard plugin, file-write publish).
- [[concepts/strobe-and-committing-edge]] — What the strobe (`bit_en`) and the committing edge are, and the sample-order trap they cause.

## Reference

- [[reference/signal-names]] — Every RTL port: direction, width, meaning, validity. Port tables generated from the Verilog (drift-checked in `tb/run_all.sh`).
- [[reference/protocol-pin-budget]] — Per-protocol IO pin counts vs the TT pad budget (26 pads, 24 usable); what the board must add per protocol.

## Comparisons

- [[comparisons/clocking-options]] — External 80 MHz vs dual-edge 40 MHz vs internal doubler vs full-custom doubler.

## Decisions

- [[decisions/adr-001-8x-oversampling]] — ADR: target 8x oversampling for 10BASE-T receive.
- [[decisions/adr-002-latch-pair-det-flop]] — ADR: stdcell latch-pair dual-edge flop; no custom DDR.

## Queries

(none yet)
