# 10BASE-T TX frame path — implementation review (2026-09-25)

Plan: `wiki/plans/eth-tx-frame-path.md` · Tasks 1-7 complete · scope groups
G1-G8 adopted by the manager on 2026-09-24.

This is the plan's Task 7 Step 4 record: what landed, the RED evidence, the
GREEN evidence, the mutation tables, the mapped timing screen, the exact
hashes, and the limits. The task-level ledger is
`.superpowers/sdd/eth-tx-frame-path/progress.md`; the canonical status blocks
are the top of `HANDOFF.md` and `wiki/STATUS.md`.

## What landed

| Task | Scope | Landed as |
|---|---|---|
| 1 | `tb_pe_eth_tx` RED-first | new TB, 9 directed cases |
| 2 | `pe_eth_tx` engine | new RTL, 892 cells mapped |
| 3 | SoC window + owner mux + `tb_pe_soc_eth_tx` | 32-entry `0xF` window, `tx_path` mux, new TB, `eth_tx_arp.pe` (502 words) |
| 4 | wrapper `uo_out[2]` mux + pad decode | `uo_out[2] = pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0]`, `tb_tt_um_protocol_emulator` decode case |
| 5 | loopback consumer + IFG acceptance | `eth_arp_echo.pe` (546), `eth_tx_two.pe` (299), `eth_tx_wrap_probe.pe` (41), `eth_tx_busy_probe.pe` (225), new `tb_pe_soc_eth_loop` |
| 6 | two mutation suites | `mutate_eth_tx_tb.sh` 18/18, `mutate_eth_tx_loop_tb.sh` 7/7 |
| 7 | mapped STA + close-out | this record, `reviews/2026-09-25/eth-tx-sta/`, refreshed diagrams |

The engine's contract, in the words its own header uses: firmware pushes the
frame's stored bytes into an 8-byte staging FIFO and writes the length; the
block owns the 56+8 hardware prelude (a wire pattern, never `0xAA` through a
byte helper), octets LSB-first, zero pad to the 64-byte minimum folded into
the FCS, a TX-dedicated `pe_crc #(.W(32))` whose field mode drains the
register to zero, runt/jabber refusal, a 96-cell IFG, and an idle that drives
`tx_bit = half_phase` so the Manchester encoder emits a constant level.

## RED evidence (the tests were watched failing first)

- **Task 1**: the unit TB on the pre-engine tree fails to elaborate —
  `../rtl/pe_eth_tx.v: No such file or directory`, exit 1.
- **Task 3**: the SoC TB on the pre-change window aliases the upper-bank
  writes into CTRL (`CFG=ff`, divider 65535, engine never enabled) and reports
  734 FAIL lines before any RTL change.
- **Task 4**: the pad TB on the pre-mux wrapper reports 5,525 FAILs, led by
  `uo_out[2] is not the eth_tx pad while port bit 7 drives`
  (`/tmp/tb_tt_red.out`).
- **Task 5 / grid alignment**: the wire loopback caught the engine advancing
  on the codec's committing `cell_en` (one clock INTO each cell), which left
  the first clock of every first half showing the previous bit — the DRU
  could not frame the engine's Manchester from a constant idle. The fix moves
  the advance to a boundary `eth_cell_start` (high on the cell's LAST clock);
  each Manchester half is now exactly three clocks. The same bring-up found
  the SRAM's registered read holding a stale/X first fetch when `run` rose
  too soon after the loader's last write, which silently dropped the
  program's first instruction; both TBs now hold 4 stopped cycles.
- **Task 6**: two mutations SURVIVED the first version of the unit suite, and
  both were real gaps in the TB rather than bad mutations — see below.

## GREEN evidence

```
./regress/run_all.sh --fast -j8        exit 0
  RTL 33/33 · firmware 26/26 · lint clean · 12 generated gates
  12 mutation suites (10 existing + eth_tx + eth_tx loopback)
./regress/synth_area.sh                 exit 0
  pe_eth_tx   892 cells / 16,040.0898 um2
  pe_pinmux   127 cells /  2,191.1904 um2
  pe_soc    6,219 cells / 108,084.8286 um2
  tt_um_top 7,960 cells / 138,817.4004 um2
```

Explicit transcripts kept:
`/tmp/run_all_t6.log` (16m21s), `/tmp/mutate_eth_tx.log`,
`/tmp/mutate_eth_tx_loop.log`, `/tmp/synth_t7.log`,
`/tmp/mgr11_tb_loop.out` and `/tmp/mgr11_tb_tt_um.out` (the Task-11 close-out
re-runs of the loop TB and the pad TB).

The loop TB's own numbers (the acceptance the plan asked for):

- echo: RX consumer saw `len=46 field=0806 sum=07`; push gaps **max 52 clk**
  against the 48-clk wire-byte budget;
- two-frame: IFG **102** idle cells (spec >= 96), RX `valid=2 bad=0`;
- wrap: 9 pushes, `REG[24]=2a` `REG[26]=04`, `bad=0`;
- busy: `refused_start=1 TXSTAT=00 RX valid=1 bad=0`.

The pad TB decodes the frame at `uo_out[2]` itself: 576 wire bits, FCS
`9cc5cb34`.

## The push-loop timing limit, stated plainly

The 52-clk worst push gap EXCEEDS the 48-clk per-byte wire drain. The 8-byte
staging FIFO absorbs it, so the echoed frame decodes FCS-clean with no wire
underrun, and the plan's Task-5 Step-2 trigger ("revisit G1/G2 if <1.5x slack")
is met and recorded rather than quietly passed. A future persona-switching
scenario would need the documented `tx_load_pend`/`tx_stuffed` fences added to
`eth_start`; nothing does that today.

## Mutation tables

### Unit (`regress/mutate_eth_tx_tb.sh`, 18/18, 0 survivors)

| # | Mutation | Caught by |
|---|---|---|
| 1 | `preamble-short` — SFD lands a cell early | prelude decode |
| 2 | `preamble-long` — one cell past the SFD | prelude decode |
| 3 | `preamble-inverted` — alternation starts with 0 | prelude decode |
| 4 | `sfd-order-flipped` — SFD's last bit 0 | bit-level decode |
| 5 | `crc-not-cleared` — frame start doesn't clear the CRC | frame 2's FCS |
| 6 | `fcs-uncomplemented` — `cfg_out_inv = 0` | decoded FCS |
| 7 | `field-mode-short` — field cells don't shift | decoded FCS |
| 8 | `pad-not-folded` — pad excluded from the CRC | residue |
| 9 | `field-mode-long` — a pad cell folded in field mode | decoded FCS |
| 10 | `pad-extra` — a 60-byte frame gains a pad byte | wire length (**was a survivor**) |
| 11 | `pad-omitted` — no pad on a 42-byte frame | decoded length |
| 12 | `ifg-95` — gap one cell short | engine IFG count (**was a survivor**) |
| 13 | `jabber-accepted` | `tx_overlong` never pulses |
| 14 | `runt-accepted` | `tx_overlong` never pulses |
| 15 | `underrun-silent` | `tx_underrun` never pulses |
| 16 | `idle-square-wave` | mid-cell transition in the 200-cell idle |
| 17 | `octet-msb-first` | decoded bytes |
| 18 | `done-before-fcs` | done-before-last-bit check |

**The two survivors are the point of the suite.** `pad-extra` survived because
no case had exactly 60 stored bytes — the only length where `stored < 60` and
`stored <= 60` differ — and `ifg-95` survived because the two-frame check
measured the gap ON THE WIRE, which also contains the start-alignment cell, so
a 95-cell engine IFG still measured >= 96. Both were fixed in the TB (an
`exact-60-no-pad` case; an engine-side `ifg_active` cell count), not excused
in the harness.

### Integration (`regress/mutate_eth_tx_loop_tb.sh`, 7/7, 0 survivors)

| # | Mutation | File | Judged by |
|---|---|---|---|
| 1 | `owner-mux-stuck-serdes` | `pe_soc.v` | loop TB |
| 2 | `overlay-not-driven` | `pe_soc.v` | loop TB |
| 3 | `pad-not-mapped` | `tt_um_protocol_emulator.v` | pad TB (the loop TB does not elaborate the wrapper) |
| 4 | `cell-start-doubled` | `pe_soc.v` | loop TB |
| 5 | `rx-capture-disconnected` | `pe_soc.v` (the MAC's `.bit_en`) | loop TB |
| 6 | `fcs-verdict-wrong-convention` | `pe_eth_mac.v` (`crc_state == 0`) | loop TB |
| 7 | `push-wrap-into-ctrl` | `pe_soc.v` | loop TB |

An earlier draft of mutation 5 gated the RX **codec's** `bit_en` and
SURVIVED: that signal feeds the SERDES, not the MAC, so it leaves the frame
path untouched. The harness header records the correct target.

Both suites follow the house convention: the baseline must pass first, every
mutation must be detected, the sources are restored from a `cp` snapshot and
**`cmp`-verified after every mutation**, `EXIT`/`INT`/`TERM` traps restore,
and `git checkout` is never used (gotcha 63). Each run prints the path of its
pristine snapshot, which is the recovery path if a SIGKILL ever interrupts a
suite — the 2026-09-24 18:43 OOM left a mutant on disk precisely because the
restore step never ran, and that mutant (the I2C suite's `m1`, which rewrites
`pad_oe` to `reg_oe`) is what reddened the tree until it was restored
byte-exactly from the snapshot in Task 11.

## Mapped timing screen (`reviews/2026-09-25/eth-tx-sta/`)

16.667 ns (60 MHz), slow/typ/fast, both constraint variants, on `pe_soc` and
`tt_um_top` — 12 screens, runner exit 0. `pe_eth_tx.v` is in both source
lists, so the netlists contain the frame FSM, the staging FIFO, the
TX-dedicated `pe_crc` and the window bank.

| design | corner | setup (zero) | hold (zero) | hold (board) |
|---|---|---|---|---|
| `pe_soc` | slow | 0.00 | −0.87 | −0.55 |
| `pe_soc` | typ | 0.00 | −0.61 | −0.42 |
| `pe_soc` | fast | 0.00 | −0.48 | −0.37 |
| `tt_um_top` | slow | 0.00 | −0.71 | −0.56 |
| `tt_um_top` | typ | 0.00 | −0.52 | −0.43 |
| `tt_um_top` | fast | 0.00 | −0.43 | −0.37 |

(The 0.00 setup summaries are the recorded pre-CTS latch time-borrow paths,
not a claim of zero margin.)

**No new violation class.** The negative-min inventory has the same four
classes as the 2026-09-24 pre-TX control, with the same worst endpoints (SRAM
`A_DIN`/`A_ADDR` pins, `rst_n` removal, `dbg_pc`, `uio_out[6]`). Two honest
deltas: the pre-CTS internal family deepened 16 ps (−0.5353 → −0.5519) as the
netlist grew, and the `rst_n`-removal path count rose with the flop count
(643 → 948) at an unchanged worst of −0.0490. Under the BOARD assumption every
external class again drops to zero paths, exactly as in Task 5b.

The class that leaves the chip — the G6 pad — is measured directly
(`probe-eth-tx-tt_um-slow.txt`): worst setup into `uo_out[2]` **+7.6330 ns**
and worst hold **+0.2964 ns**, both MET at the slow corner. A harness limit
is recorded honestly: this OpenSTA build hashes internal net names, so
`-through *u_eth_tx*state*`-style probes return nothing, and the FSM, FIFO and
CRC classes are covered by the aggregate inventory rather than individually.
Two reader workarounds are documented in `run_sta.sh`: the screen copy strips
`signed` from wire declarations (pe_ctrl's function locals, which the 3.1.0
reader rejects) and the probe runs on a non-flattened netlist.

Mapped pre-layout screens only: **no physical flow, DRC or LVS**.

## Diagrams

Both maps were refreshed to this state and re-rendered with their colocated
PNG/SVG sidecars: `project-plan` 3385×2706 (1.25:1) and `project-progress`
3947×2477 (1.59:1), both inside the Task-5a targets, with zero packages,
components or notes lost (`review: reviews/2026-09-24/DIAGRAM-SQUARER-LAYOUT.md`
for the method). The progress map shows the frame path and the loopback
acceptance GREEN and the mutation suites + STA/close-out RED, so the open work
is visible, not overstated.

## Hashes (sha256)

```
rtl/pe_eth_tx.v                      75a02108950546214bf23edf4cf8097efb7649ace778462666165d59592c73be
rtl/pe_soc.v                         5791b757a9051a94ef0ff07969f786e6b6c7a4b8d48dd240de17944c77d070a9
rtl/pe_pinmux.v                      c1fa0cec1cdc2ad04c6b9e97bc8ad4e6fdb0893e3fbda8256121ce7312949aef
rtl/tt_um_protocol_emulator.v        9cb4290125712fda2275559fc34063483ed04b215470259eed9fc4533a468f9a
tb/tb_pe_eth_tx.v                    d0540aa34daba1bc5837476dfd6fddd1418743da91e5e2ccaef43b34a1ffc4f0
tb/tb_pe_soc_eth_loop.v              f164890d3c209a033d154dda5090e37db50fcb5dd3efdfe57e1a62feac298f56
tb/tb_tt_um_protocol_emulator.v      7a53658e62a8ee5029b8dfd211bdcf06185f7a018e0249fbc3a7a98f1de031c1
regress/mutate_eth_tx_tb.sh          8211f2711420c05e9ba64f9466ee837ad045c4097b555cedc7ca7e34d7259b3a
regress/mutate_eth_tx_loop_tb.sh     31263dcb4c6c2f1f8afa90a78b5d8e2cdeb0e9d21fed1c10c0f6705f9138e1b1
regress/run_all.sh                   8266d8d679ede96be092c724efbeb41f4841af753fc833ee1284218a99275c67
reviews/2026-09-25/eth-tx-sta/synth-pe_soc.ys   516ad1404a1264cb8a8b5974f23d328cb42acd2898c5a9ed511a23b31b7a6ba8
reviews/2026-09-25/eth-tx-sta/probe-eth-tx.tcl  195b7d61f450e05bb4225d48ed2d3de7d59d7d852ebeec47f640030010197747
```

## Limits

- Simulation and mapped pre-layout screens only. No placement, routing, DRC or
  LVS; the numbers are screening evidence, not signoff.
- The push loop's worst gap (52 clk) exceeds the 48-clk wire-byte period; the
  FIFO absorbs it and no firmware does persona switching today, but the
  documented `tx_load_pend`/`tx_stuffed` fences are NOT implemented on
  `eth_start`.
- The STA screen's FSM/FIFO/CRC classes are covered in aggregate, not
  individually, because this OpenSTA build cannot address hashed net names.
- The R2 read path (bounded IMEM/DMEM reads, `READ_CPU`, `DUMP_CORE`) is a
  separate phase and is not part of this plan.
- The R1 host protocol's open P3 liveness gap (no heartbeat pad until R2) is
  unchanged by this work.
