# R3 golden vectors — per-step request/response bytes for the chip side

Generated from the implemented `pe_ctrl.v` contract on 2026-09-25 by
`python3 -m tools.host_gui.r3_vectors`. Consumed by `tb_pe_ctrl_r3` the way
`r2-hex/` is consumed by `tb_pe_ctrl_r2`.

> **chip_confirmed = false on every step below.** The chip has run its own
> `tb_pe_ctrl_r3` with a 7-mutant gate and formal proofs for S1–S4; that is
> the chip's evidence. *These* host vectors become chip-confirmed only when
> that TB passes them byte-exactly (CRC included).

## How to run one

1. `$readmemh("imem.hex", imem)` (1024 words) and `$readmemh("dmem.hex", dmem)`.
2. Preload the vector's `model_images[id]`: `state`
   (pc/a/x/y/insn/timer/run/faults/words_written) and `debug`
   (bp_addr/bp_en/bp_hit/debug_hold).
3. Drive `request_file` as bytes; compare the response to `response_file`
   word for word. **These ops emit ZERO wait words** — there is nothing to skip.
4. The `state` word is DERIVED by the chip from the debug registers, so it is
   never preloaded; assert it against `dbg_hold_r ? (bp_hit ? 3 : 2) : (run ? 1 : 0)`.

## Vectors

| # | vector / step | image | request (hex) | response (hex) | response payload words |
|---|---|---|---|---|---|
| 1 | `debug_bp_set_readback` / `bp_set_address_2` | `v01-bp-set-readback` | `a55a12200001000100027c08` | `a55a1a200001000500000000000000020001caf2` | `0000 0000 0000 0002 0001` |
| 2 | `debug_bp_set_out_of_range` / `bp_set_past_imem` | `v02-bp-set-out-of-range` | `a55a1220000100010400908e` | `a55a1a200001000500030000000000030001d086` | `0003 0000 0000 0003 0001` |
| 3 | `debug_bp_set_wrong_length` / `bp_set_len_0` | `v03-bp-set-wrong-length` | `a55a12200001000048f0` | `a55a1a2000010001000262d2` | `0002` |
| 4 | `debug_step_executes_one` / `step_from_boot_stop` | `v04-step-executes-one` | `a55a121000010000441e` | `a55a1a100001000500000002000100000000ad9f` | `0000 0002 0001 0000 0000` |
| 5 | `debug_step_executes_one` / `status_shows_pc_1` | `v04-step-executes-one` | `a55a124000020000087c` | `a55a1a400002000a00000002000100000000000000550000000000aabbb5` | `0000 0002 0001 0000 0000 0000 0055 0000 0000 00AA` |
| 6 | `debug_step_executes_one` / `read_cpu_shows_a_55` | `v04-step-executes-one` | `a55a112000030000e870` | `a55a19200003000700000001005500000000005500029899` | `0000 0001 0055 0000 0000 0055 0002` |
| 7 | `debug_step_sequence` / `step_one` | `v05-step-sequence` | `a55a121000010000441e` | `a55a1a100001000500000002000100000000ad9f` | `0000 0002 0001 0000 0000` |
| 8 | `debug_step_sequence` / `step_two` | `v05-step-sequence` | `a55a1210000200001d4e` | `a55a1a1000020005000000020002000000008ce8` | `0000 0002 0002 0000 0000` |
| 9 | `debug_step_sequence` / `status_shows_a_aa` | `v05-step-sequence` | `a55a1240000300003f4c` | `a55a1a400003000a00000002000200000000000000aa00000000f0009f8b` | `0000 0002 0002 0000 0000 0000 00AA 0000 0000 F000` |
| 10 | `debug_step_while_running` / `step_not_ready` | `v06-step-while-running` | `a55a121000010000441e` | `a55a1a100001000500060001000700000000e210` | `0006 0001 0007 0000 0000` |
| 11 | `debug_step_lands_on_bp` / `step_one` | `v07-step-lands-on-bp` | `a55a121000010000441e` | `a55a1a100001000500000002000100020001d3de` | `0000 0002 0001 0002 0001` |
| 12 | `debug_step_lands_on_bp` / `step_lands_on_2` | `v07-step-lands-on-bp` | `a55a1210000200001d4e` | `a55a1a1000020005000000030002000200036a8a` | `0000 0003 0002 0002 0003` |
| 13 | `debug_step_lands_on_bp` / `status_reports_the_hit` | `v07-step-lands-on-bp` | `a55a1240000300003f4c` | `a55a1a400003000a000000030002000200030000005500000000f000d824` | `0000 0003 0002 0002 0003 0000 0055 0000 0000 F000` |
| 14 | `debug_bp_hit_stops_live_core` / `status_after_live_hit` | `v08-bp-hit-stops-live-core` | `a55a124000010000512c` | `a55a1a400001000a000000030002000200030001000000000000f0006a21` | `0000 0003 0002 0002 0003 0001 0000 0000 0000 F000` |
| 15 | `debug_bp_hit_stops_live_core` / `status_is_stable` | `v08-bp-hit-stops-live-core` | `a55a124000020000087c` | `a55a1a400002000a000000030002000200030001000000000000f000c53c` | `0000 0003 0002 0002 0003 0001 0000 0000 0000 F000` |
| 16 | `debug_step_off_bp_clears_hit` / `step_off_the_breakpoint` | `v09-step-off-bp-clears-hit` | `a55a121000010000441e` | `a55a1a100001000500000002000300020001975d` | `0000 0002 0003 0002 0001` |
| 17 | `debug_step_off_bp_clears_hit` / `status_shows_no_hit` | `v09-step-off-bp-clears-hit` | `a55a124000020000087c` | `a55a1a400002000a000000020003000200010001000000000000000f39bf` | `0000 0002 0003 0002 0001 0001 0000 0000 0000 000F` |
| 18 | `debug_bp_clr_resumes` / `bp_clr_releases` | `v10-bp-clr-resumes` | `a55a1230000100004caa` | `a55a1a30000100050000000100020002000068bb` | `0000 0001 0002 0002 0000` |
| 19 | `debug_bp_clr_resumes` / `status_running_again` | `v10-bp-clr-resumes` | `a55a124000020000087c` | `a55a1a400002000a000000010002000200000001000000000000000f7e2c` | `0000 0001 0002 0002 0000 0001 0000 0000 0000 000F` |
| 20 | `debug_bp_clr_while_stopped_is_boot_stop` / `bp_clr_to_boot_stop` | `v11-bp-clr-boot-stop` | `a55a1230000100004caa` | `a55a1a30000100050000000000030000000014eb` | `0000 0000 0003 0000 0000` |
| 21 | `debug_bp_clr_while_stopped_is_boot_stop` / `status_reads_zero` | `v11-bp-clr-boot-stop` | `a55a124000020000087c` | `a55a1a400002000a0000000000000000000000000000000000000055b94d` | `0000 0000 0000 0000 0000 0000 0000 0000 0000 0055` |
| 22 | `debug_bad_crc_no_side_effect` / `bp_set_bad_crc` | `v12-bad-crc-no-side-effect` | `a55a12200001000100027c09` | `a55a1a2000010001000262d2` | `0002` |
| 23 | `debug_bad_crc_no_side_effect` / `status_shows_not_armed` | `v12-bad-crc-no-side-effect` | `a55a124000020000087c` | `a55a1a400002000a0000000000000000000000000000000000000055b94d` | `0000 0000 0000 0000 0000 0000 0000 0000 0000 0055` |
| 24 | `debug_status_common_prefix` / `status_full_readback` | `v13-status-common-prefix` | `a55a124000010000512c` | `a55a1a400001000a000000010004000200010001000000000000f0003d3d` | `0000 0001 0004 0002 0001 0001 0000 0000 0000 F000` |
| 25 | `debug_unsupported_target` / `step_on_loopback` | `v14-unsupported-target` | `a55a121100010000ee4f` | `a55a1a11000100010005f3d9` | `0005` |
| 26 | `debug_unsupported_target` / `bp_set_on_loopback` | `v14-unsupported-target` | `a55a12210002000100022abb` | `a55a1a210002000100054486` | `0005` |

**14 vectors, 26 steps, 0 chip-confirmed.**

Request bytes are the complete frame (`A55A` sync, header, sequence, length,
payload, CRC); response bytes likewise. Note step
`debug_bad_crc_no_side_effect/bp_set_bad_crc`: its request hex is
*deliberately corrupt* — the bad CRC is part of the golden stream, so the
testbench drives the malformed bytes rather than mangling a good frame.

## Where the vector spec and the RTL disagree

The vectors follow the **RTL**, because the chip is what has to pass them.

### vector 11 (debug_bp_clr_while_stopped_is_boot_stop)

the table's expected response says pc=0, but the RTL answers with the PC AT THE REQUEST and only re-zeroes the core at the same edge, so a following DEBUG_STATUS/STATUS reads 0. The RTL's own comment and the contract's 'Known limits' section both state the RTL behaviour; only the table row disagrees. The golden vector follows the RTL.

### vector 13 (debug_status_common_prefix)

the table expects insn=imem[4] while free-running, but pe_cpu fetches at next_pc while executing (next_pc / pc while held / 0 at the boot stop), so a free-running readback reports the word at the LANDING address, not at pc. A TB that wants insn=imem[pc] must hold the core (state 2) or preload the pipeline. The golden vector follows the RTL's fetch mode.

## Not covered by a frame

- **hit_is_stop_before** — Stop-before is proven across a step (the PC reports the landing address with the hit latched, and the following step executes the instruction there), plus by the chip's own formal claim and mutants; there is no single frame that shows a non-execution.
- **live_core_hit_keeps_the_strap (pre-state half)** — Reaching a live-core hit requires CLOCKING the core until the landing address matches, which is not a framed op. Vector 8 therefore ships the POST-HIT held state as its model image and reads it back with one DEBUG_STATUS, which is exactly what a TB sets up.
