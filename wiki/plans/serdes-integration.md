---
title: Integrate pe_serdes + pe_codec_mux into pe_soc
created: 2026-09-23
updated: 2026-09-24
type: plan
tags: [architecture, integration, serdes, codec, timing, pads]
sources: [rtl/pe_serdes.v, rtl/pe_codec_mux.v, rtl/pe_bitstuff.v, rtl/pe_nrzi.v, rtl/pe_manch.v, rtl/pe_soc.v, rtl/pe_dru.v, rtl/pe_pinmux.v, tb/tb_pe_serdes.v, tb/tb_pe_codec_mux.v, diagrams/project-plan.puml, wiki/reference/block-diagram.md, wiki/plans/ethernet-soc.md]
confidence: high
---

# Integrate `pe_serdes` + `pe_codec_mux` into `pe_soc`

## Status — IMPLEMENTED 2026-09-24

Manager decision on every open scope choice: **adopt the follow-up review's
recorded recommended defaults** (`reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`,
"SERDES decision-readiness follow-up"), and where this plan and that review
differ, follow the review's amended two-codec shape:

- **Milestone scope**: additive engine, disabled at reset (overlay off) —
  every baseline TB/firmware stays bit-identical; the self-timed
  **wire-loopback** is the first consumer (no frame layer);
- **Plain asynchronous RX**: excluded from v1 — plain/NRZI/stuffed RX uses the
  divider's free-running cell strobe over the DRU's synchronized level, i.e.
  **self-timed loopback scope only; no phase acquisition for an arbitrarily
  phased asynchronous sender** (documented limit);
- **Topology**: ONE `pe_serdes` with split payload-only enables
  (`tx_bit_en = tx_cell_en && !tx_stuffed`, `rx_bit_en = rx_cell_en &&
  rx_bit_valid`) and **TWO** unmodified `pe_codec_mux` instances (TX/RX),
  one `bit_en` per encoded cell, `half_phase` a LEVEL (two toggles per cell)
  into the TX instance's `cfg[3]` and 0 on RX;
- **Access**: the `0xF` **latched-phase 16-entry indexed window** (no ISA
  change), separate `TXLEN`/`RXLEN`, one-cycle write-triggered
  `tx_load`/`rx_start`/`clr`, and **latched** `tx_done`/`rx_valid`/`rx_err`
  events (set-beats-clear on a STATUS read); the divider free-runs while
  enabled so the timing block stays active through a possible trailing stuff
  cell after `serdes.tx_busy` falls;
- **Overlay**: the per-pin level override lives in `pe_pinmux`
  (`ov_en`/`ov_bit`) feeding BOTH pad outputs before the open-drain gate.

Implemented per the ordered work list (strobe/divider block, window, enable
split + two codec instances + overlay, firmware, TB, harnesses, screens);
the engine's section and contract live at the top of `rtl/pe_soc.v`.

**Evidence (2026-09-24):** `tb_pe_soc_serdes` PASS — plain LSB/MSB,
Manchester, and the **directed stuffed Manchester loopback** (word `0x07E0`
chosen so payload 16 arms the final stuff bit, guaranteeing the
trailing-stuff case) with monitors for cell spacing, TX hold, RX skip,
DRU-strobe source and exact advance counts; `tb_pe_serdes` extended with a
directed split-enables case; `tb_pe_pinmux` extended with overlay/od-gate
cases; `regress/mutate_soc_serdes_tb.sh` **7/7** (the plan's four required
mutations + two alignment defects + the unaligned load) and the new
`regress/mutate_serdes_tb.sh` **7/7**; `./regress/run_all.sh --fast -j8`
exit 0 with 30/30 RTL, 21/21 firmware and **all nine mutation suites**;
`./regress/synth_area.sh` clean — **pe_soc 3,571 → 4,961 cells / 56,816.88 →
82,893.77 µm² (+1,390)**, **tt_um_top 4,038 → 5,363 / 65,686.27 → 91,268.06
µm² (+1,325)** (post-A1 baseline). Two defects found and fixed during
bring-up: `half_phase` toggled once per cell instead of twice, and
Manchester `rx_start` needed the first-DRU-decode anchor (a stale idle decode
otherwise became payload bit 0). Full record, hashes and commands:
`reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md`.

**Remaining (not in this change):** the full 10BASE-T TX frame path is a
separate block/plan. The two closeout items have since landed (2026-09-24,
Task 4): `regress/mutate_codec_tb.sh` is written (13 mutations, 13 detected /
0 survived, wired into `run_all.sh` as the tenth suite) and the mapped STA
refresh has run at slow/typ/fast on `pe_soc` and `tt_um_protocol_emulator`
(no new violation class; `pe_soc` setup/hold identical to the pre-integration
screen). Evidence: `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md` and
`reviews/2026-09-24/serdes-sta/`. No physical flow, DRC or LVS.

## Why

`pe_serdes` (539 cells) and `pe_codec_mux` (130 cells: `pe_bitstuff` 99,
`pe_nrzi` 15, `pe_manch` 7, glue) are the last two **built, TB-verified,
instantiated-nowhere** blocks (`wiki/reference/block-diagram.md`). They are the
shared word engine and the line-code pipeline the stretch personas need:
10BASE-T **transmit** (the receive chain is already in `pe_soc`), low-speed USB
(NRZI + stuffing), CAN (stuffing), and a hardware-paced path for plain
protocols. The project-plan diagram records the planned blocks inside the SoC:
CPU access goes through the indexed window and timing control, while codec
output passes through the pin overlay into the pin matrix. These connections
remain planned and the integration is not implemented.

This plan started **review-only**: no RTL changes until it is accepted — it
was accepted and **implemented on 2026-09-24** (see *Status* at the top). It was
amended on 2026-09-23 for the first review's five findings (window encoding,
LENW, overlay insertion point, TX-consumer scope, strobe split) and then for
the loopback-follow-up findings: `pe_codec_mux`'s single `bit_en` gates **both**
TX and RX state in every stage, and `pe_serdes`'s single `bit_en` advances
**both** sides, so neither block can carry a payload cell and a stuffed/decoded
cell at the same time or serve two directions with different hold/skip
patterns. The resolution is **two codec instances (TX and RX)**, a **split
`pe_serdes` enable (`tx_bit_en`/`rx_bit_en`)**, codec state clocked per
**encoded cell** (never per half-cell), and an independent `half_phase` level
toggling at half-cell cadence for Manchester TX. The findings and their
source-grounded resolutions are recorded in
`reviews/2026-09-23/SERDES-INTEGRATION-REVIEW.md`. `confidence` is `medium`
until the reviewer accepts the topology and the scope decisions below.

## What the blocks actually contract (source-grounded)

**`pe_serdes`** — one shift engine, two independent sides:

| Side | Inputs | Outputs | Semantics |
|---|---|---|---|
| TX | `tx_load`, `tx_data[31:0]`, `tx_len[5:0]`, `cfg_lsb_first` | `tx_ser`, `tx_busy`, `tx_done` | load/start while busy **restarts**; bit order and length snapshot at load; `tx_ser` idles **high** |
| RX | `rx_ser`, `rx_start`, `rx_len[5:0]`, `cfg_lsb_first` | `rx_data[31:0]`, `rx_busy`, `rx_valid` | first bit lands at `rx_data[0]` (LSB-first) or `[rx_len-1]` (MSB-first); `rx_valid` is one cycle behind the final strobe |

Shared today: `clk`, `rst_n`, and **one `bit_en` that clocks both sides** (TX
`always_ff`: `bit_en && tx_busy`; RX `always_ff`: `bit_en && rx_busy`). The
plan splits it into `tx_bit_en`/`rx_bit_en`, because with stuffing the two
directions need different payload-only sequences (see "Timing/strobe block and
cadence handshake"). `MAXLEN = 32`; lengths 0/`>MAXLEN` are out of contract.
`rx_ser` must already be synchronized/captured (ADR-002 lazy capture) — the
block is single-edge and does not synchronize.

**`pe_codec_mux`** — fixed-order, runtime-bypassable pipeline:

- TX: `tx_bit -> [stuff] -> [nrzi] -> [manch] -> tx_wire`.
- RX: `rx_wire -> [manch] -> [nrzi] -> [stuff] -> rx_bit`.
- `cfg[0]` stuff, `cfg[1]` NRZI, `cfg[2]` Manchester, `cfg[3]` `half_phase`
  (timing-driven half-cell select), `cfg[6:4]` run length (0 => 5; CAN 5, USB 6),
  `cfg[7]` ones-only (USB 0xE3 vs CAN 0x63).
- `bit_en` is a **single port shared by TX and RX state**, one pulse per
  **encoded cell** — a payload cell or an inserted stuff cell (`pe_bitstuff`'s
  stuff slot is a real `bit_en` cycle: it clears `tx_pend` and advances the run
  state). It is NOT a half-cell strobe: `pe_manch`'s TX is purely combinational
  (`tx_wire = bypass ? tx_raw : (half_phase ? tx_raw : ~tx_raw)`), so the
  second Manchester half is selected by the `cfg[3]` **level**, never by a
  strobe, and clocking the pipeline twice per bit would advance `pe_bitstuff`
  and `pe_nrzi` twice per cell.
- The one `bit_en` advances both directions' state: `pe_bitstuff`'s one
  `always_ff` updates `tx_run`/`tx_pend` and `rx_run`/`rx_err` on the same
  strobe; `pe_nrzi` updates `tx_level` and `rx_level` in one block gated by it;
  `pe_manch` registers `rx_err` on it. A loopback that runs the TX encoded-cell
  cadence and the DRU-decoded RX cadence at once therefore needs **two
  instances of the pipeline**, not one (see "Codec topology" below). `clr`
  resets the pipeline state, both directions.
- TX stuff/manch outputs are combinational; NRZI's line level is registered and
  lands at the strobe. RX reports `rx_err` (stuffing/NRZI violations).

**`pe_soc` today** — deliberately no protocol hardware: CPU + tick timer +
`pe_pinmux` + SRAM/dmem/fbuf + the 10BASE-T receive chain
(`pe_dru -> pe_manch -> pe_eth_mac` + `pe_crc` + `pe_fbuf`). The CPU's IO space
is **4 bits** (`io_port[3:0]`), ports `0x0..0xE` are allocated (`0xE` BUFCTRL),
and **`0xF` is free**. The tick timer gives half-bit ticks
(`TICKS_PER_BIT = CLK_HZ/BAUD/2`) and I2C 1 µs ticks — but no hardware bit
strobe. `pe_dru` is the only lazy-capture path: `rx_pin -> bit_en`,
`rx_first/rx_second/rx_wire`, `locked`, with `SPB = 12`. `pe_pinmux` owns
per-pin out/oe/od, and firmware reads pins back through it.

**TBs and gaps.** `tb_pe_serdes` and `tb_pe_codec_mux` cover the units
(boundaries, bit orders, all codec subsets, stage timing). There is **no
mutation suite for either block** (the seven suites cover i2c, spi, fbuf,
eth_mac, eth_soc, ctrl, i2c_xfer), and no SoC- or top-level instance.

## Architectural position: why this does not break the thesis

`pe_soc`'s header says "there is NO protocol hardware in this file... no shift
register, no framing logic, no baud generator that knows what a bit is." This
integration adds a shift register and a code pipeline, so the claim must become
precise, not weakened:

- **No protocol-specific hardware.** Nothing in the engine knows framing,
  addresses, ACKs, or a protocol name; the word width, bit order, line code and
  strobe cadence are registers firmware sets. Protocol semantics stay in
  firmware, exactly as UART/SPI/I2C do today.
- **The engine is a pacing resource, not a mode.** It exists because firmware
  cannot bit-bang 10BASE-T's 20 MHz half-cells or USB's NRZI+stuffing chain.
  The bit-banged port path remains the default and keeps working unchanged.

The header, `wiki/concepts/spi-as-firmware.md` and the "no protocol hardware"
line in STATUS must be updated in the same change.

## Interface and data path (recommended shape)

**TX.** `serdes.tx_ser -> u_tx_codec.tx_bit`; `u_tx_codec.tx_wire` reaches the
pin through a per-pin **level override applied at `pe_pinmux`'s level input,
before its open-drain gate** -- not on the post-matrix `pin_out` wire. The
matrix's enable equation is
`pad_oe[i] = reg_oe[i] && (!reg_od[i] || !reg_out[i])` (`rtl/pe_pinmux.v`),
so an override that only replaced `pin_out` would leave `pad_oe` keyed to the
un-overridden register level: an engine `0` while the register held `1` on an
`od=1` pin would release instead of pulling low. The fix is to feed the
overridden level into both outputs:
`eff_out[i] = overlay_en[i] ? tx_wire : reg_out[i]`, i.e. extend the matrix
with a per-pin level override (a SoC-internal signal) rather than muxing after
it. Firmware still owns `oe`/`od`, so open-drain personas work with the engine.
Restricting v1 to push-pull pins (`od=0`) is rejected as a firmware footgun;
the pre-gate override is a small, local change. Reset default: overlay off on
every pin -- the bit-banged personas are bit-identical.

**RX.** One capture path, not two: route the engine's RX through the existing
`pe_dru` (`rx_wire`, `rx_first`, `rx_second`, `bit_en`, `locked`), whose input
is already the synchronized pin. Two modes:
- **DRU-decoded (Manchester)**: `dru.bit_en` is a **per-decoded-cell** strobe
  (stuff cells included) and the half-cell data arrives as
  `rx_first`/`rx_second`; `u_rx_codec` consumes them with `manch_en = 1` and
  `bit_en = dru.bit_en`, exactly how the signed-off eth chain drives `pe_manch`
  (`half_phase = 0`).
- **Plain/NRZI/stuffed**: `dru.rx_wire` feeds `u_rx_codec`; the cell strobe
  comes from the new timing block at the encoded-cell rate.

The plain-mode path has no start-edge phase acquisition: `dru.rx_wire` is only
the synchronized pin level, and the new timing block supplies a free-running
cell cadence. That is suitable for the first self-timed wire-loopback milestone
but does not promise reception from an arbitrarily phased asynchronous sender.
If asynchronous plain RX is in scope, add a phase-acquisition mechanism or
constrain the supported source timing before implementation.

A later refactor could replace the dedicated `pe_manch` in the eth RX chain
with `codec_mux`; **not in this change** — the receive chain is signed off and
must not be disturbed.

**Codec topology: two instances, not one.** The loopback makes the two
directions' cadences differ, and one `pe_codec_mux` has one `bit_en` for both
(as above). The integration therefore instantiates the verified pipeline
**twice**:

- `u_tx_codec` — TX-only. `tx_bit = serdes.tx_ser`, `tx_wire -> overlay`,
  `bit_en = tx_codec_cell_en` (one per encoded cell — payload or inserted stuff
  cell, **never** per half-cell). Its `tx_stuffed` output gates the serdes:
  `serdes.tx_bit_en = tx_codec_cell_en && !tx_stuffed`. RX inputs tied
  inactive, `rx_err` unused.
- `u_rx_codec` — RX-only. `rx_wire`/`rx_first`/`rx_second` from the DRU branch,
  `rx_bit -> serdes.rx_ser`, `bit_en = rx_codec_cell_en` (one per decoded
  cell — stuff cells included: `dru.bit_en` for Manchester, the timing cell
  strobe for plain/NRZI/stuffed). Its `rx_bit_valid` output gates the serdes:
  `serdes.rx_bit_en = rx_codec_cell_en && rx_bit_valid`. TX inputs tied,
  `tx_wire`/`tx_stuffed` unused.

Both instances are the existing, TB-verified `pe_codec_mux` **unmodified**, so
the unit TBs and the fixed pipeline order stay the evidence; each instance's
unused-direction state advances on its own strobe but drives no consumed
output. One `CFG` byte is replicated to both instances (every target persona
uses the same line code in both directions); the spare window index is the
natural home for a future `CFG_RX` if that ever changes. `half_phase` is not a
firmware cadence and not a strobe: it is the timing block's half-cell **level**
(2× toggle), presented in the TX instance's `cfg[3]` position
(`cfg_tx = {cfg[7:4], half_phase, cfg[2:0]}`); `cfg_rx` takes 0 there
(Manchester RX decodes from `rx_first`/`rx_second` and ignores the phase).

The alternative — one instance with a **split codec interface**
(`tx_bit_en`/`rx_bit_en`, and each stage's combined `always_ff` split into TX
and RX halves) — is workable but touches three verified modules, their port
lists and their TB/mutation expectations. The two-instance shape is preferred
for v1: it uses the blocks exactly as verified, and costs one extra pipeline (up
to ~130 mapped cells; synthesis should dead-code the unused direction — measure
with `synth_area.sh`). It is a reviewer choice, listed in the open decisions.

**Timing/strobe block and cadence handshake (new, small).** The codec's
`bit_en` is **one pulse per encoded cell** (payload or inserted stuff), never
per half-cell; the serdes enables are **payload-only**, gated by the codec's
own combinational flags with current-cycle semantics:

- `tx_codec_cell_en -> u_tx_codec.bit_en`: one pulse per encoded cell. It
  advances `pe_bitstuff`'s TX run/pend state (the stuff slot is a real cycle:
  it clears `tx_pend`) and, when enabled, `pe_nrzi`'s TX level. For Manchester
  TX it stays one per encoded bit; `pe_manch`'s TX is combinational and
  consumes no strobe.
- `serdes.tx_bit_en = tx_codec_cell_en && !tx_stuffed` (**current-cycle
  semantics**, source-grounded in `rtl/pe_bitstuff.v`): during the inserted
  stuff cell `tx_stuffed` is the combinational output of the registered
  `tx_pend`, so it is high for that whole `bit_en` cycle. The serdes holds
  `tx_shreg[tx_cnt]`/`tx_ser` across the stuff cell and advances only on
  payload cells; without the gate it consumes one payload bit per wire cell
  and the bit after a stuff insertion is shifted or lost. The unit reference is
  `tb_pe_codec_mux.tx_step_comb`: it pulses `bit_en` on the stuff slot (raw
  ignored, `tx_stuffed` checked high before the edge) and checks that the next
  payload strobe resumes the correct bit.
- `rx_codec_cell_en -> u_rx_codec.bit_en`: one pulse per decoded cell.
  Manchester takes it directly from `pe_dru.bit_en` (the DRU emits one per
  decoded cell, stuff cells included); plain/NRZI/stuffed take the timing
  block's encoded-cell strobe with `dru.rx_wire`. This advances the RX
  stuffer/NRZI state and the valid/error path.
- `serdes.rx_bit_en = rx_codec_cell_en && rx_bit_valid` (**current-cycle**):
  `rx_bit_valid` is `pe_bitstuff.rx_raw_valid`, combinational from the RX run
  state, so it is low for a received stuff cell. The RX serdes skips that cell
  and captures only payload bits.
- `half_phase` is a **level**, not a strobe: it toggles once per half-cell
  (twice per `tx_codec_cell_en` pulse) when Manchester TX is enabled and is 0
  otherwise. `pe_manch` selects the first/second half from it combinationally.

**`pe_serdes` needs the enable split.** `pe_serdes` has one `bit_en` that
clocks **both** the TX `always_ff` (`bit_en && tx_busy`) and the RX `always_ff`
(`bit_en && rx_busy`) (`rtl/pe_serdes.v`). The handshake above gives the two
directions different sequences whenever stuffing is enabled: TX **holds** on
each `tx_stuffed` cell while RX **skips** each received stuff cell, and the two
windows need not coincide (independent words, or DRU decode latency). One
shared `serdes_bit_en` cannot serve both, so the integration splits the port
into `tx_bit_en` and `rx_bit_en`, each wired to its own payload-only gate. The
split is mechanical — the two enable networks already exist inside the module,
no flops move — so the mapped area should be essentially unchanged (confirm
with `synth_area.sh`). Source cost: the `rtl/pe_serdes.v` header/contract, its
port list, `tb_pe_serdes` (drive both; add a directed case where they differ),
the new `regress/mutate_serdes_tb.sh`, and the generated
`wiki/reference/signal-names.md`. The alternatives are in the open decisions.

The divider register sets the encoded-cell period; `half_phase` is derived from
it, not from a second divisor. An optional single-shot mode lets firmware pace
plain TX by hand. This is the only new stateful block; it is protocol-agnostic
and has no notion of baud -- the divisor is a register.

## Control/status semantics and CPU/firmware access

The binding constraint is the **4-bit IO space**: `0xF` is the only free port,
and widening the port field would touch the ISA, `pe_cpu`, `peasm` and every
firmware. Recommendation: an **indexed register window at `0xF`**, no ISA
change:

- **Latched phase, all 8 data bits intact.** The window has a `phase` bit
  (reset to INDEX) and a 4-bit `INDEX` pointer:
  - `OUT 0xF, A` in INDEX phase: `INDEX <= A[3:0]`, `phase <= DATA`. The access
    carries the index, not data.
  - `OUT 0xF, A` in DATA phase: `REG[INDEX] <= A[7:0]`, `INDEX <= INDEX+1`,
    phase stays DATA -- a data burst is one index write plus N full-width
    writes.
  - `IN A, 0xF`: returns `REG[INDEX]`, `INDEX <= INDEX+1` (reads always
    auto-increment), and `phase <= INDEX`. **Any read re-arms index phase**, so
    the next write is an index write.
- Firmware sequences: write a word = `IN` (arms; use it for STATUS) + `OUT`
  index `TXDATA_lo` + 4 `OUT` data bytes; read a word = `OUT` index
  `RXDATA_lo` + 4 `IN` bytes. Mixing a write burst after a read burst costs
  the re-arming read, which can be the STATUS read.

Proposed 16-entry map (values are a shape to review, not a freeze):

| Idx | Name | R/W | Meaning |
|---|---|---|---|
| 0 | `CTRL` | w | engine enable, `tx_load`, `rx_start`, `clr`, `cfg_lsb_first`, TX-pin select |
| 1 | `CFG` | w | codec cfg byte (stuff/nrzi/manch/run/ones_only); `cfg[3]` is overridden by the timing block on the TX instance and 0 on RX |
| 2-3 | `DIVL/DIVH` | w | bit-strobe divisor |
| 4 | `TXLEN` | w | `tx_len[5:0]`, 1..32 (0 invalid); `LENW = 6` |
| 5 | `RXLEN` | w | `rx_len[5:0]`, 1..32 (0 invalid) |
| 6 | `STATUS` | r | `tx_busy/tx_done/rx_busy/rx_valid/rx_err/dru_locked/engine_en` |
| 7-10 | `TXDATA` | w | 32-bit TX word (MSB-last or first, per `cfg_lsb_first`) |
| 11-14 | `RXDATA` | r | 32-bit RX word |
| 15 | spare | - | future personas / status |

`tx_load`, `rx_start`, and `clr` must be one-cycle write-triggered strobes (or
auto-clear control bits), because the current engines treat them as
level-sensitive inputs and a held bit restarts/reloads the engine or keeps the
codec cleared. Firmware writes TX/RX data, length and configuration before the
respective start strobe. Status events such as `tx_done`, `rx_valid`, and
`rx_err` need latched flags with defined clear semantics so a CPU poll loop
cannot miss a one-cycle or strobe-gated event.

The TX completion event also needs to say whether `tx_done` means the last
payload bit was consumed or the encoded wire is idle. With stuffing, the final
payload strobe can arm a trailing stuff cell after `pe_serdes.tx_busy` falls;
the timing block must remain active long enough to emit it. Add a directed
trailing-stuff case to the loopback test.

`TXLEN`/`RXLEN` are separate because the serdes has independent sides (it can
transmit and receive at once), and a single 8-bit register cannot hold two
six-bit lengths regardless of encoding. The 6-bit 1..32 encoding follows
`LENW = $clog2(MAXLEN+1) = 6`; a 5-bit `0 => 32` encoding is an acceptable
alternative if the reviewer prefers it, but not both fields in one byte.
Codec reset is one `CTRL.clr` pulsing both instances together (loopback-safe);
independent `tx_clr`/`rx_clr` are spare-bit work for a later persona. `CFG` is
replicated to both instances — every target persona uses one line code in both
directions — and the spare index can become `CFG_RX` if that changes.

Reset default: engine disabled, overlay off, `REG` reads 0 -- every existing
TB and firmware is unaffected. Firmware cost: an index write plus one access
per byte; bursts amortise the index write, and switching bursts costs one
re-arming read. This is why the window is a resource for the paced/stretch
personas, not a replacement for bit-banging the baseline ones. The alternative
(5-bit IO space) is a separate, larger decision and is **explicitly out of
scope**.

## Reset and clocking

Single `clk`/`rst_n` domain, no new clocks. `rst_n` clears the engine, both
codec instances, divider and window. All codec/serdes enables idle low and
`half_phase` idles 0; `serdes.tx_ser` idles high (per its contract) but is only
visible on a pin when the overlay is enabled and OE is set. The only
asynchronous paths remain the existing DRU capture and the loader's SCLK
synchronizer; the engine's `rx_ser` is always a captured signal, never a raw
pad.

## Testbench and mutation evidence (planned)

1. **Unit coverage is already there**; add the missing **mutation suites** for
   `pe_serdes` and `pe_codec_mux` (`regress/mutate_serdes_tb.sh`,
   `regress/mutate_codec_tb.sh`) so the integration is not standing on TBs no
   fault injection has ever challenged (`serdes` bit order, restart-while-busy,
   `rx_valid` timing, the new per-side enables; codec pipeline order, bypass
   subsets, ones-only, half_phase).
2. **SoC-level, additive path**: a new `tb_pe_soc_serdes` that loads a small
   firmware using the `0xF` window, drives a TX word through the overlay with a
   wire model, and loops it back through the DRU + codec + serdes RX, checking
   the word both ways. Two configurations: plain (LSB-first and MSB-first) and
   Manchester (combinational `half_phase` level; **no** half-cell strobe), the
   latter decoded by the same model `tb_pe_soc_eth` uses.
   **Directed loopback requirement (the cadence handshake proof).** The
   Manchester case must run **both directions concurrently** and include a
   **stuffed** configuration (`cfg = 0x05`: stuff + manchester, default run 5;
   or `0x07`: stuff + nrzi + manchester) so the TX hold and the RX skip are
   both exercised, alongside the unstuffed `0x04`. In that run the TB must
   check:
   - `u_tx_codec.bit_en` (`tx_codec_cell_en`) pulses once per encoded cell —
     payload cells plus exactly the inserted stuff cells — and never twice per
     bit; `half_phase` toggles at twice that rate, independently.
   - `u_tx_codec.tx_stuffed` is high for the inserted cell; `serdes.tx_ser` is
     stable across it; the serdes TX advances exactly `tx_len` times (not
     `tx_len` + stuff count); the payload cell after the stuff cell carries the
     correct next bit.
   - `u_rx_codec.bit_en` (`rx_codec_cell_en`) follows `pe_dru.bit_en` once per
     decoded cell; `rx_bit_valid` is 0 on a received stuff cell;
     `serdes.rx_bit_en` is 0 there, so the serdes RX advances exactly `rx_len`
     times.
   - The decoded word equals the transmitted word (plain LSB/MSB and the
     stuffed Manchester cases).
   The SoC mutation suite for this TB must include, and require the TB to fail
   on: (a) the **TX hold removed** (`serdes.tx_bit_en = tx_codec_cell_en`),
   (b) the **RX skip removed** (`serdes.rx_bit_en = rx_codec_cell_en`), (c) the
   **codec cell enable doubled** (drive a codec instance's `bit_en` at the
   half-cell rate), and (d) the **strobe cross-wire** (`u_rx_codec.bit_en` from
   the TX cell strobe). Each is the exact failure the shared-enable topology
   would have produced.
3. **Non-regression, on the same run**: `tb_pe_soc_uart`, `tb_pe_soc_spi`,
   `tb_pe_soc_i2c_xfer`, `tb_pe_soc_tick`, `tb_pe_soc_eth` must stay green with
   the engine disabled at reset — the proof that the path is additive.
4. **First consumer, split in two**:
   - **Wire-loopback milestone (this plan)**: no frame layer. Engine TX (plain
     LSB/MSB and Manchester) drives a wire model that loops back into the DRU +
     codec + serdes RX; the word must match. This proves the engine, the strobe
     split and the overlay without any Ethernet framing.
   - **Full 10BASE-T TX consumer (separate plan/block)**: `pe_eth_mac` is
     receive-only (`rtl/pe_eth_mac.v`: `bit_en`/`rx_raw`/`rx_err`/
     `rx_first`/`rx_second` in; `fbuf_*`/`frame_*`/`crc_*` out) and `pe_fbuf`
     is the RX store -- neither can source a TX frame. A transmit path needs
     preamble/SFD generation, FCS generation (`pe_crc` is currently committed
     to the RX path, so TX needs a time-shared or duplicated LFSR), IFG/backoff
     timing, and a frame source (firmware bytes through the window, or a TX
     buffer + state machine). That is the `eth_tx` block on the progress
     diagram and gets its own plan; this plan only delivers the engine it will
     use.
5. All new TBs self-check, print `PASS`, and are registered in `run_all.sh`;
   every mutation must be independently detected and the source restored. The
   new SoC TB gets its own mutation harness (like `mutate_eth_soc_tb.sh`) whose
   required list includes the TX-hold/RX-skip/doubled-cell/cross-wire
   mutations above;
   `regress/mutate_serdes_tb.sh` and `regress/mutate_codec_tb.sh` stay
   unit-level.

## Synthesis / STA hardening risks

- **Area**: +`pe_serdes` 539 (the `bit_en` split is a port change — the two
  enable networks already exist — so no new state expected) + **two**
  `pe_codec_mux` instances (2 × 130 mapped, less whatever synthesis dead-codes
  from each instance's unused direction) + the two payload-enable gates +
  mux/divider/window glue (estimate +50-150 cells) on top of the current
  post-E1 `pe_soc` baseline of 3,306 cells / 53,615.56 µm² and `tt_um_top`
  baseline of 3,579 cells / 59,286.81 µm². The current `synth_area.sh` screen
  is recorded in `/tmp/synth_area_diagram_followup.log`; rerun it after
  implementation before comparing an area delta.
- **Standalone signoff already exists**: `pe_serdes` was through full LibreLane
  Classic (2026-09-18, former 66 MHz target): **0 DRC, 0 LVS, setup WS
  +7.6 ns (slow), hold WS +0.116 ns (fast), 78% utilization**
  (`flow/run_librelane.sh flow/pe_serdes.json`). That covers the block alone,
  not the integration's overlay mux, strobe divider or fanout -- the SoC-level
  native yosys + OpenSTA screen is still required after implementation. No
  physical flow is part of this plan.
- **Combinational depth**: the stuff -> NRZI -> Manchester cascade is
  combinational into the pad-facing overlay; Manchester's 20 MHz half-cell
  interval is **3 clk (50 ns) at 60 MHz**. The half-cell phase is a level, not
  a strobe. The unit TB runs at
  100 MHz simulation, which proves function, not silicon timing — the
  implementation needs the native yosys + OpenSTA screen (as for pe_ctrl), and
  possibly a registered Manchester output stage if the path is too deep.
- **Strobe fanout/skew**: `tx_codec_cell_en`, `rx_codec_cell_en`,
  `serdes.tx_bit_en` and `serdes.rx_bit_en` reach the shift engine, the two
  codec instances and the DRU-derived branch; `half_phase` is a separate 2×
  toggle into the TX instance's `cfg[3]`. Check max-fanout and the half-cell
  skew budget.
- **32-bit shift registers** and the 16x8 window bank are flop-based; the area
  delta is known but the window's read-mux path must be checked for
  timing/depth.
- The existing eth RX chain is untouched; its recorded STA facts stay valid.

## Pad / persona implications

- **No new pads.** The engine uses the same port bits and the matrix's OE/OD;
  the loader (`ui[3:5]`), the SPI pads (`uio[2:3]`), I2C (`uio[0:1]`) and the
  debug pins are unchanged. The pin budget is unchanged by the engine itself
  (it is routing, not new IO).
- **Personas enabled**: the 10BASE-T **wire** transmit side (the frame layer is
  a separate block), USB-LS (NRZI + ones-only stuffing), CAN (stuffing), and
  hardware-paced plain protocols. JTAG/SWD/PS/2 remain optional targets.
- **Half-duplex note**: 10BASE-T TX and RX share the RX pin (bit 7), so on a
  real wire the overlay and the DRU are never enabled in opposite directions at
  once — firmware owns the turnaround through OE. The loopback TB is
  simulation-only and runs both directions concurrently in its wire model,
  which is exactly why the two codec instances must decouple the cadences.

## Ordered work list (after review)

1. Header/docs correction: restate pe_soc's position as "no protocol-specific
   hardware" and link this plan.
2. Strobe/divider block + unit TB (mutation-tested).
3. `0xF` window + register file + reset defaults; CPU-visible test.
4. `pe_serdes` enable split + **two** codec instances (TX and RX) with the
   overlay mux, the encoded-cell enables, the two payload gates and the DRU RX
   routing.
5. `tb_pe_soc_serdes` (plain + Manchester loopback, stuffed case); keep every
   existing TB green; add the two unit mutation suites plus the SoC harness.
6. Wire-loopback TB first (plain + Manchester, both directions, with the
   directed stuffed mixed-config case above); the full 10BASE-T TX consumer
   (frame/preamble/FCS/IFG/source) is a separate block and plan.
7. `synth_area.sh` + native yosys/OpenSTA screen; update STATUS, block diagram
   (orphans retire), log and the progress diagram.

## Open decisions for the reviewer

**RESOLVED 2026-09-24 — manager decision: adopt the follow-up review's
recommended defaults for every group (see *Status* at the top); the two-codec
amended shape wins where this plan and the review differ.** The list below is
retained as the record of the options that were on the table.

1. **Scope**: additive engine (recommended) vs. migrating the baseline
   personas onto it now.
2. **Access**: the `0xF` indexed window (recommended) vs. widening the IO space
   (ISA/CPU/assembler change; out of scope here).
3. **RX path**: DRU as the single capture path (recommended) vs. a second
   synchronizer for plain modes.
4. **First consumer**: the wire-loopback milestone (recommended; no frame
   layer) vs. an engine-paced plain UART TX. The full 10BASE-T TX frame path
   is a separate plan either way.
5. **Manchester output**: combinational cascade (start) vs. a registered output
   stage (if STA demands it).
6. **Codec topology**: two `pe_codec_mux` instances, one per direction
   (recommended: uses the verified blocks unmodified) vs. a split
   `tx_bit_en`/`rx_bit_en` interface inside one instance (smaller, but touches
   the three verified codec modules and their TB/mutation expectations).
7. **Serdes cadence interface**: split `pe_serdes.bit_en` into
   `tx_bit_en`/`rx_bit_en`, each gated payload-only (recommended: mechanical,
   area-neutral, and the only shape that carries both directions' sequences
   when stuffing is enabled) vs. two direction-specific `pe_serdes` instances
   (double the 539 cells and the unit TB/mutation scope for no functional gain)
   vs. one shared enable with the engine scoped to lockstep/half-duplex
   stuffed streams (rejected: the loopback runs both directions at once and
   the window exposes independent TX/RX lengths).

At plan-writing time no RTL was changed. The implementation landed 2026-09-24
(see *Status* at the top); no physical flow, DRC or LVS was run.
