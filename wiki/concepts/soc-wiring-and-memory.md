---
title: The SoC wiring — the port-numbering rule, the pad map, memory and timing
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [architecture, physical-layer, protocol, constraint]
sources: [rtl/pe_soc.v, rtl/pe_imem.v, rtl/tt_um_protocol_emulator.v, regress/synth_area.sh, regress/sram_model.sh, reviews/2026-09-25/R3-STA.md]
confidence: high
---

# The SoC wiring

Everything the firmware reaches that is not a register: the port-numbering rule
the ISA forced, the port space and the pad map, the memory macro and its
fallback, and what synthesis and the mapped timing screen say about it. The core
these rules exist to serve is [[concepts/isa-and-soc]]; the pin matrix itself is
[[concepts/pin-matrix]].

## The port-numbering rule

**Outputs low, inputs high.** Bit 0 is the lowest output; the inputs occupy a
contiguous run of the high bits, and `PIN_IN_MASK` records where the split falls.
The write path *is* the rule: input bits keep their value, output bits take the
written value.

**Why a rule and not a per-pin convention:** firmware must set a pin with no
arithmetic. Under this rule the first output is always bit 0, so `LDI A, 1; OUT
PINOUT, A` raises it — no shift, no mask, no table. And the ISA forced *this*
rule: **there is no shift-LEFT instruction** (`0xA` is SHR, right). Had the
design put a value at bit *k*, "raise bit 3" would have cost a load, a shift
loop and a mask — two extra instructions per bit, on the path firmware uses most.

**The cost is paid on reads**, a deliberate trade: a read returns all 8 bits, so
firmware must MASK. The mask is the pin's own bit — `AND A, 8` for the shared
input — and since every pin test is a zero/nonzero test, the mask is a
**constant, not a shift**. Writes stay one instruction; reads cost two.

`PIN_IN_MASK` is the **reset direction** rather than a permanent property: it
seeds the matrix's OE register (`RST_OE = ~PIN_IN_MASK`), so reset is
bit-identical to the fixed-mask SoC it replaces, and firmware may change any
pin's direction at runtime. UART and SPI simply never do.

## The port space and the pad map

IO is a **4-bit port space** — sixteen addresses, `OUT port,a` / `IN a,port` —
and the peripherals hang off it in `pe_soc` rather than in the core. The SoC's
port numbers and the pin matrix's register addresses are *different* namespaces
([[concepts/pin-matrix]]); the indexed control window is port `0xF`.

**The pad map is owned by the wrapper**, `rtl/tt_um_protocol_emulator.v` — that
is the authoritative list, not `pe_soc`:

| pad | function |
|---|---|
| `ui_in[0]` | UART RX (also SPI MISO) |
| `ui_in[1]` | **run** — 1 = execute firmware, 0 = hold at PC 0 |
| `ui_in[2]` | 10BASE-T RX (Manchester line; port bit 7) |
| `ui_in[7:3]` | free |
| `uo_out[0]` | UART TX / SPI SCLK (one persona at a time) |
| `uo_out[1]` | IRQ_N — host fault, sticky, active low |
| `uo_out[2]` | 10BASE-T TX (reclaims `dbg_pc[0]`; port bit 7) |
| `uo_out[7:3]` | `dbg_pc[5:1]` — visible PC for bring-up |
| `uio[0:1]` | I2C SDA / SCL, open-drain |
| `uio[2:3]` | SPI MOSI / CS_N, push-pull |
| `uio[4:7]` | framed host bus: CS_N, MOSI, MISO, SCK |

The `run` strap is the one to remember: it is a **pin, not a host-bus
register**, which is why R2's read path and R3's debug control must treat it
differently ([[concepts/host-chip-protocol]]).

**Two tick counters, not one.** Port 7 (STATUS) is the UART **half-bit** tick at
260 clocks / 4.33 µs; port 4 (I2CTICK) is a free-running **1 µs** counter built
from `I2C_TICKS = CLK_HZ / 1_000_000 = 60` exactly, so it has no rounding error.
They are not the same size, and a conclusion about "the tick" is meaningless
without saying which — see [[concepts/i2c-on-the-matrix]] for the 1 µs one.

## SRAM macro versus the flop fallback

`pe_imem` is a **hard macro** with a fixed shape — 1024 × 16, 237 × 336 µm — so
it can be instantiated but **not parameterised**. A `FLOP=1` fallback synthesises
a register array at any depth, making the fallback *one parameter, not a
rewrite*: for tests, area experiments, and the harness. A generate-time
`$error` makes the illegal combination loud — `FLOP=0` is legal only at
`WORDS=1024`.

The cost of taking that fallback, re-measured on this tree with the flow and
liberty `regress/synth_area.sh` uses (yosys 0.69+post, sg13g2 typ corner):

| configuration | cells | area |
|---|---|---|
| `pe_imem` with the macro (`.bb.v` blackbox) | 12 | **186.88 µm²** |
| `pe_imem` with `FLOP=1` (register array) | 61,057 | **1,300,811.66 µm²** |

That is a **~6,960× difference**. The macro figure counts only the wrapper
logic — a blackbox contributes no cell area to yosys, because the macro's area
lives in the PDK, not in the netlist. So the fallback is for *simulation and
experiments* only, and a testbench that silently ran against it has verified
nothing about the memory — which is why `regress/sram_model.sh` **fails loudly**
when the PDK behavioural model is absent rather than substituting the flop array.
For reference, the core itself: **`pe_cpu` is 392 cells / 5,070.19 µm²**,
re-derived the same way.

## Synthesis and timing screens

`regress/synth_area.sh` reports each block at the sg13g2 typ corner, and reports
the memory blocks **twice** (`pe_imem_flop` and `pe_imem_macro`) — keeping the
fallback rule honest by the gate rather than by a comment.

The mapped pre-layout screen (`reviews/2026-09-25/r3-sta/`, 12 screens: two
designs × slow/typ/fast × ZERO/BOARD) reports **all setup met**, hold negative
at `pe_soc` under the ZERO assumption:

| screen | setup / hold (ZERO) | setup / hold (BOARD) |
|---|---|---|
| `pe_soc` slow / typ / fast | 0.00 / **−0.87, −0.61, −0.48** | 0.00 / −0.54, −0.42, −0.36 |
| `tt_um` slow / typ / fast | 2.21–7.12 / **−0.57, −0.44, −0.37** | unchanged |

The tightest hold is a **pre-existing** input-pad-to-imem-SRAM path, identical
in R2 and R3, recovering under the 1.0 ns board floor — a screening artefact of
the assumption-free ZERO variant, not a routed hold. R3 added **no new hold
class**: the attribution inventory is unchanged to within ±0.014 ns and holds
zero R3 debug endpoints.

## Limits

Mapped **pre-layout** only: no place-and-route, no DRC, no LVS, and **no board
has been run** — nothing here is hardware-confirmed. The area figures will move
with real placement. The 48-instruction budget is a property of *this* ISA at
60 MHz; a multi-cycle core would change it and the hardware/firmware split would
have to be redrawn. Note too the core has **no interrupts**, so two protocols at
once is a concurrency problem rather than an area one — answered with
store-and-forward into a frame buffer
([[concepts/ethernet-receive-path]]), not a second core.
