  // ---- EVERY OUT THE ENCODER DRIVES: the level it wrote, and the state -----
  // The address is L_enc_drive, a LABEL, not a decimal. The previous version of
  // this probe had the decimal baked in, the encoder grew by nine words, and it
  // reported intervals of 605 and 65431 clocks -- which are not half-intervals
  // and not anything else -- while looking entirely plausible. That is the
  // FIFTH placement error in this act, and it is the one labels.py was written
  // to make impossible and I then did not use.
  integer pq_n = 0, pq_clk = 0, pq_last = -1;
  always @(posedge clk) if (rst_n) begin
    pq_clk <= pq_clk + 1;
    if (dbg_pc == L_enc_drive && pq_n < 44) begin
      if (pq_last >= 0)
        $display("  PROBE(Q): OUT %0d, +%0d clocks, A = %02x, dmem[6] = %0d, dmem[11] = %02x",
                 pq_n, pq_clk - pq_last, dbg_a, dut.dmem[6], dut.dmem[11]);
      else
        $display("  PROBE(Q): OUT %0d, first, A = %02x, dmem[6] = %0d, dmem[11] = %02x",
                 pq_n, dbg_a, dut.dmem[6], dut.dmem[11]);
      pq_last <= pq_clk; pq_n <= pq_n + 1;
    end
  end
