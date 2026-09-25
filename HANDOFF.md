# Handoff — state of the repo (2026-09-23)

## Operating role: Pi Harness & RTL Hardening Steward

## Pi pane input check

When sending text to Pi through tmux, send the literal prompt and then send
`Enter` as a separate key event. A previous combined send left the text
unsubmitted. This was verified by sending literal `Hi!`, sending `Enter`
separately, and observing Pi's reply. Capture the pane after sending to confirm
that the prompt was submitted.

This role carries the user's persistent request across context flushes:

- Check the live Pi harness in the shared tmux window `pi-protocol-worker` every
  15 minutes. Inspect
  its current task and output; do not interrupt active work because a poll or
  command timed out. The pane completed the STATUS item 8 GUI-plan draft and
  the plan-source/E2 checker audit. It was left at the prompt and last checked
  at 22:55 CDT; next periodic check is due around 23:10 CDT. The new review
  found E2 macro checker residuals R1–R5; the false pass was tracked as
  E2-6 / R2 (see below and `PROJECT-REVIEW.md`). E2-6 and R3 have since been
  fixed and manager-verified (2026-09-24): both are **CLOSED**; R1/R4/R5 remain
  recorded observations.
- When idle, consult `wiki/STATUS.md` → **Next steps (ordered)** and nudge Pi
  with the next actionable documented task. Respect explicit user decisions
  and holds; do not start RTL implementation for plans that still await user
  choices. Keep the task scoped and request a concise evidence-backed report.
- Independently review landed RTL and its hardening evidence: directed tests,
  regression and mutation results, synthesis, and STA. The user allows periodic
  synthesis/STA screens to catch RTL that cannot be hardened. Treat mapped
  screens as such, not as physical signoff. Slow corner is also a hold-check
  corner.
- Update this handoff and `reviews/2026-09-23/PROJECT-REVIEW.md` with current
  source hashes/revisions, exact test commands/results, findings, and limits.
  Preserve distinctions between simulation, mapped synthesis/STA, and routed
  physical evidence. Never run physical flow, DRC, or LVS.
- Treat the default tmux server as shared live state: never kill the server or
  other sessions. To stop only an owned task, stop only that task/session.
- The shared worktree currently contains substantial uncommitted E1/E2 RTL,
  regression, review, and documentation edits, plus generated/untracked files.
  Inspect `git status` before editing and do not reset, revert, or clean other
  work. The manager restart prompt is in `MANAGER-COLD-START.md`; the Pi
  worker instructions are in `COLD-START.md`.

Current review baseline: the E1 published-byte ownership fix is in
`rtl/pe_eth_mac.v`; the full fast regression and 30/30 MAC mutation checks
passed, with fresh mapped Yosys/OpenSTA reports recorded in
`reviews/2026-09-23/e1-published-ownership/`. At 22:53 CDT, the RTL SHA-256
was rechecked as
`750d0bd591cc3c1a6e425b03e4cd471a5b398ca6cc03265c654d03daa69195d9`, matching
the recorded screen source exactly. Fresh `./regress/synth_area.sh` passed with
identical 1,681/3,571/3,888 MAC/SoC/top cells and 23,749.63/56,816.88/62,745.43
µm². Three fresh OpenSTA runs were byte-identical to the recorded reports:
setup 0.00 ns; hold −0.87/−0.61/−0.48 ns slow/typ/fast. Slow is a hold corner
and its unplaced negative hold/electrical violations remain. Full details and
logs are in `PROJECT-REVIEW.md` and `/tmp/e1-refresh-20260923/`. No physical
flow, DRC, or LVS was run. The new Linux demo-host GUI
planning task is STATUS item 8. Its draft is now in
`wiki/plans/demo-host-gui.md`, indexed in `wiki/index.md`, and logged in
`wiki/log.md`; its source/claims audit is complete and the backlog remains TODO
pending user acceptance. The read-only E2 macro-flow gate audit found residual
checker gaps R1–R5; its false pass when a macro type is configured with another
type's LEF and measured using its smaller SIZE is tracked as E2-6 / R2. The
E2-6 fix and R3 were implemented later on 2026-09-23 (see the "E2-6 FIXED"
block below) and manager-verified 2026-09-24 (macro harness 26/26 re-run,
identity-logic code review, `./regress/run_all.sh --fast -j8` exit 0): both
CLOSED, and R1/R4/R5 remain observations. The A1 readback is implemented and
manager-verified too (see `reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md` and
the manager verification block in `PROJECT-REVIEW.md`); a fresh mapped
`pe_ctrl` STA screen shows no new violation class. GUI planning belongs to the
user (separate session); no GUI/bridge implementation is dispatched here.

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

> **10BASE-T TX FRAME PATH — PLAN TASKS 1-3 LANDED (2026-09-24, Manager
> Task 10).** The manager adopted G1-G8 as written, with one recorded
> amendment: under the R1 pad map (`uio[4:7]` host bus, `ui_in[3:7]` free) the
> G6 default stands exactly as written (reclaim `uo_out[2]` = `dbg_pc[0]` as
> `eth_tx` behind the reset-bit-identical `pin_oe_bus[7]` mux) and the
> free-`uio` alternative is void; the wrapper mux is plan Task 4, so
> `rtl/tt_um_protocol_emulator.v` is untouched in this dispatch. NEW
> `rtl/pe_eth_tx.v` (892 cells / 16,040.0898 µm² mapped) is the frame engine:
> hardware 56+8 prelude (the wire pattern, never 0xAA through a byte helper),
> octets LSB-first, zero pad to the 64-byte minimum with the pad FOLDED into
> the FCS, a TX-DEDICATED `pe_crc #(.W(32))` (`0xEDB88320`/`FFFFFFFF`/
> out-inv 1; the field-mode register drains to zero — checked, not just the
> wire bits), an 8-byte staging FIFO with a sticky-observable underrun, runt
> (<14) / jabber (>1,514 stored) refusal, and a 96-cell (9,600 ns) IFG; idle
> drives `tx_bit = half_phase` so the constant wire is a real idle level, not
> a square wave. `pe_soc` gained the 32-entry `0xF` window (5-bit index;
> 16-23 push-and-wrap, 24/25 TXLEN, 26 TXCTRL, 27 TXSTAT set-beats-clear), the
> exclusive owner mux on `u_tx_codec.tx_bit` (`eth_start` gated on
> `!ser_tx_busy`, `tx_path` clear refused while `tx_busy`, `enable = eng_en &&
> tx_path`), and DIV=6. `firmware/eth_tx_arp.pe` (502 words) is the first
> consumer: it claims `tx_path` BEFORE `eng_en` (a Manchester cfg with the
> codec still owned by the idling SERDES puts a square wave on the wire — the
> same idle trap) and streams the remaining bytes under TXSTAT `fifo_ready`
> backpressure. RED evidence: Task 1's TB fails to elaborate on the pre-engine
> tree; Task 3's TB on the pre-change window aliases the upper-bank writes
> into CTRL/register space (`CFG=ff`, divider 65535, engine never enabled, 734
> FAILs), so both tests were watched failing before the RTL landed. The
> directed TBs caught two integration defects and both are fixed (TXCTRL is a
> level register — frame_start must write bit2=1; the `tx_path`-before-
> `eng_en` ordering). Evidence: `tb_pe_eth_tx` **PASS** (ARP-42 padded → 60
> stored bytes / 576 wire bits / FCS `9cc5cb34`; exact-64 → 608 bits, no pad;
> max-1,514 → 12,208 bits; IFG 100 idle cells ≥ 96; refused 1,515 and 13;
> mid-frame abort; 10-of-42 underrun; 200-cell constant idle);
> `tb_pe_soc_eth_tx` **PASS** (decoded 576 wire bits, FCS `9cc5cb34`);
> `./regress/run_all.sh --fast -j8` **exit 0 — RTL 32/32 (the 30 existing
> intact), firmware 22/22 (the 21 existing + the eth_tx_arp assemble), lint
> clean, every generated gate, all ten mutation suites**;
> `./regress/synth_area.sh` **exit 0**: `pe_eth_tx` 892 / 16,040.0898 µm²,
> `pe_soc` 4,961 → **6,191** / 82,893.7746 → **107,939.6388 µm²**,
> `tt_um_top` 6,633 → **7,980** / 113,254.8858 → **138,746.7144 µm²**. The
> same-list rule was applied in one pass: all eight `pe_soc`-elaborating
> harnesses (`run_all.sh` CASES ×8, `mutate_eth_soc`/`mutate_ctrl`/
> `mutate_i2c` ×2/`mutate_i2c_xfer`/`mutate_soc_serdes`/`mutate_spi`),
> `flow/pe_soc.json`, `info.yaml`, `tools/checks/macro_flow_config.py`,
> `regress/lint.sh` (RTL_ALL + both top lists), `regress/synth_area.sh`
> (`pe_soc`, `tt_um_top`, a standalone `pe_eth_tx` line), plus the regenerated
> `wiki/reference/signal-names.md` (16 modules / 205 ports). Hashes:
> `rtl/pe_eth_tx.v`
> `a314134e837442d2377e7cc32eba490a5597d8c9e4075a09f85f15f7e30b5486`;
> `rtl/pe_soc.v`
> `12d472d328a34814f0642baa44f3ebb323277a0501e1ba210722dd4cb4caedf9`;
> `tb/tb_pe_eth_tx.v`
> `add595c2f02e8360e3ea0729887c9f46e4167ee877f30e69d5e51e9206c2f73f`;
> `tb/tb_pe_soc_eth_tx.v`
> `b2d9e4ebe5d471eb28d1032dc831cbcccfa04db960366475302650b2d03a83a6`;
> `firmware/eth_tx_arp.pe`
> `eb3231d273848b00217249d16e952317d2f7e2f31385942bd369004e607ca856`;
> `firmware/eth_tx_arp.hex`
> `0398d76bc8d98a7f25158433581cf3fafe704489d0f04ca7be84ee22c228f82d`;
> `regress/run_all.sh`
> `5d0a33589d5488b8bc61465825bfcbbb892bab3bac0736deb66d8ad2ea9e3393`;
> `regress/synth_area.sh`
> `27a79bcd5329436f082a831720e1ce0ce63594c1a984a84425977209dc8a730c`;
> `regress/lint.sh`
> `eb7aea044ac52ee811a3d35dcb0e21981e6d20d62d0a6902625136bd8d4762fa`;
> `regress/run_firmware_tests.sh`
> `5bae71081119fc99afb2ac60727933864ab18b312fe51aa0195aa19378f1823b`;
> `flow/pe_soc.json`
> `ee9b002a1cd8f6ec5310ddc27d7325990b73b1329b52b7a342b7b7bda68a0fb0`;
> `info.yaml`
> `6160a2588fcdb5b261f3e72cee2c53e422b338cecbca8c6893cb94b1b846aa6c`;
> `tools/checks/macro_flow_config.py`
> `1511e83e5c8d8b663337b64c55cd6cca5b9654db49aa4626926af7728e7bbc41`;
> `wiki/reference/signal-names.md`
> `2746e85df7010da5a9be8601b10e6d59b8757a40ad7282c274b7730902b511e6`.
> **Limits:** no STA refresh yet (Task 7), no pad-level `uo_out[2]` decode, no
> RX loopback / two-frame SoC acceptance (Tasks 4-5), no `eth_tx` mutation
> suites (Task 6); Review Focus 7's refusal guards are implemented but their
> directed stimulus needs a SERDES-busy firmware or the Task-6 integration
> mutations. Mapped/simulation evidence only — no physical flow, DRC or LVS.
> Logs: `/tmp/run_all_eth_tx.log`, `/tmp/synth_eth_tx.log`, `/tmp/tb_soc_tx.out`
> (GREEN), `/tmp/tb_soc_tx_red.out` (RED), `/tmp/tb_pe_eth_tx.out`.

> **Context-flush continuation:** the project hardware is intended to run with
> the RP2040 controller on the Tiny Tapeout demo board (Raspberry Pi Pico),
> controlled by a separate connected Linux PC. The planned Linux demo GUI is
> now STATUS item 8. The GUI, PC-to-board transport/control API, and board-side
> support are not designed or implemented. Current loader contract: passive
> mode-0 SPI into IMEM, then `run` via `ui_in[1]`; readback remains undecided.
> The diagrams show the three-layer host path. Their colocated PNG/SVG renders
> are current: planned map 4180×2520, progress map 4189×1956. Render with the
> commands in `diagrams/README.md` (PlantUML size limit 8192). The user wants a
> squarer layout; the project review records a stronger vertical-spine layout
> proposal, pending approval before a temporary layout experiment. The Pi
> worker in tmux window `pi-protocol-worker` finished the screenshot provenance
> audit, STATUS item 8 GUI plan draft,
> and source/E2 audit; it is at the prompt. Resume the user's 15-minute checks
> (next around 23:10 CDT). STATUS item 6 (the `pe_ctrl` readback) and item 7
> (the SERDES/codec integration) were both implemented and verified on
> 2026-09-24 under manager decisions (option A1; the review's recommended
> scope defaults — see their blocks below); item 8 (demo-host-GUI plan) is a
> manager decision — the user has delegated every project decision to the
> manager, so nothing on the work list waits on the user. `wiki/plans/demo-host-gui.md`
> is authored in a separate session; do not edit it here.
> Read-only project review and mapped synthesis/STA screens are authorized
> periodically; do not run physical flow, DRC, or LVS.
>
> **Old screenshot provenance:** its 1393×269 image matches
> `/tmp/plantuml-view/project-plan.png` (3568×675) label-for-label, an
> uncommitted pre-`cc00c58` draft render from 2026-09-23 13:19. No committed
> `.puml` revision contains that architecture; only the render and a vertical
> experiment remain in `/tmp`. Same PlantUML version as current. See
> `reviews/2026-09-23/PROJECT-REVIEW.md` for evidence and the next layout step.

> **R1 FRAMED HOST BUS — RECONCILED, FIXED AND VERIFIED (2026-09-24, Tasks 8/9).**
> Attribution: the chip-side host protocol landed in this worktree at 14:33
> (`rtl/pe_ctrl.v`, `rtl/tt_um_protocol_emulator.v`, `tb/tb_pe_ctrl.v`,
> `tb/tb_tt_um_protocol_emulator.v`, `regress/mutate_ctrl_tb.sh`,
> `tools/gen/crc_config.py` + `wiki/reference/crc-config.md`) while the
> previous worker was mid-task; the wezterm OOM killed it before any canonical
> record was written. The external host-controller session repo
> (`/tmp/opencode/host-controller-gui`, read-only from here:
> `wiki/plans/host-controller-gui.md`,
> `reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md`) is the plan/review of
> record; the review's R0 pad ruling is adopted — the framed protocol wins and
> the A1 `uio[4]` echo is retired. Framed contract in brief: SPI mode 0,
> MSB-first 16-bit words, `CS_N` low spans one request + response; `16'hA55A`
> sync, `{version[3:0],opcode[7:0],target[3:0]}` (version 1), sequence,
> payload length in words, payload, CRC-16/CCITT-FALSE over every preceding
> word (poly `16'h1021`, init `16'hFFFF`, no reflection, no final XOR; RevEng
> check `0x29B1`). Responses set opcode bit 7 and echo sequence and target;
> the first response payload word is the status
> (`0 OK, 1 BUSY, 2 BAD_FRAME, 3 RANGE, 4 FAULT, 5 UNSUPPORTED, 6 NOT_READY`).
> R1 opcodes `0x01 PING`, `0x10 LOAD`, `0x11 STATUS`, `0x16 CLEAR_FAULT`,
> `0x20 TARGET`; target 1 is a deterministic internal loopback responder on
> the same MISO (PING → OK+`0x10C0`, TARGET → OK+1+`0x0010`); an unknown
> opcode/target answers UNSUPPORTED with no fault; a bad CRC/header answers
> BAD_FRAME and latches FAULT_CRC/FAULT_PROTOCOL. `IRQ_N` is `~|faults`
> (FAULT_LOAD `0x1` run abort, FAULT_CRC `0x2`, FAULT_RANGE `0x4`,
> FAULT_PROTOCOL `0x8`), sticky until a mask `CLEAR_FAULT`; a STATUS read does
> not clear. A1 supersession: `uio[4]` is host `CS_N` now; the commit-latched
> echo and the abort semantics live in the framed LOAD response (status,
> `words_written`, faults, echo — no trailing frames, no undefined-tail
> writes; an aborted word never commits, counts or echoes; LOAD while `run=1`
> answers NOT_READY with no fault). R1 pad map: `uio[4:7]` = host
> CS_N/MOSI/MISO/SCK (lower PMOD row), `uo_out[1]` = `IRQ_N`, `ui_in[3:5]`
> freed; committed count stays **19 of 24** (5 free `ui_in`, 0 free `uio`);
> `uio[0:3]` firmware row unchanged. Authorized behavior-preserving fixes
> (Task 9, `rtl/pe_ctrl.v` only): the CRC functions use the old-style
> declaration (yosys 0.69+post cannot parse `return`), and the response
> payload mux is a fixed 3-bit slot case instead of the 5-bit dynamic
> `resp_buf[resp_idx-4]` index (Verilator WIDTHTRUNC). `regress/synth_area.sh`
> now fails loudly on a yosys ERROR instead of printing `- cells` (gotcha 13).
> The P21 CS-to-first-clock sweep is a directed case in
> `tb_tt_um_protocol_emulator` (40/60/150/400 ns, all PASS, MISO released).
> Evidence: `bash regress/lint.sh` exit 0 (**15 verilator + 12 yosys
> elaboration checks**); `./regress/run_all.sh --fast -j8` **exit 0** (30/30
> RTL, 21/21 firmware, all gates, ten mutation suites); `bash
> regress/mutate_ctrl_tb.sh` **29 detected / 0 survived / 0 harness errors**;
> `./regress/synth_area.sh` **exit 0** with **`pe_ctrl` 1,731 cells /
> 30,662.1126 µm²** and **`tt_um_top` 6,633 / 113,254.8858 µm²** (`pe_soc`
> unchanged 4,961 / 82,893.7746); the seven generator `--check`s OK. Fixed
> `rtl/pe_ctrl.v` sha256
> `aea1a765ab060ab7e806f9d7c37785f0856e81bf2ceef11b36d7501e390b0bc7`;
> `tb/tb_tt_um_protocol_emulator.v`
> `84c71a72125ba6d3a8094061191bf92db5c3781e8f531d2071c6dfa6bfd8f49f`. Non-RTL
> gaps also fixed: `info.yaml` duplicate `ui[3:5]` keys removed and the map
> moved to R1; `tools/gen/pin_budget.py` +
> `wiki/reference/protocol-pin-budget.md` regenerated for the R1 direction
> arithmetic; `tools/gen/signal_glossary.py` + `wiki/reference/signal-names.md`
> regenerated with the R1 `pe_ctrl` notes. **OPEN FINDING (a) — P3 liveness
> gap:** `uo_out[1]` is `IRQ_N` and the heartbeat pad is retired, while
> timer/PC/A/X/Y are deliberately absent from the R1 STATUS layout (no field
> may lie about R2), so nothing shows liveness on a scope until the R2 read
> path lands. **(b) P21 sweep — closed** by the directed case above; no R1
> test gap remains. Mapped/simulation evidence only — no physical flow, DRC
> or LVS.

> **HOLD-SCREEN ATTRIBUTION + BOARD-ASSUMPTION STA VARIANTS (2026-09-24,
> Task 5b).** Every recorded mapped STA screen is now honest about hold: the
> zero-delay screens are kept and labelled `VARIANT: ZERO-ASSUMPTION`, and a
> `VARIANT: BOARD-ASSUMPTION` twin changes only `set_input_delay -min` and
> `set_output_delay -min` from 0.0 ns to **1.0 ns** (max delays stay at the
> recorded 3.3334 ns). All **18 screens** (3 designs × 3 corners × 2 variants:
> `pe_soc`, `tt_um_top` and a newly added `pe_ctrl` mapping so the A1 loader
> screen is re-runnable) end with a full negative-min-slack inventory
> (`report_checks -path_delay min -slack_max 0 -group_path_count 1000
> -endpoint_path_count 4 -format summary`), classified by the new
> `serdes-sta/analyze_hold.py` — nothing is hidden in the top-5 display. The
> 1.0 ns floor is a labelled screening assumption (launch/level-shifter
> ~0.1–0.2 ns + 5–10 cm FR-4 ~0.33–0.67 ns + connector/protection ~0.1–0.3 ns
> + pad ring ~0.1–0.2 ns), **not a measured board flight time**; every BOARD
> MET claim is conditional on it. Attribution: zero-variant negatives split
> into external-input assumption artifacts (`host_*`/`run` data at 0 ns min
> delay, plus `rst_n` removal checks), external-output artifacts
> (`pin_out`/`dbg_*`/`spi_miso`/`uio_out[4]`), internal pre-CTS reg→reg paths
> and paths inside the 0.25 ns hold uncertainty. Under the board assumption
> **every external class drops to 0 paths in all nine screens**; worst setup
> is unchanged in every pair; board worst hold `pe_soc` −0.54/−0.41/−0.36,
> `tt_um_top` −0.64/−0.48/−0.40, `pe_ctrl` **+0.04**/−0.07/−0.13 (slow/typ/
> fast) — `pe_ctrl` is hold-clean at slow under the board assumption. The
> worst internal slow path is a flop→fbuf SRAM-pin path (−0.5353 `pe_soc` /
> −0.6380 `tt_um_top`, pre-CTS); the routed SoC run's CTS + hold repair closed
> that family (+0.1209 ns hold, 0 violating paths). Read-only
> input-registration audit (no RTL changed): `spi_sclk`/`spi_mosi`/`spi_cs_n`
> are already 2FF-synchronized and correctly false-pathed; `rst_n`, `run`,
> `host_*` and the plain `pin_in` lanes are unregistered — constraint-only
> today, with RTL register stages recorded as the options. Mapped pre-CTS
> screens only: no RTL, no regression rerun, no physical flow/DRC/LVS.
> Evidence: `reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md` and
> `reviews/2026-09-24/serdes-sta/` (both tcl variants, the 18 reports,
> `hold-attr-analysis.txt`); refinement recorded in the post-update block of
> `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`.

> **SQUARER DIAGRAM LAYOUT — both maps re-laid out (2026-09-24, Task 5a).**
> The approved layout experiment now covers both PlantUML maps, and the
> winning sources plus re-rendered PNG/SVG sidecars are checked in. Before →
> after: `project-plan.puml` **4180×2520 (1.6587) → 3194×2476 (1.2900)**;
> `project-progress.puml` **6195×1354 (4.5753) → 3681×2493 (1.4765)** (the
> progress map had sprawled during the Task-3 end refresh). Both targets were
> met (plan ≤ 1.4:1, progress ≤ 2.0:1); SVG sidecars move in step (plan
> 4181×2521 → 3195×2477, progress 6196×1355 → 3682×2494). What changed: the
> plan's four notes are now anchored `note bottom of pads` as one compact
> block below the architecture (the graph, packages and edges are otherwise
> untouched); the progress map switched from `left to right direction` to
> `top to bottom direction` so its five packages stack as vertical status
> lanes (no structural edits). Sanctioned status-label changes only: plan
> readback package `Optional loader readback — decision pending` → `Loader
> readback A1 — landed 2026-09-24`, `Planned shared word engine` →
> `Integrated shared word engine`, the readback component and the
> `loader..>readback`/`readback..>pads` edge labels updated to match, and the
> readback/serdes notes now record the landed A1 contract and the
> split-enable/two-codec topology with its evidence pointer; progress macro
> gate `E2-6 + R3 fixed (26 checks) / manager verification pending` →
> `E2-6 + R3 closed (26 checks) / manager-verified 2026-09-24` with its class
> amber → green and its note CLOSED, the readback note now records the mapped
> STA refresh and the loopback note the 13/13 codec suite and
> no-new-violation-class result. Independent parse: plan 7/7 packages, 26/26
> components, 36/36 edges, 4/4 notes; progress 5/5, 24/24, 26/26, 4/4; only
> the sanctioned labels/notes differ, every component id preserved.
> `plantuml --check-syntax` rc=0, `--check-graphviz` OK (PlantUML 1.2026.8,
> GraphViz 16.1.0). Evidence: `reviews/2026-09-24/DIAGRAM-SQUARER-LAYOUT.md`.
> Limit: Graphviz auto-placement, so re-measure after future content changes.
> No RTL, no physical flow.

> **CLOSEOUT HARDENING LANDED (2026-09-24, Task 4): mapped STA refresh for
> the SERDES integration + the codec mutation suite.** (a) The recorded screen
> scripts' source lists gained `pe_serdes/pe_nrzi/pe_bitstuff/pe_codec_mux`
> and three corners were run at 16.667 ns on BOTH `pe_soc` and
> `tt_um_protocol_emulator`; saved as `reviews/2026-09-24/serdes-sta/`
> (`run_sta.sh`, `synth-*.ys`, `sta-*.txt`, `probe-*.txt`, the pre-integration
> control). `pe_soc`: setup 0.00/0.00/0.00, hold −0.87/−0.61/−0.48 — identical
> to the pre-integration screen at every corner; `tt_um_top`: setup 0.00,
> hold −0.71/−0.52/−0.43. **No new violation class**: the new classes
> (overlay→pad, `half_phase`, window read mux, split enables) all have
> positive slack at slow (worst: overlay→pad setup +7.96 ns, half_phase min
> +0.23 ns, window min +0.15 ns, enables min +0.75 ns); fast-corner negative
> holds are shallower members of the pre-existing pre-layout family, and the
> pad hold violation pre-existed (−0.1026 fast pre-integration → −0.0308
> post). (b) NEW `regress/mutate_codec_tb.sh`: 13 mutations across
> `pe_codec_mux`/`pe_bitstuff`/`pe_nrzi`/`pe_manch` — CAN preset `0x51`,
> `ones_only`/run length, registered `clr`/`rx_err`, frame-boundary `clr`,
> pipeline order, bypass subset, `half_phase` — all **13 detected / 0
> survived** with `cmp`-verified restore; the TB gained three directed checks
> first (CAN bad stuff bit, NRZI `clr`→idle J, manch `clr` beats a pending
> error). (c) `./regress/run_all.sh --fast -j8` **exit 0** (30/30 RTL, 21/21
> firmware, lint clean, every gate, **ten mutation suites**);
> `./regress/synth_area.sh` clean and matching the baseline (`pe_soc` 4,961 /
> 82,893.7746 µm², `tt_um_top` 5,363 / 91,268.0622 µm²). Hashes, commands and
> the full tables: `reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`. Mapped
> screens only — no physical flow, DRC or LVS.
>
> **`pe_serdes` + `pe_codec_mux` INTEGRATED into `pe_soc` and verified
> (2026-09-24, STATUS item 7).** Manager decision: every scope group takes
> the follow-up review's recommended defaults (additive engine disabled at
> reset; self-timed wire-loopback first consumer; plain RX WITHOUT phase
> acquisition — documented limit; the `0xF` indexed window), and the review's
> amended two-codec shape wins where plan and review differ. Landed: ONE
> `pe_serdes` with split payload-only enables (`tx_bit_en = tx_cell_en &&
> !tx_stuffed`, `rx_bit_en = rx_cell_en && rx_bit_valid`), TWO unmodified
> `pe_codec_mux` instances clocked per ENCODED cell, `half_phase` as a LEVEL
> (two toggles per cell) into TX `cfg[3]` and 0 on RX, the pad overlay in
> `pe_pinmux` (`ov_en`/`ov_bit`, feeding BOTH pad outputs before the OD gate),
> the 16-entry latched-phase window on port `0xF` (separate TXLEN/RXLEN,
> one-cycle `tx_load`/`rx_start`/`clr` write-triggered strobes, LATCHED
> `tx_done`/`rx_valid`/`rx_err` for polling with set-beats-clear, divider
> free-running while enabled so a trailing stuff cell still emits after
> `tx_done`). First consumer `firmware/serdes_loop.pe` + `tb_pe_soc_serdes`:
> four configs incl. the **directed stuffed Manchester loopback** (word
> `0x07E0`, trailing-stuff case guaranteed by construction) — PASS; the
> extended `tb_pe_serdes` (directed split-enables case) and `tb_pe_pinmux`
> (overlay/od cases) PASS. New harnesses: `mutate_soc_serdes_tb.sh` **7/7**
> (the plan's four required mutations — TX hold, RX skip, doubled cell enable,
> strobe cross-wire — plus three alignment/load defects) and
> `mutate_serdes_tb.sh` **7/7** (the port split). `./regress/run_all.sh
> --fast -j8` **exit 0: 30/30 RTL, 21/21 firmware**, lint clean, all seven
> gates, **all nine mutation suites** (baselines: i2c 6 + 1 documented-
> equivalent, spi 5, fbuf 5, eth_mac 30, eth_soc 8, i2c_xfer 11, ctrl 23,
> macro negatives 26). `./regress/synth_area.sh` clean: **pe_soc 3,571 →
> 4,961 cells / 56,816.88 → 82,893.77 µm² (+1,390)**, **tt_um_top 4,038 →
> 5,363 / 65,686.27 → 91,268.06 µm² (+1,325)** (post-A1 baseline); floorplan
> cache/page refreshed. Every source list that elaborates `pe_soc` gained the
> four new modules (flow config, info.yaml, synth_area, the macro gate, five
> harnesses) — the first full run failed exactly there, all green after.
> Two bring-up defects were caught by the directed tests and fixed:
> `half_phase` toggled once per cell instead of twice, and Manchester
> `rx_start` needed the first-DRU-decode anchor (a stale idle decode was
> captured as payload bit 0). **No STA refresh yet (manager-scheduled: the
> window read-mux and overlay→pad paths are the new timing classes); no
> physical flow, DRC or LVS.** Remaining: `regress/mutate_codec_tb.sh` (the
> codec itself is unmodified) and the separate eth_tx frame path. Evidence:
> `reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md`; plan status:
> `wiki/plans/serdes-integration.md`. `diagrams/project-progress.puml`
> refreshed twice (gotcha 47: A1+E2-6 first, the integration at the end).
>
> **`pe_ctrl` readback — option A1 IMPLEMENTED and verified (2026-09-24).**
> The loader now echoes every committed word on `uio[4]` (strict mode 0, one
> frame late, commit-latched): frame 0 = `0x0000`, frame k = the word
> committed at frame k-1, one trailing frame in the same CS-low session. The
> payload updates only where `words_written` increments, so an aborted word
> can never echo, and the serializer is NOT gated by `load_error`, so the
> final word of a full 1,024-word image echoes through the receive lockout
> (manager ruling a). Numeric contract (rulings b–d) in the `pe_ctrl` header
> and the plan: **every** echoed frame ≤ **2.5 MHz** (ruling c), SCLK low
> phase ≥ **100 ns (6 clk)**, `CS_N` → first rise ≥ **100 ns** (ruling d);
> computed A1 limits ~7.5 MHz (guard vs limit kept separate). `uio_oe[4] =
> load_active` (released when CS_N is high or run is high); `uio[7:5]` is now
> the only released uio gap. **Budget: committed pads 18 → 19, free `uio`
> 4 → 3** (pin-budget page regenerated; all-nine shortfall 9 → 10 kept / 3 → 4
> reclaimed). Mapped counts moved: `pe_ctrl` 292 → **463** cells / 8,661.30 µm²,
> `tt_um_top` 3,888 → **4,038** / 65,686.27 µm², `pe_soc` unchanged (floorplan
> cache and generated page refreshed). Evidence: `tb_pe_ctrl` **PASS** (new
> cases 8–12: multi-word echo/bit order, repeated-session leak, duty/rate
> variants, full-image lockout echo, run-abort in the idle AND W_PULSE
> windows, the three numeric bounds hit exactly), pad-level
> `tb_tt_um_protocol_emulator` **PASS** (5-word load with per-frame echo at
> 2.5 MHz + a full 1,024-word image reading word 1023 back with `load_error`
> set), `regress/mutate_ctrl_tb.sh` **23 detected / 0 survived** (was 11/11:
> +9 pe_ctrl echo/OE mutations, +3 wrapper `uio[4]` wiring mutations with
> their own snapshot/restore), `./regress/run_all.sh --fast -j8` **exit 0**
> (29/29 RTL, 20/20 firmware, lint clean, all seven generated gates, all seven
> mutation suites), `./regress/synth_area.sh` **exit 0 clean**, all seven
> generator `--check`s OK. RED-first evidence (tests failing on the old RTL:
> missing port, 121/26/120-failure stages) and full SHA-256 hashes:
> `reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md`. **No STA refresh was run
> (manager to schedule one for the new register→pad path); no physical flow,
> DRC or LVS.** STATUS item 6 is DONE; item 4's dbg-pin revisit trigger now
> fires but the item-4 decision stands; `diagrams/project-progress.puml` was
> not refreshed (not in scope). `wiki/plans/demo-host-gui.md` untouched.
>
> **E2-6 / R2 FIXED and R3 FIXED (2026-09-23) — fixed-pending-manager-
> verification, NOT closed.** `tools/checks/macro_flow_config.py` now checks
> type↔view identity: each configured type's resolved `lef` view must declare
> `MACRO <type>` (a LEF with no `MACRO` declaration is a finding), and a
> resolved `lib` view that declares `cell(...)` must declare one for the type.
> R3 is fixed in the same checker: no single `lib` file may serve two required
> corners (config-only; the PDK-less exit-2 semantics are unchanged).
> `regress/mutate_macro_flow_config.sh` grew **20 → 26 checks**, adding the
> required **`type-b-wrong-lef`** mutation on the existing synthetic two-type
> fixture (type B, own footprint 100×100, configured with A's 10×10 LEF at
> (20,0) in a 50×50 die), plus `type-b-wrong-lib`, `type-no-macro-lef`,
> `corner-file-shared`, `corner-key-wildcard`, and `synth-identity-clean` (the
> legal config must stay exit 0, guarding against false findings). Process and
> evidence: the false pass was demonstrated first on a `/tmp` copy
> (`bash /tmp/e26-demo.sh` — wrong-LEF config **exit 0** while B's own LEF
> **exit 1** on the identical placement, tracked flow files byte-compared
> unchanged); pre-fix harness run **21 passed / 5 failed** (RED, the five new
> checks each saw gate exit 0); post-fix `bash
> regress/mutate_macro_flow_config.sh` **26 passed / 0 failed**, exit 0 (0
> failed, 0 survived, `[type-b-wrong-lef] detected`);
> `python3 tools/checks/macro_flow_config.py` on the tracked config **exit 0**
> (both instances) with `flow/pe_soc.json` / `flow/pe_soc_pdn.tcl`
> byte-identical; `./regress/run_all.sh --fast -j8` **exit 0** (29/29 RTL,
> 20/20 firmware, lint clean, `macro flow config: OK`, `macro flow config
> negatives: OK`, every generated gate and all seven mutation suites), log
> `/tmp/run_all_e26.log`. SHA-256: checker
> `004d68d21fa3370fe4577dd23197efb6202f912629e2c951c986f9ae547b2af9` →
> `be87a3aad1e3ad9e534e422d5b9001b766cc5fa588039a881e9e685ddc8699bf`; harness
> `880131a34f4e565789b13356c33e635865538b1ffdb7a9740b1ea007f5a8be90` →
> `20b966e368812a51980811262c2bbedb0f29a490c9a6332168df8ae78694a38b`; unchanged
> `flow/pe_soc.json` `640c761e3167c4ddc0c42fcde4823e72896385bafa08b4377bf5fd2d611db653`,
> `flow/pe_soc_pdn.tcl` `9dc80c11aeaef816799a23ba712c0defe9b07afbeb2a18928735a00acf62992d`,
> `regress/run_all.sh` `0eb26669347efdafa20e340761f9d25c01903440ecbb52f1a6d4a4528817284d`.
> Limits: lib identity is checked only where a `cell(...)` declaration is
> present; GDS view identity remains unchecked; R1/R4/R5 remain recorded
> observations. Full commands, outputs and limits:
> `reviews/2026-09-23/PROJECT-REVIEW.md`, subsection "E2-6 resolution
> (2026-09-23)". E2-6 stays **fixed-pending-manager-verification** until the
> manager independently re-runs the evidence commands. No RTL, flow-config or
> PDN changes; no physical flow, DRC or LVS.
>
> **Demo-GUI plan audit + E2 macro-gate re-review complete (2026-09-23, Pi pane).**
> `wiki/plans/demo-host-gui.md` was audited claim-by-claim against ADR-007, the
> wrapper/`pe_ctrl` headers, the TT clock spec, `entities/tiny-tapeout` and the
> pin budget; four demonstrable errors were corrected: the broken
> `[[decisions/adr-007]]` wikilink slug; the loader ceiling is the derived
> `clk/6` (10 MHz only at 60 MHz, not safe at an arbitrary lower `clk`, so clock
> selection and load rate are one decision); `python3 tools/gen/*.py --check`
> runs only the FIRST generator because glob expansion passes the rest as
> arguments — the plan now lists all seven commands by name; and the Pico
> (RP2040) is recorded as the chosen controller with the RP2350 note as a
> platform-doc caveat, every USB CDC/serial reference marked hypothetical, and
> the clock page marked sky130-framed with IHP confirmation open. The seven
> named generator checks all report OK, every wikilink resolves, and STATUS
> item 8 still reads TODO.
> E2 static macro-flow gate re-reviewed read-only: `python3
> tools/checks/macro_flow_config.py` OK (exit 0, both instances),
> `regress/mutate_macro_flow_config.sh` **20 passed / 0 failed**, exit-2
> semantics re-probed with `--pdk-root` (clean+missing PDK → exit 2, same
> config plus a wrong-net finding → exit 1), and a new `-grid stdcell` connect
> probe correctly fails. **Final E2 status: NOT fully closed — open finding
> E2-6 recorded.** E2-1…E2-5 remain closed (harness **20 passed / 0 failed**);
> E2-6 is the confirmed false pass in which a macro type is configured with
> ANOTHER type's LEF (type B, own footprint 100×100, measured with A's 10×10
> SIZE) and the checker then accepts a 50×50 die. **Recommended (recorded here
> at audit time as not implemented; implemented later the same day — see the
> "E2-6 / R2 FIXED and R3 FIXED" block above):** match the configured macro type against the LEF `MACRO`
> declaration and add a regression mutation to
> `regress/mutate_macro_flow_config.sh` (e.g. `type-b-wrong-lef`) that must be
> detected as exit 1. Other review-only observations: PDN entries naming
> instances absent from the netlist are ignored; a `*` lib key (or a
> wrong-corner file) satisfies corner coverage (R3 — since fixed, see above); supply pin names are
> hard-coded to `VDD!`/`VDDARRAY!`/`VSS!`; instance tokens must equal
> `re.escape(name)` exactly (fail-closed). Evidence and probe details
> are in `reviews/2026-09-23/PROJECT-REVIEW.md`, section "Demo-GUI plan audit
> and E2 macro-gate re-review". No RTL, flow-config, checker or harness edits;
> probes ran on `/tmp` copies; no physical flow, DRC or LVS; no open plan
> implemented. **Next choices:** accept or revise the demo-host-GUI
> plan; the E2-6 fix has been authorized and implemented (fixed-pending-manager-
> verification, see the block above). The readback A1 choice was made and
> implemented (2026-09-24, see its block above); the SERDES/codec
> integration (item 7) is also decided and implemented (2026-09-24, see its
> block above). Only item 8 (the demo-host-GUI plan) remains as a manager
> decision.
>
> **Latest MAC accounting fix (2026-09-23):** a fresh independent audit found
> that an address-only consume could release bytes in the still-unpublished
> frame, then have those bytes credited again by bad-frame rollback or TYPE FCS
> windback. `published_used` now bounds every release to committed frames.
> Directed tests first failed on the old RTL; `mutate_eth_mac_tb.sh` now detects
> all 30 mutations (0 survivors, 0 harness errors), including consume/publication
> collision accounting, TYPE FCS exclusion, preservation of earlier committed
> bytes through bad rollback and `S_ERR`, and an observable partial-release
> producer-pointer rebase.
> `./regress/run_all.sh --fast -j8` passes: 29/29 RTL, 20/20 firmware, lint,
> elaboration, generated gates and all seven mutation suites. Fresh Yosys/OpenSTA
> checks report 0 `check -assert` problems, setup 0.00 ns at all corners and
> unchanged hold slack −0.87/−0.61/−0.48 ns (slow/typ/fast). Current mapped
> counts: `pe_eth_mac` 1,681 cells / 23,749.63 µm², `pe_soc` 3,571 /
> 56,816.88 µm², `tt_um_top` 3,888 / 62,745.43 µm². Full evidence is in
> `reviews/2026-09-23/E1-PUBLISHED-OWNERSHIP-REVIEW.md`. No physical flow, DRC or
> LVS was run.
> An exact-source recheck confirmed the mapped netlist is unchanged and saved
> the current synthesis/OpenSTA reports in
> `reviews/2026-09-23/e1-published-ownership/`. Slow corner is a hold-check
> corner too (−0.8692 ns worst hold); the 0.00 ns setup summary is latch time
> borrowing, while the worst slow register-to-register setup path is +2.2274 ns.
> Mapping and STA are manual screens, not `run_all.sh` gates.
>
> Earlier follow-ups fixed the original E1 destructive reclaim and the wrapped
> release / consume-collision issues, and all five E2 macro-gate findings. The
> MAC ownership contract is described in `rtl/pe_eth_mac.v`; E1-3 (full-ring
> release indistinguishable from duplicate) remains documented.
> The E2 gate now validates every PDN pin-to-net mapping, requires the macro
> grid's Metal4 stripe plus
> its ordered Metal4-to-vertical and vertical-to-horizontal connects, and
> validates every macro view (nonempty gds/lef/lib, every ./src path resolving
> in the PDK sg13g2_sram tree, and lib coverage of the flow's PVT corners), and
> derives each macro type's own LEF SIZE so every placement is checked against
> its own dimensions (E2-5);
> `regress/mutate_macro_flow_config.sh` proves the wrong-net, every
> missing-clause/wrong-layer/reversed-order, every bad/missing-view and every
> per-type geometry mutation fails it, the PDK-less baseline skips cleanly, and
> findings (view included) and yosys failures still fail (20/20), wired into
> `run_all.sh`. Details:
> `reviews/2026-09-23/E1-E2-FOLLOWUP-REVIEW.md`. With
> `HOME=/tmp/nopdk IHP_PDK=/home/mylesp/pdk/IHP-Open-PDK`, the full
> regression also passed 29/29 RTL and 20/20 firmware while the macro geometry
> and macro-negative gates reported SKIPPED. The separate `IHP_PDK` keeps the
> SRAM simulation models available while the temporary `HOME` hides the LEF.
> Original findings and resolutions are in `ETHERNET-SOC-REVIEW.md`,
> `E1-RESOLUTION.md` and `E2-RESOLUTION.md`. No physical flow, DRC or LVS was
> run.

> **pe_ctrl run-transition P1 FIXED and verified (`ef4041d`).** The independent
> test had found a word could write during `run`
> (`writes=1 writes_while_run=1 error=0`) if `run` rose after reception and
> before host-port sampling. The fix masks `host_we`, aborts and flags queued
> words in `W_IDLE`/`W_PULSE`/`W_DONE`, so nothing writes during execution or
> reappears when `run` falls. `tb_pe_ctrl` fails on the pre-fix RTL and passes
> on the fix; `regress/mutate_ctrl_tb.sh` is 11 detected / 0 survived. The full
> regression at `e448c09` was 28/28 RTL, 19/19 firmware, six mutation suites
> and the macro gate, lint clean. The three-corner screen reports 0 synthesis problems,
> +8.71 ns worst setup (slow), and −0.19/−0.16/−0.12 ns hold (fast/typical/slow)
> on the direct `run` input under a 0 ns minimum input-delay assumption, with
> unplaced high-fanout violations. The async SPI first-stage endpoints are
> intentionally unconstrained. Evidence: `PE-CTRL-RESOLUTION.md` and
> `reviews/2026-09-23/pe-ctrl-hardening/`. Physical flow, DRC and LVS deferred.

> **Three-corner STA repeat (2026-09-23):** reran the mapped `pe_ctrl` screen
> with Yosys 0.69+post and OpenSTA 3.1.0. Synthesis reports zero problems,
> 292 cells / 75 flops, and 5,791.149 µm². Setup slack slow/typical/fast is
> +8.71/+8.80/+8.86 ns; hold is −0.12/−0.16/−0.19 ns. All three fresh OpenSTA
> reports are byte-identical to the checked-in reports under
> `reviews/2026-09-23/pe-ctrl-hardening/`; the async SPI constraint and
> unplaced high-fanout caveats are unchanged. This is mapped STA only.

> **Context flush state (updated 2026-09-24): the readback RTL is in flight
> no more — A1 landed and is verified.** One written plan still waits on a
> scope decision (manager, per the delegation of every project decision):
>
> - **`pe_ctrl` readback: DONE (2026-09-24, option A1)** — one-frame
>   commit-latched echo on `uio[4]`, strict mode 0, ≤ 2.5 MHz every echoed
>   frame, low phase ≥ 100 ns, `CS_N` setup ≥ 100 ns; trailing frame in the
>   same CS-low session; full-image final word echoes through the lockout.
>   Evidence: `reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md`; contract in
>   `wiki/plans/pe-ctrl-readback.md` (decisions resolved there). The A2/A3
>   options and the status/peek alternatives were not taken.
> - **`pe_serdes` + `pe_codec_mux` integration — DONE 2026-09-24** (STATUS
>   item 7; evidence block at the top of this handoff):
>   plan amended after the first
>   review's five findings (window latched phase, separate `TXLEN`/`RXLEN`,
>   overlay before the OD gate, wire-loopback first consumer, strobe split) and
>   then the loopback-follow-up findings: `pe_codec_mux`'s one `bit_en` gates
>   both directions (Manchester TX is purely combinational; the codec strobe
>   is per encoded cell, never 2x half-cell), and `pe_serdes`'s one `bit_en`
>   clocks both sides. The plan now uses two codec instances (TX/RX), a split
>   `tx_bit_en`/`rx_bit_en`, payload-only gates (`&& !tx_stuffed` /
>   `&& rx_bit_valid`), an independent `half_phase` level, and a directed
>   stuffed Manchester loopback with TX-hold/RX-skip/doubled-cell/cross-wire
>   mutations; scope decisions in `wiki/plans/serdes-integration.md` are now
>   RESOLVED (the review's recommended defaults, adopted 2026-09-24),
>   findings in `reviews/2026-09-23/SERDES-INTEGRATION-REVIEW.md`.
>   A fresh read-only follow-up found additional interface requirements:
>   latch one-cycle status events for CPU polling; make `tx_load`, `rx_start`
>   and `clr` write-triggered strobes; keep the timing block active through a
>   possible final stuffed cell; and decide whether plain RX needs asynchronous
>   phase recovery beyond self-timed loopback. A fresh readback contract audit
>   confirmed the mapping/timing analysis but found open requirements for
>   full-image final-word echo despite receive lockout, minimum SCLK low time,
>   readback rate across every verified word, numeric CS-to-first-clock setup,
>   and the limited A1/A2 rate difference. See
>   `reviews/2026-09-23/PLAN-FOLLOWUP-REVIEW.md`; that readback-contract list
>   has since been resolved by the A1 implementation above (rulings a–d).
>   A second SERDES decision-readiness audit found the planned topology matches
>   current RTL and grouped the remaining choices into milestone scope, plain
>   asynchronous RX scope, topology, and CPU access. Those recommended
>   defaults were ADOPTED by the 2026-09-24 manager decision and implemented
>   (see the integration block at the top). The plan's area
>   baseline before the latest MAC ownership fix was 3,306 `pe_soc` cells /
>   53,615.56 µm² and 3,579 `tt_um_top` cells / 59,286.81 µm². The current
>   mapped baseline is at the top of this handoff and in
>   `E1-PUBLISHED-OWNERSHIP-REVIEW.md`.
>
> Both planned RTL changes have landed (2026-09-24): the readback (A1) and
> the SERDES/codec integration, each with its own full regression — evidence
> blocks at the top of this handoff. The latest full
> regression is `/tmp/run_all_e1_coverage_final.log` (`run_all.sh --fast -j8`:
> 29/29 RTL, 20/20 firmware, lint clean, all seven mutation suites, gates
> current). Since then the MAC published-byte ownership fix received its own
> 29/29 + 20/20 full regression; the latest log output is in the session record
> and its findings/evidence are in `E1-PUBLISHED-OWNERSHIP-REVIEW.md`. A prior
> comment-only correction in `pe_ctrl.v` records that 10 MHz gives six clocks
> per full period and leaves no margin for the synchronized readback response. The plan
> amendment, both editable PlantUML diagrams and the touched wiki/handoff docs
> are committed. The project-wide diagrams now live as text in `diagrams/`;
> retired diagram-preview instructions are removed. Current review:
> `reviews/2026-09-23/PROJECT-REVIEW.md`. The diagram cleanup checks pass, and
> the full fast regression passes 29/29 RTL, 20/20 firmware, lint, generated
> gates and all seven mutation suites. No physical flow, DRC or LVS was run.
> A later read-only map audit corrected six labels/edges: timing now separates
> encoded-cell strobe from half-cell level, the `0xF` window feeds timing and
> SERDES controls, the loopback uses a simulation wire model, and the readback
> path names pending host-contract details. Progress colors remain current.
> Both diagrams re-rendered successfully in headless mode to `/tmp`.
> Current SVG and PNG renders are now stored beside their PlantUML sources in
> `diagrams/`; regenerate them using `diagrams/README.md`.
> The board-side controller is the RP2040 on the Tiny Tapeout demo board
> (Raspberry Pi Pico). The plan diagram labels it as the SPI host; the progress
> diagram leaves physical board bring-up open.
> The mapped area refresh also updated the floorplan synthesis cache and its
> generated page: estimated macro-plus-inflated-logic area is 265,666 µm²,
> 61.4% / 36.9% / 46.0% across the three die scenarios. This remains
> arithmetic on a padless flow plus a SERDES-derived factor, not floorplan or
> physical evidence. The generated page now distinguishes configured
> coordinates and PDN script clauses from actual placement/connectivity results.

> **SPI pad exposure and project diagrams (2026-09-23).** The SPI firmware now
> has MOSI on uio[2] and CS_N on uio[3]; SCLK/MISO share uo_out[0]/ui_in[0]
> with UART TX/RX. The pad-level test covers eight frames and four wrapper
> mutations; the full run passed 29/29 RTL tests, 20/20 firmware tests, lint,
> and all seven mutation suites. The synthesis-area screen completed with
> 3,298 cells for pe_soc and 3,613 for tt_um_top at that SPI-pad revision,
> before the E1 follow-up fix; current post-fix counts are at the top of this
> handoff. Review:
> reviews/2026-09-23/SPI-PAD-REVIEW.md. Project plan and progress diagrams are
> editable PlantUML text in diagrams/project-plan.puml and
> diagrams/project-progress.puml. Refresh the progress map when implementation
> status changes and the plan map when scope or topology changes. No STA rerun
> was needed for the combinational pad aliases. The plan map now distinguishes
> the first SERDES/codec wire-loopback milestone from the separate 10BASE-T TX
> frame consumer; the progress map records the integration as open and the
> readback interface choice as pending. Physical flow, DRC and LVS remain
> deferred.

> **Fresh mapped synthesis check (2026-09-23):** `./regress/synth_area.sh` exited
> 0 under Yosys 0.69+post. All 17 hierarchy checks passed and no Yosys
> diagnostics were emitted. Highlights at that revision (before the
> E1-1/E1-2 follow-up fix; the post-fix counts are in the top block):
> `pe_eth_mac` 1,402 cells;
> `pe_imem` flop fallback 61,057 cells / 1,300,811.665 µm²; `pe_soc` 3,298
> cells / 53,730.697 µm²; `tt_um_top` 3,613 cells / 59,547.852 µm². Full log:
> `/tmp/synth_area_run.log`. The historical 2026-09-20 SRAM flop figures in the
> area budget remain labeled by date. No routed flow, DRC, or LVS was run.

The consolidated current project review is
`reviews/2026-09-23/PROJECT-REVIEW.md`. It records the plan-only status of the
readback and SERDES work, the latest regression results, and the source-only
diagram checks.

Written for whoever picks this up next, human or agent. Read this, then
`reviews/2026-09-23/REFACTOR-REVIEW.md`, then `wiki/STATUS.md`. The refactor at
`6de2a6a` was reviewed against `2cc0f03`: no new functional defect found, and
the earlier review findings (including F1/F2/F3) remain closed. The source
comparisons and fresh regression support the functional no-op claim:
`tb/` is testbenches only, `regress/`
holds the harnesses, `tools/{fw,gen,checks}/` the Python, the SoC is
`rtl/pe_soc.v`, the line codecs are one module per file, and the SRAM shell is
under `rtl/vendor/`. Commands in this file use the new paths.

## Resume after refactor review

The user asked to review the large layout refactor. Fresh verification at
`6de2a6a` passed the standard regression, all seven original probes, the
102-case asynchronous Ethernet sweep, and the F1 boundary tests. All 15 RTL
and 26 TB module token streams match the pre-refactor revision after the
intended renames; file-level directives/attributes, firmware tool executable
ASTs and four firmware images are preserved. Relocated generators/checkers
work from outside the repo; submission sources and both staged flow source
sets compile. Only the flow's file-copy block was executed, with outputs under
`/tmp`; no physical tools were run. Evidence and replay scripts are under
`reviews/2026-09-23/refactor/`.

Current branch: `main` (the reviewed CODE revision is `6de2a6a`; the
handoff/docs commit above it only adds this report and its evidence).
`review/fix-invisible-defects` remains at `2cc0f03`.
The implementation and verification state is:

| ID | Priority | Finding | Fix |
|---|---|---|---|
| R2-1 | P1 | DRU latch/flop simulation race rejects an independently timed Ethernet frame | Two-latch (master/slave) DDR capture; async 49.995 ns frame is now a permanent TB case; sweep 102/0 |
| R2-2 | P1 | Valid-CRC runt accepted with length 65,532, corrupting buffer accounting | Structural verdict (`hdr_done`, `fcs_done`, `bit_cnt == 0`, type min 64 bytes) before the residue is trusted; runts and partial bytes are TB frames 10 and 12-15 (F1 closed) |
| R2-3 | P2 | USB stuffing applied to zero runs | Explicit `ones_only` rule (`cfg[7]`, run length `cfg[6:4]`); USB config is `0xE3`; TX/RX zero-run tests; the generated reference now matches (F2 closed) |
| R2-4 | P2 | One-clock CPU stop could resume on a stale instruction | `imem_addr` is zero while stopped; `tb_pe_cpu` test 10 |
| R2-5 | P2 | SRAM fallbacks read during writes while the macro holds | FLOP reads gated on `!we` (fbuf word+lane, imem rdata); TB checks across a changing address |
| R2-6 | P2 | Emulator UART monitor sampled bit boundaries, A5 read as 4A | First data sample at 1.5 bit periods; permanent 519/520/521 case |
| R2-7 | P2 | Interrupted mutation suites left source files changed | EXIT/INT/TERM traps restore pristine sources and image, then exit; probe `changed=[]` |
| F3 | P2 | The CAN example in the new reference (`0x05`) enabled Manchester | Reference says CAN `0x51` (`0x01` equivalent; `0x05` is not a preset); `tb_pe_codec_mux` checks `0x51` on TX and RX |

Earlier finding details and source locations are in
`reviews/2026-09-23/FIX-VERIFICATION.md` and `reviews/2026-09-22/REVIEW-2.md`;
fresh refactor evidence is in `reviews/2026-09-23/REFACTOR-REVIEW.md`.
The second-review runner exits 0, the
asynchronous Ethernet sweep is 102 trials / 0 failures, and the boundary runner
`reviews/2026-09-23/run-boundaries.sh` exits 0.

**Next:** STATUS item 5's read-only floorplan feasibility is documented in
[[reference/floorplan-feasibility]] (generated; its area inputs were refreshed
from `/tmp/synth_area_diagram_followup.log`; no flow launched). The remaining
*physical* work is deferred by standing ruling and listed there as evidence for
a later run — a TT-top flow config, placement inside a real `CORE_AREA` with the
pad ring, both macros' PDN connectivity, congestion/DRC and a confirmed tile
size. SPI's MOSI/CS are now exposed on `uio[2:3]` (2026-09-23,
[[plans/spi-pads]]; verified pad-level in `tb_tt_um_protocol_emulator`). The
`pe_ctrl` readback is **IMPLEMENTED as option A1 (2026-09-24)**:
a commit-latched word echo on `uio[4]`, strict mode 0, one frame late, with
the numeric contract (every echoed frame ≤ 2.5 MHz, low phase ≥ 100 ns,
`CS_N`→first rise ≥ 100 ns) in the `pe_ctrl` header and the plan; the
full-image final word echoes through the receive lockout and aborted words
never echo. The status-frame and memory-peek alternatives were not taken.
See [[plans/pe-ctrl-readback]] (decisions resolved) and
`reviews/2026-09-24/PE-CTRL-READBACK-REVIEW.md` (RED/GREEN evidence, hashes,
23/23 mutations, clean `run_all.sh --fast -j8` and `synth_area.sh`); no STA
refresh yet — schedule one; no physical flow, DRC or LVS.
**The SERDES/codec integration LANDED (2026-09-24)** — STATUS item 7, evidence
in the block at the top of this handoff and in
`reviews/2026-09-24/SERDES-INTEGRATION-REVIEW.md` (30/30 RTL, 21/21 firmware,
nine mutation suites at that landing, pe_soc 4,961 cells / 82,893.77 µm²; the
tenth suite `regress/mutate_codec_tb.sh` and the mapped STA refresh both
landed 2026-09-24 — see the closeout block at the top and
`reviews/2026-09-24/CLOSEOUT-HARDENING-REVIEW.md`). The remaining open
blocks are the 10BASE-T TX frame path (separate plan) and the demo-host-GUI
plan (item 8, a separate session). The SERDES plan's original review record is in
**The I2C review-focus gaps are closed (2026-09-23):** arbitration loss
releases and aborts without a STOP, unexpected NACKs record an outcome and end
with a STOP, and SCL is read back after every release so stretching is waited
on; all three are tested on the emulator (60 phases, with a
transient-contention arbitration case) and real RTL, with
`regress/mutate_i2c_xfer_tb.sh` at 11/11. The remaining I2C limit is that an
abort parks — no STOP-qualified bus-free wait and no retry — plus a real
device/fast mode. See `reviews/2026-09-23/I2C-TRANSACTION-REVIEW.md` for the
original clean path and the limits this work closes. All
review follow-ups (F1/F2/F3) are closed. Continue the functional simulation loop. The user explicitly permits **periodic synthesis
and STA to catch RTL that cannot be hardened** (2026-09-23): check mapped logic,
clock/latch structures, constraints, SRAM timing coverage and timing failures.
The standing restriction is **do not run physical flow, DRC, or LVS**.
The three R2-7 mutation harnesses restored source bytes in
the tested interruptions; the preceding verification report records the scope of
those checks.

## What is verified right now

The standard regression and the directed review probes measure different cases:

```bash
./regress/run_all.sh            # 29/29 TBs + 20/20 firmware + lint + 7 mutation
                           # suites + generated-doc drift, exits 0
./regress/run_all.sh --fast     # same verdicts, parallel TB loop, 4-state iverilog
bash reviews/2026-09-22/review2/run_repros.sh
                           # the seven second-review probes; exits 0
bash reviews/2026-09-23/run-boundaries.sh
                           # F1 Ethernet structure boundaries; exits 0
```

Historical refactor baseline at `6de2a6a`, verified in a `git archive` copy:
`run_all.sh --fast -j4` →
`TOTAL: 26 PASS: 26 FAIL: 0`, `FIRMWARE: 18 PASS: 18 FAIL: 0`, `lint clean`
(14 verilator tops + 11 yosys elaborations), all four mutation suites green, plus
`signal glossary up to date`, `protocol pin budget up to date`,
`sram budget up to date`, `crc config up to date`, `clock arithmetic up to date`,
`block diagram up to date`. The reference docs are generated
from the RTL/PDK and drift-checked inside the regression, so a renamed port or
deleted TB fails the run. A `git archive` clone with none of the ignored diagrams
present also exits 0. The project architecture and progress diagrams are editable
PlantUML text in `diagrams/`; they do not depend on generated images.

**Current regression (2026-09-23, after the SPI pad exposure):**
`run_all.sh --fast -j8` exit 0 — **29/29 RTL, 20/20 firmware**, param guards
OK, lint clean, every generated-doc/macro-flow gate current, the I2C
transaction checker passing, and **all seven mutation suites OK** (i2c, spi,
fbuf, eth_mac, eth_soc, ctrl, i2c_xfer). SPI MOSI/CS_N are now on
`uio[2:3]`, verified pad-level in `tb_tt_um_protocol_emulator` (4/4 probes
detected; [[plans/spi-pads]]); the synthesis screen shows a wire-only zero-gate
delta. I2C gap evidence is in
`reviews/2026-09-23/I2C-TRANSACTION-REVIEW.md`'s resolution section. The
earlier `56ba1a9` numbers below are the historical baseline for that commit.

## The thing that actually works

`firmware/uart_echo.pe` is a complete 115200 8N1 half-duplex UART. It is not RTL.
It runs on `rtl/pe_cpu.v` inside `rtl/pe_soc.v` (one input pin, one output
pin, a tick counter). `tb/tb_pe_soc_uart.v` drives a real waveform on RX and
decodes TX, and passes on 41/42/00/FF with 8.6–8.7 µs bit cells measured at the
pin. `tools/fw/peemu.py` reproduces the same tested bytes, which is the fast loop for
firmware work (2 s, no iverilog). The R2-4 restart and R2-6 UART-monitor probes
now pass; their fixes and additional independent checks are recorded in the
2026-09-23 verification report.

If you change anything in the firmware timing path, run **both** the TB and the
emulator. They disagreed once and that disagreement is how the real bug was found
(see below).

## The first 2026-09-22 review and fixes

Nine defects were found on a `git archive` clone where every test passed; the
report is `reviews/2026-09-22/REVIEW.md`. Two change how you should read the
RTL. (1) **The DRU sampled rising edges only**, so the advertised 60 MHz /
100 ns 10BASE-T grid did not exist — the testbenches scaled the wire to the
clock. It is dual-edge now (ADR-002's latch pair), and both `tb_pe_dru` and
`tb_pe_eth_mac` drive real bit timing; the Ethernet TB is real frames with a real
FCS. (2) **One oversized frame could zero the receiver's `room` permanently**
(the reclaim truncated `pay_cnt` to 11 bits, and a full 2,048-byte frame is
`11'h000`). The rest were the submission source lists, the emulator's timer
order and stop→run prefetch, Ethernet padding, generated-document gates,
`peasm --rtl-init`, and the lint gate's coverage — which now includes
`pe_eth_mac`/`pe_fbuf` and fails on ANY yosys `ERROR:`, because the old gate
grepped for three known diagnostics and passed a file yosys could not parse.

## Where the bodies are buried

1. **A TB that "waits for" an event it may have missed tests nothing.** The UART
   SoC TB was red for three defects, the worst being `@(negedge tx_pin)` running
   *after* the echo had already started — it silently anchored on the wrong edge
   and decoded every byte shifted. Fixed by latching the edge in an `always` block
   and sampling on a grid anchored to the latched time. If you write a TB against
   firmware that replies immediately, latch, don't wait. Details: `wiki/log.md`
   2026-09-20 and `wiki/plans/through-i2c.md` Blocker 1.
2. **FIXED 2026-09-20: the instruction memory is a real SRAM macro.**
   `rtl/pe_imem.v` instantiates `1P_1024x16_c2_bm_bist`; the SoC went 8,744 cells
   / 182,650 µm² → **1,083 cells / 19,795 µm²** with 8× the program. Two things
   about it are easy to get wrong and are worth knowing before touching it:
   - **The macro's protocol has two silent traps.** `A_BM[i]=1` means *write bit
     i*, so tying BM low makes every write a no-op that reports success; and
     `A_REN=1` during a write is **write-through**, so REN must be deasserted for
     the whole write cycle. Both are read from the vendor model, both are tested
     by `tb_pe_imem`, and both are mutation-checked. Do not "simplify" the
     wrapper's `re = ~host_we` without re-reading `rtl/pe_imem.v`'s header.
   - **Simulation needs the PDK's behavioural model, which lives outside the
     repo.** `regress/sram_model.sh` locates it and FAILS LOUDLY if absent — never fall
     back to `pe_imem`'s `FLOP=1` array silently, because a testbench that runs
     against the fallback has verified nothing about the memory that will ship.
3. **The tick is 260 clocks, not 173** (integer division of 60 MHz/115200/2).
   The 173 figure was the 40 MHz operating point; ADR-005 moved the core to
   60 MHz on 2026-09-21 and the real baud is 115,385 (+0.16%). If you see 173
   or 174 in a *current* claim it is stale — 173 survives only inside historical
   narration (the ADR-004 load-window story), where it is accurate.
4. **`tb_pe_soc_uart.v` `$readmemh`s an assembled `.hex`.** `run_all.sh` now runs
   `run_firmware_tests.sh` first so it can never simulate a stale image. If you add
   another SoC TB that loads firmware, keep that ordering.
5. **The lint gate is load-bearing; do not route around it.** `regress/lint.sh` runs
   Verilator `-Wall` and a yosys elaboration check on every top, and `run_all.sh`
   fails if either finds anything. An earlier revision of this file called those
   warnings "intentional". Two of them were real defects that NO testbench can
   reach, because a testbench only sees the simulator's resolution of illegal RTL:
   `tick_flag` had two `always_ff` drivers (Icarus raced it, losing half the ticks
   a poll loop should have seen; yosys tied it to a constant 0, so the STATUS port
   was dead in silicon), and `assign dbg_pc = u_cpu.pc` was a hierarchical
   reference that yosys drove backwards into an implicit wire. Both were printed
   on every run and discarded, because `synth_area.sh` captured yosys's output and
   grepped it only for numbers. If you add RTL and the gate complains, the gate is
   right.
5b. **Hardware that no firmware exercises is untested hardware.** The STATUS port
   had no program reading it for an entire milestone, which is exactly why its
   flop could be a constant and the regression stayed green.
   `firmware/tick_count.pe` + `tb/tb_pe_soc_tick.v` exist to close that.
   When you add a peripheral, add the program that uses it in the same change.
6. **The LibreLane `--dockerized` wrapper cannot auto-enable ihp-sg13g2.** Invoke
   the container with explicit `-p ihp-sg13g2 -s sg13g2_stdcell`. Command is in
   `wiki/STATUS.md` and `README.md`. This cost hours once; do not rediscover it.
7. **Check a test vector is not a bit palindrome before trusting a bit-order
   test.** `0x5A` reverses to itself, so an SPI master that shifted LSB-first
   instead of MSB-first would put the *identical levels on the wire* and no
   assertion could tell. Same for `0x00`, `0xFF`, `0x0F`, `0x3C`, `0x81`, `0xAA`.
   `int('{:08b}'.format(b)[::-1], 2) != b` is the check. STATUS gotcha 30.
8. **Not every mutation is catchable, and an uncaught one is not automatically a
   hole.** Sampling MISO before rather than after the SCLK rise is *equivalent*
   for a CPHA=0 slave (MISO is held from the falling edge), so that mutation
   cannot change observable behaviour and no test can fail on it. The catchable
   SPI mutations were the bit-order flip and driving MOSI after the rise (the
   classic CPHA error). Check whether a mutation is observable before treating
   its survival as a coverage gap. STATUS gotcha 31.
9. **The flow's PDN and global-routing knobs are in `flow/pe_soc.json`, with
   the reasoning inline — read those comments before changing them.** The two
   that were needed: `GRT_ADJUSTMENT: 0.0` (the generic 30% derate caused
   `GRT-0116` congestion at 4.59% utilization on a design that was 7.6% full) and
   a custom `PDN_CFG` for the SRAM's **Metal4** supplies, which
   `PDN_MACRO_CONNECTIONS` alone cannot reach. Both are STATUS gotchas 33-34.
   A temporary standalone pdngen harness was used to A/B the PDN config in
   about 1 minute instead of a 30-minute flow run (scratch, not repo — but the
   technique is worth reusing).

10. **A watcher that greps for its own pattern waits forever.** `while pgrep -f
   "run_librelane|librelane"; do sleep 30; done` never exits: `pgrep -f` matches
   against the **full command line of every process, including the waiting
   shell**, whose cmdline literally contains the pattern. Three of these piled up
   and looked like hung flow runs. `pgrep -x <tool>` (process name only) showed 0
   — the work was done. Poll a **completion artifact** (`[ -f "$RUN/.../summary.rpt" ]`)
   rather than a process; if you must match a process, bracket the pattern
   (`[o]penroad`) or exclude `$$`; and always cap the loop. Recorded globally as
   the `background-job-watchers` skill.

## Current work list

The ordered live backlog is **`wiki/STATUS.md`, "Next steps (ordered)"**.
The review findings are closed, the passive SPI loader (`pe_ctrl`) is
implemented, tested and recorded, and the **I2C transaction layer is built**
(as of 2026-09-23): `firmware/i2c_xfer.pe` (311 words) runs START, address+W,
ACK, data, ACK, repeated START, address+R, ACK, read, NACK, STOP — verified on
the emulator across all 60 tick phases and on real RTL against an independent
Verilog slave FSM. **Item 4 is decided: the six `uo_out[7:2]` pads stay
`dbg_pc[5:0]` for now** (no readback path; 6 usable pads free, or 12 if
debug is reclaimed; see STATUS for the revisit trigger). **Item 5's read-only feasibility is documented in
[[reference/floorplan-feasibility]]**: the two macros plus logic fit the
template 6×4 die at ~60% occupancy, the open question is the pad ring
(`CORE_AREA` vs `DIE_AREA`), and the physical-flow evidence is deferred and
listed. `wiki/plans/through-i2c.md` is kept for its timing analysis;
`wiki/plans/i2c-transaction.md` is the completed transaction plan.

**I2C review baseline (historical, at `56ba1a9`):** the first review verified
the fixed ACK-success transaction and left three limits open — arbitration loss
recorded but continued, unexpected NACKs recorded without recovery, and SCL
stretching unhandled. **All three are closed (2026-09-23)**; the concept page
and the review's resolution section carry the evidence. What remains open is
not a recovery path but the absence of one: an abort releases and parks with an
outcome code, with **no STOP-qualified bus-free wait and no retry**. No RTL
changed in this milestone, so no new synthesis/STA
screen was needed; the previous hardening screens remain the latest evidence.

The pin matrix is already inside `pe_soc`. UART, mode-0 SPI and I2C all run as
firmware through it; `i2c_xfer.pe` exercises the full transaction (byte
transfer, ACK/NACK, addressing, repeated START, read path). The
Ethernet receive chain and frame buffer are integrated into the SoC as of
2026-09-23 (port bit 7, IO window `0x8-0xE`, `firmware/eth_rx.pe`,
`tb/tb_pe_soc_eth.v` plus its mutation suite). R2-1/R2-2 qualify the block-level
Ethernet results.

The physical results below are historical records, not checks repeated during
this review. Follow `wiki/STATUS.md` for their limitations and the standing
instruction to defer physical flow, DRC, and LVS.

If you touch `pe_crc`: its constants are generated and catalogue-checked
(`tools/gen/crc_config.py`) — never hand-edit [[reference/crc-config]]. The traps are
STATUS gotchas 17-19, and they are all of the kind that pass every obvious test.

**If you touch `pe_dru`'s `SPB`:** the ceiling is **16**, not "any multiple of 4".
`phase` is 4 bits and `4'(SPB-1)` truncates above it, which kills all capture
silently. Both guards are elaboration errors now, and `regress/param_guards.sh` (run by
`run_all.sh`) requires them to actually reject. SPB=12 is the 60 MHz grid and
passes the existing nominal-grid tests; R2-1 covers the asynchronous failure.

**Clock plan (ADR-005, 2026-09-21; LOCKED 2026-09-22):** **60 MHz operating
point** — 66 MHz is *not* usable. It provably fails the 10BASE-T TX jitter
conformance window (8.0/8.5 BT ±11 ns) at any edge placement, dithered or not;
60 MHz keeps every hard protocol exact and refines the RX grid 50% (SPB 8 -> 12).
**The 66 MHz STA signoff target is retired** (both flow configs now close at
`CLOCK_PERIOD` 16.667 ns) and **60 MHz is no longer a parameter** — `CLK_HZ` is a
`localparam` in `pe_soc`, because nothing ever instantiated the SoC at any
other rate. `reference/clock-arithmetic.md` is the generated constant table.

**The SRAM WAS the critical path, and the SoC now has the signoff that covers it.**
The 1024x16 macro's `A_CLK` -> `A_DOUT` is 7.25 ns at the slow corner = 43% of a
16.667 ns period. `pe_imem` has no output register by design (it would add a cycle
and break the CPU's fetch-ahead). The pe_serdes STA run has no SRAM in it, so the
SoC needed its own timing run. The recorded post-route result at the current
**60 MHz / 16.667 ns** target (`RUN_2026-09-22_02-58-32`) has worst-case setup
slack **+2.6601 ns** and hold slack **+0.1209 ns**, with zero violating timing
paths across three corners. See `wiki/STATUS.md`, "Timing margin at the 60 MHz
operating point", for the measured results and remaining slew/cap limitations.
Two flow settings were needed and both are documented in `flow/pe_soc.json`
with the reasoning inline: **`GRT_ADJUSTMENT: 0.0`** (the generic 30% derate was
causing `GRT-0116` congestion at 4.59% utilization) and a custom **`PDN_CFG`**
(`flow/pe_soc_pdn.tcl`) because the macro's supplies are on **Metal4** while
the PDN grid is TopMetal1/TopMetal2 — `PDN_MACRO_CONNECTIONS` connects them
logically but builds no physical path, so the grid check failed with `PSM-0069`.
STATUS gotchas 33-34.

It now has a top level to plug into. `rtl/tt_um_protocol_emulator.v` (added
2026-09-20) is the Tiny Tapeout deliverable: before it there was no `tt_um_*`
module anywhere, so nothing in the repo was submittable and every pin-budget
conclusion in the wiki described a pad interface no RTL implemented. It wires
`uio_oe[1:0]` to open-drain SDA/SCL with a fixed mapping that the pin matrix
replaces. Read its header before writing the matrix: it states the two Tiny
Tapeout rules that are expensive to get wrong (`ena` must gate nothing, and every
output must be driven in every state), and `tb/tb_tt_um_protocol_emulator.v`
enforces both continuously.

## Conventions this repo expects

- Verilog under `rtl/`, one header comment per module stating the contract and the
  reason for each non-obvious choice. Read `rtl/pe_serdes.v` and `rtl/pe_cpu.v`
  before writing new RTL — the house style is "explain the trap you avoided".
- Every TB is self-checking and prints `PASS: <name>` on success; `run_all.sh`
  greps for that. Add new TBs to its `CASES` array or they are not in the
  regression.
- Numbers in wiki pages are generated where possible (`tools/gen/*.py --check` is
  in the regression). Hand-typed numbers rot; generated ones cannot.
- The wiki is the design record, not documentation-by-afterthought:
  `wiki/STATUS.md` + `wiki/log.md` are updated as work lands. Keep them current or
  the next agent starts from a lie.

## Environment

PDK `~/pdk/IHP-Open-PDK`; Ciel `~/.ciel` (`ihp-sg13g2` enabled); EDA venv
`~/venvs/asic`; LibreLane run dirs under `~/asic-runs` (outside git). Tools needed
for the regression: `iverilog` (≥11), `yosys`, `python3`. `verilator` and
`rsvg-convert` are used by lint/diagram tooling only.
