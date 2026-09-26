  integer pn = 0, pclk = 0, pstart = -1, pcount = 0;
  always @(posedge clk) if (rst_n) begin
    pclk = pclk + 1;
    pcount = pcount + 1;
    if (dbg_pc == 10'd217) begin
      if (pstart >= 0 && pn < 5)
        $display("  PROBE(C): OUT %0d: %0d clocks and %0d instructions since the last OUT", pn, pclk - pstart, pcount);
      pstart = pclk; pcount = 0; pn = pn + 1;
    end
  end
