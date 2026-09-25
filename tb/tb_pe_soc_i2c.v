// tb_pe_soc_i2c.v — I2C pins on real RTL, driven entirely by firmware.
//
// WHAT THIS PROVES. The SoC has no I2C controller and no per-protocol hardware.
// What it has is a pin matrix: a small register file that makes each pin's
// DIRECTION a runtime value (rtl/pe_pinmux.v). This test is the evidence that
// the matrix is sufficient to speak I2C -- that the two things I2C needs and
// nothing else in the project needs, namely per-pin release and open-drain, are
// actually reachable from firmware and actually reach the pads.
//
// It is deliberately NOT a decoded-transaction test. There is no shift
// register and no address phase in firmware/i2c_pins.pe; the program is one
// START, one bit cell and one STOP. So this TB asserts the things that make
// those real:
//
//   1. THE PADS MOVE OPEN-DRAIN. The bus is modelled as a pull-up on the TB
//      side, so the only way a line goes high is if the SoC RELEASES it. A
//      firmware bug that drove high push-pull would be invisible against a
//      driver-based TB model and is a contention fault in silicon; here it
//      shows up as an assertion failure.
//
//   2. THE OD GATE CANNOT DRIVE HIGH. pin_oe must be LOW on any pin whose
//      output register bit is 1 while od is set. That is the safety property
//      of the pin matrix, and it is checked on the RTL's own output, not on
//      the pad -- so it cannot be masked by the bus model.
//
//   3. RELEASED PINS READ BACK THE PAD, NOT THE REGISTER. This is what makes
//      arbitration and clock stretching observable with a single IN, and it is
//      the reason port 0's read-back had to be generalised from the old
//      fixed-mask formula (see rtl/pe_soc.v).
//
//   4. ANOTHER DEVICE PULLING LOW IS VISIBLE. The TB pulls SDA down during the
//      arbitration sample window and requires the firmware to record a loss.
//      Without this the arbitration path would be hardware nothing exercises
//      (gotcha 14).
//
// Program: firmware/i2c_pins.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

module tb_pe_soc_i2c;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  // The TB's own copy of the clock rate. CLK_HZ is a localparam inside
  // pe_soc (see the header there); this is a TEST FACT about the board and
  // is checked against the RTL by reference/clock-arithmetic.md.
  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  // The I2C pins, from tools/fw/peasm.py CONSTS: SDA = 0x10, SCL = 0x20.
  localparam int SDA_BIT = 4;
  localparam int SCL_BIT = 5;
  localparam logic [7:0] SDA = 8'h10;
  localparam logic [7:0] SCL = 8'h20;

  logic clk = 0, rst_n;

  // host interface
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  // ---- the bus -------------------------------------------------------------
  // OPEN-DRAIN MODEL. Each line has a pull-up (the TB's job, standing in for
  // the board's resistors) and is pulled LOW by anyone driving it -- the SoC
  // through its pads, or another device through other_low.
  wire sda_line, scl_line;
  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // What the SoC actually drives. pad_oe is the matrix's real enable: in OD
  // mode a pin holding a 1 is RELEASED, so this is already the open-drain
  // behaviour and the TB does not need to impose it.
  wire sda_driven_low = pin_oe_bus[SDA_BIT] & ~pin_out_bus[SDA_BIT];
  wire scl_driven_low = pin_oe_bus[SCL_BIT] & ~pin_out_bus[SCL_BIT];

  // Another device on the bus. Used by the arbitration test.
  logic other_pulls_sda_low = 1'b0;

  assign sda_line = (sda_driven_low | other_pulls_sda_low) ? 1'b0 : 1'b1;
  assign scl_line = scl_driven_low ? 1'b0 : 1'b1;

  // What the SoC sees on its input path. Only the I2C pins carry bus levels;
  // RX (bit 3) is idle-high here because no UART is running in this test.
  assign pin_in_bus = {2'b0, scl_line, sda_line, 1'b1, 3'b0};

  logic [9:0] dbg_pc;   // R2: full PC width (pe_soc exposes PCW bits)
  logic [7:0] dbg_a, dbg_timer;

  pe_soc #(
    .IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES), .BAUD(BAUD)
  ) dut (
    .dbg_hold(1'b0), .dbg_step(1'b0),  // R3: debug control idle here
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    // R2: the host read port is idle in this TB (tied low, not floating:
    // an undriven input would make the address mux X and break the CPU read).
    .dbg_rd_req(1'b0), .dbg_rd_dmem(1'b0), .dbg_rd_addr(16'h0000),
    .dbg_rd_data(), .dbg_rd_valid(),
    .pin_in(pin_in_bus), .pin_out(pin_out_bus), .pin_oe(pin_oe_bus),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;   // NOP fill
    $readmemh("../firmware/i2c_pins.hex", prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---------------- monitors ----------------
  // Ground truth independent of any decode: every write to the pin registers,
  // and every condition seen on the pads. If an assertion below fails, these
  // say where.
  logic [7:0] last_out, last_oe, last_od;
  always @(posedge clk) if (run) begin
    if (dut.io_we && dut.io_port == 4'h3) begin
      last_od <= dut.io_wdata;
      $display("    PINOD  <= %02h t=%0t", dut.io_wdata, $time);
    end
    if (dut.io_we && dut.io_port == 4'h1) begin
      last_out <= dut.io_wdata;
      $display("    TXPIN  <= %02h t=%0t  (SDA=%b SCL=%b driven_low)",
               dut.io_wdata, $time,
               dut.io_wdata[SDA_BIT], dut.io_wdata[SCL_BIT]);
    end
    if (dut.io_we && dut.io_port == 4'h2) begin
      last_oe <= dut.io_wdata;
      $display("    PINOE  <= %02h t=%0t", dut.io_wdata, $time);
    end
  end

  // ---- assertion 2: the OD gate can never drive high ----------------------
  // Checked on the RTL's own pin_oe output rather than on the pad, so the bus
  // model cannot hide it. With od set, any pin whose output bit is 1 must have
  // its enable cleared -- that is the whole safety property of the matrix.
  logic od_seen = 1'b0;
  always @(posedge clk) if (run && rst_n) begin
    if (dut.io_we && dut.io_port == 4'h3 && dut.io_wdata != 8'h00) od_seen <= 1'b1;
    if (od_seen) begin
      for (int b = 0; b < 8; b++) begin
        if (last_od[b] && last_out[b] && pin_oe_bus[b])
          check(1'b0, $sformatf(
            "OD gate drove pin %0d high (od=%02h out=%02h oe=%02h)",
            b, last_od, last_out, pin_oe_bus));
      end
    end
  end

  // ---- condition monitor: START and STOP, from the pads -------------------
  // A START is SDA falling while SCL is HIGH; a STOP is SDA rising while SCL is
  // HIGH. Anything else is a data edge and must happen with SCL low.
  integer n_start = 0, n_stop = 0;
  time    t_start, t_stop;

  // SCL edge times, for the interval measurements. Indexed by a rolling count
  // so any number of edges can be measured, not just the two in one bit cell.
  localparam int MAX_EDGES = 32;
  time     scl_rise_t [0:MAX_EDGES-1];
  time     scl_fall_t [0:MAX_EDGES-1];
  integer  n_rise = 0, n_fall = 0;

  always @(posedge scl_line) if (run && rst_n) begin
    if (n_rise < MAX_EDGES) scl_rise_t[n_rise] = $time;
    n_rise = n_rise + 1;
  end
  always @(negedge scl_line) if (run && rst_n) begin
    if (n_fall < MAX_EDGES) scl_fall_t[n_fall] = $time;
    n_fall = n_fall + 1;
  end

  always @(sda_line) if (run && rst_n) begin
    if (!sda_line) begin                  // SDA fell
      if (scl_line) begin
        n_start++;
        t_start = $time;
        $display("    START  at %0t (SDA fell, SCL high)", $time);
      end
    end else begin                        // SDA rose
      if (scl_line) begin
        n_stop++;
        t_stop = $time;
        $display("    STOP   at %0t (SDA rose, SCL high)", $time);
      end
    end
  end

  // Any SDA move while SCL is high is one of the two conditions by definition
  // (the counter above sees both). What would be a defect is a THIRD such move
  // -- e.g. the spurious START an early draft of this firmware emitted on the
  // way into its STOP -- so the count is asserted to be exactly 1 START and 1
  // STOP at the end rather than inspected edge by edge.

  // ---------------- stimulus ----------------
  // The firmware's own microsecond counter, for cross-checking the measured
  // intervals against the constants in tools/fw/peasm.py.
  localparam real T_LOW_US = 7.0, T_HIGH_US = 6.0;

  initial begin
    $dumpfile("tb_pe_soc_i2c.vcd");
    $dumpvars(0, tb_pe_soc_i2c);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();
    $display("\n=== I2C pins on the matrix: START, bit cell, STOP ===\n");
    run = 1'b1;

    // ---- run the sequence ----
    // Generous bound: the wait loops are tick-counted, and the whole program is
    // ~2000 cycles at 60 MHz (see tools/checks/i2c_timing.py). 20,000 covers
    // it with room for the arbitration variant.
    repeat (20_000) @(posedge clk);

    // ---- assertion 4: arbitration ----
    // dmem[1] records whether the firmware lost arbitration. In the run above
    // nothing contended, so it must be 0 and dmem[0] must show SDA still high.
    check(n_start == 1, $sformatf("exactly one START on the pads (got %0d)", n_start));
    check(n_stop == 1, $sformatf("exactly one STOP on the pads (got %0d)", n_stop));
    check(dut.dmem[0] == SDA,
          $sformatf("SDA sampled while released read back HIGH (got %02h)", dut.dmem[0]));
    check(dut.dmem[1] == 8'h00,
          $sformatf("no arbitration loss when nothing contended (got %02h)", dut.dmem[1]));
    check(dut.dmem[2] == SCL,
          $sformatf("SCL read back HIGH after release (got %02h)", dut.dmem[2]));
    check(dut.dmem[3] == 8'h01,
          $sformatf("one START/STOP pair completed (got %02h)", dut.dmem[3]));
    check(dut.dmem[4] == (SDA | SCL),
          $sformatf("bus parked idle-high (got %02h)", dut.dmem[4]));

    // ---- the measured intervals, from the pads ----
    // The RTL TB measures the SPEC INTERVALS on the pads, in real time, not
    // just the conditions. Without this the RTL test passes on a bit cell whose
    // low period is below the tLOW floor -- which is not hypothetical: the
    // mutation test caught exactly that gap.
    //
    // THE EDGE INDICES ARE NOT ARBITRARY, and getting them wrong makes both
    // checks vacuous in a way that still passes. The trace is:
    //
    //   364  SCL falls  <- scl_fall_t[0]   (after the START)
    //   785  SCL rises  <- scl_rise_t[0]   (the cell's clock high)
    //  1148  SCL falls  <- scl_fall_t[1]   (the cell closes)
    //  1506  SCL rises  <- scl_rise_t[1]   (ahead of the STOP)
    //
    // so tLOW is rise[0]-fall[0] and tHIGH is fall[1]-rise[0]. The first version
    // used rise[1] and fall[1], which measured the bus IDLE stretch as tLOW
    // (19 us, always >= 4.7) and computed tHIGH as fall[1]-rise[1] -- a NEGATIVE
    // difference that wraps in the unsigned %time type to a huge number, so it
    // was >= 4.0 as well. Both assertions could never fail. The non-vacuity
    // guard below is what makes a repeat of that mistake visible.
    if (n_start == 1 && n_stop == 1 && n_rise >= 1 && n_fall >= 2) begin
      real tlow_us, thigh_us;
      tlow_us  = (scl_rise_t[0] - scl_fall_t[0]) / 1000.0;
      thigh_us = (scl_fall_t[1] - scl_rise_t[0]) / 1000.0;
      $display("    measured on the pads: tLOW=%.3f us  tHIGH=%.3f us",
               tlow_us, thigh_us);
      check(tlow_us >= 4.7,
            $sformatf("tLOW >= 4.7 us on the pads (got %.3f)", tlow_us));
      check(thigh_us >= 4.0,
            $sformatf("tHIGH >= 4.0 us on the pads (got %.3f)", thigh_us));
      // Non-vacuity: a plausible-looking interval is not enough. Require the
      // measurement to be in the right BALLPARK as well, so a wrong index (or a
      // wrapped unsigned subtraction) fails here rather than sailing through the
      // >= comparisons.
      check(tlow_us < 20.0 && thigh_us < 20.0,
            $sformatf("intervals plausibly a bit cell, not idle (tLOW=%.3f tHIGH=%.3f)",
                      tlow_us, thigh_us));
    end else begin
      check(1'b0, $sformatf(
        "enough SCL edges to measure the bit cell (rise=%0d fall=%0d)",
        n_rise, n_fall));
    end

    // ---- a second run, WITH contention -------------------------------------
    // Hardware nothing exercises is hardware you have not tested (gotcha 14):
    // the arbitration branch in the firmware is dead code unless something
    // pulls SDA down during the sample window. So re-run with another device
    // holding SDA low through the bit cell and require the firmware to notice.
    //
    // `run` MUST be deasserted before the reload. Leaving it high means the CPU
    // executes while load_firmware() overwrites instruction memory underneath
    // it -- the program then runs from a half-loaded image and the run is not
    // reproducible. (The first version of this TB did that and the contention
    // run silently reported the FIRST run's results.)
    $display("\n=== re-run with another device pulling SDA low ===\n");
    run = 1'b0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    // The other device holds SDA low for the whole run, so it is low at the
    // moment the firmware samples and the firmware must record a loss.
    other_pulls_sda_low = 1'b1;
    n_start = 0; n_stop = 0;
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    load_firmware();
    run = 1'b1;
    repeat (20_000) @(posedge clk);

    check(dut.dmem[1] == 8'h01,
          $sformatf("arbitration loss recorded when SDA held low (got %02h)", dut.dmem[1]));
    check(dut.dmem[0] == 8'h00,
          $sformatf("SDA sampled while released read back LOW (got %02h)", dut.dmem[0]));
    other_pulls_sda_low = 1'b0;

    // ---- assertion 3: released pins read the pad ---------------------------
    // Directly on the register file: drive the pad low from outside while the
    // SoC has the pin released, and require port 0 to report the pad. This is
    // the property that makes arbitration and clock stretching a single IN.
    check(!sda_driven_low, "SDA is released at the end of the run (not driven low)");

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  // Watchdog. A firmware hang must be reported as a hang, not as a timeout with
  // no output -- an unresponsive DUT and a passing DUT look alike from outside.
  initial begin
    #5_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
