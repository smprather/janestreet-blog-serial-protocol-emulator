---
title: Linux demo-host GUI (STATUS item 8)
created: 2026-09-23
updated: 2026-09-23
type: plan
tags: [plan, tooling, verification, gpio, clocking]
sources: [wiki/STATUS.md, HANDOFF.md, wiki/decisions/adr-007-pe-ctrl-passive-slave.md, rtl/tt_um_protocol_emulator.v, rtl/pe_ctrl.v, README.md, wiki/entities/tiny-tapeout.md, wiki/raw/articles/tinytapeout-clock-spec.md, wiki/plans/pe-ctrl-readback.md, wiki/plans/spi-pads.md, wiki/reference/protocol-pin-budget.md]
confidence: medium
---

# Demo host GUI: Linux PC → RP2040 demo board → ASIC

**Status: DRAFT — awaiting user acceptance.** STATUS item 8 stays **TODO**
until this plan is accepted. Planning/documentation only: no GUI code, no
bridge firmware, no RTL, no pinout change has been authorized or started.
Open choices are marked **[OPEN]**; facts carry a source path.

Why it exists: the project hardware is intended to run with the RP2040
controller on the Tiny Tapeout demo board (Raspberry Pi Pico), controlled by a
separate connected Linux PC (`HANDOFF.md`, context-flush continuation). **The
host controller is chosen, not open: the Raspberry Pi Pico (RP2040) on the
Tiny Tapeout dev board.** TT platform pages that mention a newer RP2350
revision of the demo PCB are a platform-doc caveat to confirm
(`wiki/entities/tiny-tapeout.md`, open question 2), not an alternative
controller to select. The
operator workflow today is manual; this plan defines what a GUI would have to
do, over which boundaries, and what cannot yet be decided.

## The three boundaries

```
Linux PC (operator GUI)  --[OPEN: transport/API]-->  RP2040 on TT demo board  --[fixed pads + clock]-->  tt_um_protocol_emulator (pe_ctrl + pe_soc)
```

### 1. PC ↔ board — **[OPEN]**
No repo source constrains this. The only board-side evidence in the wiki is
the clock path: the demo board runs MicroPython and the Tiny Tapeout Commander
App sets the clock with `set_clock_hz`
(`wiki/raw/articles/tinytapeout-clock-spec.md`). **Nothing in that excerpt —
and nothing in the user's statement of the host path — establishes how the PC
reaches the board, so every `USB CDC` / serial reference below is an explicit
hypothesis, not evidence.** Options and tradeoffs are in
*PC-to-board transport / API* below.

### 2. Board ↔ chip — mostly known facts

| Signal | Pad | Fact (source) |
|---|---|---|
| SCLK | `ui_in[3]` | loader clock, mode 0; rate ceiling = **core `clk` / 6** — 10 MHz only at the 60 MHz operating point, lower if the GUI lowers `clk` (`rtl/pe_ctrl.v` header: six 60 MHz clocks per SCLK period; ADR-007's ~10 MHz assumes that same 60 MHz) |
| MOSI | `ui_in[4]` | loader data, MSB-first (ADR-007) |
| CS_N | `ui_in[5]` | low resets word address to 0 and enables the loader (ADR-007) |
| `run` | `ui_in[1]` | strap: 1 = execute, 0 = hold at PC 0; loader accepts words only while `run == 0` (ADR-007; wrapper pin map) |
| clock | `clk` | generated on-board by the RP2040 (PWM/PIO), 1 Hz–66.5 MHz, Commander `set_clock_hz` (TT clock spec — **sky130-framed**, see *Clock control*); design's operating point is 60 MHz (ADR-005) |
| reset | `rst_n` | active-low, driven through the mux like any input (TT clock/mux docs) |
| UART TX | `uo_out[0]` | shared with the firmware SPI SCLK persona, one persona at a time (wrapper pin map; [[plans/spi-pads]]) |
| heartbeat | `uo_out[1]` | `dbg_timer[7]`, ~one edge per 128 ticks — "is it alive" (wrapper pin map) |
| debug PC | `uo_out[7:2]` | `dbg_pc[5:0]`, the only live "running vs silent" indicator on silicon (wrapper header; STATUS item 4) |
| I2C / fw-SPI | `uio[0:3]` | SDA, SCL, MOSI, CS_N of the *firmware* pin-matrix personas — a different SPI from the loader (wrapper pin map) |

Loader wire contract v1 (ADR-007, `rtl/pe_ctrl.v` header): SPI mode 0,
MSB-first, **16-bit words straight into `imem[addr]`**; `CS_N` low resets the
address; every 16 rising SCLK edges write one word and increment; a partial
word at `CS_N` deassert is **discarded and flagged**; SCLK is asynchronous
through a 2-flop synchronizer and needs **six core clocks per SCLK period
(three per half period)**, so the legal ceiling is `clk/6`: ~10 MHz at 60 MHz,
and proportionally lower at any lower selectable clock (1 MHz `clk` → ~166 kHz);
a word queued when `run` rises is **aborted**, latches `load_error`,
and does not reappear; instruction memory only in v1; **no MISO, no readback
in v1** — "the chip's own outputs are the verification" (ADR-007).

Mux/environment facts (`wiki/entities/tiny-tapeout.md`, raw mux doc): the active
design receives buffered `clk`/`rst_n`/`ui_in`/`uio_in`; inactive designs get
zeros and tristated outputs; `ena` is not a reset; expect up to ~10 ns
pad-to-project insertion delay (sky130 figure, IHP number is an open question
on that page).

### 3. Chip-internal status the GUI would like — mostly **not observable**

`rtl/pe_ctrl.v` produces `load_active`, `load_error` and `ctrl_words_written`,
but `rtl/tt_um_protocol_emulator.v` deliberately sinks all three in its
`_unused` bundle: **they do not reach a pad**. Combined with ADR-007's "no
readback in v1", the direct consequences for the GUI are:

- It **cannot confirm a load landed**. Any UI that says "verified" would be
  lying; the honest statement is "N words sent (host-side count), unverified".
- The only chip-side observability is pads: heartbeat, `dbg_pc[5:0]`, and
  `uo_out[0]` (UART TX / persona output) — STATUS item 4 calls the debug PC
  "the only live observability on silicon".
- Anything better is a **decision**, not an implementation detail: see
  *Observable status and error paths*.

## Operator workflows (design)

1. **Connect / prepare.** Board enumerates; operator selects the project in the
   mux, sets the clock (60 MHz), holds `rst_n` asserted, and keeps `run = 0`.
   **[OPEN]** which of these the PC can actually drive (see board-side support).
2. **Load.** The GUI must drive `run = 0` *before* clocking words, because the
   loader gates writes on it and a gated write is **invisible** (no ack, no
   pad). Assert `CS_N` (address resets), clock the image as 16-bit MSB-first
   words at ≤ min(10 MHz, selected `clk`/6), deassert `CS_N`. Word count is the
   GUI's own record.
3. **Start.** Raise `run`. ADR-007 keeps load and run as two deliberate host
   actions so both are observable on a scope; the GUI should mirror that
   (separate buttons, explicit state machine), not auto-run on load end.
4. **Observe.** Heartbeat edge rate (alive), `dbg_pc[5:0]` (executing),
   `uo_out[0]` byte stream for the UART persona (115200 8N1, measured
   8.6–8.7 µs bit cells in `tb_pe_soc_uart`), plus whatever wired protocol
   outputs reach the board. **[OPEN]** which of these the board exposes to the PC.
5. **Stop / reload.** Drop `run` (core holds at PC 0), reload from address 0.
   Instruction memory is volatile SRAM with no ROM (ADR-007): **every session
   loads before it runs**, and a power cycle loses the image.
6. **Failure handling.** Short image → the tail of IMEM is undefined, so send a
   full 1,024-word image or require self-jumping programs (ADR-007
   consequence; the shipped programs self-jump). Partial last word → discarded
   and flagged chip-side, invisible to the host → the GUI must word-align
   before sending. `run` left high during load → `host_we` is masked at the pin
   and any queued word is aborted, latching the sticky `load_error` — none of
   which reaches a pad, so the GUI sequences `run=0` first and says so in the
   UI. SCLK faster than the derived `clk/6` cap → asynchronous sampling hazard
   (`rtl/pe_ctrl.v` trap 1) → the GUI derives the cap from the selected clock
   (10 MHz only at 60 MHz) and labels any override unsafe. More than 1,024
   words → `load_error` latches chip-side, again invisible → the GUI refuses
   oversized images host-side.

## Program image, load and start

Known facts: `tools/fw/peasm.py` assembles `firmware/*.pe` to a `.hex` of
4-hex-digit 16-bit words, one per line (`firmware/uart_echo.hex`);
`tools/fw/peemu.py` is the bit-accurate PC-side reference emulator; capacity is
1,024 words × 16 bits (`TT_IMEM_WORDS = 1024` in `rtl/tt_um_protocol_emulator.v`).
`regress/run_firmware_tests.sh` already proves assemble→emulate on the PC.

**[OPEN] image format the GUI consumes**: (a) plain `.hex` as produced today;
(b) a container with name, expected clock, expected observable behavior and a
checksum; (c) container + padded full image so the undefined-tail hazard
disappears. Evidence favours (b)+(c) for operator safety, but the choice is
the user's; nothing in the repo depends on it yet.

**[OPEN] start semantics beyond the two-step**: auto-run after load exists as
"one-line change" per ADR-007 but is deliberately not the contract; the GUI
should not paper over that without a decision.

## Clock control

Facts: the demo board generates 1 Hz–66.5 MHz from the RP2040 via PWM/PIO,
MicroPython on the board, `set_clock_hz` through the Tiny Tapeout Commander
App (`wiki/raw/articles/tinytapeout-clock-spec.md`); the design's operating
point and signoff target is 60 MHz, 66 MHz retired (ADR-005,
`wiki/reference/clock-arithmetic.md`); the mux passes `clk` as an ordinary
buffered pad bit, no dedicated tree.

Source caveat: that clock page is **sky130-framed** — its ~66 MHz pad-macro
limit, its QFN-64 / `mprj_io[6]` pinout and its RP2040 references are
sky130-flow artifacts, and the wiki holds no IHP/sg13g2-specific clock-max page
(`wiki/raw/articles/tinytapeout-clock-spec.md` note;
`wiki/entities/tiny-tapeout.md` open questions 1–3). Treat 1 Hz–66.5 MHz and the
exact control API as platform-doc figures pending IHP-specific confirmation;
the 60 MHz operating point is this project's own decision (ADR-005),
independent of that page.

Loader-rate coupling (it decides what "any frequency" can mean): the loader
needs six core clocks per SCLK period (`rtl/pe_ctrl.v`), so the legal SCLK cap
is `clk_hz / 6` and ADR-007's "~10 MHz" holds only at the 60 MHz operating
point — **10 MHz is not safe at an arbitrary lower `clk`**. Clock selection and
load rate are therefore one decision: either hold the clock at 60 MHz
(recommend), or recompute and enforce the SCLK cap on every clock change.
Lower clocks remain legal for observation, just with a proportionally slower
load.

**[OPEN]**: how the GUI reaches that API (REPL command, Commander protocol, or
custom firmware); whether the clock may change while `run = 1` (recommend:
only while held in reset / `run=0`); whether the GUI offers any frequency
other than 60 MHz (recommend: 60 MHz only, others behind an explicit
"unsupported" warning); and how insertion-delay/skew caveats are surfaced to
the operator.

## Observable status and error paths (three tiers)

- **Tier 1 — no chip or pinout change (available today's RTL).** Host-side
  state: words sent, clock set, `run` asserted by the GUI; plus pad-level
  observations *if the board wires them*: heartbeat `uo_out[1]`, `dbg_pc[5:0]`
  on `uo_out[7:2]`, UART/persona bytes on `uo_out[0]`. This tier can show
  "running vs silent" but never "load verified".
- **Tier 2 — board-side only (no chip change).** Sample chip outputs on the
  RP2040 and/or observe the load on the SPI wires it itself drives (the board
  knows what it clocked; it still gets no chip reply). **[OPEN]** whether the
  demo board routes `uo_out` to anything the firmware can read — this is a
  question for TT docs/Discord, listed with [[entities/tiny-tapeout]]'s open
  questions.
- **Tier 3 — chip change (explicitly out of scope here).** (i) bring
  `load_error`/`load_active`/`words_written` to a pad — a **pinout change**,
  forbidden for this item and anyway short of pads (uo_out is fully committed;
  `wiki/reference/protocol-pin-budget.md`); (ii) MISO readback, already under
  evaluation in [[plans/pe-ctrl-readback]] with the interface choice (A1/A2/A3)
  open. If (ii) lands, the GUI's "verify load" story changes; the plan must
  not pre-empt it.

Error paths the GUI must represent honestly today: *sent-unverified*,
*load rejected by `run` (the chip masks the write and aborts a queued word,
flagging the sticky `load_error` — which reaches no pad, so it is invisible to
the host and sequencing must prevent it)*, *partial word (prevented host-side)*,
*image shorter than IMEM (warning)*, *image over 1,024 words (refused
host-side; the chip-side `load_error` is invisible)*, *clock/transport failure
(PC-side detectable)*.

## PC-to-board transport / API — **[OPEN]**

Options, with the only evidence available.

**Transport caveat:** the evidence establishes only that the board runs
MicroPython and that the Commander App sets the clock. The PC↔board link is
**not** established by the clock-spec excerpt, nor by the user's statement of
the three-layer path — so `USB CDC` (and `serial`, and `HID`) below are
**hypothetical** transports to confirm against TT board documentation, not
facts this plan relies on.

- **A. Reuse the board's existing MicroPython/Commander path over a serial
  link (USB CDC — hypothetical).** Evidence: the clock spec says the demo board runs MicroPython and
  the Commander App sets the clock — not how a PC reaches it. Cheapest board-side work (none), but the
  framing, permission model and rate are Commander's, not ours, and bit-banged
  SPI up to the derived cap (10 MHz only at 60 MHz `clk`) from a REPL is a
  latency question nobody has measured here.
- **B. Custom RP2040 firmware (MicroPython or C) exposing a small framed
  protocol** — `load`, `set_run`, `set_clock`, `status/capabilities` — over
  USB CDC (or HID) — both **hypothetical** links until the transport is
  established. Most control, cleanest API; requires board-side firmware,
  which is **not authorized** under item 8 and would be its own plan.
- **C. Probe/hardware path** (debugger, logic analyzer) — not a demo operator
  path; out of scope.
- **D. Networked front end** (TCP/SSH tunnel to the PC process) — orthogonal
  to A/B, decide later with packaging.

Transport-independent API sketch (**proposal, not decided**): capability
negotiation first (`can_read_status`, `can_set_clock`, `max_sclk_hz`), then
`load(image, word_count)`, `set_run(level)`, `set_clock(hz)`, `read_status()`
returning only what the negotiated capabilities allow. The capability step is
what keeps Tier-1 and Tier-2/Tier-3 hardware honest without UI rewrites.

## Board-side support needed (none authorized yet)

1. Drive `ui_in[3:5]` (SCLK/MOSI/CS_N) at ≤ `clk/6` (10 MHz at the 60 MHz
   operating point) and `ui_in[1]` (`run`);
   assert and deassert `rst_n`; leave `ui_in[0]`/`[2]` for their personas.
2. Generate and change the clock (exists: `set_clock_hz`).
3. Select the project in the mux (raw mux doc; **[OPEN]** API surface).
4. Read chip outputs (`uo_out[1]`, `uo_out[7:2]`, `uo_out[0]`) — **[OPEN]**
   whether the demo board exposes them to the RP2040 at all.
5. Electrical/level compatibility of the IOs — **[OPEN]**: no IHP-specific
   demo-board page is in the wiki. The controller stays the Raspberry Pi Pico
   (RP2040) as chosen; `wiki/entities/tiny-tapeout.md` open question 2 notes
   that newer demo PCBs use an RP2350 — a platform-revision caveat to confirm,
   not an unresolved project choice.

## Linux packaging — **[OPEN]**

No repo evidence constrains this. Options: `pipx`/PyPI console+GUI app;
distro `.deb`/RPM; AppImage or Flatpak (bundles udev rules cleanly); a local
web UI served by the PC process. Constraints worth fixing now regardless of
choice: no root at runtime (udev rule or `dialout`/`plugdev` group), works
offline, ships the `.hex`/container parser and `peasm` output compatibility
tests. Recommend deciding **after** the transport, since USB-device access is
transport-specific.

## Test and acceptance strategy (design now, execution later)

*PC-side, no hardware (can start once this plan is accepted):*
- Word-framing unit tests: `.hex` → 16-bit MSB-first bit stream, compared
  against the stimulus shape `tb_pe_ctrl` drives and against `peasm` output;
  word-align, full-image padding, partial-word rejection (host-side).
- Golden behavioral expectations from `tools/fw/peemu.py` (e.g. `uart_echo`
  sending `41 42`) so the GUI knows what "looks running" means per program.
- API layer tests against a scripted fake board implementing the capability
  negotiation, including Tier-1-only hardware.

*Board-in-the-loop acceptance (hardware; separate authorization):*
- A1 happy path: load `uart_echo`, `run=1`, observe heartbeat + `dbg_pc[5:0]`
  changing + UART bytes on `uo_out[0]`.
- A2 sequencing: attempt load with `run=1` is prevented by the UI and, if
  forced, reported as *rejected, unverifiable*.
- A3 rate: the GUI's SCLK cap tracks the clock — at 60 MHz, 10 MHz is
  accepted and >10 MHz refused; at a lowered clock (e.g. 1 MHz) the accepted
  rate falls proportionally (~166 kHz), proving the cap is derived, not fixed.
- A4 clock: 60 MHz set through the chosen transport; UART bit cells measure
  8.6–8.7 µs as the RTL TB does.
- A5 restart: `run=0`, reload, `run=1`, program restarts from PC 0.

*Documentation acceptance for this item:* the seven generated-doc gates stay
green — run them **by name**, one command per generator. `python3
tools/gen/*.py --check` does *not* run them all: shell glob expansion passes
the first `.py` as the program and the remaining paths as arguments to it, so
only one generator executes:

```bash
python3 tools/gen/signal_glossary.py --check
python3 tools/gen/pin_budget.py --check
python3 tools/gen/sram_budget.py --check
python3 tools/gen/floorplan_feasibility.py --check
python3 tools/gen/crc_config.py --check
python3 tools/gen/clock_arithmetic.py --check
python3 tools/gen/block_diagram.py --check
```

The page must be indexed, and STATUS item
8 flips from **TODO** only when the user accepts this plan.

## Ordered work list (each step gated on the user)

1. Answer the board-capability questions (mux API, output readback, IHP clock
   limits) — wiki/Discord, read-only; record the RP2350 demo-PCB note only as a
   platform caveat (the chosen controller remains the RP2040 Pico).
2. User decides transport (A/B/D) and status tier (1/2, or wait for
   [[plans/pe-ctrl-readback]]).
3. User decides image container + clock surface + packaging.
4. Board-side capability probe script (only if option B or a probe is chosen).
5. GUI implementation plan (separate plan page) with the test list above.
6. Hardware acceptance run.

## Open choices to the user (summary)

1. **Transport/API**: reuse MicroPython/Commander (A) vs custom board firmware
   (B) vs later/networked (D).
2. **Status strategy**: Tier 1 (pads + host-side) now, Tier 2 if the board
   exposes outputs, or wait for the MISO readback decision in
   [[plans/pe-ctrl-readback]] — do not promise load verification before then.
3. **Image format**: bare `.hex` vs container with clock/persona/checksum and
   full-image padding.
4. **Clock surface**: 60 MHz only vs operator-selectable, the
   change-clock-while-running policy, and the coupled SCLK cap (`clk/6`; 10 MHz
   is the 60 MHz figure only, not safe at an arbitrary lower clock).
5. **Toolkit + packaging**: GTK/Qt/web, pipx/AppImage/Flatpak/.deb, udev rule.
6. **Auto-run**: keep the deliberate two-step (recommended, per ADR-007) or add
   an opt-in mode.

## Related

- [[decisions/adr-007-pe-ctrl-passive-slave]] — the loader contract and why there is no readback.
- [[plans/pe-ctrl-readback]] — the open MISO/interface decision that would
  change the GUI's verification story.
- [[plans/spi-pads]] — the *firmware* SPI pads, deliberately distinct from the
  loader pads.
- [[entities/tiny-tapeout]] — demo-board/clock/mux facts and open questions.
- [[reference/protocol-pin-budget]] — why no status pad is available without a
  pinout change.
