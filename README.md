# Protocol Emulator ASIC — Jane Street competition entry

Entry for [Jane Street's protocol emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/):
design an open-source, general-purpose protocol emulator — a small chip whose
instruction set is built for reading pins, writing pins, counting cycles and
hitting protocol timing precisely, so protocols are implemented in **firmware**
rather than fixed logic. Target: IHP 130 nm CMOS5L via Tiny Tapeout, 6×4 tiles,
submission 2027-01-18.

**Status: Milestone 2 (the programmable core) complete — a UART running entirely
in firmware on real RTL. See [`wiki/STATUS.md`](wiki/STATUS.md), and
[`wiki/plans/through-i2c.md`](wiki/plans/through-i2c.md) for the work list.**

> Picking this up cold (human or agent)? Read **[`HANDOFF.md`](HANDOFF.md)** first
> — current verified state, the traps worth not rediscovering, and the next step.

## What exists today

| Block | File | Size (mapped, sg13g2 typ) |
|---|---|---|
| SERDES — 1–32 b word engine, runtime bit order, strobe-paced | `rtl/pe_serdes.v` | 539 cells / 11.2k µm² (17.2k µm² routed) |
| NRZI / Manchester / bit-stuffing codecs | `rtl/pe_line_codec.v` | 15 / 7 / 84 cells |
| Config-driven codec pipeline mux | `rtl/pe_codec_mux.v` | 115 cells / 1.7k µm² |
| **CRC / LFSR engine** — CRC-5/8/15/16/32, one datapath | `rtl/pe_crc.v` | 209 cells / 3.4k µm² |
| **DRU** — oversampled Manchester receive (10BASE-T, PS/2), dual-edge | `rtl/pe_dru.v` | 150 cells / 2.4k µm² |
| CPU — 16-bit insn, 16 opcodes, A/Y/X, PC width from IMEM depth | `rtl/pe_cpu.v` | 383 cells / 4.9k µm² |
| **Instruction memory** — real SRAM macro + protocol wrapper | `rtl/pe_imem.v` | 12 glue cells (+ the macro's LEF area) |
| Software-UART SoC — CPU + 1024-word SRAM + ticks + pin matrix | `rtl/pe_uart_soc.v` | 1,264 cells / 23.2k µm² |
| **Tiny Tapeout top level** — the deliverable | `rtl/tt_um_protocol_emulator.v` | 1,284 cells / 23.2k µm² |
| Assembler / bit-accurate emulator | `tools/peasm.py`, `tools/peemu.py` | Python |
| The UART itself — **as firmware** | `firmware/uart_echo.pe` | 114 words |

Verified by **26 self-checking testbenches + 17 firmware tests + a lint gate**
(`tb/run_all.sh`), including one TB per target protocol: UART, SPI, I2C, JTAG,
SWD, PS/2, CAN, USB-LS, 10BASE-T. The SERDES has been through the full
place-and-route flow: **0 DRC, 0 LVS, 66 MHz timing clean** (+7.6 ns setup slack
at the slow corner), reproducible with `flow/run_librelane.sh`.

`tb/lint.sh` runs Verilator `-Wall` plus a yosys elaboration check on every top,
and the regression fails if either finds anything. It exists because a green
testbench says nothing about the netlist: two drivers on one flop raced in Icarus
and became a constant 0 in yosys, and a hierarchical debug reference simulated
correctly while synthesising backwards. Neither is reachable from a testbench.

The headline is `tb/tb_pe_uart_soc.v`: **there is no UART in the RTL.** One input
pin, one output pin, a counter, and a program — 115200 8N1, echoing bytes at
8.6–8.7 µs per bit cell measured at the pin.

The instruction memory is a **real SRAM macro** (`1P_1024x16`, 1,024 program words)
behind `rtl/pe_imem.v`. Not built yet: the pin matrix (open-drain/OE), the word FIFO,
and the 2 KB frame buffer.

## Quick start

```bash
./tb/run_all.sh             # firmware regression, all 21 TBs, lint, doc drift
./tb/run_firmware_tests.sh  # just assemble + emulate the firmware
./tb/lint.sh                # verilator -Wall + yosys elaboration check
./tb/synth_area.sh          # mapped cell count + area per block (needs yosys + IHP PDK)

# the fast firmware loop: 2 seconds instead of a 1-minute RTL build
python3 tools/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex
python3 tools/peemu.py firmware/uart_echo.hex --send "41 42" --max-cycles 900000
```

Place-and-route (dockerized LibreLane; see `wiki/concepts/pdk-toolchain.md`).
The config is in the repo, so the signoff result is reproducible from a clone:

```bash
flow/run_librelane.sh flow/pe_serdes.json   # results under ~/asic-runs/
```

## Layout

```
rtl/      synthesizable Verilog (the hardware): pe_serdes, pe_line_codec,
          pe_codec_mux, pe_crc, pe_dru, pe_cpu, pe_uart_soc, and
          tt_um_protocol_emulator (the Tiny Tapeout top level — the only
          submittable module)
info.yaml Tiny Tapeout project metadata: tiles, clock, pinout
flow/     LibreLane config + runner, so place-and-route is reproducible
tb/       self-checking testbenches + run_all.sh / run_firmware_tests.sh /
          lint.sh / synth_area.sh
firmware/ protocol programs (.pe source, .hex assembled) — uart_echo is the UART
tools/    peasm.py (assembler), peemu.py (bit-accurate emulator),
          gen_*_budget.py (docs generated from RTL/PDK, drift-checked in run_all),
          live-canvas/ (optional dashboard diagram pane)
sim/      VCD waveforms from the testbenches (regenerated, not tracked)
wiki/     the design record — read STATUS.md; its Next-steps section is the work list
```

The `wiki/` is where the reasoning lives: competition rules and platform
constraints, protocol physical-layer analysis, timing plans and their arithmetic,
ADRs, the current work plan, and the toolchain notes (including the failure modes
worth not rediscovering). `wiki/STATUS.md` is the resume-here page, and its
Next-steps section is the live work list (`plans/through-i2c` is a completed plan,
kept for its findings).

## Design in one paragraph

Protocol logic belongs in **firmware**. A 383-cell CPU executes a program that
bit-bangs a protocol against pins and a counter; the UART exists only as
114 words of firmware. For protocols where a byte moves in one operation
(UART/SPI/CAN/USB) a shared SERDES does the datapath: a programmable divider
generates a `bit_en` strobe per bit cell, the SERDES converts words to/from bit
streams, and the codec pipeline applies line coding. A 60 MHz board clock (DDR
capture) makes every hard protocol's timing an exact integer number of ticks;
10BASE-T's 50 ns half-bit cell is the binding constraint at 3 ticks. Signoff is at
66 MHz so the part can be run faster than the protocols require. No PLL, no DLL.
The I2C plan picks bit-banging over the SERDES deliberately, because I2C's control
flow is per-bit — see `wiki/plans/through-i2c.md`.
