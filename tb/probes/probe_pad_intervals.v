  // ---- PROBE: the firmware's OWN wire, measured in CLOCKS ----------------
  // Watch out_line every clock, time every change, print every interval. The
  // model says the return leg is 80 half-intervals = 160 us with 63 changes
  // and 62 intervals: 46 of one half-interval and 16 of two. Intervals here
  // are in CLOCKS, so they must read 120 and 240 and nothing else.
  integer pw_clk = 0, pw_t = 0, pw_tr = 0, pw_i2 = 0, pw_i4 = 0, pw_ix = 0;
  reg     pw_lev = 1'b0, pw_started = 1'b0; reg [7:0] pw_prev = 8'h00;
  always @(posedge clk) if (rst_n) begin
    pw_clk <= pw_clk + 1;
    if (!pw_started) begin
      pw_lev    <= out_line;
      pw_started <= 1'b1;
    end else if (out_line !== pw_lev || dut.pin_out !== pw_prev) begin
      if (pw_tr > 0) begin
        if (pw_clk - pw_t == 120)      pw_i2 <= pw_i2 + 1;
        else if (pw_clk - pw_t == 240) pw_i4 <= pw_i4 + 1;
        else                           pw_ix <= pw_ix + 1;
      end
      if (pw_tr < 200)
        $display("  PROBE: change %0d at clock %0d, interval %0d", pw_tr, pw_clk, pw_clk - pw_t);
      pw_t  <= pw_clk;
      pw_tr <= pw_tr + 1;
      pw_lev <= out_line; pw_prev <= dut.pin_out;
    end
  end
  initial begin
    #(CLK_NS * 60 * 1100);
    $display("  PROBE(1100us, pass 0 only): %0d changes, %0d of 120 clocks, %0d of 240, %0d of neither", pw_tr, pw_i2, pw_i4, pw_ix);
    #(CLK_NS * 60 * 1200);
    $display("  PROBE: THE PAD: %0d changes, %0d intervals of 120 clocks, %0d of 240, %0d of neither",
             pw_tr, pw_i2, pw_i4, pw_ix);
  end
