  integer pq_n = 0, pq_clk = 0, pq_last = -1;
  always @(posedge clk) if (rst_n) begin
    pq_clk <= pq_clk + 1;
    if (dbg_pc == 10'd217 && pq_n < 80) begin
      if (pq_last >= 0) $display("  PROBE(Q): OUT %0d, +%0d clocks, A = %02x, dmem[6] = %0d, dmem[11] = %02x",
               pq_n, pq_clk - pq_last, dbg_a, dut.dmem[6], dut.dmem[11]);
      else $display("  PROBE(Q): OUT %0d, first, A = %02x, dmem[6] = %0d, dmem[11] = %02x",
               pq_n, dbg_a, dut.dmem[6], dut.dmem[11]);
      pq_last <= pq_clk; pq_n <= pq_n + 1;
    end
  end
