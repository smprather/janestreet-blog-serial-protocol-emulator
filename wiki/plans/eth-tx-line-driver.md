---
title: 10BASE-T Line Driver — the Pair, TP_IDL and Link Pulses
created: 2026-09-26
updated: 2026-09-26
type: plan
tags: [ethernet, tx, physical-layer, pads, pinout, verification, plan]
sources: [rtl/pe_eth_tx.v, rtl/pe_soc.v, rtl/tt_um_protocol_emulator.v, wiki/plans/eth-tx-frame-path.md]
confidence: medium
---

# 10BASE-T Line Driver — the Pair, TP_IDL and Link Pulses

**Status: IMPLEMENTED and COMMITTED on branch `eth-tx-line-driver`
(worktree `/home/mylesp/worktrees/eth-tx-line-driver`, based on `main` at
`4560432`), NOT MERGED.** It reclaims a pad (`uo_out[3]`, today
`dbg_pc[1]`), which is a pinout decision, so the change is a **proposal for
the manager to adopt, amend or reject** — STATUS item 4 owns the `dbg_pc`
pads. Command-level evidence is in `reviews/2026-09-26/ETH-TX-LINE-DRIVER.md`.

**How to read this page:** it is a **RECORD** of RTL, testbenches and gates
that are in the tree on that branch — claims-check it against the code. Only
two sections look forward: *Decisions taken here (for the manager)* (choices
the branch already implements, awaiting adoption) and *Follow-ups (not done
here)* (work that does not exist yet).

`confidence: medium` is about the 802.3 numbers, not the RTL: they come from
a transceiver datasheet and two secondary write-ups (see *Sources*), not from
the text of IEEE 802.3 Clause 14 itself.

## The gap this closes

Before this change the chip transmitted 10BASE-T on ONE single-ended pad
(`eth_tx`, `uo_out[2]`) that idles HIGH (`rtl/pe_eth_tx.v`, "THE IDLE
TRAP"). The frame on that pad is correct — [[plans/eth-tx-frame-path]]
proved it bit by bit — but a real link partner would still never accept it:

1. **No link pulses.** 802.3's link-integrity function: a transceiver that
   hears neither frames nor normal link pulses (NLPs) for its link-loss time
   (50–150 ms) enters *link fail* and **disables both its transmitter and its
   receiver** (ML4658 datasheet, pin `LTF`). Nothing in the RTL, the
   firmware or the plans generated NLPs, although
   [[concepts/ethernet-scope]] lists "link test pulses" as part of the line
   layer. A switch or NIC would hold the link down and drop every frame.
2. **One pad cannot make three line states.** A 10BASE-T pair is `+`, `−` or
   0 V. The idle line, the (positive) link pulses and the (positive)
   start-of-idle delimiter TP_IDL all need the third state. A single pad
   idling high must be AC-coupled on the board (half the swing), cannot make
   a positive pulse from a high idle, and would push a standing DC current
   through a DC-coupled transformer. Real transceivers put both outputs "to
   the same voltage [in idle] to prevent DC standing current in the isolation
   transformers" (ML4658).

## What 802.3 Clause 14 asks for

| Quantity | Requirement | This design |
|---|---|---|
| TX amplitude | 2.2–2.8 V peak differential into 100 Ω | made on the **board** (buffer + magnetics); the pads give two 0/3.3 V legs |
| Idle | 0 V differential | both legs equal (both high) |
| Manchester | `1` = low→high mid-cell, `0` = high→low | unchanged (`pe_manch`) |
| TP_IDL | ≥ 250 ns **positive** after the last bit, then 0 V | 3 cells = **300 ns** |
| Link pulse (NLP) | **positive**, ≥ 60 ns (typ. 100 ns), every 16 ± 8 ms | 1 cell = **100 ns**, every 160,000 cells = **16.000 ms** |
| Link loss | 50–150 ms with no pulse/frame → link fail, TX and RX disabled | why the pulses exist |
| RX squelch | reject < 300 mV peak, accept ≥ 585 mV | the **board's** comparator |

## The design (chip side)

**The pair, composed in `pe_soc`:**

```
eth_tx   = wire                (uo_out[2], unchanged)
eth_tx_n = wire ^ line_drive   (uo_out[3], new)
```

While `line_drive` is high the pair carries the Manchester signal (`±`);
while it is low both legs sit at the idle-high level, so the pair is 0 V.
`line_drive` is a `pe_eth_tx` **register that moves only on cell
boundaries**, so the two legs switch on the same clock edge and `eth_tx_n`
cannot glitch against the wire. `line_drive` is high:

- for **every frame cell**, preamble through FCS;
- for **3 cells (300 ns) of TP_IDL** after the last FCS cell, while the wire
  already sits idle-high — and also after a frame cut by an **abort** or by
  either **underrun** (mid-DATA, or a bare preamble with no header byte);
- for **one cell (100 ns)** every `NLP_CELLS` (default 160,000 = 16 ms) cells
  of **quiet idle** — a link pulse.

The rules that make the pulses safe:

- The period counts **only in quiet IDLE**: a frame, its IFG and any TP_IDL
  restart it, and so does losing `enable`. The first pulse after any activity
  is exactly `NLP_CELLS` cell boundaries after the engine is quiet again.
- A **pending start beats a due pulse**; a start that arrives **during** a
  pulse waits for that one cell (the pulse is never cut); a start that lands
  inside an **abort's TP_IDL cancels** the countdown (otherwise it would
  release the pair two cells into the new preamble).
- Losing `enable` releases the pair on the next clock.
- `tx_busy` is **unchanged**: link pulses and a post-abort TP_IDL run with
  `tx_busy` low. So firmware that drops `tx_path` right after an abort cuts
  the TP_IDL, and disabling mid-pulse cuts the pulse — both harmless.

**Ownership of `uo_out[3]`:** `eth_tx_n_en = tx_path && overlay on pin 7 &&
pin 7 driven`, and the wrapper does
`uo_out[3] = eth_tx_n_en ? eth_tx_n : dbg_pc[1]` — the same bit-identical
reset rule as the landed `uo_out[2]` mux. With `tx_path` low the SERDES may
drive pin 7, and `uo_out[3]` stays the debug PC.

**Idle is both-HIGH, not both-low.** The first sketch (in chat) said
both-low. Both-high was chosen because it leaves `eth_tx` **bit-identical**
to the landed design — every existing testbench, mutation and formal proof
about that leg stands unchanged — and it is exactly as 0 V to the
transformer. A board built from open-drain current switches reads high as
"off", so both-high is also its natural idle.

**Parameter hygiene:** `NLP_CELLS` is a parameter because the unit TB runs a
second instance at 50; its elaboration guard (`>= 2`) is proven to fire by
`regress/param_guards.sh`. `TPIDL_CELLS` is a local constant. No parameter
was added to `pe_soc`: the SoC TB measures the real 16 ms instead.

**Cost** (mapped, sg13g2 typ, pre-route; `regress/synth_area.sh` on `main`
and on the branch): `pe_eth_tx` 904 → 1,040 cells, `pe_soc` 6,345 → 6,447,
`tt_um_protocol_emulator` 10,215 → 10,269 cells (+1,410 µm², +0.8%). No other
block changed.

## The board (not the chip): what the Ethernet PMOD needs

**TX.** `uo_out[2]`/`uo_out[3]` → a line buffer → series resistors → a pulse
transformer (an RJ45 with integrated 10/100 magnetics) → RJ45 pins 1/2 (MDI,
wired like a NIC).

- *Why a buffer:* a 100 Ω line at spec amplitude needs about 25 mA per leg.
  Tiny Tapeout's published pad rating is 4 mA (a sky130 figure; IHP's is
  unverified). At 4 mA the pads alone reach about 0.4 V on the line through
  1:1 magnetics — below the 585 mV every receiver must accept. The buffer
  also keeps the cable away from the ASIC's pads (ESD, ground offsets).
- *Amplitude:* 3.3 V 74LVC-class legs with a matched source (about 50 Ω per
  leg including the driver) give about ±1.65 V on the line — under the 2.2 V
  minimum but far above the 585 mV squelch, which is fine on a short cable.
  For spec amplitude, a 74ACT-class buffer at 5 V (its TTL inputs accept
  3.3 V) with about 50 Ω per leg gives about ±2.5 V into 100 Ω.
- *Alternative:* the transceiver-style current-mode stage — the transmit
  winding's centre tap to the supply and two open-drain switches pulling its
  ends; idle both-high is both switches off.
- *Skippable for a demo, required for compliance:* pre-equalisation (the
  second half of each 100 ns pulse attenuated so 100 m of cable arrives
  flat) and the transmit low-pass filter.

**RX.** Magnetics → 100 Ω termination → a fast comparator (single-digit
nanoseconds, e.g. a TLV3501) with hysteresis or a threshold between 300 and
585 mV → `ui_in[2]`. The comparator *is* the squelch: without it the idle
line chatters into the DRU. A threshold offset skews the Manchester duty
cycle slightly (see *Follow-ups*). Two options on
[[reference/protocol-pin-budget]] were replaced: a resistor network alone
leaves detection to the pad's own input threshold, which varies chip to chip,
and an external PHY (LAN8720, ENC28J60) does its own Manchester coding, which
would bypass `pe_manch` and `pe_dru` — the chip's line layer.

**Link partner.** A PC without auto-MDI-X needs a crossover cable. Most
switches parallel-detect NLPs and link at 10 Mbit/s half duplex; many
2.5G/10G ports no longer support 10 Mbit/s.

**The debug fallback touches the line.** With the Ethernet persona off,
`uo_out[2]`/`uo_out[3]` show `dbg_pc[0]`/`dbg_pc[1]`, so a connected
front end transmits program-counter activity onto the cable. Keep the PMOD
unplugged during other demos, or change the fallback (a manager decision).

## Verification

Every level was written RED-first against interface stubs, then made GREEN:

| Level | What it proves | RED evidence (stub) |
|---|---|---|
| `tb_pe_eth_tx` (unit, checks 10–14, cases 7b and 8b) | every frame cell driven; `line_drive` moves only on cell boundaries; any driven non-bit cell is positive; TP_IDL exactly 3 cells after a frame, an abort and both underruns; a restart inside TP_IDL keeps the pair driven; pulses: first at exactly 50 boundaries, period 50, 6 clocks wide, positive, not counted through a frame or IFG, pending start wins, start during a pulse waits one cell, disable releases and restarts the period (also mid-count); the default instance's first pulse **exactly 160,000 boundaries (16.000 ms)** after enable | 15,325 failures: undriven frame bits, no TP_IDL, no pulses |
| `tb_pe_soc_eth_tx` | `eth_tx_n` is the complement in every frame cell; 3 TP_IDL cells at 1/0 then 1/1; `eth_tx_n_en` equals its equation on every clock; a **real 100 ns pulse at the pads 16.000 ms** after the engine goes idle | 6 failures |
| `tb_tt_um_protocol_emulator` | `uo_out[3]` mapping on every cycle (and `dbg_pc[1]` whenever port bit 7 is released); the pair decoded at the real pads | `uo_out[3]` not `eth_tx_n` |
| `tb_pe_soc_eth_loop` | with the SERDES on pin 7 and `tx_path` low, `eth_tx_n_en` stays low — **non-vacuous**: the case occurred for 119 clocks | — (new guard) |

- **Mutation:** `regress/mutate_eth_tx_tb.sh` **33/33 detected** (15 new
  line-driver mutants); `regress/mutate_eth_tx_loop_tb.sh` **13/13** (5 new
  pair mutants). Both harnesses ran under the global run lock.
- **Parameter guards:** 11/11 (3 new `pe_eth_tx` cases).
- **Lint:** Verilator `-Wall` plus yosys elaboration, clean.
- **Formal:** the six existing `pe_eth_tx`/`pe_soc` campaign targets re-run
  on the branch with outcomes identical to `formal/results/summary.txt`, and
  the formal mutant campaign is 14/14 caught. That needed one fix: my first
  edit realigned the line the `eth_tx_skip_gap` mutant anchors on, and the
  harness silently dropped it (a gate hole, reported to the manager).
  **No new formal property covers the line driver** (see *Follow-ups*).
- **Full regression** (`run_all.sh --fast -j8`, read gate by gate): all gates
  and all 16 mutation suites OK except two reds that are **pre-existing on
  `main`** — the KNOWN-WIP `tb_pe_soc_sr04` and an R3 package README drift.
  Its exit code (0) is not evidence: under `--fast` the script cannot exit
  non-zero (a harness bug found here; see the evidence record, §9).
- **Not run:** the physical flow, DRC and LVS (standing ruling), and no STA
  screen of the new `uo_out[3]` path yet.

## Decisions taken here (for the manager)

1. **Reclaim `uo_out[3]` (`dbg_pc[1]`) as `eth_tx_n`**; four debug pins
   remain (`dbg_pc[5:2]`).
2. **Idle both-high** (keeps `eth_tx` bit-identical).
3. **TP_IDL = 3 cells (300 ns)**, also after an abort and after either
   underrun.
4. **Link pulses in hardware**, 1 cell every 160,000 quiet-idle cells;
   pending start wins; a start during a pulse waits one cell.
5. **`tx_busy` unchanged** (pulses and post-abort TP_IDL run with it low).
6. **No `pe_soc` parameter**; the SoC TB runs the real 16 ms (about 18 s of
   simulation).

## Follow-ups (not done here)

- A **formal property** for the line driver: e.g. an inductive
  `line_drive == in_frame || tpidl_left != 0 || nlp_cell` under `enable`,
  and "a pulse starts only in quiet IDLE with no start pending".
- The `!enable` branch also clears `tpidl_left` and `nlp_cell`. Those two
  resets are defensive and behaviourally invisible, so no mutant can detect
  their removal; they are stated here rather than claimed as tested.
- **No auto-negotiation** (FLP bursts) and **no collision detection**: a
  partner parallel-detects 10 Mbit/s half duplex, and a collision on a
  half-duplex switch port is not seen by the chip.
- A `tb_pe_dru` case with **comparator duty-cycle skew** on RX.
- An **STA screen** of the `uo_out[3]` path.
- The pin-budget page's pinout is hand-kept data in
  `tools/gen/pin_budget.py`; nothing checks it against the wrapper (its
  `--check` stayed green while it was wrong until this change).
- Re-check the 802.3 numbers against Clause 14 itself.

## Sources

- Micro Linear ML4658 10BASE-T transceiver datasheet — link pulse
  85/100/200 ns every 8/16/24 ms, link loss 50/95/150 ms, squelch
  300/450/585 mV, 2.5 V peak output, idle outputs equal, pre-equalised
  two-step waveform: <https://www.cdiweb.com/datasheets/microlinear/ds4658.pdf>
- ctrl + src, "An overview of Ethernet 10BASE-T" — TP_IDL ≥ 250 ns positive
  (0.585–3.1 V), NLP ≥ 60 ns positive every 16 ± 8 ms, idle 0 V, Manchester
  convention: <https://ctrlsrc.io/posts/2023/niccle-ethernet-10base-t-overview/>
- UNH-IOL 10BASE-T MAU notes — TP_IDL begins positive:
  <https://www.iol.unh.edu/sites/default/files/knowledgebase/ethernet/10basetmau.pdf>

## Related

- [[plans/eth-tx-frame-path]] — the frame engine this extends.
- [[concepts/ethernet-scope]] — why 10BASE-T is the line layer only.
- [[concepts/physical-layer-gpio]] — what each protocol needs electrically.
- [[reference/protocol-pin-budget]] — the pinout arithmetic (regenerated).
- [[reference/signal-names]] — `line_drive`, `eth_tx_n`, `eth_tx_n_en`.
