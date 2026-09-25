# Project Status — through 10BASE-T receive

> **PE host bus R2 — read ops landed; conformance pending the model image
> (2026-09-25).** The framed host protocol's read path is in: `READ_CPU` (0x12,
> the only non-halting read — answers while `run=1`, with the registers at
> their NATIVE widths, so `dbg_pc` is no longer truncated to 8 bits), bounded
> `READ_IMEM`/`READ_DMEM` (0x13/0x14; dmem packs two bytes per response word,
> high byte first), and `DUMP_CORE` (0x15, the STATUS header while stopped,
> NOT_READY while running). `STATUS` is now 11 payload words — `status, state,
> run, target, pc, a, x, y, timer, faults, words_written` — because R2 stopped
> stubbing the cpu-derived fields. **The wait-word contract:** a bounded read
> cannot answer in the request's bit times, so the chip DRIVES `0xFFFF` filler
> words while it fetches and the real frame starts at the first non-`0xFFFF`
> word; a host skips leading fillers and validates exactly as in R1. Worst
> case 15 filler words (a 15-word read is one round trip each). This is
> transport-level only — the response bytes are unchanged and an R1 host sees
> zero wait words. An out-of-range READ latches sticky `FAULT_RANGE` (0x4),
> cleared by `CLEAR_FAULT`, and is never a wrapped read. Regression: **33/33
> RTL, 26/26 firmware, lint clean, 12 mutation suites, exit 0**; the two eth_tx
> suites (18/18, 7/7) and `mutate_ctrl_tb` (29/29) still catch every mutation.
> **Open:** the golden-vector conformance TB (`tb_pe_ctrl_r2.v`) proves the
> FRAMING byte-exact against the host's own bytes, but the package must first
> ship the model image its vectors assume — until then the data-path vectors
> are unproven and no `chip_confirmed` flag has been flipped. The TB is
> deliberately not in the regression so it cannot make a false red about the
> chip. Mapped 16.667 ns screen of the R2 read path
> (`reviews/2026-09-25/r2-sta/`, 12 screens): **no new violation class** —
> `pe_soc` unchanged (hold -0.87/-0.61/-0.48) and `tt_um_top` hold IMPROVED
> (-0.59/-0.45/-0.38, zero == board), the new classes appearing only in the
> pre-existing external-output class. Contract in `rtl/pe_ctrl.v`'s header.
> **The host branch is MERGED and PUSHED** (1cbc0bc).

> **10BASE-T TX frame path — COMPLETE, plan Tasks 1-7 (2026-09-25, manager
> Task 11 close-out + the chained Task 6/7 pass).** The last unbuilt block in
> the topology is now built and hardened. `rtl/pe_eth_tx.v` emits a full frame
> from firmware pushes (hardware 56+8 prelude, octets LSB-first, zero pad to 64
> folded into the FCS, TX-dedicated `pe_crc`, 8-byte staging FIFO with
> underrun, runt/jabber refusal, 96-cell IFG, constant idle); `pe_soc` gained
> the 32-entry `0xF` window (push/wrap 16-23, TXLEN 24/25, TXCTRL 26, TXSTAT
> 27) and the exclusive `tx_path` owner mux; the wrapper reclaims **`uo_out[2]`
> = `eth_tx`** behind `pin_oe_bus[7]` (G6). Wire-loopback acceptance PASS —
> echo `len=46 field=0806 sum=07`, two-frame IFG 102 cells, wrap `REG[24]=2a`
> `REG[26]=04`, busy `refused_start=1`; the pad decodes 576 wire bits, FCS
> `9cc5cb34`. **Two mutation suites: 18/18 unit + 7/7 integration, 0
> survivors** — and they found two real TB gaps (a 60-byte pad-boundary case
> and an engine-side IFG count), both fixed in the TB. Mapped 16.667 ns STA
> screen (`reviews/2026-09-25/eth-tx-sta/`, 2 designs x 3 corners x
> ZERO/BOARD): **no new violation class**; the G6 pad MET at +7.6330 ns setup
> / +0.2964 ns hold (slow). `./regress/run_all.sh --fast -j8` **exit 0 — RTL
> 33/33, firmware 26/26, lint clean, 12 gates, 12 mutation suites**;
> `./regress/synth_area.sh` **exit 0** — `pe_eth_tx` 892 / 16,040.0898 µm²,
> `pe_soc` **6,219 / 108,084.8286**, `tt_um_top` **7,960 / 138,817.4004**.
> Both diagrams refreshed (plan 3385x2706, progress 3947x2477, targets held,
> zero components lost). **Limits:** mapped/simulation only — no physical flow,
> DRC or LVS; the push loop's worst gap (52 clk) exceeds the 48-clk wire-byte
> period and is absorbed by the staging FIFO; per-class STA probes are limited
> by this OpenSTA build's hashed net names; the R2 read path is a separate
> phase. Review + hashes + mutation tables:
> `reviews/2026-09-25/ETH-TX-FRAME-PATH-REVIEW.md`.

> **10BASE-T TX frame path — plan Tasks 4-5 LANDED and verified (2026-09-24/25,
> Manager Task 11; supersedes the Task-10 hash block below for `pe_eth_tx.v`,
> `pe_soc.v`, `run_all.sh` and `run_firmware_tests.sh`).** The wrapper reclaim
> landed: `uo_out[2] = pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0]`, with
> `uo_out[7:3] = dbg_pc[5:1]`; RED-first (the pre-mux pad TB reports 5,525
> FAILs, `uo_out[2] is not the eth_tx pad while port bit 7 drives`), then it
> decodes the frame at the pad — `eth_tx pad: decoded 576 wire bits, FCS
> 9cc5cb34`. `info.yaml` and the regenerated pin-budget page carry the new
> function (`pin_budget.py` `pinned_out` 3 -> 4; still **19 of 24** committed).
> The loopback consumer landed: NEW `tb/tb_pe_soc_eth_loop.v` + four firmwares
> (`eth_arp_echo` 546 words, `eth_tx_two` 299, `eth_tx_wrap_probe` 41,
> `eth_tx_busy_probe` 225; hex committed; firmware 26/26). Its kept transcript:
> `echo: len=46 field=0806 sum=07`, push gaps **max 52 clk vs the 48-clk
> wire-byte budget** (the 8-byte staging FIFO absorbs it — the echoed frame
> decodes FCS-clean — but the plan's Task-5 Step-2 revisit trigger is recorded,
> not silently passed); two-frame IFG **102** idle cells (>= 96 spec), RX
> valid=2 bad=0; wrap 9 pushes, `REG[24]=2a` `REG[26]=04`, bad=0; busy
> `refused_start=1` TXSTAT `00`, RX valid=1 bad=0. Two real defects the
> loopback caught and fixed: the engine's advance moved from the codec's
> committing `cell_en` to a boundary `eth_cell_start` (high on the cell's LAST
> clock — the old point left the first clock of every first half showing the
> previous bit, so the DRU could not frame the engine from constant idle; each
> Manchester half is now exactly three clocks), and both loop/Task-3 TBs hold
> 4 stopped clocks after the loader's last write before `run` rises (the SRAM's
> registered read held a stale/X first fetch and silently dropped the
> program's first instruction). Directed sensitivity proved the new checks
> non-vacuous: the push-wrap mutation fails 3 checks, removing
> `!ser_tx_busy` fails `refused_start`; both restored `cmp`-byte-identical.
> Close-out root-caused the red tree: it was an **unrestored
> `regress/mutate_i2c_tb.sh` mutation m1** (`pad_oe = reg_oe`, the open-drain
> gate lost, failing tb_pe_pinmux/tb_pe_soc_i2c/tb_pe_soc_i2c_xfer), not a
> hand edit — the kernel OOM at 2026-09-24 18:43:28 (runaway python3, 22 GB
> anon + 5 GB swap) killed the wezterm unit mid-suite before the harness's
> `cmp`-verified restore and its signal traps could run (SIGKILL is
> untrappable). Restored canonically by `cp` from the harness's pristine
> snapshot and `cmp`-verified against both surviving copies (sha256
> `c1fa0cec...`); `firmware/i2c_pins.pe`/`.hex` were already
> pristine-identical. The RAM watchdog `tools/manager/mem_monitor.sh` ran
> from 01:43 with no trigger (`/tmp/pi-mem-interrupt` never appeared). `pe_soc.v` keeps the one-process
> set-beats-clear `tick_flag` (the two-driver / yosys-constant-0 class;
> clean elaboration, `tb_pe_soc_tick` PASS). `./regress/run_all.sh --fast -j8`
> **exit 0 — RTL 33/33, firmware 26/26, lint clean, 12 gates, 10 mutation
> suites**; `./regress/synth_area.sh` **exit 0**: `pe_eth_tx` 892 /
> 16,040.0898 µm² (unchanged), `pe_pinmux` 127 / 2,191.1904, `pe_soc`
> **6,219 / 108,084.8286**, `tt_um_top` **7,960 / 138,817.4004**. Explicit
> re-runs kept: `tb_pe_soc_eth_loop` and `tb_tt_um_protocol_emulator` PASS
> (`/tmp/mgr11_tb_loop.out`, `/tmp/mgr11_tb_tt_um.out`). Hashes:
> `rtl/pe_pinmux.v`
> `c1fa0cec1cdc2ad04c6b9e97bc8ad4e6fdb0893e3fbda8256121ce7312949aef`;
> `rtl/pe_eth_tx.v`
> `75a02108950546214bf23edf4cf8097efb7649ace778462666165d59592c73be`;
> `rtl/pe_soc.v`
> `5791b757a9051a94ef0ff07969f786e6b6c7a4b8d48dd240de17944c77d070a9`;
> `rtl/tt_um_protocol_emulator.v`
> `9cb4290125712fda2275559fc34063483ed04b215470259eed9fc4533a468f9a`;
> `tb/tb_pe_eth_tx.v`
> `3ccc1ea88dfc4e12a6f6b617fec512cfd4e401170a1412175141051d524698ba`;
> `tb/tb_pe_soc_eth_tx.v`
> `8cf8158b5ef6f11419bf1dd20bd0178ec7c5571b794cae9f847797e3dd8f7dcc`;
> `tb/tb_pe_soc_eth_loop.v`
> `f164890d3c209a033d154dda5090e37db50fcb5dd3efdfe57e1a62feac298f56`;
> `tb/tb_tt_um_protocol_emulator.v`
> `7a53658e62a8ee5029b8dfd211bdcf06185f7a018e0249fbc3a7a98f1de031c1`;
> `regress/run_all.sh`
> `87cfca6d6ca49126c0432f000810371e8a9452834679f6015093c0e71e7cc2ee`;
> `regress/run_firmware_tests.sh`
> `1566da4f6269ed325d30cc4b3f33ad20814777550a139beef51cc591d5b8751a`;
> `info.yaml`
> `e5b20cc8a886d3c67cf010e66561f766cd76755946fbb6255510b8deebbc1ab1`;
> `tools/gen/pin_budget.py`
> `260f41dfcc2f8dd028f0ea1a64d3857d1a5033460f992b325a43ffcfb3acd9a1`;
> `wiki/reference/protocol-pin-budget.md`
> `b217e225176045db151762513738173dc5ae388d05e423c9d66c8bb4a6f10874`;
> `wiki/reference/signal-names.md`
> `83d8cee32d31790dc9592f54fb05dcebd4e230e16ff6c2d578413a8efbd93c81`;
> new firmwares: `firmware/eth_arp_echo.pe`
> `9ec6d39c55d9b3fb06e914095891d7f40c7b7d82228bfcd26bcca23f5b0cec84` /
> `.hex` `a4786fa5954ed8c3961c834390842b9af9cb180eb271cc4fa2aa841d0d246679`;
> `firmware/eth_tx_two.pe`
> `451cddba1b3dd239dab9ffad26c144336db436de361e7c526fcffe98562b7039` /
> `.hex` `0bf5f4c37a341f57bdf1d6b1c855355568a8efd2ed1a562e65ee2710700f1ae7`;
> `firmware/eth_tx_wrap_probe.pe`
> `65704420cbec4c6c4fdf60aa3e80e58bf4b9c4fb9617647da440e01045902da7` /
> `.hex` `ffd0c782889e97111cdc24ab1befaae563a9693ba12cf69dc1f5971f5ff392e0`;
> `firmware/eth_tx_busy_probe.pe`
> `8ce7c4c041f00345093167f723b4fedc6577142e2f1f02b81c398e1d64e0b10b` /
> `.hex` `ad4bbc14ebc18a15a9a5a64ff40ddbbe27d14bb0d240eff1243490f7894eea33`.
> Unchanged from the Task-10 block: `firmware/eth_tx_arp.pe`/`.hex`,
> `flow/pe_soc.json`, `tools/checks/macro_flow_config.py`,
> `regress/synth_area.sh`, `regress/lint.sh`. **Limits:** no `eth_tx`
> mutation suites yet (plan Task 6); no STA screen yet (plan Task 7).
> Mapped/simulation evidence only — no physical flow, DRC or LVS.

> **10BASE-T TX frame path — plan Tasks 1-3 LANDED (2026-09-24, Manager
> Task 10).** The manager adopted G1-G8 as written; G6's `uo_out[2]` reclaim
> stands under the R1 pad map and the free-`uio` alternative is void, but the
> wrapper mux is plan Task 4, so `rtl/tt_um_protocol_emulator.v` is untouched
> here. NEW `rtl/pe_eth_tx.v` (892 cells / 16,040.09 µm² mapped) emits a full
> frame from firmware-supplied stored bytes: hardware 56+8 prelude (wire
> pattern, not 0xAA through a byte helper), octets LSB-first, zero pad to the
> 64-byte minimum (pad IS folded into the FCS), a TX-DEDICATED `pe_crc #32`
> (generated constants `0xEDB88320`/`FFFFFFFF`/out-inv; the field-mode register
> drains to zero — checked), an 8-byte staging FIFO with underrun fault, runt
> (<14)/jabber (>1,514) refusal, and a 96-cell IFG; idle is `tx_bit =
> half_phase` (constant wire, not a square wave). `pe_soc` gained the
> 32-entry 0xF window (5-bit index: 16-23 push-and-wrap, 24/25 TXLEN, 26
> TXCTRL, 27 TXSTAT set-beats-clear), the exclusive owner mux on
> `u_tx_codec.tx_bit` (`eth_start` gated on `!ser_tx_busy`; `tx_path` clear
> refused while `tx_busy`), and DIV=6. `firmware/eth_tx_arp.pe` (502 words) is
> the first consumer. Directed RED evidence: the unit TB fails to compile with
> no engine; the SoC TB on the pre-change window aliases upper-bank writes
> (`CFG=ff`, engine never enabled, 734 FAILs). The TBs caught two integration
> bugs (TXCTRL is a level register — frame_start must write bit2=1; claim
> `tx_path` before `eng_en` or the idling SERDES drives a Manchester square
> wave). Evidence: `tb_pe_eth_tx` PASS (ARP-42 → 60 stored bytes / 576 wire
> bits / FCS `9cc5cb34`; exact-64; max-1,514 / 12,208 bits; IFG 100 cells;
> refused 1,515/13; abort; underrun; 200-cell constant idle); `tb_pe_soc_eth_tx`
> PASS (576 wire bits, same FCS); `./regress/run_all.sh --fast -j8` **exit 0 —
> RTL 32/32 (the 30 existing intact), firmware 22/22 (the 21 existing + the new
> assemble), lint clean, every gate, ten mutation suites**;
> `./regress/synth_area.sh` exit 0: `pe_soc` 4,961 → **6,191** cells /
> 82,893.77 → **107,939.64 µm²**, `tt_um_top` 6,633 → **7,980** / 113,254.89 →
> **138,746.71 µm²**. Same-list updates in all eight `pe_soc`-elaborating
> harnesses + flow/info/macro-gate/lint; `signal-names.md` regenerated
> (16 modules / 205 ports). Limits: no STA screen yet (Task 7), no pad-level
> `uo_out[2]`/RX loopback (Tasks 4-5), no eth_tx mutation suites (Task 6). No
> physical flow, DRC or LVS.

> **R1 framed host bus reconciled and verified (2026-09-24, Tasks 8/9).** The
> chip-side host protocol that landed at 14:33 (unrecorded before the OOM) is
> now attributed to the host-controller plan
> (`/tmp/opencode/host-controller-gui/wiki/plans/host-controller-gui.md`) and
> its review (`reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md`), audited
> against the R0/R1 rulings, and verified. `rtl/pe_ctrl.v` speaks a framed
> mode-0 SPI contract: `A55A` sync, `{version,opcode,target}`, sequence,
> length, payload, CRC-16/CCITT-FALSE (`0x1021`/`FFFF`, RevEng check `0x29B1`);
> responses set opcode bit 7 and echo sequence/target; the first response word
> is the status (`0 OK … 6 NOT_READY`); R1 opcodes PING/LOAD/STATUS/
> CLEAR_FAULT/TARGET plus a target-1 internal loopback; `IRQ_N` (`uo_out[1]`)
> is `~|faults` and mask-cleared by CLEAR_FAULT. A1 is superseded per the R0
> ruling: `uio[4]` is host `CS_N`, and the commit-latched echo/abort semantics
> live in the framed LOAD response (no trailing frames). Pads: `uio[4:7]` =
> CS_N/MOSI/MISO/SCK, `uo_out[1]` = IRQ_N, `ui_in[3:5]` freed
> (**19 of 24** committed, 5 free `ui_in`, 0 free `uio`). Fixes: old-style CRC
> functions (yosys parse), fixed-slot response mux (Verilator WIDTHTRUNC),
> `synth_area.sh` fails loudly on yosys ERROR, P21 CS-to-first-clock sweep
> added (40/60/150/400 ns, PASS). Evidence: `lint.sh` exit 0 (15 verilator +
> 12 yosys); `run_all.sh --fast -j8` exit 0 (30/30 RTL, 21/21 firmware, ten
> suites); `mutate_ctrl_tb.sh` **29 detected / 0 survived / 0 harness errors**;
> `synth_area.sh` exit 0 — `pe_ctrl` **1,731 cells / 30,662.11 µm²**,
> `tt_um_top` **6,633 / 113,254.89 µm²**; seven generator checks OK. Hashes
> and the full contract: `HANDOFF.md` top block. **FINDING (a) — P3
> liveness gap: CLOSED on the chip side by R2 (2026-09-25).** The heartbeat
> pad is gone (`uo_out[1]` is IRQ_N) and the R1 STATUS layout deliberately
> omitted timer/PC/A/X/Y, so nothing showed liveness until the R2 read path.
> R2 supplies both halves: `STATUS` is now 11 words including `pc`, `a`, `x`,
> `y` and `timer` at their native widths, and `READ_CPU` is the ONE
> non-halting read, so a host can observe a RUNNING program rather than only a
> stopped one. What remains is host-side: surfacing it in the GUI, which is the
> separate host-controller branch's queue, not the chip's.
> **(b) P21 sweep closed** by the new directed case.

> **Diagram squarer layout + hold-screen attribution (2026-09-24, Tasks 5a/5b).**
> **5a — both maps re-laid out:** `project-plan.puml` 4180×2520 (1.6587) →
> **3194×2476 (1.29:1)** and `project-progress.puml` 6195×1354 (4.58:1) →
> **3681×2493 (1.48:1)** (the progress map had sprawled during the Task-3
> refresh); plan notes compacted into one block below the architecture,
> progress direction `left to right` → `top to bottom` (vertical status
> lanes), plus only the sanctioned status-label edits (A1 landed, engine
> integrated, E2-6 + R3 closed/green, mapped-STA-refresh and 13/13-codec
> notes); zero packages/components/edges/notes lost.
> **5b — hold attribution + both STA variants:** all **18 mapped screens**
> (3 designs × 3 corners × 2 variants) now carry a full negative-min-slack
> inventory; `VARIANT: ZERO-ASSUMPTION` reproduces the recorded screens and
> `VARIANT: BOARD-ASSUMPTION` differs only in `-min` input/output delay
> 0.0 → **1.0 ns** (a labelled screening floor, not a measured board flight
> time). Under the board assumption every external-input/removal/output
> negative drops to 0 paths in all nine screens; remaining negatives are
> internal pre-CTS or inside the 0.25 ns uncertainty; **worst setup is
> unchanged in every pair**; board worst hold `pe_soc` −0.54/−0.41/−0.36,
> `tt_um_top` −0.64/−0.48/−0.40, `pe_ctrl` **+0.04**/−0.07/−0.13 (slow/typ/
> fast; `pe_ctrl` hold-clean at slow). Read-only input-registration audit:
> SPI inputs already 2FF-synchronized; `rst_n`/`run`/`host_*`/plain `pin_in`
> are unregistered (constraint-only today; RTL register stages recorded as
> options). No RTL changed; mapped pre-CTS screens only — no physical flow,
> DRC or LVS. Evidence:
> `reviews/2026-09-24/DIAGRAM-SQUARER-LAYOUT.md`,
> `reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md`.

> **Closeout hardening (2026-09-24, Task 4): mapped STA refresh + codec
> mutation suite.** (a) The SERDES integration's new timing classes were
> screened at 16.667 ns on both `pe_soc` and `tt_um_protocol_emulator`
> (slow/typ/fast; slow is a hold corner) with the recorded scripts' source
> lists extended by `pe_serdes/pe_nrzi/pe_bitstuff/pe_codec_mux`. `pe_soc`
> (setup 0.00 ns, hold −0.87/−0.61/−0.48 ns) is **identical to the
> pre-integration screen at every corner**; `tt_um_top` is setup 0.00 ns,
> hold −0.71/−0.52/−0.43 ns. **No new violation class**: overlay→pad,
> `half_phase`, the window read mux and the split enables all have positive
> slack at slow (worst overlay→pad setup +7.96 ns); fast-corner negative
> holds are shallower members of the pre-existing pre-layout family, and the
> pad hold violation pre-existed (−0.1026 → −0.0308 ns at fast). Reports and
> scripts: `reviews/2026-09-24/serdes-sta/`. (b) NEW
> `regress/mutate_codec_tb.sh`: 13 mutations over
> `pe_codec_mux`/`pe_bitstuff`/`pe_nrzi`/`pe_manch` covering the documented
> CAN preset `0x51`, `ones_only`/run length, the registered `clr`/`rx_err`
> contract and the frame-boundary `clr` — **13 detected / 0 survived**,
> `cmp`-verified restore; the unit TB gained three directed checks first.
> (c) `./regress/run_all.sh --fast -j8` exit 0 (30/30 RTL, 21/21 firmware,
> lint clean, every gate, **ten mutation suites**); `./regress/synth_area.sh`
> clean at the baseline (`pe_soc` 4,961 / 82,893.7746 µm², `tt_um_top` 5,363
> / 91,268.0622 µm²). Full record:
> `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`. Mapped screens only — no
> physical flow, DRC or LVS.
>
> **Word engine integrated (2026-09-24): `pe_serdes` + TWO `pe_codec_mux`
> instances are in `pe_soc`** (STATUS item 7, amended plan + the follow-up
> review's recommended defaults for every scope group: additive engine,
> self-timed wire-loopback first consumer, plain RX without phase acquisition,
> `0xF` indexed window access). Split payload-only enables
> (`tx_bit_en = tx_cell_en && !tx_stuffed`, `rx_bit_en = rx_cell_en &&
> rx_bit_valid`), `half_phase` as a LEVEL (2 toggles per cell), the pad
> overlay before `pe_pinmux`'s open-drain gate, a 16-entry latched-phase
> window on port `0xF` with separate TXLEN/RXLEN, one-cycle
> `tx_load`/`rx_start`/`clr` strobes and latched status events for polling;
> the divider free-runs while enabled so a trailing stuff cell still emits
> after `tx_done`. Reset default is engine-disabled/overlay-off, so every
> baseline TB and firmware image is bit-identical (30/30 + 21/21 on the same
> run). First consumer: `firmware/serdes_loop.pe` + `tb_pe_soc_serdes`, four
> configs including the **directed stuffed Manchester loopback** (word 0x07E0,
> trailing-stuff case by construction); `regress/mutate_soc_serdes_tb.sh`
> detects the plan's four required mutations (TX-hold removed, RX-skip
> removed, doubled cell enable, strobe cross-wire) plus three alignment/load
> defects (7/7), and the new `regress/mutate_serdes_tb.sh` guards the split
> enables (7/7). Two bring-up defects the tests caught and fixed: half_phase
> toggled once per cell instead of twice, and Manchester `rx_start` needed the
> first-DRU-decode anchor (a stale idle decode was captured as payload bit 0).
> `./regress/run_all.sh --fast -j8` exit 0 with **all nine mutation suites**;
> `./regress/synth_area.sh` clean: pe_soc 3,571 → **4,961** cells /
> 56,816.88 → **82,893.77** µm² (+1,390), tt_um_top 4,038 → **5,363** /
> 65,686.27 → **91,268.06** µm² (+1,325) against the post-A1 baseline. No STA
> refresh yet (manager-scheduled); no physical flow, DRC or LVS. Evidence:
> `reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md`.
>
> **Readback landed (2026-09-24): option A1 in `pe_ctrl`.** The loader is no
> longer write-only: `uio[4]` carries a **commit-latched word echo**, strict
> mode 0, one frame late (frame 0 = `0x0000`, frame k = the word committed at
> frame k-1, one trailing frame in the same CS-low session). The echo updates
> only where `words_written` increments, so an aborted word can never echo,
> and the serializer is not gated by `load_error` — the final word of a full
> 1,024-word image still echoes through the receive lockout (manager ruling).
> Host contract is numeric: **every** echoed frame ≤ **2.5 MHz**, SCLK low
> phase ≥ **100 ns (6 clk)**, `CS_N` → first rise ≥ **100 ns** (computed A1
> limits ~7.5 MHz; the figures are guards). Budget: committed pads **18 → 19**,
> free `uio` **4 → 3**, all-nine shortfall **9 → 10** kept / **3 → 4**
> reclaimed. `tb_pe_ctrl` (cases 8–12) and pad-level
> `tb_tt_um_protocol_emulator` (full 1,024-word image) pass;
> `regress/mutate_ctrl_tb.sh` is **23/23** (was 11/11);
> `./regress/run_all.sh --fast -j8` green; `./regress/synth_area.sh` clean
> (`pe_ctrl` 463 cells / 8,661.30 µm², `tt_um_top` 4,038 / 65,686.27 µm²,
> `pe_soc` unchanged). Mapped STA refresh landed 2026-09-24 (zero-assumption
> `pe_ctrl` screen: setup +8.71/+8.80/+8.86 ns, hold −0.12/−0.16/−0.19 ns;
> its negatives are external-input/removal/output artifacts and the Task-5b
> BOARD variant makes `pe_ctrl` hold-clean at slow, +0.04 ns); no physical
> flow, DRC or LVS. Review: `reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md`;
> contract in `rtl/pe_ctrl.v`'s header and [[plans/pe-ctrl-readback]].
> Item 4's dbg-pin revisit trigger now fires; the item-4 decision itself is
> unchanged.

> **Latest MAC ownership fix (2026-09-23):** the independent E1 accounting
> audit found that a consume could release in-flight, unpublished bytes and
> then receive a second credit during frame rollback or TYPE FCS windback.
> `published_used` now limits consumer releases to committed frames. New tests
> first failed on the old RTL; the MAC mutation gate is 30/30 (0 survivors, 0
> harness errors), including publication collision accounting, TYPE FCS
> exclusion, preservation of older committed bytes on bad rollback and `S_ERR`,
> and a producer-pointer rebase mutant. Fresh
> `./regress/run_all.sh --fast -j8` passes: 29/29 RTL,
> 20/20 firmware, lint/elaboration, generated gates and all seven mutation
> suites. A fresh exact-source mapped Yosys/OpenSTA screen reports 0 synthesis
> problems, setup 0.00 ns at all corners, and worst hold slack −0.8692/−0.6065/
> −0.4778 ns (slow/typ/fast). Slow is a hold-check corner too. The 0.00 ns slow
> setup summary is a latch time-borrow path; worst slow register-to-register
> setup is +2.2274 ns. Current mapped counts: `pe_eth_mac` 1,681 cells /
> 23,749.63 µm², `pe_soc` 3,571 / 56,816.88 µm², `tt_um_top` 3,888 /
> 62,745.43 µm². Review evidence:
> `reviews/2026-09-23/E1-PUBLISHED-OWNERSHIP-REVIEW.md`; fresh logs are in
> `reviews/2026-09-23/e1-published-ownership/`. These are manual mapped screens,
> not signoff. No physical flow, DRC or LVS.
>
> Earlier E1 wrapped-release/collision issues, the E2-1..E2-5 macro-gate
> issues, and the later E2-6 / R3 checker false passes all have fixes in
> place; E2-6 and R3 are recorded as **fixed-pending-manager-verification**
> (26-check macro harness). E1-3 (full-ring release indistinguishable from
> duplicate) remains documented. The macro gate validates every
> pin-to-net mapping, the macro grid's Metal4 stripe plus its ordered
> Metal4-to-vertical and vertical-to-horizontal connects, and every macro view
> (nonempty gds/lef/lib, every ./src path resolving in the PDK sg13g2_sram
> tree, lib coverage of the flow's PVT corners, and each type's own LEF SIZE
> driving its placements' bounds/gap); a 20-check negative harness (including a
> synthetic two-type flow) is wired into the regression. A missing PDK LEF is
> an explicit SKIP (exit 2 only when there are no findings), while findings
> (view included) and yosys failures still fail. E2-1..E2-5 remain closed;
> **E2-6 (type↔LEF identity false pass) and R3 (corner-key vs file identity)
> are fixed — fixed-pending-manager-verification, not yet closed** (the
> mutation harness is now 26 checks; see
> `reviews/2026-09-23/PROJECT-REVIEW.md`, "E2-6 resolution").
> Details:
> `reviews/2026-09-23/E1-E2-FOLLOWUP-REVIEW.md`; original fixes and regression
> evidence in `ETHERNET-SOC-REVIEW.md`, `E1-RESOLUTION.md` and
> `E2-RESOLUTION.md`. Physical flow, DRC and LVS remain deferred.

<!-- BEGIN gui-worker host block (top note) - keep whole; place BESIDE the
     chip-side top-of-file blockquotes when merging, do not interleave -->
> **Host controller GUI + Pico bridge (2026-09-25; host side only).** The
> operator tooling lives on branch `host-controller-gui` and touches no
> chip-side file: `tools/host_gui/` (image/frame contracts, serial transport,
> session state machine, local page, fake PE model) and `tools/host_bridge/`
> (MicroPython frame codec, TT SDK adapter, newline-JSON USB endpoint, scripted
> acceptance runner). Host evidence: 176/176 host-GUI tests, 67/67 bridge tests
> (including the real host stack driven over the real bridge through fakes),
> ruff/compileall clean, and `acceptance.py --fake` at 22 PASS / 0 FAIL /
> 1 SKIP. **Nothing here is chip-confirmed yet**: the PE host protocol, read
> path and IRQ are RTL phases R1/R2 (plan Tasks 3-5, under the chip-side
> manager), and the real Pico/USB run is unexecuted. **R2 has since landed
> on the chip and is chip-confirmed in simulation** (15/15 golden steps
> byte-exact); the host side carries the session/API/page read_cpu, the R2
> read gate and idle-fault visibility. See
> `reviews/2026-09-25/HOST-GUI-R2-PREP.md` and
> [[plans/host-controller-gui]].
<!-- END gui-worker host block (top note) -->

>
> **Also done 2026-09-23: the SPI loader.** `rtl/pe_ctrl.v` is a passive SPI
> slave at the TT wrapper (ADR-007) that clocks 16-bit words into `pe_imem`
> through the SoC's host port; its independent run-transition P1 (a queued word
> could write while `run` was high) is fixed with abort semantics and a masked
> `host_we`, and `regress/mutate_ctrl_tb.sh` guards it 11/11. At that milestone,
> regression was 28/28 RTL, 19/19 firmware, with six mutation suites. See
> `reviews/2026-09-23/PE-CTRL-RESOLUTION.md`.

> **Resume here after a context flush.** Read this first, then `wiki/index.md`.
> Last updated: 2026-09-24, after the Task 5a diagram squarer layout and the
> Task 5b hold-screen attribution (labelled ZERO/BOARD STA variants) were
> recorded, following the closeout hardening (mapped STA refresh for the
> SERDES integration + the codec mutation suite) and, earlier the same day,
> the word-engine integration in `pe_soc` and the A1 readback in `pe_ctrl`;
> the 10BASE-T TX frame-path plan (item 9) was then authored, and both it
> and the PE host read path (item 10) have since landed.
> The code is reorganized: `tb/` holds
> testbenches only, `regress/` the harnesses, `tools/{fw,gen,checks}/` the
> Python, `rtl/pe_soc.v` is the SoC (was `pe_uart_soc`), the line codecs are one
> module per file (`pe_nrzi`/`pe_manch`/`pe_bitstuff`), and the SRAM shell is
> under `rtl/vendor/`. Functional behavior is unchanged and verified.
> Read `reviews/2026-09-23/REFACTOR-REVIEW.md` and `HANDOFF.md` before resuming.
> Branch `main` (reviewed code at `6de2a6a`; later commits only add review
> evidence/docs); `review/fix-invisible-defects` remains at `2cc0f03`.
>
> **Where the work is:** RTL development with `iverilog` + `vvp` + the emulator.
> The user permits **periodic synthesis and STA to catch RTL that cannot be
> hardened** (clarified 2026-09-23), including mapping, clock/latch structures,
> constraint coverage and SRAM timing. **Physical flow, DRC and LVS remain
> deferred.**
>
> **The forward work list is the "Next steps" section below** — it is the one place
> that list lives, and it was stale until 2026-09-22: three of its items had been
> completed while still shown as pending. `plans/through-i2c` is a COMPLETED plan
> kept for its findings, not a live work list.

## Where we are

The refactor review found matching token streams for all 15 RTL modules and
26 TB modules after the intended renames, preserved compilation directives and
attributes, identical executable assembler/emulator ASTs, and four unchanged
firmware images. A fresh archive regression, the original review probes and
102-case Ethernet sweep, boundary tests, relocated entrypoints from `/tmp`,
and submission/staged-flow source compilation all pass. Evidence is in
`reviews/2026-09-23/refactor/`; no physical flow was run.

The regression reports 29/29 RTL and **20/20** firmware checks passing, with
lint, documentation gates, and all seven mutation suites green, and the review's
directed probe suite (`bash reviews/2026-09-22/review2/run_repros.sh`) exits 0.
The second review's original seven failure cases now pass: the DRU's falling-edge capture is
now a two-latch pair (the async Ethernet sweep is 102 trials / 0 failures), the
MAC prevents the reported runt underflow, USB stuffing
is ones-only by explicit config, the CPU's stopped fetch address is zero on the
first stopped edge, both SRAM fallbacks hold their read outputs during writes,
the emulator UART monitor samples bit centres, and the mutation harnesses
restore on interruption. Resolution detail is in `REVIEW-2.md`; each fix has a
permanent test in the regression. The verification pass's two follow-ups are
also fixed: the MAC now rejects undersized type frames (64-byte minimum) and
frames that end mid-byte (`bit_cnt == 0`), and the generated codec reference
documents `cfg[6:4]` run length, `cfg[7]` `ones_only`, USB `0xE3`, and CAN
`0x51` (`0x01` equivalent; `0x05` would enable Manchester). The recheck's F3 is
closed: `tb_pe_codec_mux` exercises the documented CAN preset on TX and RX.
The F1 boundary probe, the F2/F3 drift gate, and the CAN preset probe are
green; detail in `FIX-VERIFICATION.md` and `F1-F2-RECHECK.md`.

Both layers of the thesis now exist and have baseline simulation coverage:

- **Milestone 1 — shared hardware layer.** The SERDES, the line codecs and the
  codec mux, all self-checking-TB verified, all synthesized on real IHP sg13g2
  cells, and the SERDES through the full LibreLane place-and-route flow to a
  clean historical 66 MHz signoff (2026-09-18). The current signoff target is
  60 MHz (16.667 ns).
- **Milestone 3 — 10BASE-T receive, in hardware.** `rtl/pe_eth_mac.v` (1,681
  cells after the review fixes) is the first protocol block that is deliberately
  NOT firmware, and [[concepts/ethernet-scope]] says why with arithmetic: at a 100 ns bit period
  the single-cycle core has 48 instructions per byte, and a software CRC-32
  alone needs ~240. So the bit work is hardware and the firmware sequences
  frames. The block ties together FOUR previously-orphaned pieces -- `pe_dru`,
  `pe_manch`, `pe_crc` and `pe_fbuf` -- into one signal path, which is the
  point of building it here rather than later: an orphan block is a claim that
  has never been exercised inside a design. It locks on the SFD, assembles
  bytes, checks the FCS against the RevEng catalogue residue, and
  store-and-forwards into the 2 KB frame buffer, taking both 802.3 frame kinds
  (a length field and an EtherType) because the acceptance target is ARP and
  ARP is an EtherType. `tb/tb_pe_eth_mac.v` drives raw Manchester levels into
  the real chain, so every byte checked is a byte a real receiver recovers.
  As of 2026-09-23 the chain is instantiated in `pe_soc` (port bit 7) with the
  frame window on IO `0x8-0xE`; `tb/tb_pe_soc_eth.v` drives the same wire into
  the SoC and checks that `firmware/eth_rx.pe` consumed a real ARP frame, and
  `regress/mutate_eth_soc_tb.sh` proves those checks can fail (8/8).
- **Milestone 2 — the programmable core.** A CPU, an assembler, a bit-accurate
  emulator, and **three protocols written entirely in firmware** — UART, SPI
  mode 0, and, as of 2026-09-22, **I2C** (the pin-level grammar: START, one bit
  cell, STOP). None has a state machine in the hardware: the framing and bit
  timing are programs (`firmware/uart_echo.pe`, `firmware/spi_xfer.pe`,
  `firmware/i2c_pins.pe`) the CPU executes against the pad interface, a tick
  counter and — for I2C — the pin matrix. UART, SPI and I2C share the **same
  8-bit port**, so nothing in the RTL knows which one is running.

  **As of 2026-09-22 the frame buffer is BUILT** (`rtl/pe_fbuf.v`, 2 KB behind a
  byte interface on the same 1024x16 macro as the instruction memory, per
  ADR-003). It is TB-proven on BOTH implementations -- the real macro and the
  `FLOP=1` fallback -- with 5 mutations detected and 0 survived. It **landed in
  the SoC on 2026-09-23**, with the receive chain (`pe_dru` -> `pe_manch` ->
  `pe_eth_mac`) as its writer and the IO window `0x8-0xE` as firmware's reader.
  Byte granularity comes free from the macro's bit-mask port; the
  read lane costs a register, and getting that register's timing wrong only
  shows up on pipelined accesses (gotcha 62). That is the
  competition thesis, demonstrated end to end in simulation for all three of the
  blog's baseline protocols.
- **I2C is the one that needed new hardware, and it is 111 cells** — the pin
  matrix, a runtime per-pin `{out, oe, od}` register file
  ([[concepts/pin-matrix]], [[decisions/adr-006-pin-matrix]]). It went **inside
  `pe_soc`**, not at the TT wrapper as the plan had it: the CPU's IO bus
  never leaves the SoC, so a matrix outside it could not be reached by any
  program. The UART and SPI tests now sign off *through* the matrix, which is
  stronger than testing it alongside them. Measured: **83.2–83.6 kHz** across
  all 60 tick phases, every standard-mode floor cleared at worst case
  ([[concepts/i2c-on-the-matrix]]).

**The full SoC now routes and times clean.** On 2026-09-22 the full-SoC
LibreLane run `RUN_2026-09-22_00-33-59` closed setup and hold at all three
corners with **+1.143 ns setup slack worst-case** and the instruction-fetch path
(SRAM `A_CLK` -> `A_DOUT` -> CPU) measured in context at **7.635 ns**, against a
15.15 ns period. It finished detailed routing with **zero DRC violations** and
reached **step 57 of 80**; the flow's own gates read "Routing DRC errors clear"
and "power grid violations clear", and worst-case IR drop is **0.30%** (3.56 mV
of 1.20 V). See [[reference/sram-budget]] for the numbers and
`flow/pe_soc.json` for the two flow fixes that got it there (the
`GRT_ADJUSTMENT` derate and a custom PDN config for the macro's Metal4 supplies —
[[STATUS]] gotchas 33-34).

*What still stops the flow at 80 steps:* step 57, Magic GDS streamout, cannot
extract a PR boundary from the SRAM's GDSII. The IHP macro ships **no `pblock`
layer** — its GDS has `189/4` (the IHP map's `DIEAREA`) rather than the
`prBoundary` layer LibreLane's `get_bbox.tcl` reads `FIXED_BBOX` from. This is a
PDK-macro-vs-flow-vocabulary mismatch, not a defect in this design, and the die
size it needs is already declared in the LEF (`SIZE 236.8 BY 336.46`). Gotcha 35.

**The repo is now submittable**: `rtl/tt_um_protocol_emulator.v` and `info.yaml`
exist, so there is a `tt_um_*` top level with a real pad interface
(`ui_in`/`uo_out`/`uio_*`), an `ena` that gates nothing, and open-drain SDA/SCL on
`uio[1:0]`. Until 2026-09-20 every pin-budget conclusion in the wiki described an
interface that no RTL in this repo implemented.

Nothing has been taped out. The project-wide architecture and implementation
progress diagrams are editable PlantUML sources in `diagrams/project-plan.puml`
and `diagrams/project-progress.puml`. The separate [[reference/block-diagram]]
page is a generated, drift-checked RTL inventory. Keep the plan diagram aligned
with scope and topology decisions, and the progress diagram aligned with
implementation and verification changes. **The ordered current work list is the
Next steps section below**; the summary is at the bottom of this file.

The one-line version, for the reader who wants it before clicking through:

```
  tt_um_protocol_emulator (BUILT, the deliverable)
    └── pe_soc (BUILT) ── pe_cpu ── pe_imem ──[FLOP=0]── SRAM macro
                             └ tick timer (260 clk = half a 115200 bit)
                             └ 1 us I2C tick (60 clk, exact)
                             └ pe_pinmux (111) ── per-pin {out,oe,od}
                             └ 10BASE-T RX (pe_dru -> pe_manch -> pe_eth_mac
                                            + pe_crc + pe_fbuf)
                                 └ frame window on IO 0x8-0xE -> firmware
                                 └ word engine: pe_serdes + 2 x pe_codec_mux
                                   + timing divider + 0xF window (2026-09-24)
    └── pe_ctrl (463) ── passive SPI load + A1 readback into imem

  INSTANTIATED NOWHERE (0) — both landed in pe_soc on 2026-09-24
  (split serdes enables, two codec instances, the 0xF window, the pad
   overlay; see [[plans/serdes-integration]]):
    pe_serdes (539)  pe_codec_mux (130)  — now instantiated in pe_soc
```



**Two implementation styles now coexist on purpose.** The SERDES is a word
engine: load 8–32 bits, pace with `bit_en`, collect a word — the right shape for
UART/SPI/CAN/USB. The firmware core bit-bangs instead, which is the right shape
when control flow is per-bit (I2C ACK/arbitration/stretch). [[plans/through-i2c]]
states the reasoning; do not "unify" them without reading it.

## What is built and verified

| Block | File | Cells | Area (µm²) | TBs |
|---|---|---|---|---|
| SERDES (bit engine, 1–32 b, runtime order) | `rtl/pe_serdes.v` | 539 | 11,223 synth → **17,211 routed** | `tb_pe_serdes.v` + 9 protocol TBs |
| NRZI codec | `rtl/pe_nrzi.v` | 15 | 212 | `tb_pe_nrzi` |
| Manchester codec | `rtl/pe_manch.v` | 7 | 120 | `tb_pe_manch` |
| Bit stuffer/unstuffer | `rtl/pe_bitstuff.v` | 99 | 1,417 | `tb_pe_bitstuff` |
| Codec pipeline mux | `rtl/pe_codec_mux.v` | 130 | 1,811 (whole pipeline) | `tb_pe_codec_mux` |
| **CRC / LFSR engine** (5-, 8-, 15-, 16-, 32-bit) | `rtl/pe_crc.v` | 209 | 3,354 | `tb_pe_crc` |
| **DRU** (oversampled Manchester receive, DDR) | `rtl/pe_dru.v` | **148** | **2,398** | `tb_pe_dru` |
| **CPU** (16-bit insn, 16 opcodes, PC width from IMEM depth) | `rtl/pe_cpu.v` | 377 | 4,843 | `tb_pe_cpu` |
| **Pin matrix** (per-pin OUT/OE/IN/OD, open-drain, read-back) | `rtl/pe_pinmux.v` | **111** | **2,061** | `tb_pe_pinmux` |
| **SPI loader + A1 readback** (passive slave; 16-bit words to imem, abort on run; commit-latched word echo on `uio[4]`) | `rtl/pe_ctrl.v` | **463** | **8,661** | `tb_pe_ctrl` |
| **Instruction memory** — real SRAM macro + wrapper | `rtl/pe_imem.v` | 12 glue + macro | 187 + LEF | `tb_pe_imem` |
| **10BASE-T receive MAC** (consumer ownership, committed-byte guard) | `rtl/pe_eth_mac.v` | **1,681** | **23,750** | `tb_pe_eth_mac` |
| **Programmable protocol SoC** (CPU + tick timer + pin matrix + 10BASE-T RX) | `rtl/pe_soc.v` | **3,571** | **56,817 total** | `tb_pe_soc_uart`, `tb_pe_soc_tick`, `tb_pe_soc_eth` |
| **TT top level** (the deliverable) | `rtl/tt_um_protocol_emulator.v` | **4,038** | **65,686 total** | `tb_tt_um_protocol_emulator` |

Firmware (no RTL cells — these are programs the CPU runs; see
[[concepts/spi-as-firmware]]):

| Program | Words | Verified by |
|---|---|---|
| `firmware/uart_echo.pe` — 115200 8N1 echo | 118 | `tb_pe_soc_uart.v` (real RTL), `tools/fw/peemu.py` |
| `firmware/tick_count.pe` — STATUS-port exerciser | 8 | `tb_pe_soc_tick.v` (real RTL) |
| `firmware/spi_xfer.pe` — SPI mode 0 master | 70 | `tools/fw/peemu.py` (mode-0 slave model) |
| `firmware/eth_rx.pe` — 10BASE-T frame-window consumer | 42 | `tb_pe_soc_eth.v` (real RTL, real ARP frame) |
| `firmware/i2c_pins.pe` — I2C pin grammar (START/bit cell/STOP) | 79 | `tb_pe_soc_i2c.v` (real RTL), `tools/checks/i2c_timing.py` |
| `firmware/i2c_xfer.pe` — I2C master transaction (addr, ACK, read, NACK) | 311 | `tb_pe_soc_i2c_xfer.v` (real RTL, slave FSM), `tools/checks/i2c_xfer_check.py` (60 phases) |

Numbers from `regress/synth_area.sh` (sg13g2 typ corner, mapped pre-route). The routed
figure for the SERDES comes from the full LibreLane flow (route+CTS+PDN inflate
area ~1.54× over mapped), reproducible from a clean clone with
`flow/run_librelane.sh flow/pe_serdes.json`.

Two reporting changes on 2026-09-20, so these do not look like regressions against
the previous revision of this table:

- **Areas are now whole-design totals.** `synth_area.sh` read yosys's "Chip area for
  module 'X'", which is X's *local* area excluding submodules — 69 µm² for the codec
  mux (the glue only) and 0 µm² for any wrapper. It now prefers "Chip area for top
  module", so the codec mux reads 1,691 and the SoC reads one number instead of
  needing the reader to add the CPU back in.
- **A few blocks genuinely grew**, all of it fixes: NRZI and Manchester gained a
  frame-boundary `clr` and a registered error, the CPU gained real `dbg_pc`/`dbg_a`
  ports (they were hierarchical references that did not synthesise), and the SoC's
  `tick_flag` became an actual flop instead of a driver conflict yosys was tying to
  a constant.

**DONE 2026-09-20 — the SoC went from 8,744 cells / 182.7k µm² to 1,083 cells /
19.8k µm².** The instruction memory is now the real `1P_1024x16_c2_bm_bist` macro
(`rtl/pe_imem.v`), and the program is 1,024 words instead of 128. Measured both
ways round: 1,024 words in flops is 60,806 cells / 1,300,104 µm², which reproduces
ADR-003's 1,271 µm² per instruction word exactly.

**It did NOT change nothing, and the plan was wrong to say it would.**
[[plans/through-i2c]] Blocker 3 claimed the swap "does not change the CPU's
interface or its cycle model, because the instruction port was written for a
registered ROM from the start". The cycle model was indeed already right — the
macro's read latency is one cycle, which is what the fetch-ahead assumes. But the
CPU had a **fixed 8-bit PC**, so at 1024 words `next_pc[IAW-1:0]` was an
out-of-range part-select and the reachable program stayed 256 words regardless of
depth: 896 words of addressable-by-nothing SRAM for 79,674 µm². **The PC and the
jump-target field had to widen in the same change.** Full reasoning and the
rejected alternatives: [[decisions/adr-004-program-counter-width]].

**Regression: 29/29 testbenches + 20/20 firmware tests pass, and the lint gate is
clean** (14 verilator tops + 11 yosys elaborations; `regress/run_all.sh` runs the firmware regression first, then every TB, then
`regress/lint.sh`, then the generated-doc drift checks, then seven testbench mutation
harnesses -- `regress/mutate_i2c_tb.sh`, `regress/mutate_spi_tb.sh`,
`regress/mutate_fbuf_tb.sh`, `regress/mutate_eth_mac_tb.sh`,
`regress/mutate_eth_soc_tb.sh`, `regress/mutate_ctrl_tb.sh` and
`regress/mutate_i2c_xfer_tb.sh` -- plus the macro-flow configuration gate. The lint gate covers `pe_eth_mac` and `pe_fbuf` as of
the 2026-09-22 review, and it now fails on ANY yosys `ERROR:` — it used to grep
for three known diagnostics and reported "elaborate OK" beside a file yosys
could not parse at all. Each mutation harness proves its testbench FAILS when the
property it claims is broken, because a testbench that passes on broken RTL
manufactures confidence.

**`regress/lint.sh` is not optional, and the reason is the most useful thing in this
file.** A previous revision said the Verilator warnings were "intentional". They
were not. Two of them were real defects that no testbench could ever have caught,
because a testbench only ever sees the *simulator's* resolution of illegal RTL:

- `tick_flag` was driven by two `always_ff` blocks. Icarus raced it (measured: 50 of
  100 ticks silently dropped by a two-instruction poll loop) and **yosys resolved the
  driver-driver conflict to a constant 0**, so the STATUS port worked in simulation
  and was dead in the netlist. Nothing caught it because no firmware read the port —
  `firmware/tick_count.pe` and `tb/tb_pe_soc_tick.v` now do.
- `assign dbg_pc = u_cpu.pc` is a cross-module reference. Icarus accepts it; yosys
  declared an implicit wire and drove it *backwards*, leaving `dbg_pc[7:1]` tied low
  in the netlist. They are real ports on `pe_cpu` now.

Both were printed by the tools on every run and discarded: `regress/synth_area.sh`
captured yosys's output and grepped it only for numbers. It now surfaces them and
exits non-zero. **An area report that hides correctness warnings looks like a check
and is not one.**

**The CRC block is checked against an outside authority, not against itself.**
`tools/gen/crc_config.py` derives every constant, asserts the RevEng catalogue's
published `check` value for "123456789" for six polynomials, and refuses to write
[[reference/crc-config]] unless the derived constants reproduce it. `tb_pe_crc`
re-checks the same numbers in the RTL, using the TEXTBOOK datapath as the reference
(shift-left for non-reflected CRCs, shift-right for reflected) so agreement means the
"one right-shift register serves both families" claim is measured rather than
asserted. It also folds the DUT's OWN emitted field bits and requires the catalogue's
published `residue` — independent evidence that the wire order is the standard's.

**The DRU's grid is the claim, and it is measured exhaustively.** `tb_pe_dru` drives
every Manchester transition pattern (00, 01, 10, 11 — the complete set of things a
half-cell boundary can look like), 32-bit runs, an Ethernet preamble+SFD frame, and a
random soak, and requires the bits back. It then feeds the DRU into a real `pe_manch`
and requires its `rx_err` to stay quiet, which is what makes the halves a legal
symbol and not merely "some value".

**The grid is DUAL-EDGE as of the 2026-09-22 review.** The DRU had been sampling
rising edges only, so at the 60 MHz core and SPB=12 it decoded a 200 ns bit while
10BASE-T is 100 ns/bit — real-rate receive was missed entirely, and the TBs hid it
by driving the wire at half rate. ADR-002's latch-pair DDR front end is now built:
the rising sample goes through the 2-flop synchronizer, the falling sample through a
transparent-high latch and a flop, an interleaved 3-tap majority filters the 2×
stream, and a task-based grid machine consumes both samples per clock. `tb_pe_dru`
and `tb_pe_eth_mac` now drive REAL 60 MHz / 100 ns bits; the Ethernet TB is real
frames with a real FCS. One honest limitation is recorded there: a 3-tap majority
outvotes an isolated spike on a stable level, but a spike inside the majority's
window of a real transition can move the filtered edge by a sample.

Protocol testbenches (one per target, each wrapping the same SERDES with that
protocol's real framing): UART 8N1 · SPI mode 0 full duplex · I2C 7-bit
addr/RW/repeated-start · JTAG TAP walk + BSR · SWD req/ACK/data/parity ·
PS/2 11-bit odd-parity · CAN classic + stuffing + CRC-15 · USB-LS NRZI+stuffing ·
10BASE-T Manchester + CRC-32.

**The software-UART demonstration** (Milestone 2's headline): `firmware/uart_echo.pe`
is a half-duplex 115200 8N1 echo, assembled by `tools/fw/peasm.py` to 114 words,
executed by `rtl/pe_cpu.v` inside `rtl/pe_soc.v`. `tb/tb_pe_soc_uart.v`
drives a real 8N1 waveform on the RX pin and decodes the TX pin: **PASS on
41/42/00/FF**, TX cell width 8.6–8.7 µs measured at the pin against the nominal
8.68 µs. `tools/fw/peemu.py` reproduces the same four bytes cycle-accurately, which
is the fast firmware-development loop (2 s vs a 1 min RTL build).

**Historical routed signoff of pe_serdes** (2026-09-18, full LibreLane Classic
on ihp-sg13g2, former 66 MHz target):
0 DRC, 0 LVS, setup WS +7.6 ns (slow corner), hold WS +0.116 ns (fast corner),
die 161.7 × 180.4 µm, 78 % utilization. Run dir: `~/asic-runs/pe-serdes`.
The checked-in config now targets 60 MHz (16.667 ns).

<!-- BEGIN gui-worker host block (host tooling section) - keep whole -->
## Host controller GUI and Pico bridge (host side, branch `host-controller-gui`)

This entry records the host-side half of the operator tooling; the chip half of
that plan is the RTL phases below/above (Tasks 3-5 of
[[plans/host-controller-gui]]), tracked by the chip-side manager. **This
section describes the host branch `host-controller-gui`; it is not a statement
about `main`'s chip state.**

| Piece | File | What it is | Evidence |
|---|---|---|---|
| Image/frame contracts | `tools/host_gui/{image,protocol}.py` | `.pe` assembly through the existing `peasm.py`, 1024-word cap, canonical digest; the PE frame codec (sync `A55A`, version/opcode/target, seq, len, CRC-16/CCITT-FALSE) | 55 cases, golden bytes + the published `0x29B1` check value |
| Host session | `tools/host_gui/{transport,session,server}.py`, `web/` | newline-JSON USB CDC transport with id correlation and a bounded event queue; the state machine; the loopback local page | 97 cases; transport/session/API |
| Fake PE + fake bridge | `tools/host_gui/fake_pe.py` | in-memory chip model: LOAD/STATUS/READ_CPU/READ_IMEM/READ_DMEM/DUMP_CORE/CLEAR_FAULT/TARGET + loopback target 1, sticky faults, run gating | 329 cases drive it |
| Pico bridge | `tools/host_bridge/{pe_frame,tt_adapter,main}.py` | MicroPython frame codec, TT SDK HAL (project/clock/reset/run/`uio_oe_pico`/CS_N), newline-JSON endpoint with framed SPI, LOAD-forces-run-0, start-after-load, IRQ polling, 5 MHz first-pass SCLK cap | 43 cases; 8 fake-`ttboard` cases; 4 cases with the real host stack over the real bridge |
| Acceptance runner | `tools/host_bridge/acceptance.py` | one scripted sequence for `--fake` (no device) and `--device` (hardware); per-step PASS/FAIL/SKIP + manifest; `dialout` hint instead of a traceback | `RESULT: PASS (22 PASS, 0 FAIL, 1 SKIP)` |
| R2 read contract (host side) | `tools/host_gui/r2_reads.py` | the seven R2 read obligations as named probes; read-range latches sticky `FAULT_RANGE`, READ payload low-word-first ascending, ISA widths (pc 10, a/x/y 8, insn 16) — **chip-confirmed in simulation**: `tb_pe_ctrl_r2` passes all 15 golden steps byte-exact (chip repo `R2-READ-PATH-REVIEW.md`) | 15 cases, green; package `chip_confirmed: true` |

Full result records, commands and limits: `reviews/2026-09-24/HOST-GUI-PHASE1B.md`,
`reviews/2026-09-25/HOST-GUI-PHASE2-BRIDGE.md`,
`reviews/2026-09-25/HOST-GUI-PHASE3-ACCEPTANCE.md`,
`reviews/2026-09-25/HOST-GUI-R2-PREP.md`,
`reviews/2026-09-25/HOST-GUI-TASK8-FINAL.md`. Operator steps: README's
"Host controller" section and `tools/host_gui/tests/fixtures/acceptance.md`.
The page shows the live CPU header (`/api/read_cpu`) and keeps a status poll
running while connected so a chip fault on an idle board surfaces.
<!-- END gui-worker host block (host tooling section) -->

## Area budget — where the die actually goes

Measured 2026-09-20. The mapped→die factor is **1.97**, from the only block that has
been through real place-and-route (`pe_serdes`: 11,223 mapped → 17,211 routed cells
→ 29,164 µm² die at 78% utilisation). Macros place as-is and take no inflation.

**The swap is DONE and measured** (2026-09-20, [[decisions/adr-004-program-counter-width]]).
The historical 2026-09-20 per-word figure reproduced ADR-003's estimate at that
revision:

| | Cells | Area (µm²) | Note |
|---|---|---|---|
| Instruction memory, 1,024 words in flops | 60,806 | 1,300,104 | the projection ADR-003 was built on |
| Instruction memory, 1,024 words in the macro | 12 + 1 instance | 187 glue + LEF area | measured 2026-09-20 |
| Whole SoC before the swap (128 flop words) | 8,744 | 182,650 | |
| **Whole SoC after the swap (1,024 SRAM words)** | **1,083** | **19,795** | **9.2× smaller, 8× the program** |

That baseline's flop figure reproduced ADR-003's 1,271 µm²/word estimate
(60,806 cells × 21.4 µm² / 1,024 words). A fresh 2026-09-23 mapped screen with
Yosys 0.69+post, after the read-hold fix in `pe_imem`, reports 61,057 cells /
1,300,811.665 µm² (about 1,270.3 µm² per word); the generated RTL inventory
uses the current count. The macro contributes **no** synthesised cells — its
area comes from the LEF, and it is 79,674 µm² per [[reference/sram-budget]].

**The allocation is 6×4 = 24 tiles**, not 8×4. The blog says so three times, and
`info.yaml` now matches. 8×4 is described only as "the possibility of scaling up
… (~30% more area)", to be announced by a page update and an email to sign-ups.
**Design to 24 tiles; treat 32 as headroom that may never arrive.** Verbatim source:
[[raw/articles/janestreet-competition-blog-fulltext]].

| Scenario | Die µm² | of 6×4 (real) | of 8×4 (upside) |
|---|---|---|---|
| Before the swap (flop IMEM, 128 words) | 385,265 | **89%** | 67% |
| **Now: SoC + SERDES + codecs + instruction macro + DRU + CRC** | **154,786** | **36%** | 27% |
| Still to come: pin matrix + 2 KB frame macro | +79,674 | → 54% | → 41% |

The "still to come" row is the two known remaining consumers: the frame buffer is
79,674 µm² of macro, and the pin matrix is estimated in the low hundreds of cells.
**The design is no longer area-constrained**, which is the whole point of the swap:
the remaining risk in this project is now verification, not floorplanning.

Gate count is not the constraint: 1,264 cells for the whole SoC against ~24,000 for
24 tiles at the blog's ~1K cells/tile — about 5.3% of the logic budget, with the
SERDES's 539 and the codecs' 115 on top. (The row above is the SRAM-swap
measurement; the pin matrix moved inside the SoC afterwards, which is the +178
cells.)

**Shape matters more than tile count**, because a macro has to physically fit the
rectangle. TT notation is WIDTH × HEIGHT:

| Allocation | Die (template tile) | Aspect | Note |
|---|---|---|---|
| **6×4 (real)** | 1002 × 432 µm, 0.433 mm² | 2.32:1 | keeps every macro 8×4 keeps |
| 8×4 (upside) | 1336 × 432 µm, 0.577 mm² | 3.09:1 | +33% area, same height |
| 4×6 (not the offer) | 668 × 648 µm, 0.433 mm² | 1.03:1 | would lose all 64-bit-wide macros |

The 6×4 and 8×4 dice are the same height, so **nothing in the macro analysis
changes if 8×4 arrives** — it is pure extra width. Re-answer the whole SRAM page for
the upside case with `tools/gen/sram_budget.py --tiles 8x4`.


## Design decisions in force

| Decision | Where |
|---|---|
| **12×** oversampling per bit (6 samples per 50 ns half-UI) = 8.33 ns RX grid at the 60 MHz core | `decisions/adr-001-8x-oversampling.md`, `decisions/adr-005-60mhz-turbo.md` |
| Std-cell **latch-pair dual-edge flop** for DDR capture; no custom DET | `decisions/adr-002-latch-pair-det-flop.md` |
| **60 MHz operating point — LOCKED, not a parameter** = exact integers for every hard protocol (50 ns = 3 ticks) | `decisions/adr-005-60mhz-turbo.md`, `reference/clock-arithmetic.md` |
| **Signoff target: 60 MHz** (`CLOCK_PERIOD` 16.667 ns) in both flow configs; the 66 MHz STA target is retired | `flow/pe_soc.json`, `flow/pe_serdes.json` |
| SERDES words ≤ 32 b; longer fields chunk (SWD parity, CAN/USB/ETH payloads) | `rtl/pe_serdes.v` header |
| Codec pipeline order fixed (stuff → line-code); cfg selects the **subset** | `rtl/pe_codec_mux.v` header |
| No elasticity FIFO needed (source-sync protocols + per-edge re-lock) | `concepts/cdr-oversampling.md` |
| Two SRAM macros: 1024-word instructions + 2 KB frame buffer, both `1P_1024x16` | `decisions/adr-003-memory-plan.md` |
| **Instruction macro is live; PC width derives from IMEM depth (10 bits at 1024)** | `decisions/adr-004-program-counter-width.md` |
| 10BASE-T is the LINE LAYER only; the stack is off-chip, and firmware never touches Ethernet bits | `concepts/ethernet-scope.md` |
| **Buffer ownership: `wptr` is the producer, `rptr` the consumer**; releases are bounded by both allocated and committed bytes (`used` and `published_used`), never rebase an in-flight frame, wrapped releases free their bytes (distance modulo `BUF_BYTES`), and a consume coincident with a producer `room` update keeps both deltas (`consume_credit`); the address-only full-ring release remains documented (E1-3) | `rtl/pe_eth_mac.v`, `reviews/2026-09-23/E1-PUBLISHED-OWNERSHIP-REVIEW.md` |
| **The six `uo_out[7:2]` pads stay `dbg_pc[5:0]` for now**: no readback path, 6 usable pads free (12 if debug is reclaimed); revisit when a protocol needs them or readback lands | `rtl/tt_um_protocol_emulator.v` header, STATUS item 4 |
| **Both SRAM macros are placed with all supply hooks**; the gate validates instances, every pin-to-net mapping, every macro view (nonempty gds/lef/lib, matching view class and extension, PDK-resolvable ./src paths, lib coverage of the flow's PVT corners), and the macro grid's Metal4 stripe + ordered Metal4→vertical→horizontal connects, with negative tests for each; a missing PDK LEF is a clean SKIP (exit 2 only when there are no findings), and findings and yosys failures still fail | `flow/pe_soc.json`, `tools/checks/macro_flow_config.py`, `regress/mutate_macro_flow_config.sh`, `reviews/2026-09-23/E1-E2-FOLLOWUP-REVIEW.md` |
| **`pe_ctrl` is a passive SPI slave at the wrapper**; the intended board-side host is the Tiny Tapeout demo board's RP2040 (Raspberry Pi Pico), which loads before `run` starts; no master, no flash, no bootstrap FSM | `decisions/adr-007-pe-ctrl-passive-slave.md` |
| Every codec stage takes `clr` and reports `rx_err` REGISTERED, one cycle after the strobe | the codec headers (`pe_nrzi`/`pe_manch`/`pe_bitstuff`) |
| `ena` must never gate logic; every pad output driven in every state | `rtl/tt_um_protocol_emulator.v` header |

## Timing margin at the 60 MHz operating point (measured, post-route)

From `RUN_2026-09-22_02-58-32`, `55-openroad-stapostpnr` — **the first run signed
off at `CLOCK_PERIOD` 16.667 ns = 60 MHz directly**, so the reported slack IS the
operating-point margin with no conversion:

| | setup (worst = slow corner) | hold (worst = fast corner) |
|---|---|---|
| worst slack **@60 MHz — signed off here** | **+2.6601 ns** | **+0.1209 ns** |
| as a fraction of the 60 MHz period | **16.0%** | — |
| violating paths, all 3 corners | **0** | **0** |
| max cap / max slew / max fanout violations | **8 / 10 / 7 — still present, and they WARN, they do not gate** | |

The 60 MHz figure **+2.6601 ns reproduces the +2.660 ns predicted from the 66 MHz
run's path by hand** (arrival 13.4479 ns, capture clock 0.6419 ns, uncertainty
1.0 ns, library setup 0.2008 ns), which is an independent check on the arithmetic
in that table.

**The relaxed period did NOT clear the slew/cap violations, and it could not
have.** They are unchanged at 8 max-cap / 10 max-slew, identical to the 66 MHz
run. A longer period relaxes *timing* (`setup`/`hold`); it does nothing to a
slew or capacitance limit, which is a driver-strength and fanout property of the
SRAM's pins as our routing drives them. See gotchas 37-39 — the lever is
`DESIGN_REPAIR_MAX_SLEW_PCT` / `MAX_CAP_PCT`, and the IHP reference design hits
the same checkers with no SRAM at all.

**Both runs' `1113909`/`2672` DRC counts are byte-identical across the clock
change, which is the cleanest evidence that they are macro-internal geometry and
not a function of the design's timing at all** — and gotcha 44's macro-alone diff
already showed all 2672 KLayout violations reproduce from the vendor macro with
no SoC around it.

**Fmax from the post-route critical path: 71.4 MHz** (slow corner, 1.08 V/125 C,
min period 14.007 ns). That is real headroom over 60 MHz — 19% — and it is the
number that answers "what are we leaving on the table".

**What the critical path IS, and it is not the CPU:** it starts at the SRAM
(`u_imem.g_macro.u_sram/A_DOUT[12]`), takes **7.635 ns** of the 13.448 ns
arrival, then runs through a chain of **hold-fix buffers** — `fanout118`,
`fanout115`, `fanout113`, all `sg13g2_buf_1` — costing a further **1.55 ns**,
before ending in `hold626` (`sg13g2_dlygate4sd3_1`) which alone injects
**0.623 ns** of the path as pure delay. **The hold repair is ~2.2 ns of a
14.0 ns period, i.e. it is costing ~11% of Fmax**; without it the path would
close at ~84 MHz. This is the single cheapest lever on the clock, and it is why
the hold uncertainty value (0.25 ns, the SDC split) is load-bearing.

**The margin is not the same thing as confidence in the number.** The SRAM's
7.635 ns is a `.lib` table lookup taken **outside** the characterised axes (see
gotchas 37-38): input slew presents 1.291 against a table max of 0.5952. The
SRAM read is therefore the one number in this table that OpenROAD extrapolated
rather than interpolated, and it is 57% of the arrival time.

**Also gated, and not clean:** `Checker.MaxSlewViolations` (10) and
`Checker.MaxCapViolations` (8) fire in all three corners, all on SRAM macro
pins as driven by our routing. Setup/hold are clean; these two are not.

## Toolchain — exact commands

```bash
# EVERYTHING: firmware regression (assemble + emulator) then all 29 RTL TBs.
# Runs the firmware first because tb_pe_soc_uart $readmemh's the .hex it builds.
cd ~/janestreet-blog-serial-protocol-emulator && ./regress/run_all.sh

# same suite, parallel testbench loop (same 4-state iverilog, not Verilator --
# a simulator swap would make it 69.6x SLOWER, see reference/simulator-bakeoff)
./regress/run_all.sh --fast
./regress/run_all.sh --fast -j8      # explicit job count

# firmware only (assemble firmware/*.pe -> .hex, run the emulator cases)
./regress/run_firmware_tests.sh

# one program by hand, with a cycle trace
python3 tools/fw/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex
python3 tools/fw/peemu.py firmware/uart_echo.hex --send "41 42" --max-cycles 900000

# mapped area per block (native yosys + IHP liberty). Exits non-zero if yosys
# reports a driver conflict or an implicit declaration -- it used to swallow them.
./regress/synth_area.sh

# the static gate on its own: verilator -Wall + a yosys elaboration check.
# run_all.sh runs this; there are no accepted warnings in this RTL.
./regress/lint.sh

# Editable project block diagrams are stored as PlantUML text in diagrams/.

# full place & route. The config now lives IN THE REPO (flow/), so the signoff
# result is reproducible from a clean clone; it used to exist only in
# ~/asic-runs, which meant the one routed number the project claims could not be
# regenerated by anyone else. The script handles the explicit -p / -s flags the
# dockerized wrapper needs (see gotcha 1) and stages sources into the run dir.
flow/run_librelane.sh flow/pe_serdes.json
```

Environment: PDK clone `~/pdk/IHP-Open-PDK`; Ciel PDK `~/.ciel` (enabled
`ihp-sg13g2` c4b8b4e); venv `~/venvs/asic` (volare + LibreLane 3.0.14); run dirs
`~/asic-runs` (outside git). Details: `concepts/pdk-toolchain.md`.

Waveforms: every TB writes a VCD into `sim/` (untracked — they churn on each
run; `git add -f sim/*.vcd` restores them to the repo if wanted).

## Gotchas learned the hard way

1. **LibreLane's `--dockerized` wrapper cannot auto-enable the IHP PDK** — it
   reports "PDK ihp-sg13g2 was not found" even when `~/.ciel/ihp-sg13g2` resolves
   and `config.tcl` exists. Workaround: invoke the container directly with
   explicit `-p ihp-sg13g2 -s sg13g2_stdcell` (command above). The smoke test and
   `--run-example` paths work, plain config runs do not.
2. **pip-only LibreLane is unsupported** (needs Nix or Docker); `--docker-no-tty`
   is required in headless shells.
3. **volare family name uses an underscore** (`--pdk ihp_sg13g2`) and needs an
   explicit version from `volare ls-remote`.
4. **GCC 16 breaks the stock volare/librelane pip install** (pybind11 C++ level
   probe): `pip install --upgrade pybind11 setuptools wheel`, then
   `CXX=g++ pip install --no-build-isolation volare librelane`.
5. **yosys `PROC_DFF` rejects `if (!rst_n || clr)`** — an async reset OR'd with a
   level signal ("multiple edge sensitive events"). Use a separate synchronous
   clear branch.
6. **Single-cycle event pulses get missed** in TBs behind trailing protocol
   timing (stop bits, EOF, ACK slots) — use sticky flags, exactly as the core's
   interrupt logic will.
7. **TB sampling order**: combinational stages (stuff/manch) are valid *before*
   the committing strobe; a registered stage (NRZI line level) only *after* it.
8. **A TB model must mirror the DUT's state machine** — the CAN/USB destuffer
   resets its run counter after the stuff bit, not on the 5th identical bit.
9. Non-interactive shells emit `stty`/`tcsetattr` noise and a bashrc `sort -hn`
   error — cosmetic; check the payload's real exit status.
10. **A testbench that "waits for" an event it may have already missed tests
    nothing.** `tb_pe_soc_uart.v` sat red for hours because `@(negedge tx_pin)`
    ran after the echo was already in flight (the firmware answers the moment it
    has the byte, and RX/TX are separate pins), so it anchored on the *last data
    bit* and every byte decoded shifted. Latch the edge in an `always` monitor,
    then anchor the sample grid to the latched time. Same class of bug as the
    sticky-flag lesson (gotcha 6) from Milestone 1.
11. **The emulator is the fast loop, and it must mirror the RTL's cycle model —
    including when they disagree.** `tools/fw/peemu.py` reproduced the UART byte
    correctly while the RTL TB failed; that asymmetry was the clue that the bug
    was in the TB/firmware, not the CPU. Keep both, and treat a disagreement as
    a signal, not an inconvenience.
12. **A simulator's resolution of illegal RTL is not the synthesiser's, so a
    green testbench says NOTHING about the netlist.** Two drivers on one flop
    raced in Icarus and became a constant 0 in yosys. A hierarchical reference
    (`assign dbg_pc = u_cpu.pc`) simulated fine and was driven backwards into an
    implicit wire by yosys. Neither is reachable by any testbench. `regress/lint.sh`
    is the only thing that can catch this class, which is why it is in
    `run_all.sh` and not a thing you remember to run.
13. **A tool whose warnings you discard is not a check.** `synth_area.sh`
    captured yosys's entire output and grepped it for numbers, so both defects
    above were printed on every single run for a whole milestone and never read.
    If a script captures output, it owes the reader a decision about the parts
    it did not use.
14. **Hardware nothing exercises is hardware you have not tested.** The STATUS
    port had no firmware reading it, so its flop could be a constant and the
    regression stayed green. When you add a peripheral, add the program that
    uses it (`firmware/tick_count.pe`) in the same change.
15. **A test that only checks the output cannot see broken bookkeeping.** The
    UART echo path reads slot 15, so a receive-buffer write pointer that never
    advanced (`AND 0x0E` applied to ptr+1 is always 0) passed every byte-level
    test for a milestone. `--expect-buffer` now checks the state, not just the
    bytes.
16. **Silent truncation is the assembler's worst failure mode.** Every field in
    this ISA is narrower than the immediate that fits in it, so `JMP 200`,
    `LDM A, 128` (which re-encoded as `LDM X`) and a 129-word program all
    assembled clean and ran wrong. `tools/fw/peasm.py` now rejects all of them.

17. **A 3-tap majority is not a delay, and the difference is a whole sample.**
    Its output moves one sample later than the centre tap at a level change (it takes
    two agreeing taps to flip). Feeding it straight into `pe_dru`'s edge detector
    shifted EVERY edge by a sample, which moved the phase-6 capture off the half-cell
    centre and captured the wrong LEVEL — for one bit pattern out of four. Fixed by
    resampling the majority before it drives the counter. A test that only asks "does
    the filter remove the glitch" passes in both versions; the defect only shows up as
    wrong data on a pattern the glitch test does not use.
18. **A complement belongs on the wire, not in the feedback.** `pe_crc`'s
    `cfg_out_inv` complements `crc_bit` only. Putting it inside the feedback makes
    `fb == 1` on every field strobe, so the register XORs its mask 32 times while it
    should be draining — and the emitted bits are IDENTICAL either way, so every
    transmit-side check passes. Only the receiver's drain-to-zero distinguishes them.
    When a block feeds its own output back, the output path and the feedback path are
    not interchangeable and must be written as separate expressions.
19. **Error detection is not "the CRC changed".** A payload corrupted BEFORE its CRC
    is computed is a consistent frame and verifies correctly; so is a corrupted frame
    whose CRC field happens to be the corrupted one's. The right test corrupts the
    RECEIVED stream. Asserting the naive version produced 150+ failures that were all
    arithmetic, not defects — the giveaway was that they appeared only in the soak,
    where random payloads made the coincidence common.
20. **An acquisition ambiguity is not a bug when the protocol has a preamble.**
    `pe_dru` cannot label the first captured cell's halves without a transition to
    seed the parity, so the first cell after acquisition may be mislabelled. Every
    Manchester receiver has this property and that is exactly what the 56-bit
    Ethernet preamble is for. The TB drives a lead-in and counts from the payload,
    rather than asserting something no receiver promises.

21. **A hard macro's protocol has traps that a functional test cannot see, and
    its datasheet does not mention them.** `A_BM=0` with `A_WEN=1` is a **silent
    write no-op**: the loader reports success, memory stays blank, and the SoC
    executes NOPs. `A_REN=1` during a write is **write-through** — the read port
    returns the value on `DIN`, not the stored word. Neither is in the datasheet;
    both are visible in the vendor's *behavioural model*, which is the file to read
    before writing a driver. A testbench that only checks "memory remembers a word"
    passes with either bug present, so `tb_pe_imem` asserts the specific protocol
    facts and is mutation-checked against both.
22. **A longer load window is not free, and a test can be passing by accident.**
    Deepening instruction memory from 128 to 1024 words made the loader take 1024
    cycles instead of 128. The timer free-runs from reset, so it now advances ~6
    ticks before the core starts — and `tb_pe_soc_tick` began failing, because
    its "observed ticks == free-running timer" comparison had been true only
    because the old load window (128 cycles) was *shorter than one 173-cycle tick*.
    The test was right by luck, not by construction. When a change alters how long
    something takes, re-read every test whose assumption is about *when*, not *what*.
23. **"Widening the memory" and "widening the address" are separate jobs, and
    doing one without the other buys nothing.** The 1024-word macro was useless
    until the PC and the jump-target field widened: with a fixed 8-bit PC the
    reachable program stayed 256 words and `next_pc[IAW-1:0]` was an out-of-range
    part-select. The plan had explicitly claimed the swap would need no CPU change,
    which was true of the cycle model and false of the address width — a claim can
    be right about one axis and wrong about another, and only re-reading the RTL
    against the new size finds it.
24. **A parameterised block is only tested at the values something actually
    instantiates, and a guard with the wrong bound reads as protection while
    providing none.** `pe_dru`'s guard checked `SPB % 4 != 0`, which was true and
    necessary and incomplete: `phase` is 4 bits and the wrap constant is
    `4'(SPB - 1)`, which **truncates above 16**. At SPB=20 the counter wraps at
    phase 3 instead of 19, never reaches either capture phase, and the block
    **emits nothing at all** — no error, no output, no failing signal. Every
    testbench pinned SPB at its default, so a sweep of the parameter boundary
    (8/12/16 pass, 20/24/32 fail) was the only thing that found it. The bound is
    now an elaboration error and `regress/param_guards.sh` (in `run_all.sh`) requires
    both guards to actually *reject* and both boundaries to actually *compile*,
    so a guard that stops firing fails the build.
25. **A gate invoked mid-script must resolve its paths from a captured absolute
    root.** `run_all.sh` cds into `sim/` and then back to the repo root, and `$0`
    may itself be relative (`./regress/run_all.sh`) — so `$(dirname "$0")` after the
    cd resolved to `.` and `/param_guards.sh`, and the new gate failed while
    passing perfectly when run by hand. The script now captures `REPO_ROOT` once
    at the top and every later gate uses it. **A tool that works standalone and
    fails inside the runner is a path bug, not a logic bug.**
26. **"Within spec" is a conformance test, not a budget to nibble.** The 66 MHz
    turbo was justified for months as costing "±3.8 ns = 7.6% of half-UI — eats
    the 10BASE-T TX jitter budget". Solving the actual requirement (crossings at
    8.0/8.5 BT ±11 ns, on a sliding window) proved no edge placement works at
    66 MHz at all, while **60 MHz is exact with no dither and better on every
    axis**. When a timing claim rests on a tolerance, quote the spec's numbers and
    solve for feasibility before pricing the tradeoff. See [[decisions/adr-005-60mhz-turbo]].
27. **Raising the clock re-prices the HARD MACROS first, not the logic.** The
    logic had slack to spare (2.5 ns worst reg-to-reg against a 7.58 ns
    half-cycle), but the SRAM is a fixed circuit: `A_CLK` -> `A_DOUT` is **7.25 ns
    at the slow corner**, which was 29% of a 25 ns period at 40 MHz and is **43%
    of a 16.667 ns period at 60 MHz**. `pe_imem` deliberately has no output
    register (it would add a second cycle and break the CPU's fetch-ahead), so
    that path is what the SoC STA run must close. The pe_serdes signoff does not
    cover it — that design has no SRAM. Hard macros do not scale with your clock.
28. **A TB that hardcodes the clock period as an INTEGER silently simulates at
    the wrong frequency.** `localparam int CLK_NS = 17` for a 60 MHz target is
    wrong twice over: 60 MHz is 16.667 ns, and `#(CLK_NS/2)` with an integer 17
    rounds the half-period to 8 ns, i.e. **62.5 MHz**. Always derive the period
    as `real` from `CLK_HZ` (`1e9 / CLK_HZ`), and derive the tick count from the
    same expression the RTL uses, so a clock change cannot leave the TB
    simulating one rate while the SoC thinks it is at another.
29. **Never trust a failing test until you have read the failure's own output.**
    A 60 MHz run of `tb_pe_soc_uart` "failed" during this change, and the cause
    was the harness: `vvp` was invoked from `/tmp`, so the TB's relative
    `$readmemh ../firmware/uart_echo.hex` resolved to nothing, the core executed
    uninitialised memory, and it hung like a firmware bug. The `$readmemh`
    warning was in the very output being read. Before diagnosing a design, check
    the run for warnings about the *inputs* it was supposed to load.
30. **A bit-palindromic test vector cannot catch a bit-order bug.** SPI is
    MSB-first and the UART is LSB-first, so "does this firmware shift the right
    way" is the central question for SPI — and the first version of
    `firmware/spi_xfer.pe` sent `0x5A`, which reversed is still `0x5A`. A master
    that shifted LSB-first would have put the **identical levels on the wire**.
    `0x00`, `0xFF`, `0x0F`, `0x3C`, `0x81` and `0xAA` are the same trap. Check
    the vector: `int('{:08b}'.format(b)[::-1], 2) != b`. This is gotcha 14
    wearing different clothes — a test that cannot fail is not a test.
31. **A mutation that cannot change observable behaviour cannot be caught, and
    demanding that it be caught is demanding a lie.** Three SPI mutations were
    built: flipping the MOSI bit order *was* caught (slave saw `80 80 80 80`),
    and driving MOSI after the clock rise *was* caught (slave saw `2D AD AD AD`,
    the previous bit — the classic CPHA error). Sampling MISO *before* the
    rising edge was **not** caught, and that is correct: a CPHA=0 slave presents
    MISO on the falling edge and holds it through the rise, so the sample point
    can be anywhere in the low phase. Before treating an uncaught mutation as a
    coverage hole, check whether the mutation is observable at all. Record the
    ones that are not, so the next person does not re-derive it.
32. **A free-running tick counter cannot measure a fixed delay, and the error is
    one whole tick — not a rounding error.** The tick wait in both firmwares
    snapshots the count and loops until it changes, so it returns after anywhere
    in (0, 1] ticks. For the **UART** that misalignment is the dominant error
    term (it is why a sample can land on a bit boundary; see
    [[concepts/cdr-oversampling]] and `firmware/uart_echo.pe`'s timing note). For
    **SPI** the same jitter is completely harmless, because the slave times
    itself off the SCLK edges we generate — a synchronous link has no baud rate
    to hit. Same code, same jitter, opposite consequences: the protocol decides
    whether clock jitter is a defect.
33. **A hardware macro's power pins are on the macro's own layers, and the PDN's
    straps may be on different ones — `PDN_MACRO_CONNECTIONS` does NOT fix that.**
    The IHP SRAM's `VDD!`/`VSS!`/`VDDARRAY!` straps are **Metal4** and run the
    full height of the macro; `pdngen`'s generated grid is **TopMetal1/TopMetal2**
    with Metal1 rails. `PDN_MACRO_CONNECTIONS` (format `<inst> <vdd_net>
    <gnd_net> <vdd_pin> <gnd_pin>`, one entry **per power pin** — this macro has
    two power pins, so two entries) connects the pins **logically**, and it does
    work: the log prints `<inst> matched with u_imem.g_macro.u_sram`. But a
    logical connection is not a physical path, so `check_power_grid` still
    reported ~50 unconnected Metal4 shapes and `PSM-0069`, and the router —
    free to use Metal4 for signal — **shorted into them**. The fix is a custom
    `PDN_CFG` that stripes the macro on its own supply layer and steps up:
    `add_pdn_stripe -grid macro -layer Metal4` + `add_pdn_connect -layers "Metal4
    $PDN_VERTICAL_LAYER"`. Result, same input ODB: stock config = `PSM-0069
    FAILED`; custom = **`PSM-0040 All shapes on net VPWR/VGND are connected`**.
    See `flow/pe_soc_pdn.tcl`. **Check the macro's LEF layers before
    believing the grid is wrong — and before believing `PDN_MACRO_CONNECTIONS`
    is enough.**
34. **Global-routing congestion at low utilization is a CONFIG derate, not a
    capacity problem.** The full SoC failed `GRT-0116` with 34 overflowed GCells
    at **4.59% total usage** on the real 6x4 die. The cause was `GRT_ADJUSTMENT`:
    LibreLane's generic default is **0.3** (the log prints `[INFO GRT-0022]
    Global adjustment: 30%`) while the IHP PDK ships `GRT_LAYER_ADJUSTMENTS = 0.00`
    for all 7 routing layers — so the PDK's own stated intent is no derate and
    the 30% was an inherited default fighting it. Setting `GRT_ADJUSTMENT = 0.0`
    took the same design to **0 overflow on every layer at 2.88-3.03% usage**.
    When a router fails at single-digit utilization, read the adjustment numbers
    it prints before doubting the floorplan.
35. **A vendor macro's GDSII may not speak the flow's boundary vocabulary.**
    LibreLane's Magic streamout extracts the macro's placement bbox by reading
    the `FIXED_BBOX` property that Magic derives from a **`pblock`** layer, and
    the IHP SRAM GDS ships none: it has `189/4` (the IHP map's `DIEAREA`)
    instead. The flow therefore aborts at the GDS-streamout step with "Failed to
    extract PR boundary from GDSII view of macro ... Ensure that the GDSII view
    has a PR boundary layer" — after routing, RCX, STA and IR drop have all
    already passed. The size the flow wants is not actually missing: the macro's
    **LEF declares `SIZE 236.8 BY 336.46`**. Check the LEF before believing the
    macro is malformed, and do not edit a vendor GDS to satisfy a flow script's
    layer name.
36. **A negative result is only as good as the SCOPE of the search that produced
    it.** I claimed a config comment quoted an OpenROAD warning (`GRT-0704`) that
    "does not exist in any run log", and replaced it. `GRT-0704` is real: it is in
    `RUN_2026-09-22_00-07-27/warning.log`,
    `[GRT-0704] Try reduce the layer adjustment from 30.000002% to 0%` — the tool
    literally recommending the change that fixed the congestion. The check that
    "proved" it absent was `grep -rl` run from the **repo root**, while the run
    logs live under **`~/asic-runs`**. A negative grep bounded by the wrong
    directory returns nothing, and I read "my search found nothing" as "it does
    not exist". Two consequences: (a) before recording that a quote is fabricated,
    make the search cover where the evidence WOULD be, and say in the writeup
    where you looked; (b) a false fabrication-claim is worse than the original
    quote, because it removes real evidence AND installs a wrong lesson.
37. **"Setup and hold close" is NOT "no violations" — max-cap / max-slew /
    max-fanout are SEPARATE checks, and they do fail here.** `RUN_2026-09-22_00-48-35`
    closes timing (setup WNS +1.143 ns, hold WNS +0.121 ns, 0 setup/hold violating
    paths at all three corners, TNS 0.0) and simultaneously reports **10 max-slew,
    8 max-cap and 7 max-fanout violations**, present in every run since the macro
    landed. An earlier summary of mine said "0 violations" for this run; that was
    true of setup/hold and false of the STA as a whole. Always state which check
    you mean.
38. **Some of those violations sit at slew/cap values the SRAM's .lib was never
    characterised for, and OpenROAD extrapolates SILENTLY.** This touches the path
    signed off as closed. Measured axes in
    `RM_IHPSG13_1P_1024x16_c2_bm_bist_slow_1p08V_125C.lib`:

    | axis | table max | what the design presents |
    |---|---|---|
    | input slew (`index_1`) | **0.5952** | `A_DIN[5]` **1.291** (2.2x over), `A_ADDR[0]` 0.961, `A_REN` 0.644 |
    | output cap (`index_2`) | **0.0640** | `A_DOUT[4]` **0.1169** (+83%), `A_DOUT[12]` 0.0680 (+6%) |

    Consequences and levers:

    - **The macro's internal delay is not trustworthy as characterised** at those
      points — the 7.635 ns `A_DOUT[12]` figure is a table lookup taken outside
      the table. Extrapolation usually over-estimates delay and the +1.143 ns
      margin absorbs a lot, but "probably pessimistic" is not a signoff claim.
    - **It is fixable in the FLOW, not the silicon.** The over-slewed drivers are
      `sg13g2_buf_1` (the smallest buffer IHP makes), and `A_DOUT[4]` presents
      fanout 20 against a limit of 10. `repair_design` runs with
      `-slew_margin 20.0 -cap_margin 20.0` and its own log shows it resizing
      **nothing** ("+0.0% ... Resized 0 ... Remaining 1332" all the way down) —
      the 20% margins tell the resizer these are fine. Raising
      `DESIGN_REPAIR_MAX_SLEW_PCT` / `DESIGN_REPAIR_MAX_CAP_PCT` and buffering
      `A_DOUT` is the way to bring the macro back inside its characterisation.
    - **`A_CLK` is fine, deliberately**: 0.051 ns slew, 11.7x inside the limit,
      because it comes off the delay-buffer chain. The critical path's *clock*
      side is well behaved; the *data* and *output* pins are what is over.
    - **`A_DOUT[4]` is the worst for a reason**: `pe_imem` wires `A_DOUT` straight
      to `imem_rdata`, which the CPU reads as the instruction word, so that net
      fans out to every instruction consumer. See [[reference/sram-budget]].

    Slack on the affected paths is comfortable (`A_DIN[5]` +10.27 ns,
    `A_ADDR[0]` +3.70 ns) so nothing is currently failing timing. The finding is
    that the instruction-fetch STA number rests on extrapolated macro timing, and
    the flow has a lever to remove that caveat.
39. **Max-slew/max-cap WARN; they do NOT gate — and I had this wrong.**
    *(Corrected 2026-09-22 evening; the earlier text of this gotcha said the
    opposite, and two runs were analysed on the wrong premise.)*

    Steps 74-75 really were the flow's last word on slew/cap, and they really
    are `Checker.MaxSlewViolations` / `Checker.MaxCapViolations`. But they raise
    **nothing**. The mechanism, read out of `librelane/steps/checker.py`:

        TimingViolations.check_timing_violations():
            for each metric corner:
                if corner matches a config wildcard -> err_violating_corner
                else                                -> warn_violating_corner

    and the two subclasses ship `corner_override = [""]` — **the empty string
    matches no corner** (the class docstring says exactly this: *"The default
    value is [""] which indicates matching no corners"*). So every corner lands
    in the warn list, `err_violating_corner` stays empty, and no
    `DeferredStepError` is raised. Confirmed in the run's own resolved config:

        MAX_CAP_VIOLATION_CORNERS  = ['']
        MAX_SLEW_VIOLATION_CORNERS = ['']
        TIMING_VIOLATION_CORNERS   = ['*typ*']   <- setup's var
        HOLD_VIOLATION_CORNERS     = ['*']

    **The log prints both lines together, which is what misled me:**

        Max Slew violations found in the following corners:   <- the WARN list
        * nom_fast_1p32V_m40C / * nom_slow / * nom_typ
        No max slew violations found                          <- the ERROR list

    The second line is not a contradiction of the first — it means
    `err_violating_corner` is EMPTY, i.e. "no corner met the gate". A checker
    that can only warn is not a gate, and `"No X violations found"` here is the
    *error* verdict, not a claim that no violations exist. The counts are real
    and in `final/metrics.json`: **8 max-cap, 10 max-slew, 7 max-fanout**.

    **What the flow actually deferred, in both runs, was only the DRC:**
    `1113909 Magic DRC errors found. - deferred` and `2672 KLayout DRC errors
    found. - deferred`. Nothing else. So LibreLane reached step 76/80 in both
    runs — the run ends because of DRC, full stop. (`error.log` is those two
    lines, **85 bytes**, not empty. An earlier revision of this gotcha said
    "empty", which was a reading taken mid-run and never re-checked. The same
    class of error as gotchas 37-39: a plausible claim standing in for reading
    the file.)

    To turn these into real gates, set
    `MAX_SLEW_VIOLATION_CORNERS`/`MAX_CAP_VIOLATION_CORNERS` to `["*"]`.
40. **1,113,909 Magic DRC + 2,672 KLayout DRC errors, and 100% of BOTH are inside
    the vendor SRAM macro.** Established by parsing, not assertion: every
    coordinate in `drc.magic.rpt` compared against the macro's placed footprint
    (x 10..246.8, y 10..346.46 µm) gives **1,113,909 inside, 0 outside**, with
    rules that are library-internal artefacts (`Cnt.c` 880,232; `LU.b` 104,724;
    `Gat.c` 104,737; `M2.d` 59,165). KLayout on the PDK's own 174-rule deck fires
    only **4 rules**, dominant pair `Sdiod.d`/`Sdiod.e` — **ContBar inside
    nBuLay, an ESD-diode rule** — in a design that instantiates no diodes. Every
    one of the 2,672 KLayout items names an `RM_IHPSG13_*` or `RSC_IHPSG13_*`
    cell, and `RSC_IHPSG13_*` is in **neither** the design's `sg13g2_stdcell`
    library **nor** the SRAM's LEF, so it exists only inside the SRAM's GDS.
41. **`MAGIC_GDS_FLATGLOB` exists for exactly this and is unset.** LibreLane's
    docstring: "Flatten cells by name pattern on input. **May be used to avoid
    false positive DRC errors.**" With an SRAM-name glob that is the sanctioned
    route, and better than disabling DRC. The other knob is `MAGIC_DRC_USE_GDS`
    (default true; false checks the DEF view, "less accurate as some DEF/LEF
    elements are abstract"). See gotcha 43 before using either.
42. **LVS PASSES on the same layout — "Circuits match uniquely", 1926 devices and
    1939 nets on both sides** (`70-netgen-lvs/reports/lvs.netgen.rpt`; the flow's
    step 71 `Checker.LVS` reports "Check for LVS errors clear"). This is the
    independent evidence that those DRC errors are geometric false positives
    inside the vendor cell rather than a construction defect: netgen compared
    layout against netlist and found them identical device for device, and a
    genuinely mis-built macro would very likely fail LVS too. Note the
    power-grid checker's message is itself conditional — "you may ignore these
    if LVS passes" — and LVS passes.
43. **A DRC failure inside a third-party macro is not automatically real OR
    ignorable — the test that distinguishes them is running the PDK's own deck
    on the macro ALONE.** Fails alone ⇒ the finding is the PDK/vendor's and an
    exclusion list is justified *with evidence*. Passes alone ⇒ the failure is
    introduced by composition and it is ours. **Do not silence DRC merely because
    LVS passed:** LVS checks connectivity and device identity, DRC checks
    geometry, and a cell can be electrically perfect while violating a spacing
    rule.
44. **THE VERDICT ON THE MACRO DRC, and it is not ours.** Ran the PDK's own
    `run_drc.py` on the SRAM macro **ALONE**, `--run_mode deep` (the same mode
    LibreLane uses), and diffed rule-by-rule against the full SoC:

    | rule | macro alone | full SoC | verdict |
    |---|---|---|---|
    | `Sdiod.d` | 1136 | 1136 | **identical** |
    | `Sdiod.e` | 1136 | 1136 | **identical** |
    | `Cnt.c.digibnd` | 400 | 400 | **identical** |
    | `M5.j` / `M5Fil.h` / `TM1.c` / `TM2.c` | 1 each | **0** | our fill/PDN fixed them |
    | **total** | **2676** | **2672** | |

    **2,672 of 2,672 SoC violations are reproduced EXACTLY by the vendor macro
    standalone; ZERO are introduced by assembling the SoC.** The vendor's own
    flow even prints `❌ KLayout DRC Check Failed` on the macro by itself. So the
    finding is the PDK's, and an exclusion is justified **with evidence** rather
    than assumed. Note the SoC is *cleaner* than the macro alone — the four
    1-count BEOL rules the macro fails are fixed by our PDN + fill.
45. **This is a known class, corroborated two ways.** (a) IHP's own
    `ihp-sg13g2-librelane-template` issue #19 reports the vendor's reference
    design — **which contains no SRAM at all** — completing `make librelane`
    with `1697 Magic DRC errors`, `40 KLayout DRC errors`, `[RSZ-0020] found 4
    floating nets`, and **`Checker.MaxSlewViolations` / `Checker.MaxCapViolations`
    firing in the same corners we see**. Those are deferred errors the flow
    collects and reports at the end, exactly as ours are. (b) Tiny Tapeout's
    memory page documents the IHP SRAM macros as supported for IHP shuttles and
    points at a taped-out, tested 1024x8 SRAM project — i.e. the community route
    to using these macros exists and is sanctioned.
46. **What this does NOT license.** The macro DRC being the PDK's does not make
    the *max-slew / max-cap* violations go away — those are on SRAM **pins** as
    driven by *our* routing (`sg13g2_buf_1` drivers, `A_DOUT[4]` at fanout 20),
    and they are gated by steps 74-75. Gotchas 37-39 stand unchanged. Fixing the
    slew/cap means `DESIGN_REPAIR_MAX_SLEW_PCT` / `DESIGN_REPAIR_MAX_CAP_PCT`
    plus buffering `A_DOUT`, which is our work, not the PDK's.

47. **Keep architecture and progress diagrams separate.** The editable block
    diagrams live in `diagrams/project-plan.puml` and
    `diagrams/project-progress.puml`. Update the plan view after scope or topology
    decisions, and the progress view after implementation or verification changes.
48. **A checker that re-implements the code under test cannot detect its bugs.**
    Behavior checks should exercise the shipped implementation and demonstrate
    that meaningful mutations make the check fail. A guard that cannot fail is
    indistinguishable from one that passes.
49. **Beware repr/JSON escaping when matching source text.** Three patch
    attempts failed on the line containing `if(VIEW.mode === 'fit')` because
    every `repr()`/JSON view of it renders the single quotes with a leading
    backslash -- display escaping that is **not in the file**. I chased that
    phantom backslash through three anchors that could never match. Reading the
    file as **bytes** (`b.find(b"VIEW.mode ===")`) settled it in one command.
    When an anchor will not match, look at raw bytes before rewriting it again.
50. **A "wait for the counter to change" delay is a PHASE-ROBUSTNESS bug, not a
    style choice.** `uart_echo.pe` and `spi_xfer.pe` poll a free-running tick
    counter for a change, which delivers `(0, 1]` ticks -- up to a full tick
    short. Harmless for SPI (synchronous, the slave times off our edges) and a
    sampling-margin cost for the UART. For I2C it is a **spec violation**: tLOW
    is measured at the pin against a 4.7 us floor, and the first draft of
    `firmware/i2c_pins.pe` took 1,384 cycles for 28 us of nominal delays
    (0.83x). It would have passed a bench test. Wait for an exact TARGET instead
    (`IN` / `ADD A, N` / `MOV X, A` / spin `SUB A, X` / `JNZ`).
51. **An N-tick wait delivers (N-1, N] us, so the number that must clear a floor
    is N-1.** Firmware cannot see where in the 60-cycle window a read lands
    (`0 <= phi < 60` cycles), so the target tick is `60*N - phi` cycles away.
    Constants must be chosen for the worst case: tLOW uses 7 ticks (worst case
    6 us vs a 4.7 us floor), not the 5 that looks compliant nominally. Also --
    give the larger count to the larger FLOOR: tLOW (4.7) gets 7 and tHIGH (4.0)
    gets 6. The period is `tLOW+tHIGH` either way because the waits chain in
    target form, so the swap costs nothing and rebalances the margins.
52. **Open-drain prevents CONTENTION, not a wrong-moment drive.** The OD bit
    makes "drive high into someone else's low" inexpressible, which is the
    destructive fault. It does not stop the pin driving LOW at a bad moment:
    the first draft of `i2c_pins.pe` wrote `PINOE` before `TXPIN`, and since the
    reset output register holds `0x01`, bits 4-5 were still 0 -- SDA pulled low
    for two cycles with SCL high, which **is a START condition**. So the init
    order is OD, then OUT, then OE. Same class: pulling SDA low while SCL is
    high on the way into a STOP emits a second START. Grammar bugs like these
    leave every timing interval compliant, so a timing-only check cannot see
    them -- assert the SEQUENCE too.
53. **In Verilog, a negative `time` difference wraps, and a `>=` check on it
    passes.** The I2C TB computed `tHIGH` as `scl_fall_t[1] - scl_rise_t[1]`, a
    NEGATIVE difference; `time` is unsigned, so it wrapped to ~1.8e19 and
    satisfied `tHIGH >= 4.0` forever. Its partner check was equally unfailable
    (tLOW measured the idle stretch at 19 us). Two assertions that could never
    fail, in a TB that passed. Pair every `>=` interval check with a "plausibly
    the right measurement" upper bound, and mutation-test the TB itself -- that
    is what surfaced both. See also gotcha 48.

54. **A trace that prints at `posedge clk` shows a MIXTURE of old and new
      state, and it will accuse the design of a bug that does not exist.** Two
      registers updated by the same edge -- `pc` and the instruction ROM's
      registered `A_DOUT` -- mean a `$display` with no delay can print the new PC
      beside the PREVIOUS instruction. It reported `OUT` executing with `a=00`
      instead of `0x04`, which reads exactly like a CPU bug. Sample one time
      step AFTER the edge (`#1`) and each line is a consistent snapshot of one
      cycle. Same family as gotcha 53: the hardware was fine, the observer was
      reading at the wrong instant.

55. **A registered ROM needs an edge to load before the CPU is released.**
      While the loader owns the bus, `pe_imem` holds the macro's read-enable
      LOW, so `A_DOUT` is frozen. Dropping `host_we` starts a read that needs one
      more edge before it holds `imem[0]`; releasing `run` in the same instant
      makes the CPU decode a STALE instruction at `pc=0`, so the FIRST
      instruction never executes and the PC lands on `imem[1]` with the reset
      value still in `A`. The symptom was two misleading failures at once (an
      INIT write landing as 0x00, and a slave counting frames it should not
      have). `tb_pe_soc_uart` already had the required four-clock gap -- its
      comment never said why, which is how the requirement stayed invisible.

56. **A slave model needs a LEVEL, not an edge, and the pin may already be
      asserted at reset.** The SoC drives CS_N low from reset (`RST_OUT` bit 2
      is 0), so a model arming on the CS_N FALLING edge never sees one and never
      arms -- while still reporting the frames it did catch, which makes the
      failure look like a one-frame lag in the master. Model selection off the
      LEVEL, and give a released pin a pull-up so an unselected slave reads as
      deselected rather than as a low.

57. **Verilator is 2-state, so `=== x` stops meaning anything under it.** An
      unassigned or `x`-literal signal becomes 0 silently. Measured: 12.7x (SPI)
      and 18.9x (I2C) faster than Icarus, with a ~300x more expensive build and
      a break-even near 27 runs -- and on the current five SPI mutations it
      detects exactly the same ones with identical FAIL counts. But a future TB
      that relies on `=== x` to catch an undriven net would stop testing if it
      were only ever run under Verilator. Keep the 4-state simulator for
      signoff. See [[reference/simulator-bakeoff]].

58. **A per-run speedup does not compose into a suite speedup, and the sign can
      flip.** Verilator is 12-19x faster per simulation and made `run_all.sh`
      **69.6x SLOWER** (2.40 s -> 167.19 s) because it builds per `--top-module`
      with no shared cache: 24 one-shot testbenches pay 24 builds at a median
      5.6 s. The per-run win is only realised after ~27 runs of the SAME
      testbench. So `--fast` is PARALLEL ICARUS, not a simulator swap -- the same
      4-state simulation. Verify a fast path on the FAILING case too, not only
      the passing one: `--fast` was checked to produce identical verdicts on
      all 24 then-current TBs and identical diagnostics plus exit code 1 on an
      injected fault.

 59. **Check whether a testbench can run under a 2-state simulator AT ALL before
      planning a flow around it.** `tb_pe_pinmux` aborts Verilator with
      `%Error-DIDNOTCONVERGE` because it models the bus at STRENGTH LEVELS
      (pull-up vs strong 0/1) to test the `od` bit's contention property, and
      2-state has no weak/strong distinction. This is gotcha 57's problem in a
      louder form: there it silently weakens a check, here it stops the run. A
      survey of the then-current 24 TBs under both simulators found 21 agreeing,
      one differing, and three using X-dependent constructs; these categories
      overlap. This is the cheap way to find out before wiring anything.

60. **`expect` is a RESERVED WORD in Icarus, and the error message does not say
      so.** `integer expect;` fails with "Syntax error in variable list" and a
      cascade of errors at unrelated line numbers (a `$sformatf` two statements
      later, a bare `100[AW-1:0]`). It is reserved for the SVA grammar, in a file
      that uses no assertions at all. Two other Icarus limits bit this file the
      same way: `integer a, b;` (one name per declaration) and a bit-select on a
      literal (`100[AW-1:0]`) are both rejected. When a compile produces a
      cluster of syntax errors at lines that look fine, bisect the file by
      truncation rather than reading -- the reported lines are symptoms.

61. **A mutation touching ONE implementation can only be caught by that
      implementation.** `regress/mutate_fbuf_tb.sh` first required both the macro and
      the FLOP path to fail, which reported three genuine detects as "survived".
      What matters is that a mutation is caught SOMEWHERE, plus that the TB is
      non-vacuous on each path (which a baseline PASS establishes). But keep the
      per-path result in the output: a mutation touching both paths while only
      one notices is the shape of a real blind spot.

62. **Test the PIPELINED access, not just the idle one.** Mutation testing found
      that `tb_pe_fbuf`'s read checks all held their address stable across the
      whole access, so replacing the registered lane with the LIVE address lane
      passed every one of them. In a real frame walk the address changes every
      cycle, and then the registered lane and the live one differ on every
      iteration. Sample mid-cycle (after presenting the next address, before the
      data latches) and check the byte still belongs to the OLD address. A memory
      with one cycle of read latency is only tested by requests that overlap.

63. **A mutation harness that restores with `git checkout` DESTROYS an untracked
      file.** `regress/mutate_eth_mac_tb.sh` was written that way while
      `rtl/pe_eth_mac.v` was brand new and untracked, so every restore failed
      with "did not match any file(s) known to git", all eight mutations stacked
      on each other, and the harness printed "8 detected, 0 survived" -- a
      perfect score that meant nothing. Snapshot the file with `cp` into one
      temp path and restore from that, and verify the restore with `cmp` after
      EVERY mutation. Commit new RTL before pointing a mutation harness at it.

64. **A preamble is a WIRE BIT PATTERN, not an octet.** The standard says "seven
      octets of the pattern 10101010", which reads as 0xAA; but a byte helper
      sends LSB-first, so `send_byte(8'hAA)` puts 01010101 on the wire -- the
      inverted phase. The junction with the SFD then creates a SECOND, false
      0xD5 window seven bits early, the receiver locks there, and every byte
      comes out as a mash of its neighbours. It looks exactly like a broken
      receiver. The preamble is 1010... starting with 1 (equivalently 0x55 in
      LSB-first octet terms) and must be driven as a bit pattern. The SFD (0xD5)
      is the one everyone remembers, which is why only the SFD gets the
      treatment.

65. **Enumerate an ambiguous window numerically; do not derive it by hand.**
      The SFD lock was mis-analysed twice. Hand-deriving "which 8-bit windows
      assemble to 0xD5" produced the opposite conclusion each time; enumerating
      the 64-bit prelude in code settled it in one line: 0xD5 occurs ONCE, and
      an alternating preamble can only produce 0x55/0xAA. That also showed an
      "alternating run must exceed N" guard was not merely unnecessary but
      harmful -- it would drop frames a receiver that locked late would otherwise
      catch. A window-matching question is a computation, not a proof sketch.

66. **An unsized `'0` in a ternary arm silently truncates an arithmetic result.**
      `wptr <= wptr - (is_type ? FCS_BYTES : '0)` made the subtractor's width
      come from the ternary rather than from `wptr`, because the unsized `'0`
      elaborated one bit wide. Symptom: `wptr` went X after the first frame and
      later frames mis-classified. Same family as the out-of-range part-select
      (`FCS_BYTES[AW:0]` on a 3-bit constant, which Icarus resolves to X and
      which poisoned `room` from the second frame on). Write arithmetic as a
      plain `if`/`else` with explicitly sized operands, or zero-extend with a
      sized replication -- never a mixed-width ternary.

67. **Idle is the equal-halves property, and neither `rx_err` nor `locked` can
      report it.** Measured on a held line: the DRU emits cells with
      `rx_first == rx_second`, while BOTH `pe_manch`'s `rx_err` and `pe_dru`'s
      `locked` stay 0. `rx_err` is strobe-gated and `locked` counts well-formed
      cells from a counter that equal-half cells do not feed, so neither marks an
      idle line. A 10BASE-T receiver needs carrier sense to know an
      inter-frame gap has passed, and the only reliable source is the halves
      themselves. Three different signals were tried as the idle indicator before
      measuring; measure the signal before designing around it.

68. **A receiver that aborts a frame must not keep hunting inside it.** Without
      an inter-frame gate, the aborted frame's remaining payload contains 0xD5
      windows, one of which locks the receiver into a phantom frame -- measured,
      and it made a single rejected frame report `frame_bad` twice. IEEE 802.3's
      96-bit inter-frame gap is the rule the gate implements, so require idle
      before hunting. The gate must be a LATCH (armed by idle, cleared on lock,
      not a live `idle_run >= N` comparison), because the preamble is itself 56
      VALID cells and a live comparison drops to false exactly when the SFD
      arrives.


69. **A section anchor that appears in your own prose matches the PROSE.** A script
      rewriting STATUS.md did `t.index("## Next steps (ordered)")` right after
      inserting a header that *mentioned* that section by name -- so the anchor
      matched at line 11 instead of the heading at line 1090, and the write deleted
      **1,149 of 1,171 lines**. Caught by `git diff --stat` before committing. When
      rewriting a document programmatically: match headings with `^`-anchored regex,
      assert the matched region is the size you expect, assert the file is still
      plausibly long before writing, and check the diff stat. `git checkout --` is the
      recovery, which only works if the file was committed.

70. **Date entries with `date`, never by assumption.** The wiki accumulated pages
      dated 2026-09-23 and 2026-09-24 while the actual date was 2026-09-22 -- every
      commit confirms it. Long sessions crossing midnight make "today" feel obvious
      and be wrong, and a future-dated page sorts as more current than the work it
      describes. It also broke nothing, which is why it survived: no gate reads a
      date. Run `date` and paste the answer.

71. **The log is the first artifact to rot, because nothing checks it.** Five commits
      landed (`ecfd480` through `76d54f8`) with no log entry, each one feeling like
      "still in progress" at the time. The code, the TBs and the drift gates all
      stayed honest; only the narrative went stale. The same sweep found `index.md` 10
      pages behind and the "Next steps" list showing three COMPLETED items as pending
      -- which is the worst version of the failure, because a resume-here document
      that lies about what is pending sends the next session to redo finished work.

72. **Fixing a GENERATED page fixes nothing -- edit the generator.** Four wikilinks
      in `wiki/reference/clock-arithmetic.md` carried a `.md` suffix while 308 of the
      wiki's 312 links are extensionless. Patching the page appeared to work and then
      silently reverted on the next regeneration, because the strings live in
      `tools/gen/clock_arithmetic.py`. Symptom to recognise: a file that is unchanged
      in `git diff` after you edited it. The drift gate did not catch it either -- a
      gate compares generated text against generated text, so a wrong constant in the
      generator is self-consistent and invisible. Generated docs are only as honest as
      their generator.

## Open questions / risks

- **IHP-specific max pad clock is unpublished.** The ~66 MHz figure is sky130
  pad-macro-derived. Signing off at 66 gives margin if the real limit is lower.
- **No SRAM compiler for sg13g2** — only fixed macros (30 shapes). Sizing is in
  [[reference/sram-budget]]; the choice is made in [[decisions/adr-003-memory-plan]].
  Note the granularity trap: **1.5 KB cannot be bought.** The two 1 KB parts miss a
  1,518-byte Ethernet frame by 494 bytes, so the practical floor for a frame buffer
  is 2 KB.
- **Tile size discrepancy**: blog says ~200×150 µm/tile, the TT template's
  `info.yaml` says ~167×108 µm. Use the template for layout math; re-check after
  the first real floorplan of the full design.
- **The blog is a LIVING DOCUMENT and must be re-checked.** It states it will be
  updated if 8×4 becomes available, and that sign-ups will be emailed. The repo's
  first capture of it was a summary that got the tile count wrong and stood for
  three days. Re-fetch and diff
  [[raw/articles/janestreet-competition-blog-fulltext]] periodically; its
  frontmatter carries the sha256 of the HTML as fetched on 2026-09-20.
- **No host data path exists.** The SoC's `host_*` port is firmware loading only and
  `rtl/tt_um_protocol_emulator.v` ties it off. If Ethernet or a logic-analyser mode
  wants to stream to a host, that is unbuilt and unplanned, and it needs a decision
  record BEFORE the pin matrix fixes pin assignments ([[concepts/ethernet-scope]]).
- **The `~66 MHz` ceiling and `--docker-no-tty` wrapper bug** are both worth
  confirming with TT/Jane Street (Discord / asic-competition@janestreet.com).

## Next steps (ordered)

**This is the live work list**, rewritten 2026-09-22: items 4, 5 and 6 of the
previous revision had all been completed while the list still showed them pending,
which is exactly the rot that makes a resume-here document untrustworthy.

**The blog's baseline is done and demonstrated in simulation.** UART, SPI and I2C all
run as firmware on real RTL, each with a testbench that does not know how the firmware
works. 10BASE-T receive exists as hardware. Nothing below is required to satisfy the
competition's stated baseline; the list is ordered by what de-risks the *submission*.

### 0. Review follow-ups — DONE

The earlier check passes are resolved: `reviews/2026-09-22/REVIEW.md` (nine
findings), `reviews/2026-09-22/REVIEW-2.md` (seven), `reviews/2026-09-23/FIX-VERIFICATION.md`
(F1 structure, F2 USB config), and `reviews/2026-09-23/F1-F2-RECHECK.md` (F3 CAN
preset, now `0x51`/`0x01` in the generator and reference, with a permanent
`tb_pe_codec_mux` check). The subsequent refactor review at `6de2a6a` found no
new functional defect; its fresh verification and source comparisons are in
`reviews/2026-09-23/REFACTOR-REVIEW.md`. Start at step 1 below.

### 1. Wire `pe_eth_mac` into the SoC — DONE 2026-09-23

The chain (`pe_dru` -> `pe_manch` -> `pe_eth_mac`, with `pe_crc` and `pe_fbuf`)
is instantiated inside `pe_soc`, the RX pin is port bit 7 (the TT wrapper maps
`ui_in[2]` to it), and the frame window is firmware-visible on IO `0x8-0xE`:
`ETHSTAT` (sticky valid/bad, clear-on-read), `ETHLEN(H)`, `ETHFLD(H)`, `BUFBYTE`
(a read walks the buffer) and `BUFCTRL` (reclaim). `firmware/eth_rx.pe` polls
the window, records the header in dmem and sums every payload byte. A real FCS
proves the walk: `tb/tb_pe_soc_eth.v` drives raw Manchester levels for two ARP
frames and a bad-FCS frame and checks firmware's dmem, and
`regress/mutate_eth_soc_tb.sh` breaks the window eight ways and requires every
one to be caught. The frame buffer is no longer an orphan; `pe_serdes` and
`pe_codec_mux` landed in `pe_soc` on 2026-09-24 (item 7), so nothing built
remains unwired. See [[concepts/ethernet-receive-path]].

### 2. `pe_ctrl` — the SPI load path — DONE 2026-09-23

Ruled and built: a **passive SPI slave**
([[decisions/adr-007-pe-ctrl-passive-slave]]) in `rtl/pe_ctrl.v`, between the
three loader pads (`ui_in[3]=SCLK`, `[4]=MOSI`, `[5]=CS_N`) and the SoC's
existing host write port. Mode 0, MSB-first 16-bit words; `CS_N` low resets the
word address and enables, every 16 rising SCLK edges writes `imem[addr++]`,
`CS_N` high ends the load and discards a partial word. All receive and write
paths are `run`-gated: a word queued when `run` rises is **aborted** (discarded,
`load_error` latched, `host_we` masked), so it cannot write during execution or
reappear stale when `run` falls. `tb_pe_ctrl` proves the protocol and the three
run-transition windows; `tb_tt_um_protocol_emulator` loads five words through
the pads and executes them; `regress/mutate_ctrl_tb.sh` is 11/11. See
`reviews/2026-09-23/PE-CTRL-RESOLUTION.md`.

### 3. I2C transaction layer — DONE 2026-09-23

`firmware/i2c_xfer.pe` (311 words) runs **one full master transaction**: START,
`0xA0` (addr 0x50 + W), ACK, `0xA5`, ACK, repeated START, `0xA1`, ACK, read
`0x5A`, NACK, STOP. Verified twice, independently: `tools/checks/i2c_xfer_check.py`
runs it on the emulator against a byte-level slave model across all 60 tick
phases, and `tb/tb_pe_soc_i2c_xfer.v` runs it on real RTL against a Verilog
slave FSM, asserting the bytes, the ACKs, the grammar and the standard-mode
floors on the pads (tLOW 6.00 us, tHIGH 5.98 us, period 11.98 us).
`regress/mutate_i2c_xfer_tb.sh` mutates the firmware eleven ways; all eleven are
caught. The pin-level half remains `firmware/i2c_pins.pe` (79 words); the
concept page and the traps are in [[concepts/i2c-on-the-matrix]].

**Review-focus gaps closed 2026-09-23:** arbitration loss now releases both
lines immediately and aborts **without a STOP** (outcome `dmem[6]=1`; there is
no STOP-qualified bus-free wait and no retry); an
unexpected address/data NACK records an outcome code (`2`/`3`/`4`), issues a
STOP and aborts; and SCL is read back after every release so a stretching slave
is waited on. All three have emulator (60-phase, plus a transient-contention
arbitration case) and RTL tests, and
`regress/mutate_i2c_xfer_tb.sh` is **11/11**. The remaining I2C limit is that
an abort parks — there is no automatic retry or bus-free qualification — plus
no real device or fast
mode. See [[concepts/i2c-on-the-matrix]] and
`reviews/2026-09-23/I2C-TRANSACTION-REVIEW.md`.

### 4. Reclaim or commit the six `uo_out` pins on `dbg_pc[0..5]` — DECIDED 2026-09-23

**Decision: keep them, for now.** `tt_um_protocol_emulator` leaves `uo_out[7:2]`
as `dbg_pc[5:0]`. Rationale:

- **The pad budget does not threaten the realistic cases — but "all nine at
  once" does NOT fit.** UART, the loader, `run`, the heartbeat, I2C and the SPI
  MOSI/CS pads and these six debug pins commit **18 of 24** usable pads. All
  nine protocols need **22 disjoint wires (10 out, 5 in, 7 bidir)**; with the
  debug pins kept only 6 pads are free (short 9), and even reclaiming them
  leaves 12 free against the 15 remaining wires — short 3: the 3 remaining
  inputs take the 2 free `ui_in` pads plus one `uio`, the 5 bidirectional wires
  need 5 `uio` but only 3 are left (2 bidir pads missing), and `uo_out`'s 6
  supply 6 of the 7 outputs (1 missing).
  Shedding `run`, the heartbeat and debug *and* reusing the loader's pads still
  leaves 10 outputs for `uo_out`'s 8 plus one spare `uio`: **one output
  short**. The direction-aware table is in [[reference/protocol-pin-budget]];
  the old "23 of 24, still fits" figure there had an arithmetic error
  (UART+SPI is 6 wires, not 7) and ignored the boot/debug overhead.
- **There is no readback path.** `pe_ctrl` is a passive slave with no MISO, so
  the visible PC is the only live observability on silicon; a loaded program
  that walks the PC is how bring-up distinguishes running from silent.
- **Reclaiming has no consumer yet.** It would need a wrapper/pinout redesign;
  the free `uio` pads already give the matrix four runtime-direction pins
  (`uio[7:4]`).

**Revisit trigger:** reclaim them when a protocol needs the pads and the free
`ui_in`/`uio` pins are exhausted, when a `pe_ctrl` readback path lands, or at
submission pinout freeze. The rationale is recorded in the wrapper header.
Resolved 2026-09-23: SPI's MOSI and CS_N now have pads on `uio[2]`/`uio[3]`
(matrix-gated, push-pull), verified pad-level in `tb_tt_um_protocol_emulator`
([[plans/spi-pads]]); `uio[7:4]` remain free. The debug pins are still not the
place to reclaim from first.

**Update 2026-09-24:** the A1 readback landed on `uio[4]`, so the committed
count is now **19 of 24** (not 18) and **`uio[7:5]`** are the free uio pads;
the "a `pe_ctrl` readback path lands" revisit trigger has fired.
[[plans/eth-tx-frame-path]] (planning only, manager adoption pending)
recommends reclaiming `uo_out[2]` (`dbg_pc[0]`) as the 10BASE-T `eth_tx`
output, muxed so reset stays bit-identical; RX stays on `ui_in[2]`.

**R1 update (later the same day):** the framed host bus supersedes A1 -
`uio[4]` is now host `CS_N` and the whole `uio[4:7]` row is the lower-PMOD
host SPI (CS_N/MOSI/MISO/SCK); `uo_out[1]` is `IRQ_N` (the heartbeat pad is
retired to a future R2 STATUS field) and `ui_in[3:5]` are freed. The
committed count stays 19 of 24; the free pads are `ui_in[3:7]` (5) with no
free `uio`. The Task-7 `uo_out[2]`-reclaim recommendation for `eth_tx` is
unaffected (it was baseline-independent), but the eth-tx plan's A1-era pad
notes need this R1 map when that plan is next revised (manager-owned).

**Task-10 amendment (2026-09-24):** recorded at plan adoption — under this R1
map the G6 default stands exactly as written (reclaim `uo_out[2]` = `dbg_pc[0]`
as `eth_tx` behind the reset-bit-identical `pin_oe_bus[7]` mux) and the
free-`uio` alternative is void. The wrapper mux is plan Task 4, so plan
Tasks 1-3 landed the engine and the SoC integration only and left
`rtl/tt_um_protocol_emulator.v` untouched.

### 5. Full-chip floorplan against the real tile allocation — FEASIBILITY DONE 2026-09-23

Read-only feasibility is documented in [[reference/floorplan-feasibility]],
generated from the PDK LEF, `flow/pe_soc.json` and the measured synthesis cache
(`tools/gen/floorplan_feasibility.py`, drift-gated in the regression):

- The design is two `1P_1024x16` macros (236.8×336.46 µm each, 159,347 µm²
  total) plus `tt_um_top`'s current 62,745 µm² of logic (3,888 cells). With the
  SERDES-derived ×1.69 routing inflation that is ~265,666 µm²: **61.4%
  occupancy on the template 6×4 die**, 36.9% at the blog's larger tile, 46.0%
  on the 8×4 upside. This arithmetic was refreshed after the MAC ownership fix.
- **Area is not the open question; the pad ring is.** The existing signoff is a
  padless core (`DIE_AREA` only, no `CORE_AREA`), while the TT deliverable's
  pads occupy the perimeter of the same outline, so its usable core is smaller.
  E2's static checker validates the configured coordinates against `DIE_AREA`,
  not a padded floorplan; no actual placement was run, and macro `y=10` may sit
  under the ring.
- The blog vs template assumptions are tabulated on the page: tile 200×150 vs
  167×108 µm (+66% area), die 1200×600 vs 1002×432, and the blog's ~24,000-cell
  logic figure against the template's own ~8,000-cell fit. This design's 3,579
  cells clears both, so the tile size decides the macro rectangle, not the
  budget.
- **Evidence needed later** (deferred, and not run here): a TT-top flow config;
  placement inside a real `CORE_AREA` with the ring; both macros' PDN
  connectivity (PSM-0040, no PDN-0189/PSM-0069); congestion and detailed-route
  DRC; a routed utilisation report to replace the ×1.69 estimate; macro-alone
  DRC provenance; a confirmed tile size; and the full-chip hold/high-fanout
  items from the reviews. Per the standing ruling, no LibreLane/OpenROAD, DRC
  or LVS was launched.

### Deferred by explicit ruling — do not do these

- **DRC/LVS.** Standing user ruling: final tapeout prep only, checked rarely. Retained
  facts: `1113909 Magic DRC` + `2672 KLayout DRC`, byte-identical at 60 and 66 MHz,
  **100% inside the SRAM macro footprint**, with 2,672 of 2,672 SoC KLayout violations
  reproduced by the macro **alone**. LVS passes.
- **Max-slew / max-cap / max-fanout** remain WARNINGS (8 / 10 / 7), not gated.
  Pre-existing, and not worth chasing before the RTL settles.

### 6. `pe_ctrl` readback path — DONE 2026-09-24 (option A1)

**Implemented and verified:** the loader's MISO response now exists as
**option A1** — a one-frame, commit-latched word echo on the free **`uio[4]`**,
strict mode 0, released whenever the loader is idle (`uio_oe[4] =
load_active`, i.e. `CS_N` low **and** `run` low). Frame 0 presents `0x0000`
(preloaded at `cs_fall`), frame k presents the word committed at frame k-1,
and one trailing frame in the **same CS-low session** reads the last word
(its `0x0000` lands in the already-undefined tail). The echo payload updates
only at the `W_DONE` edge where `words_written` increments, so an aborted
word can never echo; the serializer is deliberately not gated by
`load_error`, so **the final word of a full 1,024-word image still echoes
through the receive lockout** (manager ruling a).

**Numeric host contract** (in `rtl/pe_ctrl.v`'s header and the plan; manager
rulings b–d): every frame whose echo the host samples runs at **≤ 2.5 MHz**
(ruling c: the ceiling applies to the whole readback transaction); minimum
SCLK low phase **≥ 100 ns (6 clk)** with the computed limits assuming ~50%
duty; `CS_N` → first rising edge **≥ 100 ns**. The computed A1 limits remain
~65 ns per-bit low phase and `H ≥ 4 clk` for the commit latch (~7.5 MHz);
2.5/100/100 ns are chosen guards, not limits.

**Budget (was "if implemented" → now implemented):** committed **18 → 19** of
24, free `uio` **4 → 3**, all-nine shortfall **9 → 10** (debug kept) /
**3 → 4** (reclaimed); the readback is loader overhead, not one of the nine
protocols. STATUS item 4's revisit trigger now fires (dbg pins stay for now).

**Verification:** `tb_pe_ctrl` cases 8–12 (echo content/bit order, repeated-
session leak, duty/rate variants at 200/200, 160/240 and 100/900 ns, the
full-image trailing frame through the lockout, run-abort in the idle and
`W_PULSE` windows, and the three bounds hit exactly at once: first rise at
+100 ns, low phase 100 ns, 400 ns period) and pad-level
`tb_tt_um_protocol_emulator` (5-word load with per-frame echo at 2.5 MHz plus
a full 1,024-word image reading word 1023 back while `load_error` is set);
mode-0 stability is checked on every sampled edge.
`regress/mutate_ctrl_tb.sh` is **23 detected / 0 survived** (was 11/11; +9
pe_ctrl echo/OE mutations and +3 wrapper `uio[4]` wiring mutations).
`./regress/run_all.sh --fast -j8` exits 0 (29/29, 20/20, lint, all gates and
suites); `./regress/synth_area.sh` exits 0 clean (`pe_ctrl` 463 cells /
8,661.30 µm², `pe_soc` unchanged at 3,571 / 56,816.88 µm², `tt_um_top`
4,038 / 65,686.27 µm²). **Mapped STA refresh landed 2026-09-24**: the
zero-assumption `pe_ctrl` screen shows setup +8.71/+8.80/+8.86 ns and hold
−0.12/−0.16/−0.19 ns, attributed to external-input/removal/output artifacts
(Task 5b); under the BOARD variant `pe_ctrl` is hold-clean at slow (+0.04 ns).
No physical flow, DRC or LVS. Full evidence, hashes and RED logs:
`reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md`. The plan
[[plans/pe-ctrl-readback]] carries the status and the resolved decisions.

### 7. SERDES + codec integration — DONE 2026-09-24 (amended plan + review defaults)

The last two orphan blocks are **INSTANTIATED in `pe_soc`**, per the amended
plan and the follow-up review's recommended defaults for every scope group:

- **Milestone scope**: additive engine, disabled at reset, overlay off —
  every baseline TB and firmware image stays bit-identical (proved by the
  same run: 30/30 RTL, 21/21 firmware, with the engine present);
- **Topology**: ONE `pe_serdes` with the SPLIT payload-only enables
  (`tx_bit_en = tx_cell_en && !tx_stuffed` — TX holds across inserted stuff
  cells; `rx_bit_en = rx_cell_en && rx_bit_valid` — RX skips received ones)
  and TWO unmodified `pe_codec_mux` instances (TX/RX), one `bit_en` per
  ENCODED cell (never per half-cell); `half_phase` is a LEVEL with two
  toggles per cell into the TX instance's `cfg[3]`, 0 on RX;
- **RX path**: the ONE existing DRU — Manchester takes `eth_bit_en` plus
  `rx_first/rx_second`; plain/NRZI/stuffed take the divider's cell strobe over
  the DRU's synchronized level. **Plain RX has no phase acquisition: self-timed
  wire-loopback scope only** (the recommended default; documented limit);
- **Access**: the 16-entry latched-phase indexed window on port `0xF` (no ISA
  change), separate `TXLEN`/`RXLEN` (6-bit 1..32), `tx_load`/`rx_start`/`clr`
  as ONE-CYCLE write-triggered strobes, and `tx_done`/`rx_valid`/`rx_err`
  LATCHED for CPU polling (set-beats-clear on a STATUS/index-6 read). The
  divider free-runs while enabled, keeping the timing block active through a
  possible trailing stuff cell after `serdes.tx_busy` falls;
- **Overlay**: `pe_pinmux` gained `ov_en`/`ov_bit` feeding BOTH pad outputs
  BEFORE the open-drain gate (an engine 0 on an od pin pulls low, never
  releases); firmware still owns oe/od; reset is bit-identical;
- **First consumer**: `firmware/serdes_loop.pe` (70 words) + the new
  `tb_pe_soc_serdes` — plain LSB, plain MSB, Manchester, and the **directed
  stuffed Manchester loopback** (word 0x07E0 chosen so payload 16 arms the
  final stuff bit → the trailing-stuff case is guaranteed). Monitors check:
  cell pulses never closer than one cell period, `tx_ser` stable across stuff
  cells, no serdes advance on a stuff cell, the RX strobe IS the DRU's in
  Manchester, exactly `tx_len`/`rx_len` advances, `half_phase` quiet when
  Manchester is off, and bit-exact words in all four configs.

Two integration defects were found by those tests during bring-up and fixed:
the half-cell level toggled ONCE per cell instead of twice (the wire ran at
cell rate and the DRU could not decode it), and the Manchester `rx_start` was
not anchored to the first DRU decode after the grid-aligned load (a stale idle
decode became payload bit 0 and shifted the word).

**Verification (2026-09-24):** `tb_pe_soc_serdes` PASS; `tb_pe_serdes`
extended with a directed split-enables case (PASS); `tb_pe_pinmux` extended
with overlay/od-gate cases (PASS); `./regress/run_all.sh --fast -j8` exit 0 —
**30/30 RTL, 21/21 firmware**, lint clean, all seven generated gates, macro
gate + 26 negatives, and **all nine mutation suites**: i2c 6 detected + 1
documented-equivalent survivor, spi 5, fbuf 5, eth_mac 30, eth_soc 8,
i2c_xfer 11, ctrl 23 (incl. A1 readback), **serdes 7 (new)**, **soc-serdes 7
(new — the plan's four required mutations plus the two alignment defects and
the unaligned load)**; all with 0 unexplained survivors.
`./regress/synth_area.sh` exit 0 clean: **pe_soc 3,571 → 4,961 cells /
56,816.88 → 82,893.77 µm² (+1,390)** and **tt_um_top 4,038 → 5,363 /
65,686.27 → 91,268.06 µm² (+1,325)** against the post-A1 baseline; floorplan
cache and page refreshed. Every source list that elaborates `pe_soc` gained
`pe_serdes/pe_nrzi/pe_bitstuff/pe_codec_mux` (flow config, info.yaml,
synth_area, the macro gate, and five mutation harnesses). **Mapped STA
refresh landed 2026-09-24** (Task 4: `pe_soc` identical to pre-integration at
every corner, `tt_um_top` hold −0.71/−0.52/−0.43 ns, no new violation class;
Task 5b adds the labelled ZERO/BOARD variants); no physical flow, DRC or LVS.
Evidence:
`reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md`; plan status in
[[plans/serdes-integration]]. **Remaining plan item:**
`regress/mutate_codec_tb.sh` (unit suite for `pe_codec_mux`, which this task
did not modify) is not yet written. The full 10BASE-T TX frame path
(preamble/SFD/FCS/IFG/source) remains a separate block and plan.

### 8. Linux demo-host GUI — LANDED and MERGED (host branch, merge 1cbc0bc)

The GUI is no longer a plan. The host-controller branch built and verified it:
the **R1 framed host bus** on the chip side, the **Pico bridge**, the host
FakePE model, and the GUI phases 1a/1b/2/3 plus host Tasks 7/8, all merged into
`main` (merge 1cbc0bc). Chip-side evidence: [[reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW]] (R1) and [[reviews/2026-09-25/R2-READ-PATH-REVIEW]] (R2, item 10). Host-side evidence lives on the host branch.

What is LANDED: the operator workflow (load a program, start it, observe
status), the R1/R2 framed protocol on the chip, the Pico bridge in
MicroPython, the host model, and the golden-vector acceptance package with a
drift gate. The contract this replaced is now concrete: `pe_ctrl` is the
framed host bus on `uio[4:7]` with `IRQ_N` on `uo_out[1]` (19 of 24 pads
committed), and R2 adds the read path, so readback is **no longer undecided**.

The **hardware-gated remainder** is the real Pico/USB acceptance run on a
board (item 11) — everything up to it is simulation and host-side.

### 9. 10BASE-T TX frame path (`eth_tx`) — COMPLETE (Tasks 1-7, 2026-09-25)

The last unbuilt block in the topology: the SERDES/codec wire loopback (item
7) proved the engine, but a full 10BASE-T transmitter (preamble/SFD, hardware
FCS, 64-byte pad, 96-bit-time IFG, frame source) did not exist.
[[plans/eth-tx-frame-path]] is the implementation plan, in the
`ethernet-soc` style with eight scope groups, each carrying an
evidence-backed recommended default: firmware-streamed bytes through an
8-byte staging FIFO in an extended `0xF` window; hardware-owned
preamble/pad/FCS/IFG; a TX-dedicated `pe_crc` with the RevEng-checked
constants (receiver verdict is the catalogue residue, never `crc_zero`); reuse
of `u_tx_codec` + the divider at `DIV = 6` for exact 100 ns cells; `uo_out[2]`
reclaimed as `eth_tx` behind a bit-identical reset mux; first consumer
`firmware/eth_tx_arp.pe` (42-byte ARP request) with a pad-level Manchester
decode and a TX→RX loopback through `firmware/eth_rx.pe`; and two mutation
suites.

**Tasks 1-3 LANDED 2026-09-24 (manager Task 10, G1-G8 adopted as written):**
`rtl/pe_eth_tx.v` (892 cells / 16,040.09 µm²), the 32-entry `0xF` window and
owner mux in `pe_soc` (pe_soc 4,961 → 6,191 cells / 82,893.77 →
107,939.64 µm²; `tt_um_top` 6,633 → 7,980 / 113,254.89 → 138,746.71 µm²),
`firmware/eth_tx_arp.pe` + first TBs RED-first, `tb_pe_eth_tx` and
`tb_pe_soc_eth_tx` PASS, `./regress/run_all.sh --fast -j8` exit 0 (32/32 RTL,
22/22 firmware, lint, every gate, ten mutation suites),
`./regress/synth_area.sh` exit 0, same-list updates + regenerated
`signal-names.md`.

**Tasks 4-7 LANDED and verified 2026-09-25 (manager Tasks 11 + the chained
Task 6/7 pass):** the wrapper `uo_out[2] = pin_oe_bus[7] ? pin_out_bus[7] :
dbg_pc[0]` mux (G6 reclaim) with its pad-level decode case; the loopback
consumer `eth_arp_echo.pe` plus the `eth_tx_two`/`eth_tx_wrap_probe`/
`eth_tx_busy_probe` probes; the two mutation suites (**18/18** unit, **7/7**
integration, 0 survivors) which found and fixed two real TB gaps (a 60-byte
pad-boundary case and an engine-side IFG count); and the mapped 16.667 ns STA
screen (`reviews/2026-09-25/eth-tx-sta/`, 12 screens) showing **no new
violation class**, with the G6 pad `uo_out[2]` MET at +7.6330 ns setup /
+0.2964 ns hold. Final: `run_all.sh --fast -j8` exit 0 — RTL **33/33**,
firmware **26/26**, lint, every gate, **twelve** mutation suites;
`synth_area.sh` exit 0 — `pe_eth_tx` 892 / 16,040.09, `pe_soc` **6,219** /
**108,084.83**, `tt_um_top` **7,960** / **138,817.40** µm². `uo_out[2]` **is**
the `eth_tx` pad. Review: [[reviews/2026-09-25/ETH-TX-FRAME-PATH-REVIEW]].
Limits: mapped/simulation only (no physical flow/DRC/LVS); the push loop's
worst gap (52 clk) exceeds the 48-clk wire-byte period and is absorbed by the
8-byte staging FIFO; per-class STA probes are limited by this OpenSTA build's
hashed net names; the R2 read path is a separate phase.

### 10. PE host R2 read path — DONE (2026-09-25)

The host can now READ the chip. `READ_CPU` (0x12, the one non-halting read,
registers at native widths so `dbg_pc` is no longer truncated to 8 bits),
bounded `READ_IMEM`/`READ_DMEM` (0x13/0x14; dmem packs two bytes per response
word, high byte first), `DUMP_CORE` (0x15), an 11-word `STATUS`, the
**wait-word contract** (0xFFFF fillers while a read fetches; the frame starts
at the first non-0xFFFF word; worst case 15), and sticky `FAULT_RANGE` on an
out-of-range read cleared by `CLEAR_FAULT` (never a wrapped read).

Evidence: **15/15 golden steps pass byte-exactly** against the gui-worker
package (`tb_pe_ctrl_r2`, registered in `run_all.sh`; the conformance TB is the
34th RTL test); the read path has its own mapped STA screen with **no new
violation class** (`reviews/2026-09-25/r2-sta/`); the ctrl mutation suite grew
to **37** covering the read path, the wait-word contract, both bound checks and
the sticky-fault latch; regression **exit 0 — RTL 34/34, firmware 26/26, 12
mutation suites**. Record: [[reviews/2026-09-25/R2-READ-PATH-REVIEW]]. This
also **closes the P3 chip-side liveness gap** (STATUS now carries
pc/a/x/y/timer and READ_CPU answers while running).

### 11. Real Pico/USB acceptance run — OPEN (hardware-gated)

The one acceptance step that cannot be done in simulation: run the Pico
bridge and GUI against a real RP2040 on the Tiny Tapeout demo board over USB,
load a program, start it, and confirm liveness. Blocked on hardware, not on
design or software. Everything preceding it is done and green.

### 12. P3 host-side liveness surfacing — OPEN (host branch queue)

The chip now supplies liveness (STATUS pc/a/x/y/timer, READ_CPU while running);
showing it in the GUI is the host-controller branch's work.

### 13. Demo walkthrough + `chip_confirmed` flips — OPEN (host, in flight)

Refresh the demo walkthrough for the R2-landed state and have the gui-worker
flip each golden vector's `chip_confirmed` now that 15/15 pass byte-exactly on
the chip.

## Reading order for a fresh session

1. This file.
2. `wiki/decisions/adr-007-pe-ctrl-passive-slave.md` and
   `wiki/reference/protocol-pin-budget.md` — the loader's constraints and the
   pad map. The readback question is now DECIDED and LANDED: the framed host
   bus (R1) plus the read path (R2), item 10 above; the contract is in
   `rtl/pe_ctrl.v`'s header.
3. `wiki/index.md` → then `concepts/competition-overview.md` (rules, budget).
4. `concepts/factored-hardware-blocks.md` (what exists / what's planned) and
   `concepts/tx-timing-generation.md` (timing + signoff policy).
5. `rtl/pe_cpu.v` header (the ISA) and `firmware/uart_echo.pe` header (how
   firmware actually uses it — the polling idiom and the timing model).
6. `concepts/cdr-oversampling.md` (the DRU spec, still unbuilt).
7. `wiki/log.md` (last ~15 entries) for recent activity.
8. `rtl/pe_serdes.v` header comment for the SERDES contract.
9. `rtl/tt_um_protocol_emulator.v` header — the pad contract, the two TT rules
   that are expensive to get wrong (`ena` gates nothing; every output driven),
   and why open-drain is native to `uio_oe`.
10. [[decisions/adr-003-memory-plan]] — the two SRAM macros and the measured
    per-word cost of flop memory. Read before touching the SoC's memories.
11. [[concepts/ethernet-scope]] — what the 10BASE-T stretch goal is and is not,
    and the throughput arithmetic that puts Ethernet bits in hardware.
