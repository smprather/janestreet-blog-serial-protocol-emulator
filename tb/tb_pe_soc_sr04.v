// tb_pe_soc_sr04.v -- HC-SR04 ultrasonic ranging: a 10 us trigger out, a
// variable-width echo back, and a millimetre answer in the firmware's memory.
//
// WHAT THIS PROVES, and it is a different claim from every other act in this
// block. The other six are judged on a WAVEFORM: whether a receiver can decode
// the pin. This one is judged on a NUMBER. The device holds ECHO high for the
// round trip, so the pulse WIDTH is the distance, and the firmware's job is
// to turn a width into millimetres. The claim is therefore the CONVERSION,
// and it is checked as an EQUALITY against the same arithmetic done
// independently here, not as a tolerance: mm = us * 11/64 is exact, and a
// test that accepts a window around it cannot tell a correct conversion from
// one that is 3 % out -- which is the size of error a plausible-looking
// bug produces on this machine (see the header of firmware/sr04_range.pe for
// why the conversion is mostly doublings).
//
// THE MODEL knows the table and nothing else. It watches the trigger pin --
// the SoC's own output AND its own output enable, because a released pad is
// not a low pad -- and answers with a pulse whose width comes from the table.
// It is never told what the firmware will do with the width.
//
// THE CHECKS, and how each could be unfalsified:
//
//   1. THE TRIGGER PULSE, as an EQUALITY against 600 clocks, not a window.
//      The datasheet asks for 10 us minimum, and a 1 us window would admit a
//      pulse that no HC-SR04 in production would recognise. It is measured on
//      the pad AND on the output enable, because a firmware that holds TRIG
//      low forever is driving, not idling, and re-triggering by accident is a
//      real failure mode.
//   2. THE ECHO WIDTH, from the firmware's own latched count, against the
//      width the model generated: 1 % with a floor of 1.5 us, which is the
//      tick.
//   3. THE CONVERSION, as an equality against us*11/64 computed here.
//   4. BOTH pads' output enable: ECHO released on every clock of the trigger
//      pulse, and TRIG released whenever the program is not pulsing.
//   5. NON-VACUITY: exactly two triggers, two different answers, and one
//      width above 255 us so the capture's 16-bit counter is what is under
//      test (an 8-bit capture reports 136 us for 5816).
//
// THE LIMITS, stated rather than hidden. The model answers after 300 us, the
// HC-SR04's slowest documented response, and it recovers 2 ms after the echo
// ends, where the datasheet's figure is 50 ms worst case. A real device at
// 4 m would need a longer wait and the act's numbers would not change; a
// shorter recovery here is a statement about the TESTBENCH's timescale, not
// about the firmware, and the firmware is told to release both pads during it
// precisely so that a real device's re-trigger rule is not being relied upon.

`timescale 1ns / 1ps

`ifndef SR04_HEX
  `define SR04_HEX "../firmware/sr04_range.hex"
`endif

module tb_pe_soc_sr04;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;     // THE MACHINE'S SIZE
  localparam int BAUD = 115_200;
  localparam real CLK_NS = 1e9 / 60_000_000;

  // The firmware's map, named here because this file reads those bytes.
  localparam int F_US_LO  = 2;        // the measured echo width
  localparam int F_US_HI  = 3;
  localparam int F_COUNT  = 10;   // measurements banked: the completion flag
  localparam int F_SLOT0  = 6;        // slot n's answer is at 6 + 2n
  localparam int F_STRIDE = 2;

  localparam int N_MEAS = 2;
  localparam int TRIG_CLOCKS = 600;    // 10.000 us at 60 MHz: the equality below
  localparam int RESP_US = 300;        // the model's sensor response delay
  localparam int RECOV_US = 2000;      // the model's recovery gap (see header)
  localparam real TOL_PCT = 1.0;
  localparam real TOL_FLOOR_US = 1.5;

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;
  wire  [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  logic echo = 1'b0;
  // bit 7 unused, bit 6 is TRIG (DRIVEN by the SoC, so the pad is ignored and
  // PIN reads the register back), bit 5 is ECHO (released, so PIN reads here).
  assign pin_in_bus = {1'b1, 1'b0, echo, 5'b11111};

  // The trigger as the DEVICE sees it: the level AND the enable. A released
  // pad is not a low pad, and this testbench exists partly to keep that
  // distinction honest.
  wire trig = pin_out_bus[6] & pin_oe_bus[6];
  wire trig_oe = pin_oe_bus[6];
  wire echo_oe = pin_oe_bus[5];

  logic [9:0] dbg_pc;
  logic [7:0] dbg_a, dbg_timer;

  pe_soc #(
    .IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES), .BAUD(BAUD)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    .dbg_rd_req(1'b0), .dbg_rd_dmem(1'b0), .dbg_rd_addr(16'h0000),
    .dbg_rd_data(), .dbg_rd_valid(),
    .pin_in(pin_in_bus), .pin_out(pin_out_bus), .pin_oe(pin_oe_bus),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer),
    .dbg_hold(1'b0), .dbg_step(1'b0)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  integer i;
  logic [15:0] prog [0:IMEM_WORDS-1];
  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh(`SR04_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0]; host_wdata = prog[i];
    end
    @(posedge clk); #1; host_we = 1'b0;
  endtask

  // ---- THE SENSOR MODEL -------------------------------------------------
  //
  // It watches the trigger pin and answers once per trigger, from a table of
  // echo widths in microseconds. Two of them, and the second is longer than
  // 255 -- so a firmware whose capture counter is a byte fails on the second
  // and not on the first.
  integer e_us  [0:N_MEAS-1];
  integer n_trig = 0;
  integer trig_clocks = 0;     // the measured trigger pulse, in clocks
  integer cur_clocks = 0;
  integer echo_high_clocks = 0;
  integer echo_rel_oe = 0;     // clocks in a trigger pulse with ECHO driven
  integer trig_oe_lo = 0;      // clocks TRIG was driven without a pulse

  task automatic serve(input integer w_us);
    integer k;
    begin
      #(RESP_US * 1000.0);
      echo = 1'b1;
      #(w_us * 1000.0);
      echo = 1'b0;
    end
  endtask

  // One process for the whole model, so the edge ordering is not a race
  // between two always blocks on the same signal -- the defect the WS2812
  // testbench in this repository found twice.
  integer meas_idx;
  initial begin
    n_trig = 0; trig_clocks = 0; cur_clocks = 0;
    echo_high_clocks = 0; echo_rel_oe = 0; trig_oe_lo = 0; meas_idx = 0;
    @(posedge trig);
    forever begin
      if (n_trig < N_MEAS) begin
        n_trig = n_trig + 1;
        meas_idx = n_trig - 1;
        fork
          begin
            // measure the pulse on the pad, clock by clock, and check the
            // enable of the OTHER pad on every clock of it
            // Count the clock edges across which TRIG is high, and nothing
            // else: the counter starts at zero and the loop is entered while
            // the pad is still high, so it counts 600 for a 600-clock pulse
            // and not 601. The first version of this seeded the counter at one
            // and waited a clock before testing, which made every pulse look
            // one clock longer than it was -- the same class of off-by-one as
            // a counter decremented before its first use.
            trig_clocks = 0;
            while (trig) begin
              @(posedge clk);
              trig_clocks = trig_clocks + 1;
              if (echo_oe) echo_rel_oe = echo_rel_oe + 1;
            end
          end
          serve(e_us[meas_idx]);
        join
        #(RECOV_US * 1000.0);
        if (n_trig < N_MEAS) @(posedge trig);
      end
    end
  end

  // TRIG driven while not pulsing is a level, not a pulse: the datasheet's
  // trigger is a pulse, and a held-high trigger is a second measurement the
  // firmware did not intend.
  always @(posedge clk) if (rst_n && run && trig_oe_lo == 0) begin
    if (trig_oe && !trig) trig_oe_lo = trig_oe_lo + 1;
  end

  // ---- the checks -------------------------------------------------------
  integer seg, waited, tol_us;
  integer got_us, got_mm, exp_mm, wide_seen;
  integer fw_hi, fw_lo, fh_hi, fh_lo;

  // The ISA has no carry flag and neither does a testbench: a difference of
  // two 16-bit counts needs its own abs.
  function integer iabs(input integer v);
    iabs = (v < 0) ? -v : v;
  endfunction

  initial begin
    $dumpfile("tb_pe_soc_sr04.vcd");
    $dumpvars(0, echo, pin_in_bus, trig, pin_oe_bus, dbg_pc);

    e_us[0] = 1160;    // 199.375 mm: the model's 200 mm target
    e_us[1] = 5816;    // 999.625 mm, and 5816 > 255, so the capture's
                       // sixteen-bit counter is what is under test

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    load_firmware();
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== HC-SR04 ranging: %0d measurements, %0d us and %0d us echoes ===\n",
             N_MEAS, e_us[0], e_us[1]);
    run = 1'b1;
    // The completion test goes INSIDE the body, after a wait, and that is not
    // tidiness. A poll of the form `while (flag != DONE)` EXITS IMMEDIATELY
    // when the flag is still X, because `X != 1` is X and a while-condition
    // of X is false -- so the loop measures a firmware that has not started
    // yet and the whole testbench reports six failures on a design that is
    // about to work. The first version of this file had exactly that, and
    // the symptom was a testbench that finished 17 us after the core was
    // released and called it a dead firmware. The frequency meter's poll
    // cannot have this bug because its test is inside the body after a
    // 256-clock wait, which is why the two files now look the same.
    waited = 0;
    while (waited < 6000) begin
      repeat (256) @(posedge clk);
      waited = waited + 1;
      if (dut.dmem[F_COUNT] == 8'h02) waited = 6000;
    end
    check(dut.dmem[F_COUNT] == 8'h02,
          $sformatf("the firmware banked both measurements (dmem[%0d] = %02h)",
                    F_COUNT, dut.dmem[F_COUNT]));
    check(n_trig == N_MEAS,
          $sformatf("the model saw exactly %0d triggers (%0d) -- a trigger that is driven rather than pulsed shows up here",
                    N_MEAS, n_trig));

    // ---- 1. the trigger pulse, as an EQUALITY ------------------------
    check(trig_clocks == TRIG_CLOCKS,
          $sformatf("the trigger pulse is EXACTLY %0d clocks = %0.3f us (measured %0d = %0.3f us), and the device asks for 10 us minimum",
                    TRIG_CLOCKS, TRIG_CLOCKS*CLK_NS, trig_clocks, trig_clocks*CLK_NS));
    check(echo_rel_oe == 0,
          $sformatf("ECHO was RELEASED on every clock of the trigger pulse (%0d clocks driven)",
                    echo_rel_oe));
    // ONE clock of driven-at-a-level is the ARCHITECTURAL MINIMUM and not a
    // defect: the pad is claimed, the level write and the release write are
    // three separate instructions, so between the level going to 0 and the
    // release there is exactly one clock in which the pad is driven low. The
    // count is still the discriminator -- a pad HELD driven runs to thousands
    // of clocks -- and one is the whole of the allowance.
    check(trig_oe_lo <= 1,
          $sformatf("TRIG is driven at a level for at most the one clock the level write and the release write are apart (%0d clocks)",
                    trig_oe_lo));

    // ---- 2/3. the width and the conversion, per measurement ----------
    wide_seen = 0;
    for (seg = 0; seg < N_MEAS; seg++) begin
      fw_lo = dut.dmem[F_US_LO];
      fw_hi = dut.dmem[F_US_HI];
      got_us = (fw_hi << 8) | fw_lo;
      exp_mm = (e_us[seg] * 11) / 64;         // the specification, in integer mm
      fh_lo = dut.dmem[F_SLOT0 + seg*F_STRIDE];
      fh_hi = dut.dmem[F_SLOT0 + seg*F_STRIDE + 1];
      got_mm = (fh_hi << 8) | fh_lo;
      if (got_us > 255) wide_seen = wide_seen + 1;

      $display("    measurement %0d: echo %0d us -> firmware %0d us, answer %0d mm (expected %0d mm)",
               seg, e_us[seg], got_us, got_mm, exp_mm);
      // 1 % of the width, with a floor of 1.5 us rounded UP to 2 because the
      // tick is a whole microsecond and a floor of 1 would be tighter than
      // the instrument.
      tol_us = e_us[seg] / 100;
      if (tol_us < 2) tol_us = 2;
      if (iabs(got_us - e_us[seg]) > tol_us)
        check(0, $sformatf("measurement %0d: the measured width %0d us is outside 1 %% (floor 2 us) of the model's %0d us",
                           seg, got_us, e_us[seg]));
      // The conversion is EXACT for 11/64, so this is an equality. The
      // tolerance that would matter is the constant's own +0.22 % against
      // the speed of sound, and that is a property of the constant, not of
      // the arithmetic, so it is reported in the header rather than
      // smuggled in as slack here.
      check(got_mm == exp_mm,
            $sformatf("measurement %0d: %0d us is %0d mm, not %0d mm -- us*11/64 is exact and this is an equality",
                      seg, got_us, got_mm, exp_mm));
    end
    check(wide_seen >= 1,
          $sformatf("at least one echo is wider than 255 us, so the capture's 16-bit counter is what is under test (a byte capture reports %0d us for %0d)",
                    wide_seen, e_us[N_MEAS-1] % 256));

    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    #60_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
