  // ---- THE ENCODER'S OWN STATE AT EVERY OUT IT DRIVES --------------------
  // A: dmem[6] is the half-interval number the block is TRANSMITTING.
  // Y is the level the block computed BEFORE the polarity gate, which is the
  // one value on this machine that says whether the BYTE fetch and the MASK
  // were right; A is what reached the pad after the gate.
  // Both are printed at the OUT itself (L_enc_drive, from the assembler's
  // listing), not twenty instructions downstream: every probe in this act that
  // sampled downstream of its subject has been wrong, and this one samples AT.
  integer pe_n = 0;
  always @(posedge clk) if (rst_n) begin
    if (dbg_pc == L_enc_drive) begin
      pe_n <= pe_n + 1;
      if (pe_n < 26)
        $display("  PROBE(ENC): OUT %0d  c=dmem[6]=%0d  mask=dmem[11]=%02x  Y=%02x  A=%02x  flag=dmem[3]=%02x  d0..2=%02x %02x %02x  d14=%02x",
                 pe_n, dut.dmem[6], dut.dmem[11], dut.u_cpu.y, dbg_a, dut.dmem[3],
                 dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[14]);
    end
  end
  initial begin
    #(CLK_NS * 60 * 1100);
    $display("  PROBE(ENC): %0d OUTs witnessed at enc_drive", pe_n);
  end
