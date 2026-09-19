# Protocol Emulator ASIC — Jane Street competition entry

Entry for [Jane Street's protocol emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/):
design an open-source, general-purpose protocol emulator — a small chip whose
instruction set is built for reading pins, writing pins, counting cycles and
hitting protocol timing precisely, so protocols are implemented in **firmware**
rather than fixed logic. Target: IHP 130 nm CMOS5L via Tiny Tapeout, 8×4 tiles,
submission 2027-01-18.

**Status: Milestone 1 (shared hardware layer) complete — see [`wiki/STATUS.md`](wiki/STATUS.md).**

## What exists today

| Block | File | Size (mapped, sg13g2 typ) |
|---|---|---|
| SERDES — 1–32 b word engine, runtime bit order, strobe-paced | `rtl/pe_serdes.v` | 539 cells / 11.2k µm² (17.2k µm² routed) |
| NRZI / Manchester / bit-stuffing codecs | `rtl/pe_line_codec.v` | 12 / 5 / 84 cells |
| Config-driven codec pipeline mux | `rtl/pe_codec_mux.v` | 9 cells glue |

Verified by 14 self-checking testbenches (`tb/`), including one per target
protocol: UART, SPI, I2C, JTAG, SWD, PS/2, CAN, USB-LS, 10BASE-T. The SERDES has
been through the full place-and-route flow: **0 DRC, 0 LVS, 66 MHz timing clean**
(+7.6 ns setup slack at the slow corner).

Not built yet: the DRU (oversampled phase-picker), the programmable
sequencer/state machine, the pin matrix, and the assembler.

## Quick start

```bash
./tb/run_all.sh      # compile + run all 14 testbenches (~1 min, needs iverilog)
./tb/synth_area.sh   # mapped cell count + area per block (needs yosys + IHP PDK)
```

Place-and-route (dockerized LibreLane; see `wiki/concepts/pdk-toolchain.md`):

```bash
cd ~/asic-runs/pe-serdes
docker run --rm -i --user 1000:1000 \
  -v $HOME:$HOME -v $HOME/.ciel:$HOME/.ciel -e PDK_ROOT=$HOME/.ciel \
  -w $PWD ghcr.io/librelane/librelane:3.0.14 \
  python3 -m librelane -p ihp-sg13g2 -s sg13g2_stdcell config.json
```

## Layout

```
rtl/     synthesizable Verilog (the hardware)
tb/      self-checking testbenches + run_all.sh / synth_area.sh
sim/     VCD waveforms from the testbenches
wiki/    knowledge base: STATUS.md (resume here), concepts/, decisions/, raw/
```

The `wiki/` is the design record: competition rules and platform constraints,
protocol physical-layer analysis, timing plans and their arithmetic, ADRs, and
the toolchain notes (including the failure modes worth not rediscovering).

## Design in one paragraph

Everything is strobe-paced, so the core clock and protocol timing are
independent: a programmable clock divider generates a `bit_en` strobe per bit
cell, the SERDES converts words to/from bit streams, the codec pipeline applies
line coding, and firmware sequences it all. A 40 MHz board clock (DDR capture)
makes every hard protocol's timing an exact integer number of ticks; 10BASE-T's
50 ns half-bit cell is the binding constraint at 2 ticks. Signoff is at 66 MHz
so the part can be run faster than the protocols require. No PLL, no DLL.
