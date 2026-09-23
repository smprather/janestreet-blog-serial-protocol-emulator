---
title: ADR-007 — pe_ctrl is a passive SPI slave, and it lives at the wrapper boundary
created: 2026-09-23
updated: 2026-09-23
type: decision
tags: [decision, architecture, boot, verification, pads]
sources: [rtl/tt_um_protocol_emulator.v, rtl/pe_soc.v, rtl/pe_imem.v, info.yaml, wiki/STATUS.md]
confidence: high
---

# ADR-007 — pe_ctrl is a passive SPI slave, and it lives at the wrapper boundary

## Status

**Accepted.** Resolves the open question at the end of
[[decisions/adr-006-pin-matrix]] ("should `pe_ctrl` also be an SPI master…"),
and fixes the loader's placement and pads for the same structural reason
ADR-006 moved the matrix *inside* the SoC: the pads are at the wrapper, and the
write port `pe_ctrl` must drive already crosses the SoC's boundary.

## Context

There is no way to get a program into instruction memory on silicon.
`rtl/pe_imem.v` has a host write port, but `rtl/tt_um_protocol_emulator.v`
ties `host_we`, `host_imem_sel`, `host_addr` and `host_wdata` to zero; the port
exists only for testbenches to preload. On power-up the SRAM macro holds
undefined contents, and it is volatile — there is no ROM and no non-volatile
program store anywhere in the design.

That last fact decides the master-vs-slave question before any board argument
does. An SPI **master** cannot be driven by "the SPI firmware path" at boot:
at boot there is no program in instruction memory for the firmware path to run.
A master mode would therefore require a **hardwired** bootstrap FSM plus a
flash part on the board, i.e. exactly the kind of protocol state machine this
project exists to avoid, bought to serve an environment (no host attached)
that every actual use of this chip has: an RP2040 on the Tiny Tapeout demo
board, an FTDI cable, or a bench MCU.

## Decision

**1. `pe_ctrl` is a passive SPI slave.** The host drives SCLK / MOSI / CS_N and
the chip shifts data into `pe_imem`. There is no master role, no flash, and no
bootstrap state machine.

**2. It is hardware, not firmware.** The no-ROM argument above is the whole
reason: the first program cannot load itself.

**3. It lives in `rtl/tt_um_protocol_emulator.v`,** between the loader pads and
the SoC's existing `host_*` port. The SoC is unchanged, and every existing
SoC-level testbench that drives `host_*` directly keeps working. Putting the
loader inside `pe_soc` would have meant three new SoC ports to arbitrate
against the host port the testbenches already use; the wrapper is also where
the pads it needs actually live.

**4. The v1 wire contract.**

| | |
|---|---|
| SPI mode | 0 (CPOL=0, CPHA=0): data is sampled on the **rising** SCLK edge |
| Bit order | MSB-first |
| Word width | 16 bits, written straight to `imem[addr]` |
| Framing | `CS_N` low resets the word address to 0 and enables the loader; every 16 rising SCLK edges write one word and increment the address; `CS_N` high ends the load |
| Partial word | a load that ends mid-word is discarded (and flagged) |
| `run` | stays the `ui_in[1]` strap; the loader accepts words only while `run == 0`, so it can never overwrite executing code |
| SCLK rate | ≤ ~10 MHz: the pin is asynchronous and goes through a 2-flop synchronizer ahead of the rising-edge detector |
| Scope | instruction memory only in v1; `dmem` writes and a MISO readback path are additive later changes |

**5. Pads.** `ui_in[3]` = SCLK, `ui_in[4]` = MOSI, `ui_in[5]` = CS_N. The
protocol bits 0–3, UART RX / ETH RX and `run` keep their assignments. The
loader does **not** share the matrix's SPI pads (bits 0–2): under
`PIN_IN_MASK = 8'hF8` the reset OE drives those three bits as outputs, so the
host cannot own them while `run` is low.

## Consequences

**The chip becomes bootable from any host with three spare pins.** That is the
whole return: load, raise `run`, and the deliverable runs a program chosen at
boot rather than one baked into simulation.

**`run` remains an explicit host decision.** The loader deliberately does not
auto-release the core on `CS_N` deassert: two host actions (load, then run) are
easier to observe on a scope and keep the existing `ui_in[1]` contract intact.
An auto-run mode is a later, one-line change if a board wants it.

**No readback in v1.** Without MISO the host cannot confirm words landed. The
chip's own outputs are the verification (a loaded program toggles pins /
sends bytes), and the TBs do check writes at the port level. A read path is a
later additive change — `host_addr`/`host_imem_sel` already select a source.

**A short load leaves the tail of instruction memory undefined.** The loader
writes exactly the words the host sends. A program that runs past its end is
undefined on silicon, so firmware should end in a self-jump (the existing
programs do) or the host should send a full image.

**Idle `CS_N` is high.** The existing TT testbench drives `ui_in = 0` at reset,
which reads as `CS_N` asserted; with SCLK static that is harmless, but the TB
idles `CS_N` high after this change so the state is honest.

**The loader is testable stand-alone and integrated.** `pe_ctrl` gets its own
TB (host-side bit-banging, word framing, CS reset, `run` gate) and the TT TB
gains a load-through-the-pads execution check; both are mutation-tested like
every other block.

## Alternatives considered

**SPI master, booting the chip from a flash part.** Rejected: there is no ROM,
so the master needs hardwired bootstrap logic rather than firmware; it adds a
board part and a flash model to the test suite; and every environment this chip
runs in already has a host. It optimizes for the one case that does not exist
yet.

**The loader as a firmware program.** Rejected: circular. The program that
would run the loader has to be in the memory the loader fills.

**Loader inside `pe_soc`.** Rejected: the SoC's `host_*` port is already the
loader's output boundary, and the pads are at the wrapper. Inside the SoC the
loader would need new ports and an arbiter against the port the testbenches
drive.

**Sharing the matrix's SPI pads (port bits 0–3).** Rejected: their reset OE is
"drive", so the chip owns SCLK/MOSI/CS at reset and the host cannot.

**A `pe_serdes`-based receiver instead of a fixed 16-bit shift register.**
Not rejected — deferred to the implementation plan. A fixed-width shift register
is smaller and easier to mutation-test; the SERDES is the project's shared word
engine and already does MSB-first receive, at the cost of a
`rx_start`/`rx_len`/`rx_valid` protocol around every word. The plan decides
with the cell counts in hand.

## Related

- [[decisions/adr-006-pin-matrix]] — the open question this ADR closes, and the
  placement argument it reuses.
- [[concepts/spi-as-firmware]] — the SPI firmware path the loader does not use,
  and why this is not a contradiction.
- [[reference/protocol-pin-budget]] — where the three loader pads fit.
- [[STATUS]] — "Next steps" item 2, now ruled.
- `rtl/tt_um_protocol_emulator.v` — the host port this drives.
