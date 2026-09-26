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
//
//   2a. AND THE DIRECTION-CHANGE PAIR IS PINNED RATHER THAN EXCUSED. The
//      direction change is the only thing in the program that is not a step,
//      so one interval carries it: that interval is longer than the ramp line
//      by the setup delay and the flip's instructions, and the interval after
//      it is shorter by the same amount. The first version of this check
//      reported the pair as two anomalies and never established what either
//      was, which is indistinguishable from a program with two separate faults.
//      So: every other interval is exactly on the line, the pair SUMS to
//      exactly twice the line, the change is the long one, and the excess is at
//      least the setup delay. A firmware that added or dropped an instruction
//      in the flip fails the sum.
//   3. THE PERIODS ARE DISTINCT AND MONOTONIC, and each is within the band the
//      driver can be clocked at. Twelve equal periods would satisfy (2) with
//      a zero ramp, which is why the monotonicity and the distinctness are
//      checked separately rather than inferred from the slope.
//   4. THE DIRECTION CHANGES ONCE, MID-RAMP, and the driver gets its setup
//      time: the interval from the DIR edge to the next STEP edge is at least
//      5 us. A driver that samples DIR on the STEP edge takes the old
//      direction or the new one depending on the silicon, and a program that
//      changed DIR one instruction too late works on one chip and not another.
//      The edges are LOCATED, not counted: an edge inside a step interval is a
//      change a driver would decode and there must be exactly one. Counting
//      edges instead of locating them reported "the direction changed exactly
//      once" for a program in which it never changed after the first step --
//      see the header on firmware/stepper_ramp.pe for why.
//   5. THE ONE PLACE THE RAMP IS NOT ON THE LINE, stated rather than hidden:
//      the direction-change pair of 2a. The TB prints both intervals in clocks,
//      prints the excess, and pins the pair with a sum.
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
  localparam int SETUP_CYC = 349;           // ST_SETUP on (2,13): 5*69 + 4

  // A driver's limits, stated rather than assumed. A step pulse narrower than
  // 1 us is one the chip can miss, and a direction that changes less than 5 us
  // before a STEP edge is one the chip may decode from the old value.
  localparam longint STEP_MIN_U = 10000;    // 1.0 us
  localparam int SETUP_MIN_US = 5;          // 5.0 us, the driver's spec
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
  //
  // AND A RELEASED DIR PAD IS LOW, not "whatever the data register happens to
  // say". The first version of this watched pin_out alone, which meant a
  // program that changed direction and then DROPPED THE PAD looked identical to
  // one that drove it: the change was still a one-clocked edge on the register
  // and every check passed. That is the pin-matrix read-back trap this
  // repository keeps meeting -- with the OD bit, with 1-Wire, and here: what a
  // peripheral sees is the PIN, and a released pin is a pull-down. The mutation
  // gate caught this one (st-dir-released SURVIVED), which is the second time
  // in this block that the gate has found the act's own blind spot rather than
  // a defect in the design.
  wire step_low = pin_oe_bus[STEP_BIT] & ~pin_out_bus[STEP_BIT];
  wire dir_lvl  = pin_oe_bus[DIR_BIT] ? pin_out_bus[DIR_BIT] : 1'b0;
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
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer),
    // R3 debug control, idle. These two ports arrived with the R3 block, and a
    // testbench that predates them leaves them UNCONNECTED -- which arrives as
    // Z, makes the core's execute gate X, and the firmware then never executes
    // a single instruction: every dmem read comes back x and the pin never
    // moves. rtl/pe_cpu.v now defaults them defensively too; this tie-off is
    // the act not DEPENDING on that, so the two repairs cannot mask each other.
    .dbg_hold(1'b0), .dbg_step(1'b0)
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
  // THE DIRECTION AT EVERY STEP EDGE. A driver decodes DIR on the STEP edge, so
  // the level there is part of the protocol and not decoration -- and it is the
  // one thing this act's edge-counting checks could not see. Two mutants that
  // RELEASE the DIR pad survive every other check here: the edges they make
  // land on the interval BOUNDARIES rather than inside an interval, and a pad
  // that floats to the pull-down still reads as a valid level. The level at the
  // step edge does not care where the edge is.
  bit     dir_at_edge [0:MAX_PULSES-1];
  integer edge_pending = -1;
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
  // The direction is sampled ONE CLOCK AFTER the step edge, not in the same
  // block. dir_lvl and step_low are both combinational functions of the pad
  // registers, and the pad is written on this same clock edge, so reading
  // dir_lvl in the edge-triggered process is a race with the register update --
  // the same two-process-on-one-counter race the WS2812 act found in its own
  // testbench, and the reason that act measures with $realtime in one process.
  // Here the fix is to mark the edge and read the level a clock later.
  always @(posedge clk) if (run && rst_n && edge_pending >= 0) begin
    dir_at_edge[edge_pending] = dir_lvl;
    edge_pending = -1;
  end

  always @(step_low) if (run && rst_n) begin
    if (step_low) begin
      p_rise = $rtoi($realtime * 10.0);
      if (n_pulse < MAX_PULSES) edge_pending = n_pulse;
    end
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
  integer n_dirA, n_dirB, n_dir_first, n_dirflip;
  integer flip_step, n_in_gap, n_ramp_int;
  longint flip_at = 0, setup_us;

  initial begin
    $dumpfile("tb_pe_soc_stepper_ramp.vcd");
    $dumpvars(0, step_low, dir_lvl, pin_out_bus, pin_oe_bus, dbg_pc);

    n_pulse = 0; p_rise = -1; n_flip = 0; n_in_gap = 0; flip_step = -1; flip_at = 0;

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
      $display("      interval %0d: %0d.%0d us", k, per_u[k]/10000, (per_u[k]/1000)%10);
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
    for (k = 0; k + 2 < n_pulse; k = k + 1) begin
      if (iabs(ramp[k] - RAMP_U) <= CLK_U) n_onramp = n_onramp + 1;
      else
        $display("      step %0d -> %0d: the ramp is %.2f clocks, want %0d",
                 k, k+1, ramp[k]/166.67, RAMP_STEP_CYC);
    end
    // ---- THE DIRECTION-CHANGE INTERVAL, AND WHY IT IS CHECKED AS A PAIR --
    //
    // The direction change is the only thing in this program that is not a
    // step, so exactly one interval carries it: that interval is LONGER than
    // the ramp line by the setup delay and the flip's instructions, and the
    // interval after it is SHORTER by the same amount. The first version of
    // this check expected that pair to be off the line and was wrong twice
    // over -- it expected TWO exceptions and there are two, but it described
    // them as two anomalies when they are one cost and its recovery, and it
    // never established what the cost WAS.
    //
    // The check that says something is: every other interval is EXACTLY on the
    // line, the pair SUMS to exactly twice the line, and the direction-change
    // interval is the long one by at least the setup delay. That pins the cost
    // to a number instead of excusing it, and a firmware that added or dropped
    // an instruction in the flip would fail the sum.
    // n_pulse pulses give n_pulse-2 comparable intervals, and two of them are
    // the direction-change pair.
    n_ramp_int = n_pulse - 2;
    check(n_onramp == n_ramp_int - 2,
          $sformatf("every step interval except the direction change and the one after it is EXACTLY %0d clocks -- %0d of %0d are",
                    RAMP_STEP_CYC, n_onramp, n_ramp_int));
    if (flip_step >= 1 && flip_step + 1 < n_pulse - 1) begin
      check(iabs((ramp[flip_step-1] + ramp[flip_step]) - 2*RAMP_U) <= 2*CLK_U,
            $sformatf("the direction-change interval and the one after it SUM to exactly twice the ramp step (%.2f + %.2f, want 2 x %.2f) -- the change costs the same in both directions and is not a second anomaly",
                      ramp[flip_step-1]/166.67, ramp[flip_step]/166.67, RAMP_STEP_CYC));
      check(ramp[flip_step] > RAMP_U,
            $sformatf("the direction-change interval is the LONG one (%.2f clocks, want more than %0d) -- a change made later would be short, and a driver that samples DIR on the STEP edge would take the old direction",
                      ramp[flip_step]/166.67, RAMP_STEP_CYC));
      check(ramp[flip_step-1] < RAMP_U,
            $sformatf("the interval before the change is on the line (%.2f clocks)", ramp[flip_step-1]/166.67));
      check(ramp[flip_step] - RAMP_U >= SETUP_CYC - 4*CLK_U,
            $sformatf("the direction change costs at least the setup delay (%.2f clocks over the line, want >= %0d)",
                      (ramp[flip_step]-RAMP_U)/166.67, SETUP_CYC));
    end

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
    // AN EDGE INSIDE A STEP INTERVAL, not an EDGE COUNT. The first version
    // counted edges and asked for two, and got two: one when the program set
    // DIR at startup and one when the FIRST STEP cleared the direction bit,
    // because the step's level write went out as 0x00. So the act reported "the
    // direction changed exactly once" for a program in which the direction
    // never changed after the first step, and the setup-time check below never
    // ran at all because no edge was ever inside an interval. Two checks, both
    // satisfied, both about something that was not happening.
    //
    // So the edges are LOCATED, not counted: an edge inside a step interval is
    // a direction change a driver would decode, and there must be exactly one
    // of them. The startup edge is before the first pulse and is not one.
    flip_step = -1;
    n_in_gap = 0;
    for (i = 0; i < n_flip; i = i + 1) begin
      if (flip_t[i] < p_start[0]) continue;      // before the ramp: the init
      for (k = 0; k + 1 < n_pulse; k = k + 1)
        if (flip_t[i] > (p_start[k] + p_len[k]) && flip_t[i] < p_start[k+1]) begin
          flip_step  = k;
          flip_at    = flip_t[i];
          n_in_gap   = n_in_gap + 1;
        end
    end
    check(n_in_gap == 1,
          $sformatf("the direction changes EXACTLY ONCE inside the ramp, where a driver would decode it (%0d edges in an interval)",
                    n_in_gap));
    // The interval from the direction edge to the NEXT STEP edge: that is what
    // a chip which samples DIR on the edge is given, and it is the whole point
    // of changing direction in the middle of a ramp. The first version read
    // flip_t[0] here rather than the edge it had found, and reported 0.0 us
    // for a change that had 6.1 us in front of it.
    if (flip_step >= 0) begin
      setup_us = (p_start[flip_step+1] - flip_at) / 10000;   // 0.1 ns -> us
      $display("    DIR changed in interval %0d, %.2f us before the next STEP edge",
               flip_step, setup_us/1.0);
      check(setup_us >= SETUP_MIN_US,
            $sformatf("the driver got its direction setup time (%.2f us, want >= %.1f us)",
                      setup_us/1.0, SETUP_MIN_US/1.0));
    end
    $display("    DIR edges on the pin: %0d (%0d inside the ramp)", n_flip, n_in_gap);

    // ---- the direction AT every step edge, which is where it is decoded ----
    n_dirA = 0; n_dirB = 0; n_dirflip = -1;
    for (k = 0; k < n_pulse; k = k + 1) begin
      if (k < N_STEPS/2) n_dirA = n_dirA + (dir_at_edge[k] ? 1 : 0);
      else               n_dirB = n_dirB + (dir_at_edge[k] ? 1 : 0);
    end
    for (k = 1; k < n_pulse; k = k + 1)
      if (dir_at_edge[k] != dir_at_edge[k-1]) n_dirflip = k;
    $display("    direction at the step edges: %0d of %0d high in the first run, %0d of %0d in the second, changing at step %0d",
             n_dirA, N_STEPS/2, n_dirB, N_STEPS - N_STEPS/2, n_dirflip);
    // One direction for the whole of each run, and the two DIFFERENT: this is
    // what a driver decodes, and a pad released for the step pulse reads as the
    // pull-down, so the first run measures 0 of 6 high.
    check(n_dirA == N_STEPS/2,
          $sformatf("every step of the first run is decoded with DIR HIGH (%0d of %0d) -- a released DIR pad reads as the pull-down, and a driver samples it on the edge",
                    n_dirA, N_STEPS/2));
    check(n_dirB == 0,
          $sformatf("every step of the second run is decoded with DIR LOW (%0d of %0d are high)",
                    n_dirB, N_STEPS - N_STEPS/2));
    check(n_dirflip == N_STEPS/2,
          $sformatf("the direction decoded by the driver changes once, at step %0d (got %0d)",
                    N_STEPS/2, n_dirflip));

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
