---
title: Project atlas — what the pieces are
created: 2026-09-26
updated: 2026-09-26
type: concept
tags: [architecture, protocol, verification, tooling]
sources: [rtl/pe_cpu.v, rtl/pe_soc.v, rtl/pe_ctrl.v, rtl/pe_pinmux.v, rtl/pe_serdes.v, rtl/pe_eth_mac.v, rtl/pe_eth_tx.v, rtl/pe_dru.v, rtl/pe_crc.v, rtl/pe_fbuf.v, rtl/pe_imem.v, rtl/tt_um_protocol_emulator.v, tools/host_gui/session.py, tools/host_gui/fake_pe.py, tools/host_gui/vectors.py, tools/host_bridge/pe_frame.py, docs/demo-walkthrough.md, wiki/STATUS.md, wiki/reference/block-diagram.md]
confidence: high
---

# Project atlas — what the pieces are

**What you'll learn here:** what the project is *made of*, in one page, before
any detail. If you have arrived from a log, a review, or a commit message and
hit a word you do not recognise — `fw-bus`, `pe_eth_mac`, a "persona", a
"golden package" — this is the page that decodes it.

**How to verify this page:** every block named here exists as a file in `rtl/`
or `tools/`, and every act exists in `firmware/`. The one-line roles are quoted
from those files' own headers. Then follow [[getting-started]], which runs the
project.

---

## The one-sentence shape

A small CPU with a programmable pin matrix speaks serial protocols by running
**programs**; the bits too fast for software are hardware; a host bus loads
those programs and can stop, step and inspect them while they run; and every
claim the project makes is pinned to a check that can prove it wrong.

Four things follow, and they are the whole architecture:

1. **The chip** — the RTL that becomes silicon.
2. **The host stack** — the code on your laptop that drives the chip.
3. **The firmware acts** — the protocols, each one a program. These are the
   product.
4. **The verification stack** — the checks that make the other three credible.

---

## 1. The chip — 16 RTL files in `rtl/`

| block | what it is, in one line |
|---|---|
| `tt_um_protocol_emulator` | the **deliverable**: the pad interface the foundry sees, wiring the rest together |
| `pe_cpu` | the CPU: 16 opcodes, 16-bit instructions, **single-cycle** |
| `pe_imem` | 1,024 × 16-bit instruction memory, on a hard SRAM macro |
| `pe_soc` | the processor plus RAM that can speak a protocol: the port map, the tick counters, and every window firmware reads |
| `pe_pinmux` | a runtime per-pin `{out, oe, od}` file — direction and open-drain, changeable by a program |
| `pe_ctrl` | the **host bus**: framed SPI, plus load, read, and the debug controls |
| `pe_serdes` | the **word engine**: paces 1–32-bit words at a rate firmware cannot reach |
| `pe_codec_mux`, `pe_nrzi`, `pe_manch`, `pe_bitstuff` | the line codecs: NRZI, Manchester, and bit stuffing, chosen by register |
| `pe_dru` | oversampled receive: finds edges in a 100 ns Manchester line |
| `pe_eth_mac` | Ethernet receive: locks on the SFD, assembles bytes, checks the FCS |
| `pe_eth_tx` | Ethernet transmit: preamble, FCS, padding, inter-frame gap |
| `pe_crc` | one CRC engine for CRC-5 through CRC-32 |
| `pe_fbuf` | the 2 KB frame buffer the MAC writes and firmware reads |
**The one idea worth carrying out of this table:** a protocol is normally a block
of gates. Here it is usually a **program** — a *persona* — and the gates stay
general. Only 10BASE-T is hardware, and that is arithmetic rather than taste: at
that speed the CPU has 48 instructions per byte and a software CRC-32 alone
needs about 240.

---

## 2. The host stack — the code on your machine

| piece | what it is |
|---|---|
| **Pico bridge** (`tools/host_bridge/`) | MicroPython on a Raspberry Pi Pico, on the Tiny Tapeout dev board; speaks the framed protocol to the chip over SPI |
| `pe_frame.py` | the bridge's implementation of the frame format — the **same contract**, written twice, on purpose |
| `ControllerSession` (`session.py`) | the state machine: `DISCONNECTED → PREPARED → LOADING → LOADED → RUNNING → STOPPED → FAULTED`, with the rules about what may follow what |
| `FakePE` (`fake_pe.py`) | an in-memory model of the chip, so the host can be developed and tested with no board |
| `Transport` | the serial link; `FakeBridge` is its stand-in for tests |
| the GUI (`server.py` + a browser page) | what an operator actually looks at |
| **golden packages** (`vectors.py`, `r2_vectors.py`, `r3_vectors.py`) | checked-in request/response bytes plus the model image they assume, generated from the model and required to match |
| fuzzers and soak (`fuzz_protocol.py`, `soak_host.py`) | hostile frames at both decoders, and a long run watching for leaks |

The bridge and the host implementing the *same* frame format independently is
the point: when a byte differs, one of them is wrong, and the golden package
says which.

---

## 3. The firmware acts — the protocols, and the two families

An **act** is one demonstrable protocol, presented as a unit in
`docs/demo-walkthrough.md`. An act is a **program** in `firmware/`, a
**testbench** that measures it on the pins, and a **model of the device** at
the other end. **Twenty-four** `.pe` programs exist in `firmware/`; the acts below
are the ones with a demo or a deep-dive page.

### The timing family — the waveform *is* the specification

These protocols have **no clock on the wire**. A receiver decides a bit by
sampling the line at one instant in each cell, so if you are one clock out you
are simply wrong — and a peer that resynchronises on every edge will never
notice.

| act | protocol | the idea that makes it instructive |
|---|---|---|
| `ws2812` | one-wire LED strip, 800 kHz | the cell is **exactly 75 clocks** at 60 MHz, and the 1-cell is 48 clocks — both exact, not fitted |
| `servo_sweep` | hobby servo PWM | a protocol with nothing in it but a number: 1–2 ms high, every 20 ms |
| `dht11_read` | temperature sensor | the **bit value is a width**; the receiver must synchronise, not count |
| `ds18b20` | 1-Wire temperature | the **device speaks first**, and a read slot's polarity is the opposite of a write slot's |
| `nec_ir` | infrared remote | **no wire at all**: light, and a 38 kHz carrier that cannot be late |
| `freqmeter` | frequency and duty | the first act that only **listens** |
| `sr04_range` | ultrasonic ranging | distance is computed by the firmware; the conversion is the act |
| `fm-biphase` | FM0/FM1 marking | a protocol judged on whether a *receiver* can read it — **concept page only so far**; no `.pe` exists yet, so this row describes the act's subject, not shipped firmware |

### The bus family — there is a clock, and a peer defines the edges

Here a bit cell is defined by the peer's clock, so firmware that runs slightly
fast still produces a readable waveform. That is the easier half, and it is where
the competition's baseline protocols live.

| act | protocol | note |
|---|---|---|
| `i2c_adv` | I²C combined format, read burst, clock stretch | open-drain, and the pin matrix is what makes it expressible |
| `spi_mode3` (+ CRC-8) | SPI mode 3 with a per-word CRC | CRC-8 in an ISA with **no XOR** |
| `uart_flow` | UART with RTS/CTS | flow control stated as one invariant |
| `midi` | MIDI 1.0 at 31.25 kbaud | a rate a fractional tick **cannot** express, and **running status** |
| `dmx512` | DMX512-A at 250 kbaud | a rate the tick cannot express at all; 512 slots need two counter bytes |

### The two odd ones out

- **I²C, UART and SPI basics** (`i2c_pins`, `i2c_xfer`, `uart_echo`, `spi_xfer`)
  are the competition's *baseline* protocols, kept as the foundation.
- **10BASE-T is not an act** — it is hardware, and the firmware only sequences
  frames. See [[concepts/ethernet-scope]].

---

## 4. The verification stack — why to believe any of it

| layer | what it is | what it catches |
|---|---|---|
| **testbenches** (`tb/`, ~45) | each measures its protocol **on the pins** and prints what it measured | a protocol that does not work |
| **mutation suites** (`regress/mutate_*.sh`, 16) | break the RTL *on purpose*, one plausible mistake at a time, and require the testbench to notice | a test that cannot fail |
| **documentation gates** | the wiki's own rules, its links, and its figures | documentation that has quietly gone stale |
| **lint** (`regress/lint.sh`) | elaboration warnings | constructs that are legal to simulate and wrong to synthesise — no testbench can catch these |
| **formal** (`formal/`) | properties proved for the hardware blocks, with mutants proving they are not vacuous | claims a testbench cannot reach |
| **process gates** | the single-run lock, the dependency pre-flight, the merge gate | a *green run that verified nothing* |

The theme: **a claim is only real once something can prove it wrong.** That is
why a claim in this project is always paired with the artefact that would catch
it being false.

---

## 5. Names table — decoding the shorthand in logs and reviews

Worker and workstream names appear constantly in `WORKLOG.md`, review filenames
and commit subjects. They are **log vocabulary, not project vocabulary** — but
a reader who does not know them cannot read the project's own history, so here
they are.

| name you will meet | what it is |
|---|---|
| `fw-bus` | the **bus-protocol firmware workstream** — the bus family above (I2C-advanced, SPI3+CRC, UART-RTS-CTS, MIDI, DMX-512) |
| `fw-timing` | the **timing-protocol firmware workstream** — the timing family above |
| `diag-*` | the **documentation and diagram workstreams** (`diag-bus`, `diag-proto`, `diag-timing`), which produce the concept pages and the figures |
| `gui` | the **host-side workstream** — the GUI, the bridge, `FakePE`, the golden packages |
| `protocol` | the **chip-side hardening workstream** — RTL, the host bus, STA and close-out |
| `wiki-features` | the documentation and manual layer (this tier) |
| `verify` | the verification and formal workstream |

> **A strong recommendation, recorded here so it is easy to apply:** every
> reader-facing page should speak in **domain names** — the acts, the
> protocols, the blocks — because those are the things the project *is*. The
> actor names belong to the logs. Where a page must cite a workstream, **this
> table is the link**: say "the bus-protocol firmware workstream (fw-bus)" the
> first time, and the reader can come back here.
>
> This page exists because of the observation that started it: *"I have no idea
> what fw-bus is."* A shorthand that saves an author eleven characters can cost
> a reader the whole document.

---

## Now go and do something

- [[getting-started]] — the hands-on track, with a runnable command at each step.
- [[glossary]] — every term above, and the ones the manual assumes.
- [[concepts/overview]] — how the layers fit, and what is *not* true yet.
