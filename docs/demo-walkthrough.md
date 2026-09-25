# Demo walkthrough — Protocol Emulator: one FPGA, a laptop, four protocols

This is the judge-facing script for demonstrating the entry. It covers what the
chip does, how the host controller drives it, what is *proven* versus
*simulated* versus *pending hardware*, and how to demo without a board.

Every claim below is backed by a checked-in artifact (a testbench, a
regression log, or a host test). Where something is not proven yet, it says
so — a judge should be able to tell the difference at a glance.

## The one-sentence pitch

A single synthesizable microcontroller-grade core, running protocol logic as
*firmware* instead of gates, exposes UART, SPI, I2C and 10BASE-T over its pin
matrix; a local browser UI on a laptop loads programs into it and observes it
over a USB-attached dev board, and the whole thing is verified by a
regression that runs in about a minute.

## 60-second architecture view

```
  ┌──────────── laptop (Linux) ────────────┐   USB CDC   ┌──── dev board ────┐   SPI   ┌──── shuttle ────┐
  │  browser UI  ← WebSocket →  host stack  │  newline    │  Pico/RP2040     │ mode-0  │  protocol       │
  │  (tools/host_gui)   transport/session  │  JSON       │  bridge           │ host    │  emulator SoC   │
  │                    ↕ PE frame codec    │  ─────────► │  (tools/host_     │ SPI ───► │  pe_cpu + SRAM  │
  │  transport ────────────────────────────┘             │   bridge)        │         │  + pin matrix   │
  └──────────────────────────────────────────────────────┤  uio[4:7]        │         │  + 10BASE-T     │
                                                         └──────────────────┘         └─────────────────┘
```

The design bet is in the middle box: protocols are *programs* the CPU runs, so
a protocol persona is a `.pe` file, not a Verilog block. The cost of that bet
(a slower bit-banged core) is paid deliberately: 260 clocks per half UART bit
at 60 MHz gives 115,385 baud against a nominal 115,200 (+0.16 %), which every
frame in the demos is checked against.

## The four protocol acts (each is a real artifact)

1. **UART — 115200 8N1 echo.** `firmware/uart_echo.pe` (118 words) echoes
   bytes on the pin matrix. Proven on RTL by `tb_pe_soc_uart`, which drives a
   real waveform in and decodes the real waveform out, passing on `41/42/00/FF`
   with a measured 8.6–8.7 µs bit cell. On the emulator it is
   `python3 tools/fw/peemu.py firmware/uart_echo.hex --send "41 42"`.
2. **SPI — mode-0 master.** `firmware/spi_xfer.pe` is a mode-0 master against
   a slave model; the same mode-0 engine also carries the host load path.
3. **I2C — a real transaction.** `firmware/i2c_xfer.pe` (311 words) does
   START, address+write, ACK, data, repeated START, address+read, NACK, STOP.
   Proven against an independent Verilog slave FSM *and* across all 60 clock
   phases; the golden tests caught arbitration loss, a missed NACK, and missing
   SCL stretch handling — all three now fixed and covered.
4. **10BASE-T Ethernet — both directions.** A receive MAC that
   validates the FCS, guards committed bytes and streams frames into a
   firmware-visible window (`eth_rx.pe`), plus a transmit path that emits
   real Manchester cells onto the pad and decodes them back at the pad
   (`tb_pe_eth_tx`: an ARP reply is stored as 60 bytes and re-decoded from 576
   wire bits). Firmware programs drive both (`eth_arp_echo`, `eth_tx_two`, a
   wrap probe and a busy probe).

## The three timing acts — where the waveform IS the specification

The four protocols above all have something to decode: a start bit, a clock edge, an
ACK. Get a bit slightly wrong and the peer resynchronises. The three acts below
are the opposite, and they are why this project can claim *cycle* accuracy
rather than merely "works on the bench": **there is no clock on the wire, the
value is a pulse width, and a firmware that is one clock out is wrong.**

They are also the cheapest thing to demonstrate live, because each is a `.pe`
file and a testbench, and each testbench prints its measurements.

**5. WS2812 — 800 kHz one-wire, GRB, 24 bits, cycle-exact.**
`firmware/ws2812.pe` (129 words) drives a strip on pin 6. 1.25 µs per cell is
**exactly 75 clocks** at 60 MHz, with no remainder, and the bit cell is
straight-line code — so the period is the *length of the program*, not a count
calibrated against a tick. `tb_pe_soc_ws2812` measures on the pads: every 1-cell
high for **exactly 48 clocks (800.0 ns, the datasheet's nominal tHIGH1)**, every
0-cell for exactly 0, the 24 cells spanning exactly 24 × 75 clocks, and every
1-cell's rising edge on the 75-cycle grid. It runs the strip twice, so the >50 µs
reset *between* frames is measured too (62.3 µs measured).

> The grid check is the one that earns the word "cycle-accurate". A cell that was
> 74 or 76 clocks still clears every datasheet window in the world — it is still
> 1.23 µs — and a decoder that resynchronises on every rising edge would never
> notice. The mutation suite includes exactly that mutant, and the TB catches it.

**6. Servo PWM — 50 Hz, 1–2 ms, five positions.**
`firmware/servo_sweep.pe` (84 words) sweeps 1000, 1500, 1750, 1250 and 2000 µs.
Each position carries **its own gap, chosen as 20 ms − its own pulse**, so the
frame is a *slot* and the rise-to-rise is 20 ms whatever the pulse is. Measured:
**19 999.95 µs = 50.000 Hz**, and the five widths land within 0.15 µs of nominal.
The order is deliberately not monotonic, so a firmware that emitted the right
widths in the wrong order fails.

> The two full 20 ms slots are what the 50 Hz claim rests on; the last three
> positions use a 2.5 ms gap. That trade is stated in the firmware header and the
> TB prints the short gaps rather than hiding them.

**7. DHT11 — a start signal and a 40-bit timed read.**
`firmware/dht11_read.pe` (134 words) drives the 18 ms start signal, the 30 µs
host-high window, then releases the line and **reads 40 bits whose value is a
pulse width** (26–28 µs high = 0, 70 µs = 1). `tb_pe_soc_dht11` models a sensor
driven at the **worst case of each window** and checks the sample margin on both
sides: **17.0 µs past the longest 0-release, 25.0 µs before the 1-release ends**.

> The host **synchronises on the data line's edges** rather than counting
> milliseconds per bit, because the sensor's 0-bit is 76–78 µs long and a
> fixed-wait host drifts 40 µs over twenty zero bits — three times the margin.
> That is the single most useful thing this act demonstrates, and it is a
> firmware property, not a hardware one.

### What the three acts cost, and what they prove about the claim

| | WS2812 | Servo | DHT11 |
|---|---|---|---|
| firmware | 129 words | 84 words | 134 words |
| simulated time | 65 µs | **52.5 ms** | **22 ms** |
| regression time | 0.4 s | **66 s** | 29 s |
| the number that is the claim | 48 clocks, exactly | 20 ms, ±0.005 µs | 17/25 µs of margin |
| mutants caught | 5/5 | 4/4 | 5/5 |

`regress/mutate_timing_tb.sh` runs those 14 firmware mutants in parallel on
private copies and then verifies the tree was never written to. It exists because
the DUT of these three is partly a *program*: nothing in `rtl/` can notice that a
cell is one clock short.

**The honest cost:** the servo and DHT11 testbenches simulate milliseconds, so
the full regression's wall time goes from about a minute to about three. The
frame rate is measured on two slots rather than five, and the three TBs dump a
narrow set of signals instead of everything, for exactly that reason. The
alternative — a fast regression that does not measure milliseconds — cannot make
the claim at all.

## How the host controller fits in the demo

The GUI is not a mock: it speaks the real wire protocol to the real bridge.

- **Assemble.** Pick `firmware/uart_echo.pe`; the host runs the existing assembler
  (`tools/fw/peasm.py`), refuses >1024 words, and shows the word count, a
  SHA-256 of the canonical image and a terminal-jump warning.
- **Load.** The words are framed (sync `A55A`, version/opcode/target,
  sequence, length, CRC-16/CCITT-FALSE) and clocked into the chip's
  instruction memory. The response is a real acknowledgement: words written,
  fault bits, and a final-word echo. The GUI refuses to proceed unless the
  acknowledgement matches the image.
- **Start / stop.** `run` is held low through reset and load, and is raised
  only after a successful load. A stopped core is a *deliberate state*, not a
  side effect.
- **Observe.** Status shows run/state, registers, the heartbeat timer, fault
  bits and words written; a register dump and bounded memory reads are
  available while stopped. A chip fault surfaces as an event and the GUI
  labels what is *host-commanded*, *board-observed* or *chip-confirmed*.
- **The bridge is real firmware.** `tools/host_bridge/main.py` runs on the
  Pico, owns reset, the 60 MHz project clock and the SPI pins, and was
  verified on a real MicroPython interpreter (not just by inspection).

## What is proven, what is simulated, what is pending

| Claim | Status | Evidence |
|---|---|---|
| UART / SPI / I2C / 10BASE-T personas run as firmware | **RTL-proven** | `tb_pe_soc_uart`, `tb_pe_soc_spi`, `tb_pe_soc_i2c*`, `tb_pe_soc_eth*`, `tb_pe_eth_tx` |
| Full regression is green | **RTL-proven** | `./regress/run_all.sh --fast -j8` → exit 0 on a cold clone: **RTL 34/34, firmware 26/26, 12 mutation suites** (R2 and the wait-word gate are registered in `run_all`; see `docs/cold-clone-audit.md`) |
| 60 MHz maps and routes | **RTL-proven (mapped, not routed)** | area + screen reports; physical flow intentionally out of scope |
| Host GUI + bridge against fakes | **host-proven** | one-command gate `tools/host_gui/run_host_tests.sh` (host tests, bridge tests, lint, both fuzz campaigns, soak smoke, MicroPython conformance, acceptance `--fake` → 22 PASS / 0 FAIL / 1 SKIP) |
| Bridge on a real MicroPython | **measured** | built the MicroPython unix port and ran the deployed modules on it; found and fixed 5 deployment blockers (`reviews/2026-09-25/HOST-BRIDGE-MICROPYTHON.md`) |
| Framed host bus (PING/LOAD/STATUS/CLEAR_FAULT/TARGET, target-1 loopback, sticky faults, `IRQ_N`) | **RTL-proven** | chip-side R1 landed and verified with mutation coverage; the host's bridge/acceptance drive the same contract |
| Host protocol on real silicon (R1) | **LANDED + verified** | the chip team landed the framed bus, `IRQ_N` and target 1; the host stack speaks that exact contract today |
| Memory/register readback (R2) | **chip-confirmed (simulation)** | chip R2 landed and registered in `run_all`: `tb_pe_ctrl_r2` reports **18/18** golden steps PASS, byte-exact (CRC included) with the model image loaded per vector, the opening 3-word LOAD replayed as a real frame, and `pe_ctrl` STA-screened. The record lives in the **chip** repo (`reviews/2026-09-25/R2-READ-PATH-REVIEW.md`); this repo's package consumed those same steps as its acceptance spec (`reviews/2026-09-25/R2-READ-VERIFICATION.json`) |
| Liveness is observable (P3) | **chip-confirmed (simulation)** | R2's STATUS is 11 words incl. `pc/a/x/y/timer` at native widths, and `READ_CPU` is the one **non-halting** read, so a host can watch a RUNNING program (chip P3 finding closed; host GUI surfacing is this branch) |
| Board-in-the-loop acceptance | **pending** | runner + runbook exist (`docs/host-bridge-bringup.md`); needs a board. This is the one thing the demo table marks not-done |
| Physical flow (DRC/LVS) | **out of scope by design** | deferred in the plan; no physical tools run |

The honest shape of the entry: the *chip* is a verified microcontroller with
four working protocol personas, a verified framed host bus (R1) and verified
register/memory readback (R2, byte-exact against the same golden vectors the
host gates on); the *host* stack is a verified client whose real bridge
firmware speaks that bus and whose acceptance spec is the chip's own passing
table. The one thing not yet demonstrated is the **physical** run - a Pico over
USB with a real shuttle - which is stated as such everywhere it appears.

## Timings worth quoting

- Core: **60 MHz** (16.667 ns). UART tick: **260 clocks per half bit** →
  115,385 baud vs 115,200 nominal (+0.16 %).
- Host SPI first pass: **5 MHz** cap (`min(5 MHz, clk/6)`), the negotiated
  rate the bridge reports in `hello` and refuses to exceed.
- Full regression wall time: about a minute (`run_all.sh --fast -j8`).
- The demos are sized to be watchable: a 118-word image loads in one framed
  transaction (about 2 KB on the wire) acknowledged with four response words,
  and a status read is a single frame exchange.

## Fallback demo — no board at all (the judge's laptop is enough)

If there is no board on the table, the whole story still runs, in order of
"how much hardware it touches":

1. **Show the GUI against the bridge on the same laptop.** Start the host
   stack; the acceptance runner's `--fake` mode is a complete, honest
   end-to-end run: real GUI/session/transport/bridge, a modelled chip.
   `python3 tools/host_bridge/acceptance.py --fake` → 22 PASS / 0 FAIL / 1
   SKIP, and you can drive the same sequence from the browser.
2. **Show the firmware on the emulator.** `python3 tools/fw/peemu.py
   firmware/uart_echo.hex --send "41 42"` — the exact words the hardware
   testbench checks, from the CPU model, in ~2 seconds.
3. **Show the protocols as code, not slides.** Open the four `.pe` files and
   the four testbenches; the personas are a few hundred words each, and each
   one's proof is a checked-in test with a `PASS` line.
4. **Frame the remaining hardware work out loud** (the table above). A demo
   that ends by naming its own pending integration — with the acceptance spec
   already written for it — reads as a team that knows where it is.

## Run it yourself

```bash
# full host-side gate (no board needed, about a second)
tools/host_gui/run_host_tests.sh

# the end-to-end acceptance against fakes
python3 tools/host_bridge/acceptance.py --fake

# the firmware loop the demos use
python3 tools/fw/peemu.py firmware/uart_echo.hex --send "41 42" --max-cycles 900000

# with a board (bring-up + triage table in docs/host-bridge-bringup.md)
python3 tools/host_bridge/acceptance.py --device /dev/ttyACM0 --board <revision>
```
