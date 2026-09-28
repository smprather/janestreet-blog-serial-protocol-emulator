  // ---- WHERE DOES THE TESTBENCH'S DECODER LOCK, AND ON WHICH TRANSITION? --
  // The trace prints every interval it classifies, with the gap, the phase it
  // decided, and the class it chose. The question is ONE line of it: the lock
  // must be the two-half gap that the preamble's run of eight identical bits
  // puts at the 0-to-1 boundary, and no other gap in that run is two halves.
  integer pc_n = 0, pc_seen = 0;
  always @(posedge clk) if (rst_n) begin
    if (dec_iv2 + dec_iv4 + dec_ivx > pc_seen) begin
      pc_seen = dec_iv2 + dec_iv4 + dec_ivx;
      if (pc_n < 46)
        $display("  PROBE(TB): #%0d  gap %0d us  phase -> %0d  %0s  acc %02x  bit %0d  flag %0d",
                 pc_n, dec_us, dec_phase,
                 (dec_us == 4) ? "MID" : (dec_us == 2) ?
                   ((dec_phase == 1) ? "mid" : (dec_phase == 0) ? "BOUNDARY" : "skip") : "RESYNC",
                 dec_acc, dec_bit, dec_flag);
      pc_n = pc_n + 1;
    end
  end
