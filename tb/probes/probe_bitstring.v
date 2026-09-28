  // ---- THE RECEIVER'S 24 PAYLOAD BITS AS A STRING -------------------------
  // "Which end" is not a question a byte can answer. This prints the bits in
  // ARRIVAL order so they can be laid beside the sent string (a5 3c 96, high
  // bit first) with a ruler rather than guessed at.
  //
  // *** AND THE TRIGGER IS THE WHOLE OF IT. *** The first version of this
  // probe tested `dec_mids > 0`, which is true on every clock after the first
  // mid, so it appended the accumulator's low bit once a CLOCK and printed
  // twenty-four ones -- an instrument that measures the clock instead of the
  // event, which is this act's own subject one level down. The trigger is the
  // COUNT CHANGING, not the count being non-zero.
  reg [8*40:1] pbs;
  integer pbn = 0, pbs_mids = 0;
  always @(posedge clk) if (rst_n) begin
    if (dec_mids != pbs_mids) begin
      pbs_mids = dec_mids;
      if (!dec_pre && dec_bits > 8 && pbn < 24) begin
        pbs = {pbs[8*39:1], (dec_acc[0] ? "1" : "0")};
        pbn = pbn + 1;
      end
    end
  end
  initial begin
    #(CLK_NS * 60 * 1100);
    $display("  PROBE(S): sent    101001010011110010010110   (a5 3c 96, high bit first)");
    $display("  PROBE(S): arrived %0s   (%0d bits)", pbs, pbn);
  end
