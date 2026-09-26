# Feature ideas — protocol emulator ASIC brainstorm (2026-09-26)

**Scope:** a brainstorm of features for the Jane Street protocol emulator ASIC
competition, from table stakes to outside-the-box ideas, written from the
competition post and Tiny Tapeout's published specs.

**Status check:** each idea carries a status, checked on 2026-09-26 against
`main` at `93e4c64` (including uncommitted working-tree changes) and the
unmerged `fw-bus-protocols` and `fw-timing-protocols` branches. Plan IDs such
as A2 or D3 refer to
[`wiki/plans/feature-brainstorm.md`](../wiki/plans/feature-brainstorm.md).

**Later on 2026-09-26:** the 10BASE-T blocker this check found (no link
pulses, a single-ended TX pad) is implemented on branch `eth-tx-line-driver`
— see [`wiki/plans/eth-tx-line-driver.md`](../wiki/plans/eth-tx-line-driver.md).
It is proposed, not merged, because it reclaims a pad.

| Status | Meaning |
|---|---|
| **Built** | on `main`, with a testbench or firmware test behind it |
| **Built, differently** | the project solved the same problem another way |
| **On a branch** | built on an unmerged branch |
| **Partial** | some of it exists; the note says what is missing |
| **Planned** | in the project brainstorm or the STATUS work list |
| **New** | not found in the repo |

## What the check found

- **Already built:** the 60 MHz clock with both-edge sampling, the
  line-coding pipeline, the CRC engine, Manchester clock recovery, the pin
  matrix, single-step debug, the SPI host link, mutation testing, a formal
  campaign, and 10BASE-T receive and transmit in simulation.
- **Blocker (fixed on branch `eth-tx-line-driver`, proposed):** 10BASE-T
  sent no link pulses, and its one single-ended transmit pin couldn't produce
  them cleanly, so a real switch or NIC would keep the link down and ignore
  every frame. See the 10BASE-T entry under Protocols.
- **New ideas that need no new pads or protocol RTL** (the project
  brainstorm's "What I would NOT build" rules): extra open-drain lines
  through external buffers, a "What is this signal?" persona, bus-health and
  RC-timing analog personas, a board bring-up persona, sigrok as an
  independent checker, and translating `.pio` programs on the host.
- **New ideas that need RTL** (decide against the area budget, like the
  project's Tier 2): WAIT with timeout, call/return, the reflex table and hot
  swap. **New ideas that need pads:** the chip's own USB port and the VGA
  monitor.

---

## What limits the design

- **Pins:** 24 in total: 8 input-only, 8 output-only and 8 bidirectional. Only
  the 8 bidirectional pins can act as open-drain (by toggling `uio_oe`), so
  I2C, SWD, 1-Wire, USB and PS/2 all compete for them.
- **Clock and pads:** the demo board's RP2040/RP2350 supplies the clock, up to
  about 66 MHz. Tiny Tapeout (TT) lists outputs at about 33 MHz maximum and up
  to about 20 ns round trip through its pin multiplexer. Those figures come
  from the older sky130 pad docs, so check them for IHP.
- **Area:** about 1K cells per tile, so roughly 24K cells at 6×4. Flip-flops
  are costly, so FIFOs and buffers should go in SRAM. TT's IHP SRAM example is
  a 1024×8 macro with one port.

**Repo check:** all three are already recorded.
`wiki/reference/protocol-pin-budget.md` counts 19 of 24 pads committed, with
bidirectional pads running out first. STATUS "Open questions" notes that the
IHP pad limits are unpublished. The top level maps to 7,960 cells, and both
memories use `1P_1024x16` macros (ADR-003) rather than the 1024×8 example;
SRAM, not logic, is the tight budget.

## Both-edge receive sampling, plus a 60 MHz clock

Receive data can be sampled on both clock edges. If the design meets timing at
60 MHz, that gives 120 million samples per second, 8.3 ns apart. 60 MHz also
gives a whole number of clock cycles per bit for almost every protocol on the
list:

| Protocol | Bit time | Cycles at 60 MHz |
|---|---|---|
| 10BASE-T (Manchester half-bit) | 50 ns | 3 |
| USB Full-Speed | 83.3 ns | 5 |
| USB Low-Speed | 667 ns | 40 |
| I2C Fm+, CAN 1 Mbit/s | 1 µs | 60 |
| WS2812 | 1.25 µs | 75 |
| USB-PD BMC | 3.33 µs | 200 |
| DMX512 | 4 µs | 240 |
| MIDI | 32 µs | 1920 |

That's 6 samples per 10BASE-T half-bit, 10 per USB Full-Speed bit, and 8.3 ns
resolution on every timestamp. Three things to watch:

- **Duty cycle:** the two edges are evenly spaced only if the clock is 50%
  duty. Generate it with an even divide (for example, RP2350 at 120 MHz,
  divided by 2 with PIO or PWM), or measure the offset at boot against a known
  signal.
  - **Status: built, differently.** ADR-002 accepts uneven sample spacing
    from board-clock duty error and relies on the DRU's per-edge re-sync.
- **Timing checks:** paths from falling-edge flops to rising-edge flops get
  only half a cycle (8.3 ns). Constrain them in static timing analysis (STA)
  and synchronize both samples.
  - **Status: built.** The latch-pair capture (ADR-002) is part of the
    60 MHz signoff.
- **Transmit:** keep it on one edge. Even 10BASE-T needs only 3 cycles per
  half-bit.
  - **Status: built.** `pe_eth_tx` sends 3-clock half-bits from one edge.

**Status: built.** 60 MHz is locked (ADR-005), and receive runs 12×
oversampled through a latch-pair both-edge front end (ADR-001, ADR-002,
`rtl/pe_dru.v`). Post-route signoff at 60 MHz shows +2.66 ns setup slack
(STATUS, "Timing margin").

## Table stakes

- **UART:** fractional baud generator, 5–9 data bits, parity, send and detect
  break, idle-line detect, auto-baud, and RS-485 driver-enable timing.
  - **Status: partial.** 115200 8N1 echo and RTS/CTS flow control run as
    firmware (`uart_echo.pe`, `uart_flow.pe`). Parity, break, auto-baud and
    RS-485 are not built.
- **SPI:** controller and target, modes 0–3, either bit order, any word
  length, several chip selects, 3-wire mode, and dual/quad lines for flash
  chips.
  - **Status: partial.** Controller mode 0 (`spi_xfer.pe`) and mode 3 with
    CRC (`spi_mode3.pe`) run as firmware. Target mode and dual/quad are not
    built.
- **I2C:** controller and target, clock stretching in both directions,
  repeated START, 10-bit addresses, multi-controller arbitration, and the
  SMBus checksum (PEC).
  - **Status: partial.** The controller handles repeated START,
    combined-format reads, clock stretching, arbitration loss and NACKs
    (`i2c_xfer.pe`, `i2c_adv.pe`). Target mode, 10-bit addresses and PEC are
    not built.
- **Host link:** load programs and stream data over SPI from the RP2350, with
  an interrupt line back.
  - **Status: built.** `rtl/pe_ctrl.v` is a framed SPI bus (load, status,
    reads, debug) with `IRQ_N`, driven by the Pico bridge and browser GUI in
    `tools/`. Only the hardware run is open (STATUS item 11).
- **Transaction commands, like FTDI's MPSSE:** the host sends "I2C write 0x50
  [00], read 16" and on-chip firmware does it, so casual users never write
  assembly.
  - **Status: new.** The host loads whole programs; there is no
    command-level API.
- **Safe power-on:** every bidirectional pin starts undriven and stays that
  way until a program claims it. Users will be clipping it onto unknown
  boards.
  - **Status: built.** Reset releases every pin and idles it high
    (`wiki/concepts/pin-matrix.md`).

## Architecture: departures from PIO and PRU

- **Program memory:** each RP2040 PIO block has 32 instructions shared by 4
  state machines. SRAM holds far more, but with one port the engines can't all
  fetch every cycle. Fetch round-robin into small per-engine loop buffers, and
  give every branch a fixed cost so timing stays predictable.
  - **Status: built, differently.** One CPU fetches from a 1,024-word SRAM
    macro (`rtl/pe_imem.v`), so there is no fetch contention to solve.
- **Timed I/O, as on XMOS chips:** instructions like "set this pin at time T"
  and "record when the next edge arrives", measured against a shared
  free-running counter. Timing no longer depends on counting instructions; the
  code only has to stay ahead of the schedule.
  - **Status: partial.** A free-running `TIMER` (port `0x5`) and a 1 µs tick
    (port `0x4`) exist, but nothing schedules a pin change; timing is
    counted loops.
- **Missed-deadline detector:** if a scheduled change's time has already
  passed, the chip raises a sticky error instead of toggling late. Timing bugs
  become visible.
  - **Status: partial.** `pe_eth_tx` flags a TX FIFO underrun instead of
    leaving a gap on the wire. Plans A5 and B5 (a persona that grades its
    own timing) are related.
- **WAIT with timeout, on several conditions at once:** pin pattern, edge,
  timer, FIFO state, or another engine's flag. A PIO WAIT can hang forever.
  - **Status: new.** There is no WAIT instruction; firmware polls in loops
    (`i2c_adv.pe` counts its clock-stretch polls).
- **A small real ALU:** add, subtract, compare with a constant, bit
  count/parity, bit reversal. PIO's only arithmetic is decrement and an X≠Y
  test.
  - **Status: partial.** `ALU` does add, subtract, AND and OR with an 8-bit
    immediate, plus `SHR`, `INCX` and `DECX` (`rtl/pe_cpu.v`). There is no
    XOR, shift-left, parity or bit reversal.
- **Loops and subroutines:** hardware loops with no per-iteration cost, plus a
  2–4 entry call stack.
  - **Status: new.** The CPU has no call/return or hardware loops.
- **Any signal on any pin:** each pin gets invert, open-drain and
  glitch-filter options, instead of PIO's contiguous blocks of pins.
  - **Status: partial.** `rtl/pe_pinmux.v` gives firmware per-pin output,
    output-enable and open-drain with pad read-back. Hardware engines use
    fixed pads (`eth_tx` is `uo_out[2]`), and there is no per-pin invert or
    glitch filter.
- **Direct FIFOs between engines:** one engine handles raw bits and passes
  bytes to another that handles packets. PIO state machines can only signal
  each other with flags; data goes through the CPU or DMA.
  - **Status: partial.** Firmware feeds `pe_eth_tx` through an 8-byte
    staging FIFO; a general word FIFO is listed as future work (README).
- **Reflex table:** a few pre-set "if the pins look like X, drive Y" rules
  that fire within one cycle, faster than any instruction. They cover the SPI
  target's reply bit, the CAN acknowledge bit and the USB reply deadline
  without hand-counted delays.
  - **Status: new.**
- **Two tiers:** tiny timing-exact engines for bits (the PIO approach) plus
  one small general-purpose core for CRCs, addressing, retries and the host
  protocol (the PRU approach). A bit-serial RISC-V such as SERV is small and
  can keep its registers in SRAM.
  - **Status: built, differently.** One firmware core plus dedicated
    hardware engines (the SERDES word engine and the Ethernet MAC);
    `wiki/plans/through-i2c.md` explains the split.
- **Hot swap:** double-buffered program memory, so a new protocol loads while
  the old one runs and takes over cleanly, without glitching the pins.
  - **Status: new.** `LOAD` forces `run=0` (README, host section).
- **Debuggable engines:** halt, single-step, breakpoints and a program-counter
  trace over the host link.
  - **Status: built.** Single-step and one breakpoint (`DEBUG_STEP`,
    `DEBUG_BP_SET` in `rtl/pe_ctrl.v`), register and memory reads, and the
    PC on the `dbg_pc` pads. Watchpoints and hit counters are plan A3.

## Hardware helpers that turn stretch goals into settings

- **Line-coding stages** between the shift register and the pin, chained as
  needed: NRZI, Manchester, biphase-mark, bit stuffing and unstuffing with a
  settable run length, 4b5b/GCR from a lookup table, and 38 kHz carrier
  modulation for IR.
  - **Status: partial.** NRZI, Manchester and bit stuffing form a
    configurable pipeline (`rtl/pe_nrzi.v`, `pe_manch.v`, `pe_bitstuff.v`,
    `pe_codec_mux.v`). FM0/FM1 biphase runs as firmware on branch
    `fw-timing-protocols`. 4b5b/GCR tables and carrier modulation are new.
- **CRC unit** on the bit stream, with settable polynomial, start value, bit
  order and final XOR, up to 32 bits. One unit covers USB, CAN, Ethernet,
  USB-PD, SMBus and SD cards.
  - **Status: built.** `rtl/pe_crc.v` covers CRC-5/8/15/16/32, with
    constants checked against the RevEng catalogue
    (`tools/gen/crc_config.py`).
- **Clock recovery:** locks onto incoming edges and nudges its timing
  CAN-style, picking whichever of the two edge samples is further from
  transitions. It also follows drifting UARTs on cheap RC-clocked devices.
  - **Status: built** for Manchester: `rtl/pe_dru.v` samples both edges at
    12× and re-locks on every edge. UART drift tracking is new.
- **Collision check:** compares what the chip drove with what the line
  actually shows, so I2C and CAN arbitration happen in hardware.
  - **Status: partial.** Released pins read the pad, and `i2c_xfer.pe`
    detects arbitration loss in firmware. There is no hardware compare, and
    CAN is only tested at the SERDES level.
- **Extra open-drain lines:** join one output pin and one input pin through an
  external open-drain buffer, and the chip treats the pair as one line. That
  gets around the 8-pin limit.
  - **Status: new**, and aimed at a known gap: the pin budget finds
    bidirectional pads run out first.

## Protocols

- **USB Low-Speed:** NRZI, bit stuffing, CRC-5/16, end-of-packet detection,
  and a reply that must start within a few bit times. The reflex table plus
  the line-coding stages make this routine.
  - **Status: partial.** NRZI and bit stuffing pass a SERDES-level test
    (`tb/tb_pe_usb.v`). There is no persona, end-of-packet handling or reply
    timing.
- **10BASE-T:** two outputs into a resistor network (ideally with a pulse
  transformer) to transmit, a link pulse every 16 ms, an external comparator
  into one input to receive with both-edge sampling, and CRC-32.
  - **Status: partial, two of three gaps closed on a branch.** Receive
    (`pe_dru` → `pe_manch` → `pe_eth_mac` into a 2 KB frame buffer) and
    transmit (`pe_eth_tx`: preamble, pad, FCS, gap) pass in simulation, with
    ARP frames both ways. The first two gaps below are implemented on branch
    `eth-tx-line-driver` (proposed: `eth_tx_n` on `uo_out[3]`, 16 ms link
    pulses, a 300 ns TP_IDL; see `wiki/plans/eth-tx-line-driver.md`); the
    third is board hardware. The gaps as found:
    - **No link pulses.** A partner that sees no ~100 ns pulse every
      8–24 ms for 50–150 ms disables its transmitter and receiver, so every
      frame is dropped.
    - **One single-ended TX pin that idles high.** The board has to AC-couple
      it (half the swing), and a positive link pulse can't start from a high
      idle. A second pad (`eth_tx_n`, reclaimed from `dbg_pc` as STATUS
      item 4 allows) gives the three line states 10BASE-T needs: +, − and
      0 V idle.
    - **Receive needs a comparator** with a squelch threshold between the
      magnetics and `ui_in[2]`. The pin budget's other options fit poorly: a
      resistor network alone leaves detection to the pad's input threshold,
      and an external PHY does its own Manchester, bypassing `pe_manch` and
      `pe_dru`.
- **CAN, JTAG, SWD, PS/2:**
  - CAN needs bit timing, the collision check, bit stuffing and the
    acknowledge bit.
  - SWD needs parity and bus turnaround.
  - PS/2 needs to follow a clock driven by the device, and the host holding
    the clock low to pause it.
  - **Status: partial.** Each passes a SERDES-level testbench
    (`tb_pe_can.v`, `tb_pe_jtag.v`, `tb_pe_swd.v`, `tb_pe_ps2.v`); none runs
    as a persona on the SoC yet.
- **Ones the judges may not expect:**
  - USB Power Delivery on the CC wire (300 kbit/s, 4b5b, CRC-32; needs a small
    analog front end).
  - Game controllers: N64/GameCube, NES/SNES, PlayStation.
  - Apple ADB, and bidirectional DShot for drone speed controllers, which
    sends GCR-coded telemetry back.
  - DCC model railroad control and DALI lighting.
  - HDMI-CEC and SENT automotive sensors.
  - DMX512, MIDI and WS2812 LEDs.
  - 1-Wire, LIN, Wiegand and IR remotes.
  - **Status: partial.** WS2812, 1-Wire (DS18B20) and NEC IR receive run as
    firmware on `main`; MIDI and DMX512 are on branch `fw-bus-protocols`.
    The rest are new. The project also has personas this list missed:
    DHT11, HC-SR04 ranging, servo, a stepper ramp and a frequency meter.
- **Moonshot:** USB Full-Speed, which is 5 cycles per bit at 60 MHz. Pad drive
  strength and edge speed are the likely blockers.
  - **Status: new.**

## The same chip as a bench instrument

- **Logic analyzer:** records a timestamp only when a pin changes (8.3 ns
  resolution), keeps a rolling buffer from before the trigger, and ships with
  a sigrok driver so PulseView works out of the box.
  - **Status: planned.** B4 (a persona that timestamps edges with the
    existing timer) and A2 (flight recorder). STATUS notes there is no host
    streaming path; captures would be read with `READ_DMEM`.
- **Decoded capture:** engines decode while capturing and store bytes and
  events instead of raw samples. Captures last far longer in 1 KB, and
  triggers can be protocol-aware, such as "I2C write to 0x50".
  - **Status: planned.** G5 (analyser personas). The DS18B20 and NEC
    personas already receive but don't report.
- **"What is this signal?":** measures pulse widths and edge patterns to guess
  the UART baud rate, SPI mode, I2C or Manchester.
  - **Status: new.**
- **Margin testing:** sweeps sample timing to find where a receiver or device
  under test starts failing, and adds controlled jitter to measure its
  tolerance.
  - **Status: planned.** B3 (margin maps) and C3 (margin hunting). A
    60-phase timing sweep already exists for I2C
    (`tools/checks/i2c_xfer_check.py`).
- **Bus health:** releases an I2C line and times the rise to estimate pull-up
  strength and bus capacitance. It also measures frequency, period and duty
  cycle, and tests bit error rates with pseudo-random patterns.
  - **Status: partial.** A frequency/duty meter runs as firmware
    (`freqmeter.pe`). Rise-time estimation and bit-error testing are new,
    though `pe_crc` already doubles as an LFSR.
- **Analog readings from digital pins:** RC-timing ADC, capacitive touch, and
  a 1-bit sigma-delta DAC through an external resistor and capacitor.
  - **Status: new.**
- **Board bring-up helper:** scans I2C addresses, reads SPI flash IDs, lists
  JTAG device IDs and searches the 1-Wire bus, then reports what's on the
  board.
  - **Status: new.**
- **Mini chip tester:** drives and checks test patterns on each pin with masks
  and timing, so this chip can test other chips, including other Tiny Tapeout
  projects.
  - **Status: new.**

## Verification (Jane Street explicitly calls this out)

- **One source of truth for the instruction set,** written in Hardcaml/OCaml.
  The RTL decoder, assembler, disassembler, cycle-accurate simulator and docs
  are all generated from it, so they can't drift apart.
  - **Status: partial.** A Python assembler and bit-accurate emulator
    (`tools/fw/`) plus generated, drift-checked reference pages
    (`tools/gen/`). The RTL is hand-written Verilog, not Hardcaml. A
    protocol-description language is plan D1.
- **Formal proofs:**
  - Check every executed instruction against the reference model through a
    trace port, as riscv-formal does for RISC-V.
  - Prove pin-routing rules, such as "no pin is driven by two engines unless
    shared open-drain is on".
  - **Status: partial.** 10 properties over 5 modules, with mutants and
    vacuity labels (`formal/results/summary.txt`). `formal_pe_cpu.v` proves
    the debug-control contract, not per-instruction semantics. Pin-matrix
    safety has its own proof (`formal_pe_pinmux.v`, ADR-006).
- **Timing proofs for firmware:** write delays in ns/µs, have the assembler
  convert them to cycles for the actual clock, and prove every protocol timing
  rule (for example, I2C tSU;STA ≥ 4.7 µs) from notes in the source.
  - **Status: partial.** Per-protocol checkers
    (`tools/checks/i2c_timing.py`) and generated clock arithmetic
    (`tools/gen/clock_arithmetic.py`) exist; datasheet-driven checks are
    plan D3. Timing notes in the assembly source are new.
- **Independent checkers:** run simulated waveforms through sigrok's protocol
  decoders, so correctness isn't judged only by the project's own code.
  - **Status: partial**, with different checkers: CRCs are checked against
    the RevEng catalogue and I2C against independent slave models. sigrok
    is new.
- **Random and mutation testing:** run random programs on the RTL and the
  reference model and compare. Then use mutation testing (Yosys `mcy`) to show
  the testbench catches deliberately planted bugs.
  - **Status: partial.** 16 mutation harnesses (`regress/mutate_*.sh`) and
    formal mutants are built, as are seeded fuzzers for the host protocol
    (`tools/host_gui/fuzz_*.py`). Random programs compared between RTL and
    the emulator are new.
- **AI behind a gate:** let an LLM draft protocol programs and assertions from
  datasheets. Accept only what passes the timing prover, the independent
  checkers, and a check that the assertions aren't trivially true.
  - **Status: planned.** D2 (natural language to persona, gated by
    measurement).
- **One test suite on three platforms:** ASCII-waveform tests, Jane Street's
  own style, that run unchanged on the simulator, an FPGA and the returned
  chip.
  - **Status: partial.** Golden request/response packages
    (`tb/r2-vectors`, `tb/r3-vectors`) are shared by the RTL testbenches and
    the host's fake chip. Golden waveforms are plan B2, and there is no FPGA
    flow.
- **Self-checking silicon:**
  - SRAM built-in self-test.
  - Internal loopback: one engine talks to another over virtual pins to run a
    conformance suite.
  - Counters showing which opcodes and branches ever ran.
  - A ring oscillator that reports how fast this particular chip's silicon
    turned out.
  - **Status: partial.** Loopback exists on the host bus (target 1) and
    pad-to-pad for Ethernet (`tb_pe_soc_eth_loop.v`). Self-conformance is
    plans E3 and G4, and coverage counters are plan A4. SRAM self-test and
    the ring oscillator are new.

## Outside the box

- **Time-travel debugging:** the engines always do the same thing given the
  same inputs. Record only timestamped input edges and the simulator can
  replay a real-silicon session exactly, internal state included. Also stream
  a trace from the chip and compare it with the simulator: the first
  difference shows exactly where silicon and model disagree.
  - **Status: planned.** A1 (reverse execution) and A2 (flight recorder)
    rest on the same determinism.
- **Protocol rule checking on real boards:** turn SystemVerilog-style
  assertions ("SDA never changes while SCL is high, except for START/STOP")
  into monitor programs that watch a real bus and timestamp every violation.
  It's a protocol linter for other people's boards.
  - **Status: planned in part.** G5 (analyser personas) covers listening;
    checking against written rules is new.
- **Programming by example:** capture a device's traffic, generate a program
  that imitates it, and compare several captures to find which fields vary.
  That lets you fake undocumented parts in tests.
  - **Status: new.**
- **Simulated device on real pins:** a Python or Verilator model of a
  peripheral runs on the PC and appears on real pins. The chip handles the
  fast parts and uses flow control (clock stretching, NAK/retry) to buy the PC
  time. Firmware can then be tested against sensors that don't exist yet.
  - **Status: new.**
- **Its own USB port:** a V-USB-style Low-Speed USB stack running on the
  chip's own engines removes the need for an FTDI or RP2350 bridge. The chip
  speaks the protocol it's controlled over.
  - **Status: new.** The host link is SPI through the Pico, and USB would
    need two bidirectional pads.
- **Answers ping over 10BASE-T:** it builds ARP and ICMP echo replies on the
  fly, with the ALU doing the IP checksum and the CRC unit doing CRC-32. A
  0.7 mm² chip you can ping is a memorable demo.
  - **Status: partial.** An ARP request and a TX→RX loopback run in
    simulation (`eth_tx_arp.pe`, `eth_arp_echo.pe`). ICMP is missing, and
    `wiki/concepts/ethernet-scope.md` puts the IP stack off-chip. The link
    fixes are on branch `eth-tx-line-driver`; the board front end is not
    built.
- **One program, eight channels:** treat the 8 pins of a port as parallel
  lanes and run one program across all of them, giving 8 UART receivers, 8
  servo outputs or 8 1-Wire buses from a single engine.
  - **Status: new.**
- **More protocols than engines:** save and restore an engine's state in SRAM
  so slow protocols take turns on the same engine.
  - **Status: planned in part.** F4 (the protocol chord: four protocols
    from one timer); saving and restoring state is new.
- **Standalone converters:** PS/2 keyboard to USB keyboard, NES controller to
  USB, UART to I2C, MIDI to PWM, with two protocols linked by an internal FIFO
  and no PC.
  - **Status: new.** The pin budget names a "bus-converter persona" as the
    case to design the pin matrix around.
- **Bus monitor on a VGA screen:** one engine drives VGA through the Tiny VGA
  PMOD and shows decoded traffic as text, so no PC is needed.
  - **Status: new**, and it needs pads the project doesn't have spare.
- **Timing-rule compiler:** describe a protocol as timing rules ("SDA falls at
  least 4 µs after SCL rises"). The compiler schedules the instructions and
  outputs the timing proof along with the program. The instruction set is
  small enough to formally check whole programs against the protocol spec.
  - **Status: planned.** D1 (one description, three consumers) and D3 (a
    datasheet table as a conformance matrix).
- **Reuse PIO programs:** an assembler front end that translates existing
  RP2040 `.pio` programs (WS2812, I2S, VGA and more), so there's a library on
  day one.
  - **Status: new.**

## Recommended focus

This won't all fit in about 24K cells. The strongest subset to build around:

1. **Timed I/O, the missed-deadline detector and firmware timing proofs.**
   Timing becomes correct by design, checked three ways: in the assembler,
   formally in the RTL, and live on the chip. It's the strongest answer to
   "what would you do differently from PIO" and matches Jane Street's interest
   in verification.
   - **Status: partial.** The timer, the underrun flag and per-protocol
     timing checkers exist; plans A5, B5 and D3 cover much of the rest.
2. **Line-coding stages, clock recovery and both-edge sampling at 60 MHz.**
   They make USB Low-Speed and 10BASE-T a matter of settings rather than
   heroic firmware.
   - **Status: built.**
3. **One showstopper demo:** ping over 10BASE-T, or the chip showing up as its
   own USB device.
   - **Status: partial.** ARP over 10BASE-T works in simulation, and branch
     `eth-tx-line-driver` adds the link pulses and the TX pair; a live demo
     still needs the board front end (line buffer, magnetics, comparator).
4. **Time-travel replay,** as a verification story no other entry is likely
   to have.
   - **Status: planned** as A1 and A2.

## Sources

- [Jane Street: Can you design a chip? Announcing the protocol emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/)
- [Tiny Tapeout clock spec](https://tinytapeout.com/specs/clock/)
- [Tiny Tapeout GPIO spec](https://tinytapeout.com/specs/gpio/)
- [Tiny Tapeout CMOS5L Verilog template](https://github.com/TinyTapeout/ttihp-verilog-template/tree/cmos5l)
- [Tiny Tapeout IHP SRAM example](https://www.tinytapeout.com/chips/ttihp0p2/tt_um_urish_sram_test)
- [Micro Linear ML4658 10BASE-T transceiver datasheet](https://www.cdiweb.com/datasheets/microlinear/ds4658.pdf) (link-pulse timing, squelch thresholds, idle drive)
