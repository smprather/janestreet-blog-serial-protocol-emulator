// R2_READ_EXPECT — generated from the gui-worker golden package
// (tb/r2-vectors/manifest.json, commit 262a639). One line per step:
//   <step>|<req hex>|<rsp hex>|<req bytes>|<rsp bytes>|<faults after>
localparam int R2_NUM_STEPS = 15;
localparam string R2_STEP [0:R2_NUM_STEPS-1] = "{"
    "read_imem_address_1_count_2|read_imem_bounded.read_imem_address_1_count_2.req.hex|read_imem_bounded.read_imem_address_1_count_2.rsp.hex|14|16|0",
    "read_dmem_address_0_count_4|read_dmem_bounded.read_dmem_address_0_count_4.req.hex|read_dmem_bounded.read_dmem_address_0_count_4.rsp.hex|14|16|0",
    "dump_core_header|dump_core_header.dump_core_header.req.hex|dump_core_header.dump_core_header.rsp.hex|10|32|0",
    "status_header|dump_core_header.status_header.req.hex|dump_core_header.status_header.rsp.hex|10|32|0",
    "read_cpu_while_running|read_cpu_non_halting.read_cpu_while_running.req.hex|read_cpu_non_halting.read_cpu_while_running.rsp.hex|10|24|0",
    "read_cpu_full_width_regs|full_width_debug_regs.read_cpu_full_width_regs.req.hex|full_width_debug_regs.read_cpu_full_width_regs.rsp.hex|10|24|0",
    "read_imem_not_ready|read_while_running_rejected.read_imem_not_ready.req.hex|read_while_running_rejected.read_imem_not_ready.rsp.hex|14|12|0",
    "read_dmem_not_ready|read_while_running_rejected.read_dmem_not_ready.req.hex|read_while_running_rejected.read_dmem_not_ready.rsp.hex|14|12|0",
    "dump_core_not_ready|read_while_running_rejected.dump_core_not_ready.req.hex|read_while_running_rejected.dump_core_not_ready.rsp.hex|10|12|0",
    "read_imem_last_word|range_never_wraps.read_imem_last_word.req.hex|range_never_wraps.read_imem_last_word.rsp.hex|14|14|0",
    "read_imem_past_end_no_wrap|range_never_wraps.read_imem_past_end_no_wrap.req.hex|range_never_wraps.read_imem_past_end_no_wrap.rsp.hex|14|12|4",
    "read_dmem_past_end_no_wrap|range_never_wraps.read_dmem_past_end_no_wrap.req.hex|range_never_wraps.read_dmem_past_end_no_wrap.rsp.hex|14|12|4",
    "bad_read_answers_range|read_range_fault_lifecycle.bad_read_answers_range.req.hex|read_range_fault_lifecycle.bad_read_answers_range.rsp.hex|14|12|4",
    "status_shows_sticky_fault|read_range_fault_lifecycle.status_shows_sticky_fault.req.hex|read_range_fault_lifecycle.status_shows_sticky_fault.rsp.hex|10|32|4",
    "clear_fault_clears_the_bit|read_range_fault_lifecycle.clear_fault_clears_the_bit.req.hex|read_range_fault_lifecycle.clear_fault_clears_the_bit.rsp.hex|12|14|0",
  };
