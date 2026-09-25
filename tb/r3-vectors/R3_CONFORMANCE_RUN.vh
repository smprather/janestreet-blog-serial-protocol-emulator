// R3_CONFORMANCE_RUN — generated from the gui-worker golden package
// (tb/r3-vectors/manifest.json, 14 vectors / 26 steps) by
// tools/gen/gen_r3_vectors.py. DO NOT EDIT: `--check` re-derives it.
//
// Every request and response below is the HOST's own bytes, replayed
// through $readmemh and compared word for word, CRC included. Nothing
// here re-derives an expected response: the package IS the acceptance
// spec, and a step only says PASS when the chip's bytes match it.
//
// WHAT IS PRELOADED, AND WHY IT IS NOT A WEAKENING. The package's
// load_procedure says to preload each vector's model_images[] state and
// debug context; those pre-states are the host MODEL's snapshots, and
// several are not host-reachable at all (a core stopped on a breakpoint
// with a=0 has not executed the two LDI instructions that precede it).
// So the pre-state is driven onto the DUT's own registers, and what is
// asserted is the RESPONSE: the framing, the status, the payload layout,
// the byte order, the CRC and the state encoding. The logic that
// ESTABLISHES those states is a different harness's job — tb_pe_ctrl_r3
// (directed, written RED-first) with its 7-mutant gate, plus the S1-S4
// formal claims. Neither harness lets the other off the hook.
task automatic r3_run_all;
  begin
    $readmemh("../tb/r3-vectors/imem.hex", r3_imem_img);
    $readmemh("../tb/r3-vectors/dmem.hex", r3_dmem_img);
  end
  // ---- debug_bp_set_readback (DEBUG_BP_SET arms the address and reads it straight back in the 5-word prefix.) ----
  begin : r3_v01
    r3_vector_begin("debug_bp_set_readback");
    // image v01-bp-set-readback: pc=0 run=0 bp_addr=0 bp_en=0 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b0, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x22 OP_DEBUG_BP_SET, expected faults 0x0000
    begin : r3_v01_s0
      $readmemh("../tb/r3-vectors/debug_bp_set_readback.bp_set_address_2.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_set_readback.bp_set_address_2.rsp.hex", r2_rsp_mem);
      r3_step(12, 20, "bp_set_address_2", 16'h0000);
    end
    r3_vector_end();
  end
  // ---- debug_bp_set_out_of_range (A breakpoint address past IMEM_WORDS is RANGE, changes nothing, and latches NO fault (R3 adds no fault class).) ----
  begin : r3_v02
    r3_vector_begin("debug_bp_set_out_of_range");
    // image v02-bp-set-out-of-range: pc=0 run=0 bp_addr=3 bp_en=1 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd3, 1'b1, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x22 OP_DEBUG_BP_SET, expected faults 0x0000
    begin : r3_v02_s0
      $readmemh("../tb/r3-vectors/debug_bp_set_out_of_range.bp_set_past_imem.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_set_out_of_range.bp_set_past_imem.rsp.hex", r2_rsp_mem);
      r3_step(12, 20, "bp_set_past_imem", 16'h0000);
    end
    r3_vector_end();
  end
  // ---- debug_bp_set_wrong_length (A wrong payload length is a 1-word BAD_FRAME with no side effect on any debug register (S5).) ----
  begin : r3_v03
    r3_vector_begin("debug_bp_set_wrong_length");
    // image v03-bp-set-wrong-length: pc=0 run=0 bp_addr=0 bp_en=0 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b0, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x22 OP_DEBUG_BP_SET, expected faults 0x0008
    begin : r3_v03_s0
      $readmemh("../tb/r3-vectors/debug_bp_set_wrong_length.bp_set_len_0.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_set_wrong_length.bp_set_len_0.rsp.hex", r2_rsp_mem);
      r3_step(10, 12, "bp_set_len_0", 16'h0008);
    end
    r3_vector_end();
  end
  // ---- debug_step_executes_one (DEBUG_STEP executes exactly one instruction and leaves the core in DEBUG_HOLD (S1).) ----
  begin : r3_v04
    r3_vector_begin("debug_step_executes_one");
    // image v04-step-executes-one: pc=0 run=0 bp_addr=0 bp_en=0 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b0, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v04_s0
      $readmemh("../tb/r3-vectors/debug_step_executes_one.step_from_boot_stop.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_executes_one.step_from_boot_stop.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "step_from_boot_stop", 16'h0000);
    end
    // step 1: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v04_s1
      $readmemh("../tb/r3-vectors/debug_step_executes_one.status_shows_pc_1.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_executes_one.status_shows_pc_1.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_shows_pc_1", 16'h0000);
    end
    // step 2: opcode 0x12 OP_READ_CPU, expected faults 0x0000
    begin : r3_v04_s2
      $readmemh("../tb/r3-vectors/debug_step_executes_one.read_cpu_shows_a_55.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_executes_one.read_cpu_shows_a_55.rsp.hex", r2_rsp_mem);
      r3_step(10, 24, "read_cpu_shows_a_55", 16'h0000);
    end
    r3_vector_end();
  end
  // ---- debug_step_sequence (Two steps retire two instructions: pc 0->1->2 and the LDI at 1 has run exactly once (a=0xAA).) ----
  begin : r3_v05
    r3_vector_begin("debug_step_sequence");
    // image v05-step-sequence: pc=0 run=0 bp_addr=0 bp_en=0 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b0, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v05_s0
      $readmemh("../tb/r3-vectors/debug_step_sequence.step_one.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_sequence.step_one.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "step_one", 16'h0000);
    end
    // step 1: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v05_s1
      $readmemh("../tb/r3-vectors/debug_step_sequence.step_two.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_sequence.step_two.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "step_two", 16'h0000);
    end
    // step 2: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v05_s2
      $readmemh("../tb/r3-vectors/debug_step_sequence.status_shows_a_aa.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_sequence.status_shows_a_aa.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_shows_a_aa", 16'h0000);
    end
    r3_vector_end();
  end
  // ---- debug_step_while_running (A free-running core cannot be stepped: NOT_READY with the full 5-word prefix, the pre-step state, and no side effect.) ----
  begin : r3_v06
    r3_vector_begin("debug_step_while_running");
    // image v06-step-while-running: pc=7 run=1 bp_addr=0 bp_en=0 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd7, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b0, 1'b0, 1'b0);
    r3_run_strap = 1'b1;
    r3_freeze_arm(10'd7, 8'h00, 8'h00, 8'h00);
    // step 0: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v06_s0
      $readmemh("../tb/r3-vectors/debug_step_while_running.step_not_ready.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_while_running.step_not_ready.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "step_not_ready", 16'h0000);
    end
    r3_freeze_disarm();
    r3_vector_end();
  end
  // ---- debug_step_lands_on_bp (A step whose landing address is the armed breakpoint reports state 3, the landing PC, and bp_flags 0b11 (S3).) ----
  begin : r3_v07
    r3_vector_begin("debug_step_lands_on_bp");
    // image v07-step-lands-on-bp: pc=0 run=0 bp_addr=2 bp_en=1 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd2, 1'b1, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v07_s0
      $readmemh("../tb/r3-vectors/debug_step_lands_on_bp.step_one.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_lands_on_bp.step_one.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "step_one", 16'h0000);
    end
    // step 1: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v07_s1
      $readmemh("../tb/r3-vectors/debug_step_lands_on_bp.step_lands_on_2.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_lands_on_bp.step_lands_on_2.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "step_lands_on_2", 16'h0000);
    end
    // step 2: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v07_s2
      $readmemh("../tb/r3-vectors/debug_step_lands_on_bp.status_reports_the_hit.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_lands_on_bp.status_reports_the_hit.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_reports_the_hit", 16'h0000);
    end
    r3_vector_end();
  end
  // ---- debug_bp_hit_stops_live_core (A free-running core stops on the breakpoint with run still high, and reports state 3 (S3).) ----
  begin : r3_v08
    r3_vector_begin("debug_bp_hit_stops_live_core");
    // image v08-bp-hit-stops-live-core: pc=2 run=1 bp_addr=2 bp_en=1 bp_hit=1 hold=1
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd2, 8'h00, 8'h00, 8'h00,
                10'd2, 1'b1, 1'b1, 1'b1);
    r3_run_strap = 1'b1;
    r3_freeze_arm(10'd2, 8'h00, 8'h00, 8'h00);
    // step 0: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v08_s0
      $readmemh("../tb/r3-vectors/debug_bp_hit_stops_live_core.status_after_live_hit.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_hit_stops_live_core.status_after_live_hit.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_after_live_hit", 16'h0000);
    end
    // step 1: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v08_s1
      $readmemh("../tb/r3-vectors/debug_bp_hit_stops_live_core.status_is_stable.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_hit_stops_live_core.status_is_stable.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_is_stable", 16'h0000);
    end
    r3_freeze_disarm();
    r3_vector_end();
  end
  // ---- debug_step_off_bp_clears_hit (A step off the breakpoint clears the hit and returns to DEBUG_HOLD with bp_flags 0b01 (S4).) ----
  begin : r3_v09
    r3_vector_begin("debug_step_off_bp_clears_hit");
    // image v09-step-off-bp-clears-hit: pc=2 run=1 bp_addr=2 bp_en=1 bp_hit=1 hold=1
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd2, 8'h00, 8'h00, 8'h00,
                10'd2, 1'b1, 1'b1, 1'b1);
    r3_run_strap = 1'b1;
    // step 0: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v09_s0
      $readmemh("../tb/r3-vectors/debug_step_off_bp_clears_hit.step_off_the_breakpoint.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_off_bp_clears_hit.step_off_the_breakpoint.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "step_off_the_breakpoint", 16'h0000);
    end
    // step 1: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v09_s1
      $readmemh("../tb/r3-vectors/debug_step_off_bp_clears_hit.status_shows_no_hit.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_step_off_bp_clears_hit.status_shows_no_hit.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_shows_no_hit", 16'h0000);
    end
    r3_vector_end();
  end
  // ---- debug_bp_clr_resumes (DEBUG_BP_CLR disarms, clears the hit and RELEASES the hold: run=1 resumes, run=0 falls to the boot stop with PC 0.) ----
  begin : r3_v10
    r3_vector_begin("debug_bp_clr_resumes");
    // image v10-bp-clr-resumes: pc=2 run=1 bp_addr=2 bp_en=1 bp_hit=1 hold=1
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd2, 8'h00, 8'h00, 8'h00,
                10'd2, 1'b1, 1'b1, 1'b1);
    r3_run_strap = 1'b1;
    r3_freeze_arm(10'd2, 8'h00, 8'h00, 8'h00);
    // step 0: opcode 0x23 OP_DEBUG_BP_CLR, expected faults 0x0000
    begin : r3_v10_s0
      $readmemh("../tb/r3-vectors/debug_bp_clr_resumes.bp_clr_releases.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_clr_resumes.bp_clr_releases.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "bp_clr_releases", 16'h0000);
    end
    // step 1: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v10_s1
      $readmemh("../tb/r3-vectors/debug_bp_clr_resumes.status_running_again.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_clr_resumes.status_running_again.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_running_again", 16'h0000);
    end
    r3_freeze_disarm();
    r3_vector_end();
  end
  // ---- debug_bp_clr_while_stopped_is_boot_stop (With run=0, DEBUG_BP_CLR drops the hold to the normal boot stop and the PC re-zeroes; the response reports the PC at the request.) ----
  begin : r3_v11
    r3_vector_begin("debug_bp_clr_while_stopped_is_boot_stop");
    // image v11-bp-clr-boot-stop: pc=3 run=0 bp_addr=0 bp_en=1 bp_hit=0 hold=1
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd3, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b1, 1'b0, 1'b1);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x23 OP_DEBUG_BP_CLR, expected faults 0x0000
    begin : r3_v11_s0
      $readmemh("../tb/r3-vectors/debug_bp_clr_while_stopped_is_boot_stop.bp_clr_to_boot_stop.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_clr_while_stopped_is_boot_stop.bp_clr_to_boot_stop.rsp.hex", r2_rsp_mem);
      r3_step(10, 20, "bp_clr_to_boot_stop", 16'h0000);
    end
    // step 1: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v11_s1
      $readmemh("../tb/r3-vectors/debug_bp_clr_while_stopped_is_boot_stop.status_reads_zero.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bp_clr_while_stopped_is_boot_stop.status_reads_zero.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_reads_zero", 16'h0000);
    end
    r3_vector_end();
  end
  // ---- debug_bad_crc_no_side_effect (A bad CRC arms nothing and executes nothing (S5).) ----
  begin : r3_v12
    r3_vector_begin("debug_bad_crc_no_side_effect");
    // image v12-bad-crc-no-side-effect: pc=0 run=0 bp_addr=0 bp_en=0 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b0, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x22 OP_DEBUG_BP_SET, expected faults 0x0002 (CRC is deliberately corrupt: FAULT_CRC expected)
    begin : r3_v12_s0
      $readmemh("../tb/r3-vectors/debug_bad_crc_no_side_effect.bp_set_bad_crc.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bad_crc_no_side_effect.bp_set_bad_crc.rsp.hex", r2_rsp_mem);
      r3_step(12, 12, "bp_set_bad_crc", 16'h0002);
    end
    // step 1: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0002 (CRC is deliberately corrupt: FAULT_CRC expected)
    begin : r3_v12_s1
      $readmemh("../tb/r3-vectors/debug_bad_crc_no_side_effect.status_shows_not_armed.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_bad_crc_no_side_effect.status_shows_not_armed.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_shows_not_armed", 16'h0002);
    end
    r3_vector_end();
  end
  // ---- debug_status_common_prefix (DEBUG_STATUS is the 5-word prefix plus run/a/x/y/insn, and it answers while running and while held.) ----
  begin : r3_v13
    r3_vector_begin("debug_status_common_prefix");
    // image v13-status-common-prefix: pc=4 run=1 bp_addr=2 bp_en=1 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd4, 8'h00, 8'h00, 8'h00,
                10'd2, 1'b1, 1'b0, 1'b0);
    r3_run_strap = 1'b1;
    r3_freeze_arm(10'd4, 8'h00, 8'h00, 8'h00);
    // step 0: opcode 0x24 OP_DEBUG_STATUS, expected faults 0x0000
    begin : r3_v13_s0
      $readmemh("../tb/r3-vectors/debug_status_common_prefix.status_full_readback.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_status_common_prefix.status_full_readback.rsp.hex", r2_rsp_mem);
      r3_step(10, 30, "status_full_readback", 16'h0000);
    end
    r3_freeze_disarm();
    r3_vector_end();
  end
  // ---- debug_unsupported_target (Every debug op answers UNSUPPORTED on the loopback target.) ----
  begin : r3_v14
    r3_vector_begin("debug_unsupported_target");
    // image v14-unsupported-target: pc=0 run=0 bp_addr=0 bp_en=0 bp_hit=0 hold=0
    r3_imem[0] = 16'h0055;
    r3_imem[1] = 16'h00aa;
    r3_imem[2] = 16'hf000;
    r3_imem[3] = 16'h000f;
    r3_imem[4] = 16'h4002;
    r3_clear_faults();
    r3_preload_regs(10'd0, 8'h00, 8'h00, 8'h00,
                10'd0, 1'b0, 1'b0, 1'b0);
    r3_run_strap = 1'b0;
    // step 0: opcode 0x21 OP_DEBUG_STEP, expected faults 0x0000
    begin : r3_v14_s0
      $readmemh("../tb/r3-vectors/debug_unsupported_target.step_on_loopback.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_unsupported_target.step_on_loopback.rsp.hex", r2_rsp_mem);
      r3_step(10, 12, "step_on_loopback", 16'h0000);
    end
    // step 1: opcode 0x22 OP_DEBUG_BP_SET, expected faults 0x0000
    begin : r3_v14_s1
      $readmemh("../tb/r3-vectors/debug_unsupported_target.bp_set_on_loopback.req.hex", r2_req_mem);
      $readmemh("../tb/r3-vectors/debug_unsupported_target.bp_set_on_loopback.rsp.hex", r2_rsp_mem);
      r3_step(12, 12, "bp_set_on_loopback", 16'h0000);
    end
    r3_vector_end();
  end
endtask
