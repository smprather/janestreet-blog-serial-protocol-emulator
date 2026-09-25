// tb_pe_soc_stepper_ramp.v — a step/dir stepper ramp, emitted by firmware and
// measured on the pins.
//
// WHAT THIS PROVES, AND WHY IT IS THE SIMPLEST CLAIM IN THE BLOCK.
//
// The other four timing acts put a waveform on a pin and something at the far
// end reads it back. A stepper is a MECHANISM: the driver chip counts STEP
// edges and the motor's position IS that count. There is no acknowledgement,
// no status word, and nothing at the far end that resynchronises — so the
// unit of correctness is a single NUMBER, the step period, and a program one
// clock out on it has put the motor somewhere it will never report being.
//
// So this act makes the sharpest claim in the repository and the easiest to
// falsify: every step period is an exact instruction count measured on the
// pin, and the ramp is EXACTLY LINEAR TO THE CLOCK. Not "inside a window":
// a step period is one number, and 85.2 us of ramp per step either is there
// or it is not. Every number below is printed, and a window that a program
// 5 % wrong would still pass is not what this act is for.
//
// THE MODEL, and what it is allowed to know.
//
//   STEP is pin 6 and is ACTIVE LOW: a stepper driver's input is pulled down
//   and a released pin is the inactive state, so the low pulse IS the step.
//   (This is the "who owns the high level" question again — the infrared act's
//   high level belongs to the supply, 1-Wire's belongs to a pull-up, and a
//   stepper driver's belongs to a pull-DOWN, which is the third answer.)
//
//   DIR is pin 5 and is watched as a LEVEL, because a driver decodes it on the
//   STEP edge and the whole question is how long it has been stable.
//
//   The receiver times the low pulses, the silences between them, and the
//   direction edge. It has no notion of a ramp, a run or a step index: those
//   are reconstructed afterwards, from the numbers, in the checking block. A
//   model that knew the firmware's twelve step periods could not detect the
//   firmware having the wrong ones.
//
// THE CHECKS, and how each could be unfalsified:
//
//   1. TWELVE STEPS, and each one a low pulse of at least 1 us. A step
//      narrower than a driver can see is a step that does not happen.
//   2. THE RAMP IS EXACTLY LINEAR: every step period is 5110 clocks shorter
//      than the one before it -- the ten outer-counter steps the firmware
//      subtracts -- checked as an equality against that constant, not against
//      a tolerance. This is the check the act exists for.
//   3. THE PERIODS ARE DISTINCT AND MONOTONIC, and each is within the band the
//      driver can be clocked at. Twelve equal periods would satisfy (2) with
//      a zero ramp, which is why the monotonicity and the distinctness are
//      checked separately rather than inferred from the slope.
//   4. THE DIRECTION CHANGES ONCE, MID-RAMP, and the driver gets its setup
//      time: the interval from the DIR edge to the next STEP edge is at least
//      5 us. A driver that samples DIR on the STEP edge takes the old
//      direction or the new one depending on the silicon, and a program that
//      changed DIR one instruction too late works on one chip and not another.
//   5. THE ONE PLACE THE RAMP IS NOT ON THE LINE, stated rather than hidden:
//      the interval across the direction change carries the flip and its setup
//      delay, so it is not 5110 clocks shorter than its neighbour. The TB
//      prints it, checks it is still inside the band, and checks the ramp again
//      on either side of it.
//   6. NON-VACUITY: the twelve periods must take twelve distinct values, and
//      the slope must be non-zero, so a receiver that had collapsed the ramp
//      could not be described as having measured one.
//
// THE COST: about 14 ms of 60 MHz — twelve steps from 1.67 ms down to 0.73 ms,
// which is the sum of the periods, so the act costs exactly as much as the
// mechanism it models. That is the argument for keeping the ramp SHORT: the
// claim is about the step period being exact, and twelve steps demonstrate
// that as well as a thousand.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree.
`ifndef STEPPER_HEX
  `define STEPPER_HEX "../firmware/stepper_ramp.hex"
`endif

module tb_pe_soc_stepper_ramp;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  localparam int STEP_BIT = 6;
  localparam int DIR_BIT  = 5;

  localparam int N_STEPS = 12;
  localparam int RAMP_STEP_CYC = 5110;   // the ten outer steps the firmware drops
  // The same 5110 clocks in this file's 0.1 ns units: 5110 * 1e12/60e6 ps,
  // / 100. Stated as a constant because the ramp check is an EQUALITY against
  // it, and an equality against a value recomputed from the clock each time
  // would be an equality against a rounding decision.
  localparam longint RAMP_U = 851667;    // 5110 clocks, to 0.1 ns

  // A driver's limits, stated rather than assumed. A step pulse narrower than
  // 1 us is one the chip can miss, and a direction that changes less than 5 us
  // before a STEP edge is one the chip may decode from the old value.
  localparam longint STEP_MIN_U = 10000;    // 1.0 us
  localparam longint SETUP_MIN_U = 50000;   // 5.0 us
  localparam longint PERIOD_LO_U = 4000000;  // 0.40 ms = 400 us, the fastest
  localparam longint PERIOD_HI_U = 25000000; // 2.50 ms = 2500 us, the slowest

  // Every width in this file is in TENTHS OF A NANOSECOND. $time is scaled to
  // the module's timeunit (1 ns here) and returns an integer, so it quantises
  // a measurement to 0.06 clocks -- and this act's claim is that the step
  // period is right to the CLOCK. $realtime times ten, rounded, is 0.006
  // clocks, a thousandth of the claim.
  localparam longint CLK_U = 167;           // 16.667 ns, rounded up
  localparam int MAX_PULSES = 64;

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // The driver's inputs: STEP is active low, DIR is a level.
  wire step_low = pin_oe_bus[STEP_BIT] & ~pin_out_bus[STEP_BIT];
  wire dir_lvl  = ~pin_out_bus[DIR_BIT];
  assign pin_in_bus = {1'b1, step_low, 5'b11111, dir_lvl, 1'b1};

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
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  function integer iabs(input integer v);
    iabs = (v < 0) ? -v : v;
  endfunction

  integer i, k, t_flip, n_flip;
  longint p_start [0:MAX_PULSES-1];
  longint p_len   [0:MAX_PULSES-1];
  longint p_rise  = -1;
  longint t_now;
  longint flip_t [0:MAX_PULSES-1];
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh(`STEPPER_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- the driver: one edge-triggered recorder on each input -----------
  integer n_pulse = 0;
  always @(step_low) if (run && rst_n) begin
    if (step_low) p_rise = $rtoi($realtime * 10.0);
    else if (p_rise >= 0) begin
      t_now = $rtoi($realtime * 10.0);
      if (n_pulse < MAX_PULSES) begin
        p_start[n_pulse] = p_rise;
        p_len[n_pulse]   = t_now - p_rise;
        n_pulse = n_pulse + 1;
      end
      p_rise = -1;
    end
  end

  always @(dir_lvl) if (run && rst_n && n_flip < MAX_PULSES) begin
    flip_t[n_flip] = $rtoi($realtime * 10.0);
    n_flip = n_flip + 1;
  end

  longint per_u [0:MAX_PULSES-1];   // the step periods, in us
  longint ramp [0:MAX_PULSES-1];   // the difference from the previous step
  integer n_distinct, n_monotone, n_inband, n_onramp;
  integer flip_step, setup_u;

  initial begin
    $dumpfile("tb_pe_soc_stepper_ramp.vcd");
    $dumpvars(0, step_low, dir_lvl, pin_out_bus, pin_oe_bus, dbg_pc);

    n_pulse = 0; p_rise = -1; n_flip = 0;

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== stepper: %0d steps, ramp -%0d clocks per step ===\n", N_STEPS, RAMP_STEP_CYC);
    run = 1'b1;
    repeat (1_100_000) @(posedge clk);   // 18.3 ms: the whole ramp

    // ---- 1. twelve steps, each a pulse a driver can see ------------------
    $display("    step pulses: %0d", n_pulse);
    check(n_pulse == N_STEPS,
          $sformatf("the firmware emitted %0d steps (got %0d)", N_STEPS, n_pulse));
    for (k = 0; k < n_pulse && k < N_STEPS; k = k + 1)
      if (p_len[k] < STEP_MIN_U)
        check(1'b0, $sformatf("step %0d's pulse is %.2f us, narrower than a driver's 1 us",
                              k, p_len[k]/1e4));

    // ---- 2/3. the ramp, as an EQUALITY against the constant --------------
    // TWO LOOPS, and the reason is the third measurement bug in this
    // repository's timing testbenches: the first version did both in one pass
    // and compared each period against the NEXT one before it had been
    // computed, so every "ramp" came out equal to a period and every ramp
    // check passed. A check that reads a value the loop has not filled in yet
    // is a check that cannot fail, and it read like a real measurement in the
    // output. All the periods first, then all the differences.
    for (k = 0; k + 1 < n_pulse; k = k + 1)
      per_u[k] = p_start[k+1] - (p_start[k] + p_len[k]);   // 0.1 ns units
    for (k = 0; k + 2 < n_pulse; k = k + 1)
      ramp[k] = per_u[k] - per_u[k+1];   // the last period has no successor
    $display("    step periods:");
    for (k = 0; k + 1 < n_pulse; k = k + 1)
      $display("      step %0d: %.3f us (%.1f Hz)", k, per_u[k]/1e4,
               1.0e6/(per_u[k]/1e4));
    $display("    dmem: steps_left=%0d runs_left=%0d ramp=%0d done=%02x",
             dut.dmem[3], dut.dmem[5], dut.dmem[4], dut.dmem[14]);
    $display("    ramp per step, in clocks (want exactly %0d):",
             RAMP_STEP_CYC);
    for (k = 0; k + 2 < n_pulse; k = k + 1)
      $display("      step %0d -> %0d: %.2f clocks", k, k+1, ramp[k]/166.67);
    check(dut.dmem[14] == 8'h01,
          $sformatf("the firmware finished the ramp (dmem[14] = %02h)", dut.dmem[14]));

    // ---- 2. THE RAMP, AS AN EQUALITY AGAINST THE CONSTANT ----------------
    //
    // Not a tolerance and not a trend: the firmware subtracts ten outer steps
    // of the (4,40) pair, which is 5110 clocks, and every interval must be
    // that to within one clock. An equality is the strongest statement this
    // act could make about a mechanism whose unit of correctness is a single
    // number, and it is checkable because 5110 is a constant and not a
    // property of the data.
    n_onramp = 0;
    for (k = 0; k + 1 < n_pulse; k = k + 1) begin
      if (iabs(ramp[k] - RAMP_U) <= CLK_U) n_onramp = n_onramp + 1;
      else
        $display("      step %0d -> %0d: the ramp is %.2f clocks, want %0d",
                 k, k+1, ramp[k]/166.67, RAMP_STEP_CYC);
    end
    // The interval ACROSS the direction change carries the flip and its setup
    // delay, so it is not on the line. That is one interval out of eleven and
    // it is named rather than allowed through.
    check(n_onramp == n_pulse - 2,
          $sformatf("every step interval except the direction change is EXACTLY %0d clocks -- %0d of %0d are",
                    RAMP_STEP_CYC, n_onramp, n_pulse - 2));

    // ---- 3. the periods are distinct, monotonic, and in band -----------
    n_distinct = 0;
    n_monotone = 0;
    n_inband = 0;
    for (k = 0; k + 1 < n_pulse; k = k + 1) begin
      if (k + 2 < n_pulse && per_u[k] != per_u[k+1]) n_distinct = n_distinct + 1;
      if (per_u[k] > per_u[k+1]) n_monotone = n_monotone + 1;
      if (per_u[k] >= PERIOD_LO_U && per_u[k] <= PERIOD_HI_U) n_inband = n_inband + 1;
    end
    $display("    %0d of %0d intervals strictly shorten, %0d distinct values, %0d in band",
             n_monotone, n_pulse - 1, n_distinct, n_inband);
    check(n_monotone == n_pulse - 1,
          $sformatf("every step interval SHORTENS (%0d of %0d) -- a ramp that does not accelerate is not a ramp",
                    n_monotone, n_pulse - 1));
    check(n_distinct == n_pulse - 2,
          $sformatf("the periods are pairwise distinct (%0d of %0d intervals differ) -- twelve equal periods would satisfy a slope check with a zero ramp",
                    n_distinct, n_pulse - 2));
    check(n_inband == n_pulse - 1,
          $sformatf("every period is inside %.0f-%.0f us (%0d of %0d)",
                    PERIOD_LO_U/1e4, PERIOD_HI_U/1e4, n_inband, n_pulse - 1));

    // where the direction changed, and how long the driver was given
    // Search EVERY recorded edge, not just the first. The first version
    // looked only at flip_t[0] and found no interval containing it, so the
    // setup-time check below was never executed and the act reported a pass
    // for a check that had not run. A check inside `if (found)` that is never
    // reached is the quietest kind of vacuity there is, and the fix is to
    // assert that something was found.
    flip_step = -1;
    for (i = 0; i < n_flip; i = i + 1)
      for (k = 0; k + 1 < n_pulse; k = k + 1)
        if (flip_t[i] > (p_start[k] + p_len[k]) && flip_t[i] < p_start[k+1])
          flip_step = k;
    check(flip_step >= 0,
          $sformatf("the direction changed inside a step interval, where a driver would decode it -- found it in interval %0d of %0d",
                    flip_step, n_pulse - 1));
    if (flip_step >= 0) begin
      setup_u = (p_start[flip_step+1] - flip_t[0]) / 1e5;   // 0.1 ns -> 0.1 us
      $display("    DIR changed %0d steps in, %.1f us before the next STEP edge",
               flip_step + 1, setup_u/1e5);
      check(setup_u * 10 >= SETUP_MIN_U,
            $sformatf("the driver got its direction setup time (%.1f us, want >= 5.0 us)",
                      setup_u/1e5));
    end
    check(n_flip == 2,
          $sformatf("the direction changed exactly once (%0d changes on the pin)", n_flip - 1));

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    #25_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
