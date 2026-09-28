  // ---- THE SEAM: what the preamble byte was, and where the payload began --
  // The bit string says the payload is banked with ONE extra bit at the front.
  // There are exactly two ways that happens and they are told apart by ONE
  // number: the preamble's assembled byte.
  //   0xFF -> the preamble took eight bits and the extra bit is the payload's
  //           first, so the receiver started one mid early.
  //   0x7F -> the preamble took only SEVEN, and the eighth one was banked as
  //           the payload's first bit: the byte completed one mid LATE.
  reg [8*40:1] pbs;
  integer pbn = 0, pbs_mids = 0, ppre_byte = -1, ppre_at = -1, pmids_at_pre = -1;
  always @(posedge clk) if (rst_n) begin
    if (dec_mids != pbs_mids) begin
      pbs_mids = dec_mids;
      if (dec_pre && dec_bit == 7) begin          // the 8th preamble bit is IN
        ppre_byte = dec_acc;                     // A already holds the shift
        ppre_at   = dec_bits;
        pmids_at_pre = dec_mids;
      end
      if (!dec_pre && dec_bits > ppre_at && pbn < 26) begin
        pbs = {pbs[8*39:1], (dec_acc[0] ? "1" : "0")};
        pbn = pbn + 1;
      end
    end
  end
  initial begin
    #(CLK_NS * 60 * 1100);
    $display("  PROBE(SEAM): preamble byte = %02x after %0d mids, flag = %0d", ppre_byte, ppre_at, dec_flag);
    $display("  PROBE(SEAM): mids at the preamble's end = %0d, payload bits banked = %0d", pmids_at_pre, pbn);
    $display("  PROBE(SEAM): arrived %0s", pbs);
  end
