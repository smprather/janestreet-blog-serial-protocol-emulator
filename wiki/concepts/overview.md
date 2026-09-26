---
title: Overview — how the pieces fit
created: 2026-09-25
updated: 2026-09-25
type: concept
tags: [architecture, verification, protocol, tooling]
sources: [rtl/tt_um_protocol_emulator.v, rtl/pe_soc.v, rtl/pe_cpu.v, rtl/pe_pinmux.v, rtl/pe_ctrl.v, rtl/pe_serdes.v, rtl/pe_eth_mac.v, rtl/pe_eth_tx.v, rtl/pe_dru.v, rtl/pe_imem.v, tools/fw/peasm.py, tools/fw/peemu.py, tools/host_gui/session.py, tools/host_gui/fake_pe.py, tools/host_gui/vectors.py, tools/host_gui/fuzz_protocol.py, tools/host_gui/soak_host.py, tools/host_bridge/acceptance.py, regress/run_all.sh, regress/dep_guard.sh, regress/verify_merge.sh, regress/lint.sh, formal/fv_run.sh, formal/results/summary.txt, formal/results/mutants.txt, tb/r2-vectors/manifest.json, tb/r3-vectors/manifest.json, tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt, docs/demo-walkthrough.md, wiki/STATUS.md, wiki/decisions/adr-003-memory-plan.md, wiki/decisions/adr-004-program-counter-width.md, wiki/decisions/adr-005-60mhz-turbo.md, wiki/decisions/adr-006-pin-matrix.md, wiki/decisions/adr-007-pe-ctrl-passive-slave.md, wiki/concepts/ethernet-scope.md, wiki/reference/signal-names.md]
confidence: high
---

# Overview — how the pieces fit

**You are:** an engineer who has just been pointed at this repo and does not
yet know what any of it is for.

**After this page you will be able to:** name the five layers, say which
question each one answers, explain why a protocol here is a *file* rather than
a block of gates, and — the part that distinguishes this project from a
clever design — describe how a claim in it is made falsifiable.

**Read time:** about 20 minutes. Then go to [[index]].

---

## The one sentence

A tiny single-cycle CPU with a runtime-configurable pin matrix speaks
serial protocols the way people usually write them — as **programs**, in an
assembler, running on a real 1 KB instruction memory — while the bits that
genuinely cannot be software (10BASE-T Manchester at 100 ns, NRZI + bit
stuffing) are hardware; a host bus loads those programs, reads them back,
breaks on them and steps them; and every claim either of them makes is pinned
to an artifact that is checked for the ability to fail.

Read that again and note which half is the *product* and which half is the
*method*. The competition ([[concepts/competition-overview]]) asks for the
first: a general-purpose protocol emulator, reprogrammable after fabrication.
The second is what this project decided to build on top of it, and it is the
half a judge can check.

---

## The five layers

```text
  ┌─ 5. the verification culture ────────────────────────────────────────┐
  │    16 mutation suites, a formal campaign, drift gates, and the        │
  │    process gates that stop a green run meaning nothing                │
  ├─ 4. the host stack ──────────────────────────────────────────────────┤
  │    browser GUI ⇄ WebSocket ⇄ session state machine ⇄ transport       │
  │    ⇄ newline-JSON bridge ⇄ PE frame codec      (tools/host_gui,    │
  │                                                  tools/host_bridge) │
  ├─ 3. firmware — the persona model ────────────────────────────────────┤
  │    24 .pe programs, each one a protocol, each with a testbench that  │
  │    MEASURES IT ON THE PADS                     (firmware/, tb/)    │
  ├─ 2. the host bus ────────────────────────────────────────────────────┤
  │    pe_ctrl: framed mode-0 SPI slave, load / read / debug / faults   │
  │    (+ an internal target that consumes no pad)                      │
  └─ 1. the chip ───────────────────────────────────────────────────────┘
       tt_um_protocol_emulator  →  pe_soc  →  pe_cpu + pe_imem
                                              + pe_pinmux
                                              + word engine (serdes+codecs)
                                              + 10BASE-T (dru+mac+tx+crc+fbuf)
```

Read the stack **bottom-up for the silicon** and **top-down for the trust**:
the bottom half is what the chip *is*, the top half is what lets you believe
anything about it.

---

## Layer 1 — The chip

## The wrapper: which pad does what

`rtl/tt_um_protocol_emulator.v` is the deliverable and the only file the
foundry sees. It owns the pads and does three things: maps `uio[0:3]` to the
firmware protocol row, maps `uio[4:7]` to the host bus, and muxes a couple of
outputs.

| pad | carries | notes |
|---|---|---|
| `ui_in[0]` | UART RX | also the shared protocol input |
| `ui_in[1]` | `run` | **a pad, not a bus command** — see ADR-007 |
| `ui_in[2]` | 10BASE-T RX | Manchester line, straight into the DRU |
| `ui_in[3:7]` | **free** | five inputs uncommitted |
| `uo_out[0]` | UART TX / SPI SCLK | shared port bit 0; one persona at a time |
| `uo_out[1]` | `IRQ_N` | sticky fault, active low |
| `uo_out[2]` | `eth_tx` | reclaimed from `dbg_pc[0]` behind a mux |
| `uo_out[7:3]` | `dbg_pc[5:1]` | a visible program counter, for bring-up |
| `uio[0]` | SDA | open-drain |
| `uio[1]` | SCL | open-drain |
| `uio[2]` | SPI MOSI | |
| `uio[3]` | SPI CS_N | |
| `uio[4:7]` | host CS_N / MOSI / MISO / SCK | the framed bus |

**19 of 24 pads are committed** ([[reference/protocol-pin-budget]]). That
number is the single most useful constraint for any idea you have: nothing
that needs a new pad is cheap here. Note also that `run` is a *pin*. There is
no ROM, so instruction memory powers up holding whatever the SRAM macro
happens to contain, and the chip cannot load itself — which is why `pe_ctrl`
is a **passive slave** and not a master with a bootstrap FSM
([[decisions/adr-007-pe-ctrl-passive-slave]]).

## `pe_soc`: a 4-bit port space and three rules

The SoC is the smallest processor-plus-RAM that can speak a protocol. There is
no UART state machine, no baud generator that knows what a bit is. The CPU's
**entire** I/O space is four bits wide:

| port | what | rule that matters |
|---|---|---|
| `0x0` `PIN` | read the pin levels | a *driven* pin reads back what was written; a *released* pin reads the **pad** |
| `0x1` `PINOUT` | write the output levels | |
| `0x2` `PINOE` | per-pin output enable | 1 = drive, 0 = release (high-Z) |
| `0x3` `PINOD` | per-pin open-drain | with 1, a pin holding 1 is released |
| `0x4` `I2CTICK` | free-running 1 µs counter | the timing reference for firmware |
| `0x5` `TIMER` | free-running, one increment per half bit | |
| `0x6`/`0x7` `I2CSTAT`/`STATUS` | tick-happened flags, cleared by reading | |
| `0x8`–`0xB` | ETHSTAT / ETHLEN / ETHFLD | reading ETHSTAT **clears** `valid`/`bad` |
| `0xC`–`0xD` | ETHFLDH / BUFBYTE | BUFBYTE is a **pipeline**: one cycle apart minimum |
| `0xE` `BUFCTRL` | release consumed bytes | safe while the next frame arrives |
| `0xF` `ENGINE` | a 32-entry indexed window | index-write then burst-write; any read auto-increments and re-arms index phase |

Three rules are worth internalising, because each one exists because the
obvious alternative was tried:

1. **Outputs low, inputs high.** Bit 0 is the lowest output and the inputs are
   a contiguous high run; `PIN_IN_MASK` (currently `8'hF8`) records where the
   split falls. The reason is an ISA limitation: there is no shift-*left*, so
   a value at bit *k* costs arithmetic. Making the first output bit 0 means
   `LDI A, 1; OUT PINOUT, A` raises a pin. The cost is that reads must be
   masked — a constant mask, because every pin test is a zero/nonzero test.
2. **The pin matrix lives inside the SoC, not in the wrapper.** The plan said
   the wrapper would instantiate it; that is unimplementable, because the
   CPU's I/O bus never leaves `pe_soc` and a matrix outside would have no way
   to be written. It is 111 cells of per-pin `{out, oe, od}`
   ([[concepts/pin-matrix]], [[decisions/adr-006-pin-matrix]]). It is the
   reason I2C exists here at all: SDA is *driven low*, *released*, and
   *read back* — often inside one bit cell, because arbitration means the
   master must compare what it drove against what the bus has.
3. **`bu` is not a byte and `eth_tx` is not a feature.** Port `0xF` is one
   window serving two owners, with a documented split (lower bank = word
   engine, upper bank = the TX staging FIFO, TXLEN, TXCTRL, TXSTAT). The
   ownership rules are formalised — `formal/pe_soc/formal_pe_soc.v` proves the
   owner gate and the owner guard, and the guards were found to be missing.

## `pe_cpu`: 16 opcodes, and why the ISA is that shape

16-bit instructions, 16 opcodes, **single-cycle**, `A/X/Y` 8-bit, `PC`
`clog2(IMEM_WORDS)` = 10 bits at 1,024 words.

```text
LDI OUT IN MOV JMP JZ JNZ ALU INCX DECX SHR LDS STS LDM STM NOP
```

No stack, no call/return, no multiply, no shift-left. The size of that list
*is* the architecture's claim, so the reasoning behind each omission is worth
having:

- **Single-cycle** is what makes every timing protocol achievable at all. A
  multi-cycle core makes a counted delay loop's length depend on the
  instruction mix; here a WS2812 bit cell is the **length of a straight-line
  program**, not a calibrated count. It is also what makes the core
  *replayable exactly*, which is the foundation of several features in
  [[plans/feature-brainstorm]].
- **No shift-left** is why the port-numbering rule above exists. The ISA
  limitation shaped the memory map. That is the intended relationship between
  the two, not an accident.
- **8-bit `A`** is why `PE-CTRL-READBACK` had to go: the R2 read path reports
  registers at their **native** widths, and the fix for a truncated `dbg_pc`
  was not to widen the report but to stop lying about it.
- **The PC widened with the memory, not before.** When the flop instruction
  memory was swapped for a 1 KB SRAM macro ([[decisions/adr-003-memory-plan]]),
  the CPU still had an 8-bit PC — so `next_pc[IAW-1:0]` was an out-of-range
  part-select and the reachable program stayed 256 words: **896 words of
  addressable-by-nothing SRAM for 79,674 µm².** The PC and the jump-target
  field had to widen in the same change
  ([[decisions/adr-004-program-counter-width]]). The plan had claimed the swap
  "does not change the CPU's interface"; the cycle model was right and the
  interface was not.

**The memory, honestly:** 1,024 words of 16-bit IMEM on one
`1P_1024x16_c2_bm_bist` macro (79,674 µm²) and **16 bytes of data memory**,
which is why DMEM-backed buffers do not exist and every larger buffer in the
design is the frame buffer or the port-`0xF` window. The largest firmware
image is `eth_arp_echo` at 546 words. [[reference/sram-budget]] has the
geometry arithmetic and [[reference/floorplan-feasibility]] has what it means
for the die.

## The three implementation styles, and the arithmetic that picks between them

This is the part a newcomer most often gets wrong, because the project
deliberately runs **three** different answers at once. The reasoning
([[plans/through-i2c]], [[plans/serdes-integration]]) is:

| style | use it when | example |
|---|---|---|
| **firmware bit-bang** | control flow is per-bit: ACK, arbitration, stretch | UART, SPI, I2C, all three timing acts |
| **word engine** (`pe_serdes` + 2× `pe_codec_mux` + `pe_nrzi`/`pe_manch`/`pe_bitstuff`) | you need 1–32-bit words at a rate firmware cannot reach, with the line code as a *register* | USB (NRZI + ones-only stuffing), CAN (Manchester) |
| **dedicated hardware** | the bit work exceeds the core's arithmetic, provably | 10BASE-T receive and transmit |

The arithmetic that forces the third case is worth memorising because it is
the whole justification ([[concepts/ethernet-scope]]): at a 100 ns bit period
the single-cycle core has **48 instructions per byte**, and a software CRC-32
alone needs about **240**. So the bit work is hardware and the firmware only
sequences frames.

Do not "unify" the styles. `plans/through-i2c` states the reasoning and
[[STATUS]] repeats the instruction.

## The one protocol in hardware, and why it ties four orphans together

`pe_eth_mac` (1,681 cells) + `pe_eth_tx` (892) + `pe_crc` + `pe_fbuf` (2 KB,
same macro family) + `pe_dru` (the 12× oversampled receive unit) is the only
place where a protocol is *not* a persona. Its value to the project is
structural, not functional: the MAC is what **ties four previously-orphaned
blocks into one signal path**, and the wiki is explicit that "an orphan block
is a claim that has never been exercised inside a design." A DRU alone, a CRC
alone, a frame buffer alone — each was a block with a testbench and no
system.

The RX path locks on the SFD, assembles bytes, checks the FCS against the
RevEng catalogue residue, and store-and-forwards into the frame buffer,
handling both 802.3 frame kinds because the acceptance target is ARP and ARP
is an EtherType. The TX path emits the hardware prelude, appends the FCS
through a TX-dedicated CRC, zero-pads to 64 bytes *into the FCS*, refuses
runts and jabbers, and holds a 96-cell inter-frame gap.

---

## Layer 2 — The host bus

`rtl/pe_ctrl.v` is the chip's side of a **framed, versioned, CRC-protected
command/response protocol** over mode-0 SPI, and it is the most
thoroughly-specified thing in the repo. Its header block is the contract; read
it rather than the code.

## The frame

```text
word 0      sync 16'hA55A
word 1      {version[3:0], opcode[7:0], target[3:0]}      version = 1
word 2      sequence
word 3      payload length, in 16-bit words
word 4..N   payload
word N+1    CRC-16/CCITT-FALSE over every preceding word, sync included
            poly 0x1021, init 0xFFFF, no reflection, no final XOR
```

Responses set opcode bit 7 and echo sequence and target. The first response
payload word is a status code: `0 OK, 1 BUSY, 2 BAD_FRAME, 3 RANGE, 4 FAULT,
5 UNSUPPORTED, 6 NOT_READY`. The CRC constants are **not to be retyped** —
they are generated and checked against the RevEng catalogue by
`tools/gen/crc_config.py`.

## The three phases, and what each one bought

| phase | opcodes | what it turned "can load" into |
|---|---|---|
| **R1** | `PING`, `LOAD`, `STATUS`, `CLEAR_FAULT`, `TARGET` | a loader with status and sticky faults (`IRQ_N`) |
| **R2** | `READ_CPU` (0x12), `READ_IMEM` (0x13), `READ_DMEM` (0x14), `DUMP_CORE` (0x15) | *observation* — and `STATUS` went from stubbing the CPU fields to **eleven real words** (`status, state, run, target, pc, a, x, y, timer, faults, words_written`) because R2 stopped pretending the core's registers were not there |
| **R3** | `DEBUG_STEP` (0x21), `DEBUG_BP_SET` (0x22), `DEBUG_BP_CLR` (0x23), `DEBUG_STATUS` (0x24) | *debug* — hold the core, retire exactly one instruction, stop on a PC |

Three details from R2/R3 that are worth more than the feature list:

**The wait-word rule.** A bounded read cannot answer inside the request's own
bit times: the chip must fetch first, and each word is one round trip. So it
drives `0xFFFF` filler words on MISO while fetching, and the real frame starts
at the first non-`0xFFFF` word. A host skips leading fillers and then
validates exactly as in R1. Three properties make this safe: a filler can
never be a header (every response sets bit 7 and version/target are bounded,
so no header word is all ones); the skip is **leading-only**, so a `0xFFFF`
inside a payload is data; and worst case is 15 fillers (16 payload slots
minus the status word). It is also **backward compatible**: an R1 response is
ready immediately with zero fillers, and the response *bytes* are unchanged —
wait words are transport-level only.

**`READ_CPU` is the one non-halting read.** It answers while `run=1`, which is
the entire point of a debugger seeing a *live* program. Everything else that
walks memory answers `NOT_READY` while running. This closed a real gap: the
R1 `STATUS` layout deliberately omitted `timer/pc/a/x/y` rather than stub
them, so nothing showed liveness, and the P3 heartbeat pad that used to do it
is gone.

**The debug-hold trap, which is the one to know before you touch a board.**
Once held, the run strap is ignored **in both directions**. The gate is
`cpu_exec = dbg_step || (run && !dbg_hold)`, and `dbg_hold_r` is cleared at
exactly two places — reset, and `DEBUG_BP_CLR`. So a host that single-steps or
stops on a breakpoint and then "re-asserts `run=1` to carry on" finds the
core **still held, with no fault and no error to explain it**. The only
releases are `DEBUG_BP_CLR` (which also disarms — hence the
step-off → clear → re-arm recipe) and a reset. This is a property of the
design, not a bug, and it is written in `pe_ctrl.v`'s header precisely because
"it costs a bring-up board a long time if nobody has written it down."

**The internal loopback target.** The header's `target` field selects a
target, and **target 1 is a deterministic loopback on the same MISO that
consumes no pad, clock or external MISO** — `PING` answers a fixed word,
`TARGET` answers a capability word, everything else is `UNSUPPORTED`. It
exists so a second on-chip capability needed no second bus. It is also the
cheapest unused resource in the design; see `C1` in
[[plans/feature-brainstorm]].

## The state encoding

`state` is two bits, and R2's `STATUS` reports the *same* encoding, so R1 host
code keeps its meaning:

| value | meaning |
|---|---|
| 0 | `STOPPED` — the normal boot stop: `run=0`, no hold, PC held at 0 |
| 1 | `RUNNING` — strap high, no hold |
| 2 | `DEBUG_HOLD` — held by the debug controls, **PC preserved** |
| 3 | `BP_HIT` — held by the breakpoint, PC preserved, hit latched |

`bp_flags`: bit0 = armed, bit1 = hit. `bp_addr` is the armed address or 0 when
disarmed, and a breakpoint *at* address 0 is legal and distinguished by
bit0. There is exactly **one** breakpoint register today; the demo walkthrough
states the gap out loud — no watchpoint, no data breakpoint.

---

## Layer 3 — Firmware, and what a "persona" is

There are **24 `.pe` programs** in `firmware/`, and a protocol persona is a
**file**, not a block of gates. But a `.pe` file alone is not a persona. The
complete artifact has three parts, and all three are checked in:

1. **the program** — `firmware/<name>.pe`, assembled by `tools/fw/peasm.py` to
   a committed `.hex`;
2. **a testbench that measures it on the pads** — `tb/tb_pe_soc_<name>.v`,
   which drives a real waveform in and decodes the real waveform out and
   prints its measurements;
3. **a peer model** — the thing on the other end: an I2C slave FSM, a DHT11
   sensor, a DS18B20, an SR04, a NEC carrier, an Ethernet frame source.

The measure-on-the-pads rule is not decorative. Every timing claim in
[[STATUS]] and in `docs/demo-walkthrough.md` is a *measured* number against
nominal — 48 clocks for a WS2812 1-cell, 19,999.95 µs for a servo frame,
120.0 µs for a DS18B20 presence pulse, 38,049 Hz off the pin for NEC infrared
— and several of them are stated as *equalities* rather than windows
(the stepper ramp's twelve steps must fall by **exactly** 5110 clocks each).

## The timing discipline, stated once

There are two clocks a firmware persona can measure against, and confusing
them produces a false failure:

- the **1 µs `I2CTICK`**, whose phase residual is up to a full microsecond —
  which is **80% of a WS2812 bit cell**; measuring a WS2812 against it will
  report an error that is not there;
- **counted cycles**, because the core is single-cycle and every timed
  interval is either straight-line code or a fixed-cost loop.

So the timing claims are claims about **clocks**, and the tick is for coarse
sequencing. This is the single most useful thing to internalise about
[[concepts/tx-timing-generation]].

`peasm` grew `--const NAME=VALUE` so that a *fitted counted delay constant*
could be perturbed — added for a mutation, and it is also the hook any
parameter sweep would use.

## What the three families of persona look like

- **framed protocols** (UART, SPI, I2C): something to decode, so a peer
  resynchronises you. 83.2–83.6 kHz across all 60 tick phases for I2C.
- **timing protocols** (WS2812, servo, DHT11): **no clock on the wire**; the
  value *is* a pulse width, and a program one clock out is simply wrong. This
  is why the project claims cycle accuracy rather than "works on the bench".
- **receiving personas** (DS18B20, NEC infrared, SR04, frequency meter): the
  timing belongs to somebody else. DS18B20 is the only act where the *device*
  initiates. NEC infrared has **no wire at all** — light, and a receiver that
  must find a 38 kHz burst and time the gaps between them.

`docs/demo-walkthrough.md` is the judge-facing script and is organised as
"acts". Act 5 (WS2812) is the one to read to understand what this project
thinks it is doing: the *grid* check (every 1-cell's rising edge on the
75-cycle grid) is the one that earns the word cycle-accurate, because a cell
of 74 or 76 clocks still clears every datasheet window in the world, and a
decoder that resynchronises on every rising edge would never notice. There is
a mutation for exactly that mutant, and the TB catches it.

---

## Layer 4 — The host stack

```text
browser page  ⇄ WebSocket  ⇄  Api (plain dicts)  ⇄  ControllerSession
                                                          ⇄  Transport
                                                    (SerialTransport | FakeBridge)
                                                          ⇄  newline-JSON
                                                   ⇄  Pico/RP2040 bridge
                                                          ⇄  PE frame codec
                                                          ⇄  framed SPI
```

Three design decisions in there are load-bearing and easy to get wrong:

- **The request logic is dependency-free.** `Api` is plain dicts; FastAPI and
  uvicorn are imported lazily so the regression stays runnable with no
  third-party packages. The server binds **loopback by default**, and neither
  arbitrary filesystem paths nor arbitrary serial devices are reachable over
  HTTP — `/api/assemble` and `/api/load` take a bare `.pe` *name* resolved
  inside a configured directory, and `/api/connect` takes no device argument.
- **The session is a real state machine**, not a pile of booleans:
  `DISCONNECTED, PREPARED, LOADING, LOADED, RUNNING, STOPPED, FAULTED`, with
  the rules (load only while stopped, start only after a load, dump only while
  stopped) enforced in one place. A transport timeout becomes a **typed
  fault, not a fake success**. Chip faults are sticky: a fault event sets
  `FAULTED` and only a successful `CLEAR_FAULT` leaves it.
- **The warning is not a refusal.** Arming a breakpoint on a core that is
  already held is *legal* (a step can land back on the armed address and
  latch 2→3), so the session issues a `UserWarning` and arms anyway. A
  refusal here turned two real tests red, and the reasoning is worth knowing
  because it is a general trap: **the model's idea of what is legal can be
  wrong in the safe direction, and "fixing" the model to refuse would break
  the chip.** The warning reads `self.state` built from the chip's **own**
  state word, so it pins the host's reaction to what the chip said — and a
  test with **no model in the loop** drives the session state directly to keep
  it honest.

### The golden packages, and what "chip-confirmed" means

`tools/host_gui/vectors.py` is a framework; each phase (`r2_vectors`,
`r3_vectors`) is a *configuration plus a vector list*. Two properties are
load-bearing and both are enforced:

- **the artifact cannot drift from the contract** — every frame is produced by
  driving the live `FakePE` through the shared codec, and `--check` requires
  the checked-in JSON to equal a fresh build;
- **a step is chip-confirmed only by citation** — `chip_confirmed` is set from
  an evidence entry, not asserted, and a phase that has no evidence stays
  `false`. The docstring is blunt: *"Nothing this module produces is evidence
  about silicon. A package is the gate the chip must pass; a step is
  chip-confirmed only when it appears in the phase's evidence set with a
  citation, and nothing is confirmed by assertion."*

The **model image** is the other half. Every vector ships the 1,024-word IMEM
and 16-byte DMEM image its request assumes, as `$readmemh` exports, so a
testbench can consume the files directly with no translation step — and there
is a standing note that the R2 exports are deliberately left **byte-identical**
across a later refactor, because perturbing a byte of a confirmed artifact
would be worse than an untidy file.

R3 adds the piece that makes a conformance gate honest under a *disagreement*:
`tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt` is a **pinned list of the words the
chip does not match today**, and the TB fails if the observed set ever differs
from it. That is deliberately stricter than an XFAIL list of step names,
because a step that starts failing *for a new reason* must not read as
"known". The one remaining R3 divergence is documented at length as a
**testbench model boundary, not a contract disagreement** — with a
measurement of what the chip does in every regime it can be put into, and the
conclusion that a state is not one the chip can physically occupy.

There is a fourth copy of this framework pointed at the chip's own testbench,
which replays each step's `request_file` and compares the response to
`response_file` **word for word, CRC included**. `python3
tools/host_bridge/acceptance.py --fake` runs the demo beats with no board.

---

## Layer 5 — The verification culture

This is the layer that makes the rest believable, and it is the layer a
newcomer should read the *rules* of before reading any code. The rules live in
the harness headers, not in a style guide, which is why they hold.

## The spine: every claim must be able to fail

**16 mutation harnesses** (`regress/mutate_*.sh`). Each enumerates mutations
that are *plausible implementation choices* — not random damage — and requires
the matching testbench to notice every one. Current shapes: 48/48 timing
firmware mutants, 29/29 host-bus, 21/21 firmware-bus, 18/18 + 7/7 Ethernet
TX, 13/13 codec, and so on.

Three rules inside them are worth stating because each one was learned:

- **Restore is a file copy, verified with `cmp` after *every* mutation.** A
  failed restore stacks mutations and reports a meaningless perfect score.
  There is a named incident: a red tree turned out to be an unrestored
  mutation from a harness killed by a kernel OOM, and the recovery was
  `cmp`-verified against two independent surviving copies.
- **A missing `MUTABLE` line is the opposite of an empty one.** An empty
  `MUTABLE` means the suite mutates nothing in the repo and is therefore
  **never skipped**; a missing one means unmappable, and the gate escalates to
  running everything rather than guessing. `check_mutation_lists.sh` proves
  each list still covers every file its harness writes — because a stale list
  had made the mapper *skip* the suite guarding a changed file.
- **A benign mutant is deleted, not tolerated.** The timing work found this
  twice: a carrier that alternated 788/782 clocks passed every window, and the
  gate then claimed to catch a no-op. The project's own formulation is the
  best statement of the principle: **a gate claiming to catch a no-op is the
  same error as a check that cannot fail.**

## The formal campaign, and its honesty about itself

`formal/` runs yosys' built-in `sat` in two shapes, **10 properties across 5
modules**, with **14 formal mutants** all caught. `formal/results/summary.txt`
does not just list passes — it labels outcomes `PROVED`, `REACHABLE` and
**`VACUOUS`**, because a vacuous proof is a claim about nothing.

`fv_run.sh` exists to make the campaign's flags impossible to get wrong in one
harness and missing from another, and its header is a list of traps that have
actually bitten:

- `-set-assumes` — **`$assume` cells are constraints; `sat` ignores them
  without the flag.** Verified with a minimal design whose `assume(1'b0)`
  changed nothing until the flag was added. Without it, the reset discipline
  and every contract assumption in the wrappers is decoration.
- **Success is spelled differently by the two proof shapes** — BMC prints
  `no model found: SUCCESS`, induction prints `Induction step proven:
  SUCCESS!`. Grepping only the BMC spelling made every successful induction
  run report `ERROR` — the log said SUCCESS while the harness said ERROR,
  which would have sent the next session chasing a proof that already closed.
- **An induction failure is not a counterexample** — it means the claim set
  did not close at that length, which is a *modelling* signal.
- The instrumentation is `FORMAL`-guarded **alias ports** of existing signals,
  never new datapath, and `tools/check_formal_ifdef.sh` fails any synthesis
  path that defines it.

The campaign's own findings — **F1** (a `pe_eth_tx` TXLEN apply-window) and
**F2** (a `pe_soc` owner SET-side guard) — were found by this, not by a
testbench.

## The lint gate, and the two bugs no testbench could catch

`regress/lint.sh` is "not optional, and the reason is the most useful thing in
this file" — the project's own words. A testbench only ever sees the
*simulator's* resolution of illegal RTL, so it cannot catch a construct that
is legal to simulate and wrong to synthesise. Two such defects existed:

- a register driven by **two `always_ff` blocks**: Icarus raced it (50 of 100
  ticks silently dropped by a two-instruction poll loop) and **yosys resolved
  the driver-driver conflict to a constant 0**, so the feature worked in
  simulation and not in silicon;
- a hierarchical reference where a port was required, so a register
  "synthesised" to nothing.

The gate now fails on *any* yosys `ERROR:`; it used to grep for three known
diagnostics and report "elaborate OK" beside a file yosys could not parse at
all.

## The process gates, and why they exist

These are the least glamorous and most load-bearing part of the repo, and each
one closes a specific way a green result can be a lie:

| gate | the lie it closes |
|---|---|
| `run_lock.sh` (flock, exit 75) | two runs mutating and restoring the *same* RTL at once — a run can read a file another run mutated, which is exactly the "nonsense result" the harnesses exist to detect |
| `dep_guard.sh` + the pre-flight | **bash reads a script incrementally**, so editing a harness mid-run can make it report a false pass. A content change exits **4 (INCONCLUSIVE) and never a green** |
| `check_harness_preflight.sh` | a *seventeenth* harness being added unprotected: it would take the lock, get stamped, never get checked. The fix arrived through the front door of the thing the guard was built for |
| `check_shell_syntax.sh` | `bash -n regress/*.sh` parses only the **first** file and passes the rest as positional parameters — so the one-liner every shell project reaches for silently checks 1 file of 31, and a glob puts the unchecked ones last. It printed a pass beside 16 green suites with **exit 4** |
| `verify_merge.sh` | 5b4731f was pushed with six red timing acts and every gate green a minute earlier: R3's new `dbg_hold`/`dbg_step` inputs never reached the fw branch's testbenches, so their ports floated to Z, the execute gate went X, and six unrelated programs sat at reset. **No gate could catch it — until the merge, the two states did not coexist** |
| the generated-doc drift gates | reference pages generated from RTL, checked in CI, so a port table cannot quietly go stale |
| `param_guards.sh`, `check_staged_mutants.sh` | build parameters and staged-mutant hygiene |

Two conventions in that table are worth adopting elsewhere: **exit 4 is
inconclusive and must never be reported as a pass**, and **a narrowed gate
prints every suite as RUN or SKIP with the reason**, so a green result says
what it covered *and what it did not*.

## The rule underneath all of it

> **A count is an assertion.**

This project has shipped false numbers — and the near-misses are more
instructive than the hits. Recorded on the day the number was written down: a
manifest's `confirmed_steps` list *looked* one short of its own flags, and
the near-miss was caught only because the author checked whether their own
arithmetic was the thing that was wrong before publishing it. (It was not a
defect: two vectors both had a step named `step_one`, so there were 25
(vector, step) **pairs** and 24 unique **names**.) Publishing a number derived
with a `Set` that was counting *pairs* is the shape of thing that does not
survive review.

## A live example of the rule, found while writing this page

Because the rule above is only worth stating if you can point at it, here is a
concrete one, stated as a question rather than a verdict because that is what
it is:

`tb/r2-vectors/manifest.json` (and `--check` says it is *up to date*, so this
is what the generator produces) contains **18 steps, of which 15 carry
`chip_confirmed: true` and 3 do not** —
`read_imem_at_ceiling_15`, `read_imem_over_ceiling`, `read_dmem_zero_count` —
and its package-level flag is correctly **`chip_confirmed: false`**. But:

- the evidence block has **no `not_confirmed_steps` key at all**, so the
  three are not *named* anywhere in the evidence (R3's does, each with a
  reason, and its TB fails if the observed set changes);
- the `notice` says *"**every** golden step in this package passes
  byte-exactly ... 15/15, per vector"*, which describes the confirmed subset
  as though it were the whole package;
- and the sibling artifact `reviews/2026-09-25/R2-READ-VERIFICATION.json` —
  same generator family — says `chip_confirmed: true` with **18** confirmed
  steps and cites "18/18".

So two artifacts in the same family disagree about the number (15 vs 18), the
notice overstates coverage, and the unconfirmed set is invisible without
walking the JSON. It is exactly the class this repo exists to catch, and it is
cheap to close — extend the evidence set, or enumerate the three with reasons
the way R3 does.

**How to check it yourself:**
`python3 -c "import json;d=json.load(open('tb/r2-vectors/manifest.json'));print([s['name'] for v in d['vectors'] for s in v['steps'] if not s['chip_confirmed']])"`

---

## What is not true yet

Stated plainly, because a document that only lists strengths is not a map.

- **Nothing has been taped out.** The deliverable exists and is submittable
  (`rtl/tt_um_protocol_emulator.v` + `info.yaml` are a real `tt_um_*` top
  with a real pad interface), but there is no silicon.
- **The real-board acceptance run has not been executed.** Every
  "chip-confirmed" claim in this repo means *byte-exact in a simulation
  testbench*. Not one host test has talked to a physical chip over USB. The
  Pico, a shuttle and a human are all required.
- **No physical flow, DRC or LVS.** The timing evidence is *mapped* Yosys +
  OpenSTA screens (three corners, with labelled ZERO/BOARD input-delay
  variants), which are a screening tool, not signoff. A full LibreLane run
  closed setup and hold at all three corners with +1.143 ns worst-case setup
  and zero DRC violations, but stopped at step 57 of 80 for a **PDK-vs-flow
  vocabulary mismatch**, not a design defect: the IHP SRAM macro ships no
  `pblock` layer, so LibreLane's `get_bbox.tcl` cannot extract a PR boundary
  from its GDSII.
- **8×4 tiles may never happen.** The competition blog says 6×4 and describes
  8×4 as a possibility it might offer later. Design for 24 tiles.
- **Three of five `ui_in` pads are free and all of `uio` is spoken for.** Any
  idea that needs a pad is expensive.
- **The regression figure moves.** Do not quote a number from memory;
  [[STATUS]] is the place it lives, and it changes as blocks land.

---

## An hour-long reading order

If you read nothing else:

1. **`docs/demo-walkthrough.md`** — the judge-facing script, organised as
   acts, and the fastest way to see what the chip *does*.
2. **This page**, then [[concepts/spi-as-firmware]] for the thesis in one
   concrete protocol.
3. **`rtl/pe_soc.v`'s header** (the first ~120 lines) — the port map, the
   numbering rule, and why the pin matrix is where it is.
4. **`rtl/pe_ctrl.v`'s header** — the entire host contract, including the
   debug-hold trap, in one comment block.
5. **`regress/mutate_ctrl_tb.sh`'s header** — the mutation philosophy and the
   "one mutation is deliberately absent" reasoning.
6. **`regress/run_all.sh`'s header** — what `--fast` actually does (it is *not*
   Verilator, and the reason is measured), the lock, and the pre-flight.
7. **`formal/fv_run.sh`'s header** — the toolchain traps.
8. **`tools/host_gui/vectors.py`'s docstring** — what a golden package is and
   is not.
9. Then pick a theme below and go deep.

## Where to go next

| if you want to understand… | read |
|---|---|
| why 60 MHz and what "exact" buys | [[concepts/tx-timing-generation]], [[decisions/adr-005-60mhz-turbo]], [[reference/clock-arithmetic]] |
| why Ethernet is hardware and the others are not | [[concepts/ethernet-scope]], [[concepts/ethernet-receive-path]] |
| the pin matrix, and the I2C milestone | [[concepts/pin-matrix]], [[concepts/i2c-on-the-matrix]], [[decisions/adr-006-pin-matrix]] |
| the shared word engine | [[plans/serdes-integration]], [[concepts/factored-hardware-blocks]] |
| the sample-order trap that bit two timing acts | [[concepts/strobe-and-committing-edge]] |
| the host bus and the host tools | [[plans/host-controller-gui]], [[plans/pe-ctrl]], [[plans/demo-host-gui]] |
| what is built and what is only claimed | [[STATUS]] — read the blockquotes newest-first |
| what could be built next | [[plans/feature-brainstorm]] |
| every page in one list | [[index]] |
