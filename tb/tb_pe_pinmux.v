// tb_pe_pinmux.v — the pin matrix: direction, open-drain, read-back, arbitration.
//
// WHAT THIS PROVES, in the order wiki/plans/through-i2c.md cares about:
//
//   1. DRIVE LOW / RELEASE.  The I2C primitive: oe=1,out=0 pulls a pin low;
//      oe=0 releases it and the external pull-up wins.
//   2. THE PAD CANNOT BE DRIVEN HIGH ON AN OPEN-DRAIN BUS.  With od=1 and
//      out=1 the pad is RELEASED. This is the bus-contention property, and it
//      is checked on the MECHANISM (pad_oe) as well as the level, because the
//      pull-up also reads 1 -- a design that drove high would pass a
//      level-only check on an idle bus and short out against a slave on a busy
//      one.
//   3. READ-BACK DURING TRANSMIT == ARBITRATION.  The master releases to send a
//      1, reads the bus, and finds 0 because another master is pulling down.
//      The matrix must report the WIRE level, not the value we wrote; a
//      registered copy of `out` would pass a naive test and fail this one.
//   4. PUSH-PULL DRIVES HIGH FOR REAL.  UART TX idle, SPI CS_N, CAN
//      recessive all need a driven high, and the check distinguishes a genuine
//      strong drive from a released pin sitting at the pull-up level -- the two
//      read the same on an idle bus, which is why the wire model below tracks
//      them separately.
//   5. THE SAME FIRMWARE IDIOM WORKS IN BOTH MODES.  Toggling `out` sends bits
//      whether the pin is push-pull or open-drain. This is the project's thesis
//      ("swap the program, gates unchanged") reduced to one assertion, and it
//      is the reason the od bit earns its gates.
//   6. THE REGISTER FILE IS TOTAL.  OUT/OE/OD read back what was written, the
//      three are mutually independent, IN is read-only, and reset works from a
//      driven state rather than only from the reset state.
//
// THE WIRE MODEL, and why it is not one line.
//
// tb_pe_i2c.v models the bus as "released = 1, driven low = 0", which is all a
// single-master test needs. That model CANNOT catch the interesting failures
// here, for one reason: a released pin and a pin driven high both read 1, so
// the model cannot tell the safety property from its violation. So this one
// tracks strong drive separately from the weak pull-up:
//
//   * `ours_low`  — we are driving low (strong 0)
//   * `ours_high` — we are driving high (strong 1; only reachable in push-pull)
//   * `other_low` — another device on the bus is pulling low (strong 0)
//   * everything else — the external pull-up holds the line at the weak level
//
// and it reports CONTENTION when a strong 1 meets a strong 0. On a real bus
// that is a short between two transistors; in the model it is a fault flag the
// testbench asserts never fires. That assertion is the whole point: the od bit
// exists to make the hazardous state unreachable, so "contention never
// happened" is the property under test, not an incidental observation.

`timescale 1ns / 1ps

module tb_pe_pinmux;

  localparam int PINS = 8;

  // Register addresses (mirrors rtl/pe_pinmux.v).
  localparam logic [1:0] A_OUT = 2'd0,
                        A_OE  = 2'd1,
                        A_IN  = 2'd2,
                        A_OD  = 2'd3;

  logic            clk = 0, rst_n;
  logic            we;
  logic [1:0]      addr;
  logic [PINS-1:0] wdata, rdata;
  logic [PINS-1:0] pad_out, pad_oe;
  // The engine level overlay (a SoC-internal input): when ov_en[i] is set the
  // pad level comes from ov_bit instead of the OUT register, and the
  // open-drain gate must key off that overridden level.
  logic [PINS-1:0] ov_en  = '0;
  logic            ov_bit = 1'b0;

  // ---- the wire ----------------------------------------------------------
  logic [PINS-1:0] other_low = '0;      // another device pulling low
  wire  [PINS-1:0] pad_in;              // declared here: resolved by g_wire below

  wire  [PINS-1:0] ours_low  = pad_oe & ~pad_out;
  wire  [PINS-1:0] ours_high = pad_oe &  pad_out;
  wire  [PINS-1:0] contention = ours_high & other_low;

  // Per-pin wire resolution. This MUST be per-pin: an earlier version wrote the
  // resolution as a bus-wide ternary, which meant one pin pulling low dragged
  // the whole byte low and the "other pins stay high" checks failed for a
  // reason that had nothing to do with the DUT. A bus model that is wrong in
  // the same direction as a plausible DUT bug is worse than no model.
  genvar gw;
  generate
    for (gw = 0; gw < PINS; gw++) begin : g_wire
      assign pad_in[gw] = contention[gw]             ? 1'bx   // a short: indeterminate
                        : (ours_low[gw] | other_low[gw]) ? 1'b0 // a real pull-down
                        :                                  1'b1; // strong high or pull-up
    end
  endgenerate

  // Reported separately so the push-pull test can distinguish a real drive from
  // the pull-up. `driven_high` is true only where WE are pulling the line up.
  wire [PINS-1:0] driven_high = ours_high & ~other_low;

  pe_pinmux #(.PINS(PINS)) dut (
    .clk(clk), .rst_n(rst_n),
    .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .ov_en(ov_en), .ov_bit(ov_bit),
    .pad_in(pad_in), .pad_out(pad_out), .pad_oe(pad_oe)
  );

  localparam real CLK_NS = 10.0;
  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  integer contentions = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // Contention is checked continuously, not sampled: a one-cycle short between
  // two drivers is exactly the kind of glitch a sampled check misses.
  always @(*) if (|contention) contentions++;

  // ---------------- register access ----------------
  task automatic wr(input [1:0] a, input [PINS-1:0] d);
    @(posedge clk); #1;
    we = 1'b1; addr = a; wdata = d;
    @(posedge clk); #1;
    we = 1'b0;
  endtask

  logic [PINS-1:0] rd_val;
  task automatic rd(input [1:0] a);
    @(posedge clk); #1;
    addr = a;
    #1;
    rd_val = rdata;
  endtask

  task automatic do_reset();
    rst_n = 1'b0;
    we = 1'b0; addr = 2'd0; wdata = '0;
    other_low = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk); #1;
  endtask

  // Set a pin's mode in one go: what to drive, whether it participates, and
  // whether it is open-drain. This is the firmware idiom (three writes, or a
  // composed read-modify-write), written as a task because every test needs it.
  task automatic mode(input [PINS-1:0] o, input [PINS-1:0] e, input [PINS-1:0] od);
    wr(A_OUT, o); wr(A_OE, e); wr(A_OD, od);
    #1;
  endtask

  initial begin
    $dumpfile("tb_pe_pinmux.vcd");
    $dumpvars(0, tb_pe_pinmux);

    // ================================================================ reset
    do_reset();
    check(pad_oe  === 8'h00, "reset: oe must be 0 on every pin (released)");
    check(pad_out === 8'hFF, "reset: out must idle high on every pin");
    check(pad_in  === 8'hFF, "reset: nothing drives, so the pull-up holds the wire high");

    // =========================================== 1. drive low, then release
    // I2C START is exactly this: pull SDA low while SCL is still high.
    wr(A_OUT, 8'h00);            // out = 0: what to drive when participating
    #1;
    check(pad_in === 8'hFF, "out=0 with oe=0 must NOT pull the wire low: released means released");

    wr(A_OE, 8'h01);             // pin 0 participates -> driven low
    #1;
    check(pad_in[0] === 1'b0, "pin 0 driven low must pull the wire low");
    check(pad_in[7:1] === 7'h7F, "pins 7:1 are still released and stay high");
    check(pad_oe === 8'h01, "only pin 0 may be driving");

    wr(A_OE, 8'h00);             // release pin 0
    #1;
    check(pad_in === 8'hFF, "releasing pin 0 lets the pull-up take it high again");

    // ============================= 2. open-drain mode cannot drive high
    do_reset();
    mode(8'hFF, 8'h01, 8'h01);   // out=1, pin 0 participates, open-drain
    // THE SAFETY PROPERTY. od=1 with out=1 must RELEASE, not drive.
    check(pad_oe[0] === 1'b0,
          "OPEN-DRAIN: out=1 must release the pin, not drive it high");
    check(driven_high[0] === 1'b0,
          "OPEN-DRAIN: the pad must not be a strong high (that is the short)");
    check(pad_in[0] === 1'b1, "a released pin reads high on an idle bus");

    // And prove it against a real opponent: another master pulls low. If we
    // were driving high this would be contention; released, it is simply a
    // loss -- which the next test reads.
    other_low = 8'h01;
    #1;
    check(pad_in[0] === 1'b0, "another master pulling low must win over our released pin");
    check(|contention === 1'b0, "OPEN-DRAIN: no contention may occur on a released pin");
    other_low = '0;
    #1;

    // ============================== 3. read-back during transmit (arbitration)
    // The master sends a 1 on an open-drain bus: out=1 (which RELEASES in od
    // mode, per test 2). If another master is sending a 0, the line is low and
    // this master has lost arbitration. Firmware needs that level read during
    // the same bit cell it drove.
    do_reset();
    mode(8'hFF, 8'h01, 8'h01);   // intend a 1: out=1, od=1 -> released
    other_low = 8'h01;           // another master sends a 0 in the same cell
    #1;
    rd(A_IN);
    check(rd_val[0] === 1'b0,
          "ARBITRATION: released + another master low must read LOW (we lost)");
    check(rd_val[7:1] === 7'h7F, "unaffected pins read high");
    other_low = '0;
    #1;
    rd(A_IN);
    check(rd_val[0] === 1'b1, "with the other master gone the same release reads HIGH (we won)");

    // The mirror case: we intend a 0 (out=0, still od) and nobody fights us.
    mode(8'h00, 8'h01, 8'h01);
    rd(A_IN);
    check(rd_val[0] === 1'b0, "driving 0 in open-drain reads back 0");

    // ==================================== 4. push-pull drives high for real
    do_reset();
    mode(8'hFF, 8'h01, 8'h00);   // out=1, participating, PUSH-PULL
    check(pad_oe[0] === 1'b1, "push-pull high: oe must be asserted");
    check(pad_out[0] === 1'b1, "push-pull high: out must be 1");
    check(pad_in[0] === 1'b1, "push-pull high: the wire reads high");
    // The distinguishing check. A released pin ALSO reads 1 on an idle bus, so
    // "reads 1" proves nothing; `driven_high` proves WE are holding it up.
    check(driven_high[0] === 1'b1,
          "PUSH-PULL: a pin at 1 must be a STRONG drive, not the pull-up");
    // And an opponent pulling low must produce CONTENTION -- which is the
    // electrical fact that separates driving a 1 from releasing. On a real bus
    // this is a short between two transistors and the level is indeterminate;
    // the model reports X rather than picking a winner, because a model that
    // picked one would be hiding the fault it exists to expose. This is the one
    // test where contention is correct, and it is also the demonstration of why
    // open-drain mode forbids the state that causes it.
    other_low = 8'h01;
    #1;
    check(contention[0] === 1'b1,
          "PUSH-PULL: a driven high against another driver is contention (expected here)");
    check($isunknown(pad_in[0]),
          "PUSH-PULL: contention leaves the line indeterminate, not resolved to a level");
    contentions = 0;             // the one above was deliberate; arm the counter again
    other_low = '0;
    #1;

    // ============== 5. the SAME firmware idiom sends bits in both modes
    // Push-pull and open-drain must both send a 1 with out=1 and a 0 with
    // out=0, so a bit-banging loop written for one drives the other. If this
    // fails, "reprogram the chip instead of rebuilding it" is false for I2C.
    // Push-pull first.
    do_reset();
    mode(8'hFF, 8'h01, 8'h00);   // push-pull, participating
    check(pad_in[0] === 1'b1, "push-pull: out=1 sends a 1");
    mode(8'h00, 8'h01, 8'h00);
    check(pad_in[0] === 1'b0, "push-pull: out=0 sends a 0");
    mode(8'hFF, 8'h01, 8'h01);   // now the same two writes, open-drain
    check(pad_in[0] === 1'b1, "open-drain: out=1 sends a 1");
    check(driven_high[0] === 1'b0, "open-drain: and sends it by RELEASING, not driving");
    mode(8'h00, 8'h01, 8'h01);
    check(pad_in[0] === 1'b0, "open-drain: out=0 sends a 0");
    check(pad_oe[0] === 1'b1, "open-drain: and sends it by driving low");
    check(contention[0] === 1'b0, "open-drain: still no contention");

    // ============================ 6. oe remains authoritative in od mode
    // od selects the drive STYLE; oe selects whether the pin participates at
    // all. od=1 with oe=0 must be inert, or a pin nobody configured would
    // still move with every write to OUT.
    mode(8'h00, 8'h00, 8'h01);   // od=1 but not participating, out=0
    check(pad_oe[0] === 1'b0, "od=1 with oe=0 must be released (oe is authoritative)");
    check(pad_in[0] === 1'b1, "and must not pull the wire low");

    // ======================================== 7. the register file is total
    do_reset();
    wr(A_OUT, 8'hA5);  rd(A_OUT); check(rd_val === 8'hA5, "OUT readback");
    wr(A_OE,  8'h3C);  rd(A_OE);  check(rd_val === 8'h3C, "OE readback");
    wr(A_OD,  8'h0F);  rd(A_OD);  check(rd_val === 8'h0F, "OD readback");

    // A write to IN must be a no-op and must not disturb anything. Read-only
    // registers that silently accept writes are how one firmware typo becomes a
    // mystery bug three protocols later.
    wr(A_IN, 8'hFF);
    rd(A_OUT); check(rd_val === 8'hA5, "a write to IN must not change OUT");
    rd(A_OE);  check(rd_val === 8'h3C, "a write to IN must not change OE");
    rd(A_OD);  check(rd_val === 8'h0F, "a write to IN must not change OD");

    // The three registers must be mutually independent. A shared write-enable
    // or a mis-decoded address would pass every test above and fail this.
    wr(A_OUT, 8'hF0);
    rd(A_OE); check(rd_val === 8'h3C, "writing OUT must not disturb OE");
    rd(A_OD); check(rd_val === 8'h0F, "writing OUT must not disturb OD");
    wr(A_OE, 8'h0E);
    rd(A_OUT); check(rd_val === 8'hF0, "writing OE must not disturb OUT");
    rd(A_OD);  check(rd_val === 8'h0F, "writing OE must not disturb OD");
    wr(A_OD, 8'h11);
    rd(A_OUT); check(rd_val === 8'hF0, "writing OD must not disturb OUT");
    rd(A_OE);  check(rd_val === 8'h0E, "writing OD must not disturb OE");

    // ============================ 8. reset is reachable from a driven state
    // A reset that only works from the reset state has never been tested.
    wr(A_OUT, 8'h00);
    wr(A_OE,  8'hFF);
    wr(A_OD,  8'hFF);
    #1;
    check(pad_oe !== '0, "pre-reset: pins are driving (the state reset must undo)");
    do_reset();
    check(pad_oe  === 8'h00, "reset must release every pin");
    check(pad_out === 8'hFF, "reset must return OUT to its idle-high value");
    check(pad_in  === 8'hFF, "reset must leave the wire pulled high");
    rd(A_OD);
    check(rd_val === 8'h00, "reset must return OD to push-pull");

    // ======================================= the engine level overlay (A1/integration)
    // The override lives BEFORE the open-drain gate and must feed both
    // outputs: pad_out carries the overlay level on the selected pin, and the
    // od gate must read the OVERIDDEN level -- an engine 0 on an od=1 pin whose
    // register holds 1 must PULL LOW, not release (that is the exact bug the
    // plan rejects a post-matrix mux for).
    wr(A_OUT, 8'hFF); wr(A_OE, 8'hFF); wr(A_OD, 8'h00);
    ov_en = 8'h04; ov_bit = 1'b0;               // overlay pin 2 low
    #1;
    check(pad_out === 8'hFB, "overlay level must replace the register level on the selected pin");
    check(pad_out[7:3] === 5'h1F, "pins without ov_en keep the register level");
    check(pad_oe  === 8'hFF, "push-pull overlay pin still drives (oe untouched)");
    wr(A_OD, 8'h04);                            // pin 2 open-drain, register holds 1
    #1;
    check(pad_out[2] === 1'b0, "od gate must see the overlay level (engine 0 pulls low)");
    check(pad_oe[2]  === 1'b1, "od pin with overlay 0 must DRIVE low, not release");
    ov_bit = 1'b1;
    #1;
    check(pad_oe[2]  === 1'b0, "od pin with overlay 1 must release");
    ov_en = '0; ov_bit = 1'b0;
    wr(A_OD, 8'h00); wr(A_OE, 8'h00); wr(A_OUT, 8'hFF);
    #1;
    check(pad_out === 8'hFF, "overlay off restores the register level");
    check(pad_oe  === 8'h00, "overlay off restores the reset drive state");

    // ==================================================== the contention count
    // Every deliberate contention above was consumed by resetting the counter.
    // Any remaining count is a hazard the design produced on its own -- which
    // is precisely what the od bit is supposed to make impossible.
    check(contentions == 0,
          $sformatf("no contention may occur outside the deliberate push-pull test (saw %0d)", contentions));

    if (errors == 0) $display("PASS: tb_pe_pinmux");
    else $display("FAILURES pinmux: %0d", errors);
    $finish;
  end

  initial begin
    #1_000_000;
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
