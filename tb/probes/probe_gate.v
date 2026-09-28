  // ---- THE GATE'S OWN INPUTS, SAMPLED AT THE GATE -------------------------
  // The pad says the complement route ran at c = 14 and the listing says it
  // cannot have. So this samples AT the gate: dmem[3] and dmem[6] as the gate's
  // own LDM X, 6 sees them, and A and X as the JZ that decides sees them. Every
  // earlier measurement in this act was taken at the OUT -- twenty instructions
  // downstream -- which is how a probe ends up disagreeing with the listing
  // while both are honest about what they read.
  integer pgn = 0;
  always @(posedge clk) if (rst_n) begin
    if (dbg_pc == 10'd223 && pgn < 20) begin
      $display("  PROBE(GATE): c=%0d  at LDM X,6: dmem[6]=%0d dmem[3]=%0d dmem[11]=%02x",
               pgn, dut.dmem[6], dut.dmem[3], dut.dmem[11]);
      pgn = pgn + 1;
    end
    if (dbg_pc == 10'd232 && pgn >= 13 && pgn <= 18)
      $display("  PROBE(GATE):          at the JZ: A=%02x X=%02x  (A is 0-S, so S=%0d)",
               dbg_a, dut.dbg_x, (8'h00 - dbg_a) & 8'hFF);
  end
