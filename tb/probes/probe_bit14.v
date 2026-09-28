  // ---- THE LEVEL, THE MASK AND THE COUNTER AT EVERY HALF-INTERVAL --------
  // The levels string says half-intervals 14 and 15 are swapped; the listing
  // says the block computes 0x00 there; so this prints all three of the
  // quantities the level is made of, for the first twenty half-intervals.
  integer pbn = 0;
  always @(posedge clk) if (rst_n) begin
    if (dbg_pc == 10'd243 && pbn < 20) begin
      pbn = pbn + 1;
      $display("  PROBE(B14): OUT %0d  A = %02x  dmem[6] = %0d  dmem[11] = %02x",
               pbn, dbg_a, dut.dmem[6], dut.dmem[11]);
    end
  end
