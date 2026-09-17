---
source_url: https://blog.janestreet.com/protocol-emulator-asic-competition/
ingested: 2026-09-17
sha256: 8cf3d1936838e57d7a15fb1931048e191ed53453ca270db3d98a0baf14139a17
---

# Can you design a chip? Announcing the protocol emulator ASIC competition

Jane Street Blog, 2026-09-10, by Benjamin Devlin and Anish Singhani.

## The challenge

Design an open-source, general-purpose protocol emulator ASIC. A small chip (tiny CPU with an instruction set for reading pins, writing pins, counting cycles, hitting timing precisely) that bit-bangs protocols in firmware rather than fixed logic. Useful for hardware debugging and reverse engineering.

The hard part is flexibility: reprogrammable enough to support new protocols after fabrication, within timing and I/O constraints. Inspiration: PIO state machines on the RP2040, PRU cores on TI Sitara parts.

- Start with UART, SPI, and I2C.
- Stretch goals: low-speed USB and 10Mbit Ethernet.
- Others to consider: JTAG, SWD, PS/2, CAN bus.
- FPGA-prototype the RTL before the ASIC flow if possible.
- Novel applications of the architecture are welcome.
- Verification matters: formal methods, random constrained tests, AI-assisted verification. Jane Street uses Hardcaml for their own FPGA/ASIC RTL.

## The rules

- Process: IHP 130nm CMOS5L via Tiny Tapeout. Start from the CMOS5L Verilog template (RTL to GDS). Set tile size in info.yaml to 8x4.
- Area: planned maximum 8x4 Tiny Tapeout tiles per design.
- Open source submission; build in public encouraged. Teams strongly recommended.
- Deadline: January 18th, 2027. Targeting the March 2027 CMOS5L shuttle (subject to foundry schedule).
- Prize: most novel designs get taped out; winners receive chips and dev boards.

## How much fits?

- 8x4 = 32 tiles, ~200 um x 150 um per tile, ~1 mm2 nominal tile area. Rough budget ~1K logic cells per tile.
- SRAM can beat flip-flops on area for instruction memory; Tiny Tapeout has SRAM examples on this node.
- Run synthesis early, check mapped cell area, leave room for clock-tree buffers and routing. Run full P&R and check timing — small-after-synthesis does not imply routable or fast enough.

## Getting started

Tiny Tapeout docs cover the flow end to end with free/open tools. Suggested path: get a UART transmitter out of a pin, then make it programmable. Sign-up form for updates; questions to asic-competition@janestreet.com.
