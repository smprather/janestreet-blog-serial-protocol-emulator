  integer pq = 0, pq_prev = 0;
  always @(posedge clk) if (rst_n && dec_iv2 + dec_iv4 + dec_ivx > pq_prev) begin
    pq_prev = dec_iv2 + dec_iv4 + dec_ivx;
    if (pq < 26)
      $display("  PROBE(E): #%0d gap %0d us, phase now %0d, mids %0d bnds %0d skips %0d resyncs %0d, acc %02x, flag %0d, bit %0d",
               pq, dec_us, dec_phase, dec_mids, dec_bnds, dec_skips, dec_resync, dec_acc, dec_flag, dec_bit);
    pq = pq + 1;
  end
