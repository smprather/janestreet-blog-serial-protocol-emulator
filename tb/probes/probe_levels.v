  // ---- THE EIGHTY LEVELS THE ENCODER DRIVES, AS A STRING -----------------
  // The interval histogram says the levels change the right number of times and
  // it cannot say WHAT they are: the two polarities have identical interval
  // sequences, which is this act's own finding, so a histogram is blind to a
  // complement. So the levels are read directly, one per OUT, as a string --
  // the same trick that made the frame's ORDER readable at a glance.
  //
  // AND THE STRING'S LENGTH IS THE COMPLETENESS PROOF, which is the number the
  // previous probe never printed: eighty characters means eighty OUTs were seen,
  // and anything shorter is a dropped event stated as a count.
  reg [8*90:1] pls;
  integer pln = 0, pl_pass = 0;
  always @(posedge clk) if (rst_n) begin
    if (dbg_pc == 10'd243) begin
      // The address is the encoder's OUT TXPIN from the assembler's listing. The
      // macro L_enc_drive is emitted by labels.py and IS in the file, but a
      // probe using it failed to elaborate in this session for a reason not
      // diagnosed -- and a silent injection failure is worse than a decimal
      // that says where it came from, so this one says so.
      // A new transmission is the firmware's OWN counter reading zero, not the
      // testbench's `pass`: a probe is injected above the point where `pass` is
      // declared, and the first version of this probe referenced it and
      // compiled to nothing.
      if (dut.dmem[6] == 0) begin
        pl_pass = pl_pass + 1; pln = 0; pls = 0;
      end
      if (pln < 80) begin
        pls = {pls[8*89:1], (dbg_a != 8'h00) ? "1" : "0"};
        pln = pln + 1;
      end
    end
  end
  initial begin
    #(CLK_NS * 60 * 1100);
    $display("  PROBE(LVL): transmission %0d drove %0d levels", pl_pass, pln);
    $display("  PROBE(LVL): pad    %0s", pls);
    #(CLK_NS * 60 * 1200);
    $display("  PROBE(LVL): transmission %0d drove %0d levels", pl_pass, pln);
    $display("  PROBE(LVL): pad    %0s", pls);
  end
