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

## The debug act — arm a breakpoint, hit it, step across it, resume (R3)

The four acts above are firmware personas. This one is the thing you cannot do
with `peemu.py`: **the chip is stopped by a host command, on a real instruction
boundary.** It is the act that turns "the host can read the chip" into "the
host can debug the chip", and it runs entirely over the same framed bus as the
load — no side channel, no simulation-only hook.

Run it yourself, no board needed:

```
python3 tools/host_bridge/acceptance.py --fake   # the 7 r3_demo_* beats
```

1. **Arm.** `DEBUG_BP_SET(2)` over the host bus. The response's five-word
   prefix reads back the address it just armed and `bp_flags=0x01`.
2. **Run, and hit.** Raise the `run` strap. The core advances until its
   *landing* address equals the armed one, and stops there. The demo clocks
   the model to that point because `FakePE` does not self-advance; a real core
   gets there on its own.
3. **The hit is a distinct state, not "stopped".** `DEBUG_STATUS` reports
   `state=3` (**BP_HIT**), `pc=2`, `bp_flags=0x03` (bit0 armed + bit1 hit) —
   and `run=1`. That last one is the point: **the hit holds the core, it does
   not drop the run strap.** A plain stop is `state=0`; a single-step pause is
   `state=2`. All four are in one 2-bit word, and R2's own `STATUS` reports the
   same encoding, so old host code keeps its meaning.
4. **Inspect.** `READ_CPU` gives `pc/a/x/y/insn` — with `insn` the word *at*
   the held PC, which is exactly the instruction you are about to single-step.
   `DEBUG_STATUS` adds the breakpoint address and flags on top. (Its last word
   is the **run strap**, not the debug state: a detail this repo's own vectors
   initially got wrong and the chip's conformance run caught.)
5. **Step across it — and both halves matter.** One `DEBUG_STEP` retires
   **exactly one instruction**, so `a` visibly changes and the PC advances to 3.
   Stop-before is about the instruction *at* the breakpoint, which had **not**
   run — which is what lets a debugger inspect that instruction and then step
   *it*. Stepping off the breakpoint clears the hit.
6. **Clear.** `DEBUG_BP_CLR` is the **only** release, and it also disarms: with
   the strap high the core resumes; with the strap low it falls to the boot
   stop and the PC re-zeroes. So a core can never be stranded on a hold.
7. **Resume with the breakpoint still wanted.** Step off → clear → re-arm. The
   GUI offers this as one action precisely because the naive "clear to get
   going" silently drops your breakpoint.

Two honest caveats, both on the acceptance output itself: a free-running core
cannot be stepped at all (the chip answers `NOT_READY` with no fault), and a
breakpoint is **one PC address** — there is no watchpoint and no data
breakpoint in R3.


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
| Host GUI + bridge against fakes | **host-proven** | one-command gate `tools/host_gui/run_host_tests.sh` (host tests, bridge tests, lint, both fuzz campaigns, soak smoke, MicroPython conformance, acceptance `--fake` → 35 PASS, 0 FAIL, 1 SKIP) |
| Bridge on a real MicroPython | **measured** | built the MicroPython unix port and ran the deployed modules on it; found and fixed 5 deployment blockers (`reviews/2026-09-25/HOST-BRIDGE-MICROPYTHON.md`) |
| Framed host bus (PING/LOAD/STATUS/CLEAR_FAULT/TARGET, target-1 loopback, sticky faults, `IRQ_N`) | **RTL-proven** | chip-side R1 landed and verified with mutation coverage; the host's bridge/acceptance drive the same contract |
| Host protocol on real silicon (R1) | **LANDED + verified** | the chip team landed the framed bus, `IRQ_N` and target 1; the host stack speaks that exact contract today |
| Memory/register readback (R2) | **chip-confirmed (simulation)** | chip R2 landed and registered in `run_all`: `tb_pe_ctrl_r2` reports **18/18** golden steps PASS, byte-exact (CRC included) with the model image loaded per vector, the opening 3-word LOAD replayed as a real frame, and `pe_ctrl` STA-screened. The record lives in the **chip** repo (`reviews/2026-09-25/R2-READ-PATH-REVIEW.md`); this repo's package consumed those same steps as its acceptance spec (`reviews/2026-09-25/R2-READ-VERIFICATION.json`) |
| Liveness is observable (P3) | **chip-confirmed (simulation)** | R2's STATUS is 11 words incl. `pc/a/x/y/timer` at native widths, and `READ_CPU` is the one **non-halting** read, so a host can watch a RUNNING program (chip P3 finding closed; host GUI surfacing is this branch) |
| Debug control: arm / hit / inspect / step / clear / resume (R3) | **chip-confirmed (simulation), 25/26 steps** | chip R3 landed; the chip's own `tb_pe_ctrl_r3_conf` is **GREEN 26/26** against the contract, with a 7-mutant gate (all caught) and formal proofs for S1–S4. It covers **25 of the 26** steps in this repo's golden package byte-exactly, and those 25 now carry `chip_confirmed=true` with the chip's citations; the one exception is a step whose expected `insn` is not contract-determined for a free-running core (a freeze-snapshot TB model boundary), which **both sides leave unproven** rather than "fixing" to match a testbench. The host's GUI panel, session state machine and the 7-beat `r3_demo_*` acceptance act drive the same contract; see `reviews/2026-09-25/R3-DEBUG-VERIFICATION.json` and `R3-VECTOR-BYTES.md`. **Not** hardware-confirmed |
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
   `python3 tools/host_bridge/acceptance.py --fake` → 35 PASS, 0 FAIL, 1 SKIP
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
