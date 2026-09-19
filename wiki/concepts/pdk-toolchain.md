---
title: PDK and Toolchain Setup
created: 2026-09-17
updated: 2026-09-18
type: concept
tags: [process-node, signoff, sta, spice]
sources: []
confidence: high
---

# PDK and Toolchain Setup

Local bring-up of the IHP sg13g2 design environment on CachyOS (Arch). All paths verified on-machine.

## PDK: ~/pdk/IHP-Open-PDK (1.2 GB, depth-1 clone of IHP-GmbH/IHP-Open-PDK)

- `ihp-sg13g2/libs.ref/sg13g2_stdcell`: lib, lef, gds, verilog, cdl, spice.
- `ihp-sg13g2/libs.ref/sg13g2_sram`: single-port 1P macros with BIST + bitmask, 256x16 up to 2048x64, each with fast/typ/slow .lib plus lef/verilog/gds/cdl. NO compiler — fixed macros only (upstream OpenRAM does not support sg13g2). Instruction-memory plan: pick the smallest macro that fits, or flops for tiny tables. Capacity analysis: [[reference/sram-budget]].
- `ihp-sg13g2/libs.ref/sg13g2_io`: lib/lef/gds/verilog/cdl/spice, 6 corners + dummy.
- `ihp-sg13g2/libs.tech`: checked-in tool configs for klayout, magic, netgen, ngspice, xyce, openroad, librelane, xschem, and more.

## Corners ( liberty vs SPICE)

- Liberty: 6 corners only — fast (1.32 V/-40 C, 1.65 V/-40 C), typ (1.20 V/25 C, 1.50 V/25 C), slow (1.08 V/125 C, 1.35 V/125 C). No FS/SF in .lib, as expected.
- SPICE (`libs.tech/ngspice/models/cornerMOSlv.lib`): mos_tt/ff/ss/**fs/sf** plus _mismatch and _stat variants. The [[concepts/gpio-signoff-corners]] FS/SF bit-thinning extraction is directly executable with ngspice (pre-installed).

## Flow tooling (~/venvs/asic + Docker)

- VERIFIED 2026-09-17: `librelane --docker-no-tty --dockerized --smoke-test -p ihp-sg13g2` PASSES (image ghcr.io/librelane/librelane:3.0.14). Full Classic flow runs in the container against volare build ddb601a4.
- pip-only install is officially unsupported: system yosys (0.68, no `-y`/pyosys flag) cannot run LibreLane's pyosys steps. Blessed paths are Nix or Docker; Docker daemon (v29.8.0) is what works here.
- `--docker-no-tty` is mandatory in headless shells (default `-t` allocation fails with "cannot attach stdin to a TTY-enabled container").
- Native tools on PATH (yosys, openroad, klayout, magic, netgen, ngspice) remain useful for standalone STA/SPICE/LVS side-quests outside the flow.
- `volare enable` needs the UNDERSCORE family name (`--pdk ihp_sg13g2`) plus an explicit version from `volare ls-remote --pdk ihp_sg13g2`.
- `volare`/`librelane` pip install on GCC 16: `pip install --upgrade pybind11 setuptools wheel`, then `CXX=g++ pip install --no-build-isolation volare librelane`.

## Lessons

- AUR installs must run as the user; passwordless sudo covers paru's internal sudo calls.
- Non-interactive shells emit `stty`/`tcsetattr` noise and bashrc `sort -hn` errors — cosmetic; check real exit state of the payload command, not the wrapper noise.

## Tool survey 2026-09-17 (Classic flow: 80 steps, tools = verilator/yosys/openroad/magic/klayout/netgen/eqy)

- Docker image (the execution env): yosys 0.62, openroad, klayout 0.30.7, magic 8.3.623, netgen, verilator 5.044, eqy — COMPLETE, proven by passing smoke test. Only standalone `slang` absent (SV parsing via slang inside the image unconfirmed; verilator covers lint either way).
- Native PATH: yosys 0.68 (abc built in, slang plugin loads — fine standalone; lacks only the `-y` pyosys flag the flow needs), openroad, klayout 0.30.10, magic 8.3.683, netgen, ngspice, verilator, iverilog.
- Natively missing, none blocking: eqy, slang standalone, opensta standalone (lives inside openroad), covered, cvc/graywolf/qflow (not used by this flow).
- Verdict: nothing missing for RTL2GDS. Native gaps affect only standalone side-quests outside the container.
