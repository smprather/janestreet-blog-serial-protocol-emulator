---
title: "Block diagram"
created: 2026-09-22
updated: 2026-09-22
type: reference
tags: [architecture, reference, verification]
sources: [rtl/, tools/synth_area.sh, wiki/plans/through-i2c.md]
confidence: high
---

# Block diagram

> **Generated** by `tools/gen_block_diagram.py`. The built/orphan split is
> checked against `rtl/` and `tb/run_all.sh` on every regression, so a block
> cannot be drawn as a signal path unless something instantiates it.

## What is in the chip today

Read this as **two styles coexisting on purpose**. The firmware core
bit-bangs pins; the SERDES is a word engine. [[plans/through-i2c]] argues
why, and the short version is that control flow is per-bit for I2C
(ACK, arbitration, clock stretch) and per-word for UART/SPI/CAN/USB.

```mermaid
flowchart TB
    subgraph BOARD["off-chip / board"]
        HOST["host loader<br/><i>a TB today; pe_ctrl later</i>"]
        WIRE["protocol pins<br/>ui_in / uo_out / uio"]
    end

    subgraph TT["tt_um_protocol_emulator — the deliverable"]
        subgraph SOC["pe_uart_soc"]
            CPU["<b>pe_cpu</b><br/>the ISA: 16 opcodes, A/Y/X, 8-bit datapath<br/><i>383 cells</i>"]
            IMEM["<b>pe_imem</b><br/>instruction memory; SRAM macro by default<br/><i>12 cells</i>"]
            TICK["tick timer<br/><b>260</b> clk = half a 115200 bit"]
            PORT["fixed-mask port<br/>PIN_IN_MASK = 8'hF8"]
            CPU --> IMEM
            CPU --> TICK
            CPU --> PORT
            IMEM -.->|FLOP=0| SRAM
        end
        SRAM["SRAM macro<br/>RM_IHPSG13 1P_1024x16"]
    end

    HOST -.->|"imem/dmem write port"| IMEM
    PORT -->|"drive"| WIRE
    WIRE -->|"sense"| PORT

    classDef built fill:#1f4d2e,stroke:#4ade80,color:#fff
    classDef plan fill:#4a1f1f,stroke:#f87171,color:#fff,stroke-dasharray: 5 5
    class CPU,IMEM,TICK,PORT,SRAM built
```

### Built, verified — and wired to nothing

These blocks pass their own testbenches but no SoC instance drives them.
Drawn as detached, because that is what they are:

```mermaid
flowchart LR
    pe_serdes["<b>pe_serdes</b><br/>word engine: load 8-32 bits, pace with bit_en<br/><i>539 cells</i>"]
    pe_dru["<b>pe_dru</b><br/>digital receiver unit: 12x oversampled edge recovery<br/><i>121 cells</i>"]
    pe_crc["<b>pe_crc</b><br/>CRC/LFSR generator, 8/16/32-bit, catalogue-checked<br/><i>209 cells</i>"]
    pe_pinmux["<b>pe_pinmux</b><br/>per-pin direction, open-drain, read-back (the I2C gate)<br/><i>111 cells</i>"]
    pe_codec_mux["<b>pe_codec_mux</b><br/>stuff -> nrzi/manchester; cfg selects the subset<br/><i>115 cells</i>"]
    classDef orphan fill:#3a2f0f,stroke:#facc15,color:#fff,stroke-dasharray: 5 5
    class pe_serdes,pe_dru,pe_crc,pe_pinmux,pe_codec_mux orphan
```

## The built blocks, and where they actually live

| block | role | instantiated in | cells | TB |
|---|---|---|---|---|
| `pe_cpu` | the ISA: 16 opcodes, A/Y/X, 8-bit datapath | pe_uart_soc.v | 383 | `tb_pe_cpu` |
| `pe_imem` | instruction memory; SRAM macro by default | pe_uart_soc.v | 12 | `tb_pe_imem` |
| `pe_nrzi` | NRZI encode/decode | pe_codec_mux.v | 15 | `tb_pe_codec_mux` |
| `pe_manch` | Manchester encode/decode | pe_codec_mux.v | 7 | `tb_pe_codec_mux` |
| `pe_bitstuff` | bit stuffing (CAN/USB style) | pe_codec_mux.v | 84 | `tb_pe_codec_mux` |
| `pe_serdes` | word engine: load 8-32 bits, pace with bit_en | **nowhere — orphan** | 539 | `tb_pe_serdes` |
| `pe_dru` | digital receiver unit: 12x oversampled edge recovery | **nowhere — orphan** | 121 | `tb_pe_dru` |
| `pe_crc` | CRC/LFSR generator, 8/16/32-bit, catalogue-checked | **nowhere — orphan** | 209 | `tb_pe_crc` |
| `pe_pinmux` | per-pin direction, open-drain, read-back (the I2C gate) | **nowhere — orphan** | 111 | `tb_pe_pinmux` |
| `pe_codec_mux` | stuff -> nrzi/manchester; cfg selects the subset | **nowhere — orphan** | 115 | `tb_pe_codec_mux` |

### Orphans: built, tested, and driving nothing

**5 of 10 blocks are instantiated nowhere in `rtl/`.**
That is not an accident and not a bug in the diagram — it is the project's
staging: each block was built and verified standalone before anything
wired it up. But it is worth stating plainly, because it is the single
biggest gap between "what is built" and "what the chip does":

- **`pe_serdes`** — word engine: load 8-32 bits, pace with bit_en
- **`pe_dru`** — digital receiver unit: 12x oversampled edge recovery
- **`pe_crc`** — CRC/LFSR generator, 8/16/32-bit, catalogue-checked
- **`pe_pinmux`** — per-pin direction, open-drain, read-back (the I2C gate)
- **`pe_codec_mux`** — stuff -> nrzi/manchester; cfg selects the subset

[[STATUS]] gotcha 14 is the rule this section exists to satisfy:
**"hardware nothing exercises is hardware you have not tested."** A block
with a passing TB is verified *in isolation*; that is weaker than verified
in the design, and the difference is exactly what this table shows.

## Planned, and why each one is a gate

| not built yet | what it unblocks |
|---|---|
| **pe_ctrl (SPI load path)** | boot the chip in real silicon; today the loader is a host port driven by the TB, so the chip cannot boot itself |
| **frame buffer (2nd SRAM)** | ADR-003; 10BASE-T needs 2 KB. Instruction macro only, so far |
| **pe_pinmux into the SoC** | plan step 5: put the matrix in front of the fixed-mask port |
| **I2C 1 us tick divider** | plan step 5: 60 clocks at 60 MHz, distinct from the 260 UART tick |
| **pe_serdes into the SoC** | the SERDES is routed and TB-proven but no SoC instance drives it |

## The two memory stories

There are two memories in the ADRs and only one in the RTL:

- **Instruction memory — BUILT.** `pe_imem` instantiates the PDK's
  `RM_IHPSG13_1P_1024x16_c2_bm_bist` by default (`FLOP=0`). This is the
  SRAM that carries the design's critical path (`A_CLK` -> `A_DOUT`,
  7.635 ns in context at the slow corner), and it is the reason the SoC
  needed its own STA run at all — see [[reference/sram-budget]].
- **Frame buffer — NOT BUILT.** ADR-003 plans a 2 KB frame buffer for
  10BASE-T (a max Ethernet frame is 1518 bytes, so the 1 KB parts miss by
  494). No RTL exists for it.

The `FLOP=1` path in `pe_imem` synthesises a register array instead of the
macro (60,806 cells vs 12). It exists for tests and area experiments and is
mapped separately by `synth_area.sh`; it is **not** what the SoC uses.

## Refreshing the cell counts

Counts come from `tb/synth_area.sh` (mapped, typ corner). To refresh:

```bash
./tb/synth_area.sh | awk 'NF>=3 && $2 ~ /^[0-9]+$/ {print $1, $2}' \
  > wiki/reference/.block-diagram-cells
python3 tools/gen_block_diagram.py
```

## Related

- [[reference/clock-arithmetic]] — the 60 MHz constants every block derives from.
- [[reference/signal-names]] — the port list, generated from the RTL.
- [[concepts/factored-hardware-blocks]] — why these blocks are factored this way.
- [[concepts/pin-matrix]] — the orphan that gates I2C.
- [[plans/through-i2c]] — the ordered work list.
- [[STATUS]] — what is built and verified, in prose.
