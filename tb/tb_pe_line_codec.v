// tb_pe_line_codec.v — self-checking testbenches for the Tier-1 codec trio.
//
// Timing discipline: drive inputs, #1 to settle combinational outputs,
// sample BEFORE the strobe that commits state.
//
// pe_nrzi:     TX and RX as two instances joined by an explicit wire (a
//              real receiver cannot see TX state). Fixed + adversarial
//              (all-ones = no transitions, all-zeros) + random vectors.
// pe_manch:    both half-cells of every bit; decode; error injection.
// pe_bitstuff: run_cfg 5 (CAN) and 6 (USB), TX stuff placement, RX
//              destuff, wire-stream round trip, violation, bypass, clr.

`timescale 1ns / 1ps

// ---------------------------------------------------------------- NRZI
module tb_pe_nrzi;
  logic clk=0, rst_n;
  logic tx_en, tx_bypass, tx_raw, tx_wire, tx_lvl;
  logic rx_en, rx_bypass, rx_wire, rx_raw, rx_lvl_unused;
  logic wire_lvl, clr;

  pe_nrzi u_tx (.clk(clk), .rst_n(rst_n), .bit_en(tx_en), .bypass(tx_bypass),
                .clr(clr),
                .tx_raw(tx_raw), .tx_wire(tx_wire), .rx_wire(1'b0),
                .rx_raw(), .tx_lvl(tx_lvl));
  pe_nrzi u_rx (.clk(clk), .rst_n(rst_n), .bit_en(rx_en), .bypass(rx_bypass),
                .clr(clr),
                .tx_raw(1'b1), .tx_wire(), .rx_wire(rx_wire),
                .rx_raw(rx_raw), .tx_lvl(rx_lvl_unused));

  always #5 clk = ~clk;
  integer errors = 0;
  integer seed = 42;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL nrzi: %s @%0t", m, $time); errors++; end
  endtask

  task automatic strobe_tx(); tx_en = 1; @(posedge clk); #1; tx_en = 0; endtask
  task automatic strobe_rx(); rx_en = 1; @(posedge clk); #1; rx_en = 0; endtask

  // Send one raw bit: TX strobes (may toggle the line), wire settles,
  // RX decodes against its previous sample, then commits it.
  task automatic send_bit(input bit b, output bit decoded);
    tx_raw = b;
    strobe_tx();
    #1;
    wire_lvl = tx_wire;
    rx_wire  = wire_lvl;
    #1;
    decoded = rx_raw;
    strobe_rx();
  endtask

  initial begin
    $dumpfile("tb_pe_nrzi.vcd"); $dumpvars(0, tb_pe_nrzi);
    rst_n=0; tx_en=0; rx_en=0; tx_bypass=0; rx_bypass=0; clr=0;
    tx_raw=0; rx_wire=0; wire_lvl=0;
    repeat(3) @(posedge clk); #1; rst_n=1; @(posedge clk); #1;

    // Fixed vector: runs, alternation, and boundaries
    begin
      logic [63:0] v; bit d;
      v = 64'b1011_0001_1111_1110_0101_0101_0000_0000_1100_1100_1010_1010_1110_0001_0110_1001;
      for (int k = 63; k >= 0; k--) begin
        send_bit(v[k], d);
        check(d === v[k], $sformatf("fixed bit %0d", k));
      end
    end

    // Worst case: all ones (no transitions at all)
    begin
      bit d;
      for (int k = 0; k < 24; k++) begin
        send_bit(1'b1, d);
        check(d === 1'b1, $sformatf("ones run bit %0d", k));
      end
    end

    // All zeros (transition every bit)
    begin
      bit d;
      for (int k = 0; k < 24; k++) begin
        send_bit(1'b0, d);
        check(d === 1'b0, $sformatf("zeros run bit %0d", k));
      end
    end

    // Random soak
    for (int t = 0; t < 12; t++) begin
      logic [31:0] rv; bit d;
      rv = $random(seed);
      for (int k = 31; k >= 0; k--) begin
        send_bit(rv[k], d);
        check(d === rv[k], $sformatf("rand %0d bit %0d", t, k));
      end
    end

    // Bypass passthrough
    tx_bypass = 1; rx_bypass = 1;
    tx_raw = 1'b1; #1; check(tx_wire === 1'b1, "bypass tx passthrough");
    rx_wire = 1'b0; #1; check(rx_raw === 1'b0, "bypass rx passthrough");
    tx_bypass = 0; rx_bypass = 0;

    // clr returns both sides to idle J at a frame boundary.
    //
    // Without this the only route back to a known line state is a chip reset,
    // which a USB packet boundary is not: every packet starts from idle J and
    // the stuffer already had a clr for exactly this reason. Drive the line to
    // K first so "idle J" is a real change and not the state we were in.
    begin
      bit d;
      send_bit(1'b0, d);                       // a 0 toggles the line off J
      check(tx_lvl === 1'b0, "line is at K before clr");
      rx_wire = 1'b0; strobe_rx();             // receiver tracks K too
      clr = 1'b1; @(posedge clk); #1; clr = 1'b0; #1;
      check(tx_lvl === 1'b1, "clr returns TX to idle J");
      // A receiver reset to J decodes a held-J wire as 1 (no transition).
      rx_wire = 1'b1; #1;
      check(rx_raw === 1'b1, "clr returns RX level to idle J");
    end

    if (errors == 0) $display("PASS: tb_pe_nrzi");
    else $display("FAILURES nrzi: %0d", errors);
    $finish;
  end
endmodule


// ------------------------------------------------------------- Manchester
module tb_pe_manch;
  logic clk=0, rst_n, bit_en, bypass, half_phase, tx_raw, tx_wire;
  logic rx_wire, rx_first, rx_second, rx_raw, rx_err;
  logic clr;
  pe_manch dut (.*);
  always #5 clk = ~clk;
  integer errors = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL manch: %s @%0t", m, $time); errors++; end
  endtask

  // Check both half-cells of one transmitted bit.
  task automatic tx_bit(input bit b);
    half_phase = 1'b0; tx_raw = b; #1;
    check(tx_wire === (b ? 1'b0 : 1'b1), $sformatf("bit %b first half", b));
    half_phase = 1'b1; #1;
    check(tx_wire === (b ? 1'b1 : 1'b0), $sformatf("bit %b second half", b));
  endtask

  // Present one bit-cell's two half samples and commit it with the strobe.
  // rx_raw is combinational and is read BEFORE the committing edge; rx_err is
  // REGISTERED and is read after it. That split is the repo's standing
  // sampling rule (wiki/concepts/strobe-and-committing-edge.md).
  task automatic rx_cell(input bit f, input bit s);
    rx_first = f; rx_second = s; bit_en = 1'b1; #1;
    @(posedge clk); #1; bit_en = 1'b0;
  endtask

  initial begin
    $dumpfile("tb_pe_manch.vcd"); $dumpvars(0, tb_pe_manch);
    rst_n=0; bit_en=0; bypass=0; clr=0; half_phase=0; tx_raw=0;
    rx_wire=0; rx_first=0; rx_second=0;
    repeat(3) @(posedge clk); #1; rst_n=1; @(posedge clk); #1;

    tx_bit(1'b0);   // H then L
    tx_bit(1'b1);   // L then H
    tx_bit(1'b0);

    // RX decode from DRU half-cell samples. rx_raw before the strobe...
    rx_first=1'b1; rx_second=1'b0; #1;
    check(rx_raw === 1'b0, "rx H->L decodes 0");
    rx_cell(1'b1, 1'b0);
    check(rx_err === 1'b0, "rx H->L legal");
    rx_first=1'b0; rx_second=1'b1; #1;
    check(rx_raw === 1'b1, "rx L->H decodes 1");
    rx_cell(1'b0, 1'b1);
    check(rx_err === 1'b0, "rx L->H legal");

    // A cell with no mid-bit edge is illegal, and the error arrives with the
    // committing edge, one cycle wide.
    rx_cell(1'b1, 1'b1);
    check(rx_err === 1'b1, "rx high no-transition flagged");
    @(posedge clk); #1;
    check(rx_err === 1'b0, "error is one cycle wide");
    rx_cell(1'b0, 1'b0);
    check(rx_err === 1'b1, "rx low no-transition flagged");
    @(posedge clk); #1;

    // The reason rx_err is registered at all: equal half-cells with NO strobe
    // are not an error, they are an idle line. The combinational version
    // asserted continuously between frames and whenever another protocol had
    // Manchester bypassed, so rx_err could not be OR'd with the stuffer's.
    rx_first=1'b1; rx_second=1'b1; bit_en=1'b0; #1;
    @(posedge clk); #1;
    check(rx_err === 1'b0, "equal halves without a strobe are not an error");

    // Bypass
    bypass = 1; tx_raw = 1'b1; rx_wire = 1'b0;
    rx_cell(1'b1, 1'b1);
    check(tx_wire === 1'b1, "bypass tx passthrough");
    check(rx_raw === 1'b0, "bypass rx passthrough");
    check(rx_err === 1'b0, "bypass suppresses error");

    if (errors == 0) $display("PASS: tb_pe_manch");
    else $display("FAILURES manch: %0d", errors);
    $finish;
  end
endmodule


// ----------------------------------------------------------- Bit stuffing
module tb_pe_bitstuff;
  logic clk=0, rst_n, bit_en, bypass, clr;
  logic [3:0] run_cfg;
  logic tx_raw, tx_wire, tx_stuffed;
  logic rx_wire, rx_raw, rx_raw_valid, rx_err;
  pe_bitstuff dut (.*);
  always #5 clk = ~clk;
  integer errors = 0;
  integer seed = 7;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL stuff: %s @%0t", m, $time); errors++; end
  endtask

  task automatic strobe(); bit_en = 1; @(posedge clk); #1; bit_en = 0; #1; endtask

  // TX one raw bit; returns the wire bit this strobe emitted.
  task automatic tx_bit(input bit b, output bit w);
    tx_raw = b; #1;
    w = tx_wire;
    strobe();
  endtask

  // Emit the owed stuff bit (raw input ignored on this strobe).
  task automatic tx_stuff(output bit w);
    #1;
    check(tx_stuffed === 1'b1, "stuff strobe flagged");
    w = tx_wire;
    strobe();
    #1;
    check(tx_stuffed === 1'b0, "stuff flag clears after the strobe");
  endtask

  initial begin
    $dumpfile("tb_pe_bitstuff.vcd"); $dumpvars(0, tb_pe_bitstuff);
    rst_n=0; bit_en=0; bypass=0; clr=0; run_cfg=4'd5;
    tx_raw=0; rx_wire=0;
    repeat(3) @(posedge clk); #1; rst_n=1; @(posedge clk); #1;

    // ---- CAN (run_cfg=5): five 1s then a stuffed 0 ----
    begin
      bit w;
      clr = 1; @(posedge clk); #1; clr = 0;
      for (int k = 0; k < 5; k++) begin
        tx_bit(1'b1, w);
        check(w === 1'b1, $sformatf("can: data 1 at %0d", k));
      end
      check(tx_stuffed === 1'b1, "can: stuff owed after 5 ones");
      tx_stuff(w);
      check(w === 1'b0, "can: stuff bit complementary (0)");
      tx_bit(1'b0, w);
      check(w === 1'b0, "can: data resumes after stuff");
    end

    // ---- CAN: five 0s ----
    begin
      bit w;
      clr = 1; @(posedge clk); #1; clr = 0;
      for (int k = 0; k < 5; k++) begin
        tx_bit(1'b0, w);
        check(w === 1'b0, $sformatf("can0: data 0 at %0d", k));
      end
      tx_stuff(w);
      check(w === 1'b1, "can0: stuff bit complementary (1)");
    end

    // ---- USB (run_cfg=6): six 1s then a stuffed 0 ----
    begin
      bit w;
      run_cfg = 4'd6;
      clr = 1; @(posedge clk); #1; clr = 0;
      for (int k = 0; k < 6; k++) begin
        tx_bit(1'b1, w);
        check(w === 1'b1, $sformatf("usb: data 1 at %0d", k));
      end
      check(tx_stuffed === 1'b1, "usb: stuff owed after 6 ones");
      tx_stuff(w);
      check(w === 1'b0, "usb: stuff bit complementary");
    end

    // ---- Wire-stream round trip: TX all-ones (max stuffing), replay RX ----
    begin
      bit w; int nwire; logic wbits [128]; int nraw; logic rec [128];
      run_cfg = 4'd5;
      clr = 1; @(posedge clk); #1; clr = 0;
      nwire = 0;
      for (int k = 0; k < 64; k++) begin
        tx_bit(1'b1, w);
        wbits[nwire] = w; nwire++;
        if (tx_stuffed) begin
          tx_stuff(w);
          wbits[nwire] = w; nwire++;
        end
      end
      check(nwire > 64, "stuffing inserted extra wire bits");

      clr = 1; @(posedge clk); #1; clr = 0;
      nraw = 0;
      for (int i = 0; i < nwire; i++) begin
        rx_wire = wbits[i]; #1;
        if (rx_raw_valid) begin rec[nraw] = rx_raw; nraw++; end
        strobe();
      end
      check(nraw == 64, $sformatf("rx recovered 64 raw bits (got %0d)", nraw));
      for (int i = 0; i < 64; i++)
        check(rec[i] === 1'b1, $sformatf("rx recovered bit %0d = 1", i));
    end

    // ---- RX violation: bit after a full run is not complementary ----
    begin
      run_cfg = 4'd5;
      clr = 1; @(posedge clk); #1; clr = 0;
      for (int k = 0; k < 5; k++) begin
        rx_wire = 1'b1; #1; strobe();
      end
      rx_wire = 1'b1; #1;   // illegal: should have been a stuffed 0
      check(rx_raw_valid === 1'b0, "violating bit occupies the stuff slot");
      strobe(); #1;
      check(rx_err === 1'b1, "violation detected");
    end

    // ---- bypass ----
    begin
      bypass = 1; tx_raw = 1'b1; rx_wire = 1'b0; #1;
      check(tx_wire === 1'b1, "bypass tx passthrough");
      check(tx_stuffed === 1'b0, "bypass: no stuff");
      check(rx_raw_valid === 1'b1, "bypass: rx always valid");
      bypass = 0;
    end

    if (errors == 0) $display("PASS: tb_pe_bitstuff");
    else $display("FAILURES stuff: %0d", errors);
    $finish;
  end
endmodule
