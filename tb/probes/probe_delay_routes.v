  integer pl_n1 = 0, pl_n2 = 0, pl_n3 = 0, pl_last = -1, pl_clk = 0;
  always @(posedge clk) if (rst_n) begin
    pl_clk <= pl_clk + 1;
    if (dbg_pc == 10'd274) pl_n1 = pl_n1 + 1;   // mid   loop DECX
    if (dbg_pc == 10'd281) pl_n2 = pl_n2 + 1;   // first loop DECX
    if (dbg_pc == 10'd288) pl_n3 = pl_n3 + 1;   // next  loop DECX
    if (dbg_pc == 10'd276 && pl_last >= 0 && pl_n2 < 4)
      $display("  PROBE(L): a loop iteration, %0d clocks after the last", pl_clk - pl_last);
    if (dbg_pc == 10'd276) pl_last = pl_clk;
  end
  initial begin
    #(CLK_NS * 60 * 1100);
    $display("  PROBE(L): loop entries -- mid %0d, first %0d, next %0d", pl_n1, pl_n2, pl_n3);
  end
