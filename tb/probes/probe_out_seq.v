  // ---- EVERY OUT THE ENCODER DRIVES, AND PROOF THAT IT SAW ALL OF THEM ----
  // A probe that drops events and prints a plausible table is worse than no
  // probe: every row it does print has missing neighbours, and a gap in a table
  // nobody reads is not a measurement. So this one COUNTS its hits and prints
  // the total, and the total is the first thing to look at: 80 half-intervals
  // means 80 OUTs, and anything else is either a missed event or a wire that
  // went quiet, and those are different findings.
  integer pq_n = 0, pq_clk = 0, pq_last = -1, pq_maxc = 0, pq_gaps = 0;
  always @(posedge clk) if (rst_n) begin
    pq_clk <= pq_clk + 1;
    if (dbg_pc == L_enc_drive) begin
      pq_n <= pq_n + 1;
      if (dut.dmem[6] > pq_maxc) pq_maxc <= dut.dmem[6];
      if (pq_last >= 0) begin
        if (pq_clk - pq_last != 121) pq_gaps <= pq_gaps + 1;
        if (pq_n <= 84)
          $display("  PROBE(Q): OUT %0d, +%0d clocks, A = %02x, dmem[6] = %0d, dmem[11] = %02x",
                   pq_n, pq_clk - pq_last, dbg_a, dut.dmem[6], dut.dmem[11]);
      end
      pq_last <= pq_clk;
    end
  end
  initial begin
    #(CLK_NS * 60 * 1100);
    $display("  PROBE(Q): TOTAL %0d OUTs witnessed, the largest dmem[6] seen was %0d, and %0d of the gaps were not 121 clocks",
             pq_n, pq_maxc, pq_gaps);
  end
