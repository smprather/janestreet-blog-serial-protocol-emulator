// tb_pe_soc_freqmeter.v -- an input frequency and duty meter: the pin is an
// INPUT and the firmware recovers numbers from a waveform it does not control.
//
// WHAT THIS PROVES, AND WHY IT IS A DIFFERENT SHAPE OF PROBLEM FROM THE SIX
// TIMING ACTS ALREADY HERE.
//
// Those six all DRIVE a pin. This one listens. The PWM arrives from outside,
// the firmware has no way to ask when the edges are coming, and the answer it
// has to produce is a number it can only get by counting between two edges it
// did not schedule. The number that is the claim is the ACCURACY OF THE
// COUNT, and the honest way to state that is per point rather than as one
// datasheet window: the tick is one microsecond, so the relative error is
// 1/period -- 0.01 % at 100 Hz and 1.0 % at 10 kHz. The tolerance is
// therefore 1 % of the period with a floor of one and a half ticks, and it is
// stated per point because the instrument's resolution IS the claim.
//
// THE MEASURING INSTRUMENT IS NOT THE SWEEP TABLE. The generator below knows
// the table and nothing else: it produces a level and the edges fall out of
// counting clocks. The checks do not compare the firmware against the table
// -- they compare it against a SECOND, INDEPENDENT measurement of the same
// pad, taken by the receiver below from the pin's own edges. A generator that
// knew the answer would agree with a firmware that had the sweep wrong; this
// one cannot, because it is never told what the firmware will do with it.
// The table is still checked, once per point, because the table is the
// SPECIFICATION and a test that never looks at the specification is a test
// that cannot notice the specification changing underneath it.
//
// AND THE LOW END OF THE SWEEP IS THE POINT OF THE ACT. At 100 Hz the
// period is 10 000 us, which does not fit in one 8-bit counter, so a
// firmware counting into a byte wraps and reports 16 us for a 100 Hz signal
// -- a wrong ANSWER rather than a wrong precision, and a defect with no
// symptom at 10 kHz. Every point is checked, not the ends, because that
// defect is invisible everywhere else.
//
// WHY THE SWEEP IS SIX RUNS OF THREE PERIODS, and not sixteen points in one
// run. THE MACHINE HAS SIXTEEN BYTES OF DATA MEMORY (DMEM_BYTES = 16 in
// rtl/pe_soc.v, and every top level passes 16), and a period is two bytes
// and a high time two bytes, so the firmware can bank TWO points per run and
// not a whole sweep. The first version of this testbench asked for sixteen
// points in dmem[0..63] on a machine with sixteen bytes: it read twelve of
// its own expectations out of an address space that does not exist, and its
// DONE flag at dmem[14] was inside the data it was reporting. A test that
// sizes memory to what it wishes for is a test that reports success without
// measuring anything.
//
// So each run presents THREE periods and the firmware banks the second and
// the third. The first period of every run is a warm-up and is NOT checked,
// for a reason that is a property of the protocol rather than of the
// firmware: the firmware starts in the middle of it, so the time since the
// previous rising edge is not a period. A receiver that starts mid-period
// misses that one period, and a testbench that pretended otherwise would be
// asking the firmware to measure something it was never present for.
//
// THE CHECKS, and how each could be unfalsified:
//
//   1. EVERY BANKED POINT, against an independent measurement of the pad:
//      twelve points from 80 Hz to 10 kHz, each to 1 % of the period and to
//      one and a half microseconds absolute. An endpoint-only check passes a
//      firmware that is wrong in the middle.
//   2. THE HIGH TIME, on the same terms. The duty is a ratio of the high time
//      to the period, so a firmware that measures the two with the same edge
//      discipline gets a ratio that is right even when both are off by a
//      microsecond -- which is the property worth showing, and it is why the
//      high time is checked in its own right and not only through the duty.
//   3. THE DUTY, AS A PERCENTAGE, to two percentage points of the pad's own
//      measured ratio.
//   4. THE MEASURED ORDER IS THE DRIVEN ORDER within every run, and all
//      twelve periods and all twelve duties are pairwise distinct, so a
//      firmware that returned a stale reading for some points cannot pass by
//      accident.
//   5. NON-VACUITY ON THE SWEEP: the duties are not constant and not 50 %
//      anywhere, the periods are not a constant ratio apart, and one banked
//      period is above 255 while another is below it -- the last being the
//      16-bit claim itself, since a byte counter cannot report 10 000.
//
// THE COST: the sweep is eighteen periods and the slowest is 10 ms, so the
// simulation is about 43 ms of 60 MHz -- 2.6 M clocks, more than any other
// testbench in this repository. That is not trimmed, and the reason is in
// the header of the act's firmware: the 100 Hz point is where the 16-bit
// claim is tested, and dropping it would leave the act asserting something
// it had not measured. The generator is edge-driven with absolute delays
// rather than clocked, which is what keeps a 2.6 M clock testbench inside
// the time the rest of this repository's TBs take.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree.
`ifndef FREQMETER_HEX
  `define FREQMETER_HEX "../firmware/freqmeter.hex"
`endif

module tb_pe_soc_freqmeter;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;    // THE MACHINE'S SIZE, not a wish
  localparam int BAUD = 115_200;

  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  // The firmware's data-memory map. Spelled out here because this file
  // READS those bytes, and a test that reads memory it has not named is one
  // refactor away from reading the wrong thing.
  localparam int FM_T_LO   = 0;      // the period counter
  localparam int FM_IDX    = 5;      // 0, 1, then 2 when both slots are full
  localparam int FM_DONE   = 6;
  localparam int FM_PER0   = 8;      // slot 0's period, low byte first
  localparam int FM_HI0    = 10;     // slot 0's high time
  localparam int FM_STRIDE = 4;      // slot 1 is four bytes on

  localparam int N_SEG    = 6;       // runs
  localparam int N_PER_SEG = 3;      // periods per run (the first is a warm-up)
  localparam int N_PTS    = N_SEG * N_PER_SEG;   // 18 driven periods
  localparam int N_BANK   = N_SEG * (N_PER_SEG - 1);  // 12 banked points

  // The claim's tolerance, stated. One percent of the period, with a floor of
  // one and a half ticks: the tick is one microsecond and the firmware counts
  // them, so at the fast end of the sweep the TOLERANCE is the dominant term
  // and the quantisation is a percent of it. That is why the accuracy claim
  // is per point and not a single number.
  localparam real TOL_PCT  = 1.0;
  localparam real TOL_FLOOR_US = 1.5;
  localparam real DUTY_TOL = 2.0;    // percentage points, absolute

  // Everything in this file is a real from $realtime, in nanoseconds, and the
  // firmware's own resolution is a microsecond, so the TB's unit is a
  // thousand times finer than the thing being measured.
  localparam int MAX_EDGE = 32;

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // The PWM pad is an INPUT: the generator drives it and the SoC reads it back
  // through the pin matrix, which is the whole point -- the firmware recovers
  // a number from a pin it never writes.
  logic pwm = 1'b0;
  assign pin_in_bus = {1'b1, pwm, 6'b111111};
  wire [7:0] pin_out_unused = 8'h00;

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

  integer i;
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh(`FREQMETER_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- THE SWEEP, as MEMORIES -----------------------------------------
  //
  // Not unpacked-array localparams: Icarus does not support those ("unpacked
  // array parameters are not supported yet") and says so only with a
  // `sorry`, which is not a loud enough failure for a table every check
  // depends on. Initialised in the initial block, so the values are still
  // written in one readable place.
  integer p_us  [0:N_PTS-1];   // the period at each point, in microseconds
  integer d_pct [0:N_PTS-1];   // the duty at each point, in percent

  // ---- THE GENERATOR ----------------------------------------------------
  //
  // It knows the sweep and nothing else. It produces a level, and the edges
  // fall out of counting clocks -- so a period that is 10 000 us really is
  // 600 000 clocks of real time, and the firmware's edge detection is tested
  // against that rather than against a number the TB would like it to see.
  //
  // EDGE-DRIVEN, with absolute delays rather than one iteration per clock.
  // A 2.6 M clock testbench that woke up 2.6 M times to decide whether the
  // pin had moved would spend most of its wall time deciding that it had
  // not; the waveform only has an edge every 50 us at the fastest point and
  // every 5 ms at the slowest.
  //
  // Each run launches its own copy of this task with an EPOCH stamp. A stale
  // copy wakes up, sees that its epoch is old, and goes away without touching
  // the pin -- which is what stops the previous run's generator from
  // producing one more edge into the middle of the next run's first period.
  integer gen_epoch = 0;

  task automatic gen_run(input integer seg, input integer ep);
    integer pt, ph;
    integer per_clocks, hi_clocks;
    begin
      pt  = seg * N_PER_SEG;
      ph  = 1;                       // START HIGH
      pwm = 1'b1;                    // and the line idles high, which the
                                     // firmware's initial previous-level byte
                                     // requires (firmware/freqmeter.pe)
      while (ep == gen_epoch) begin
        per_clocks = p_us[pt] * 60;                 // us * 60 = clocks
        hi_clocks  = (per_clocks * d_pct[pt]) / 100;
        #(CLK_NS * (ph ? hi_clocks : (per_clocks - hi_clocks)));
        if (ep == gen_epoch) begin
          if (ph) begin
            pwm = 1'b0; ph = 0;                      // the falling edge
          end else begin
            pwm = 1'b1; ph = 1;                      // the rising edge
            pt = (pt + 1 >= (seg+1)*N_PER_SEG) ? seg*N_PER_SEG : pt + 1;
          end
        end
      end
    end
  endtask

  // ---- THE RECEIVER: edges off the pad, and only that -------------------
  //
  // This is the independent instrument. It knows when the pin moved and
  // nothing about the sweep, and it is what the firmware's numbers are
  // checked AGAINST.
  integer n_edge = 0;
  real    e_t [0:MAX_EDGE-1];
  bit     e_lv[0:MAX_EDGE-1];
  always @(pwm) if (rst_n && n_edge < MAX_EDGE) begin
    e_t[n_edge]  = $realtime;    // $time is scaled to the timeunit AND
    e_lv[n_edge] = pwm;          // returns an integer; $realtime is a real
    n_edge = n_edge + 1;         // in nanoseconds, and this file needs the
  end                             // difference between two of them.

  // ---- the checks --------------------------------------------------------
  // What the firmware banked, and what the pad independently says.
  integer seg, k, idx;
  integer got_p   [0:N_BANK-1];
  integer got_h   [0:N_BANK-1];
  real    mea_p  [0:N_BANK-1];   // the receiver's own period, microseconds
  real    mea_h  [0:N_BANK-1];
  integer exp_p  [0:N_BANK-1];
  integer exp_h  [0:N_BANK-1];
  real    mea_d, got_d;
  integer fb_hi, fb_lo, fh_hi, fh_lo;
  integer n_bad_p, n_bad_h, n_bad_d, n_distinct_p, n_distinct_d, n_big, n_small;
  integer n_unwritten;
  integer j, l, dup, kk, waited, lim_clks, seg_clks;

  initial begin
    $dumpfile("tb_pe_soc_freqmeter.vcd");
    // NOTE: dut.dmem is a vpiMemory behind the SRAM macro and cannot be dumped
    // ("$dumpvars cannot dump a vpiMemory"), so the firmware's answers are read
    // out at the end of each run instead -- which is better anyway, since the
    // point is the NUMBERS and not the waveform.
    $dumpvars(0, pwm, pin_in_bus, dbg_pc);

    // The sweep, in six runs of three periods, ASCENDING inside a run: the
    // warm-up is then the cheapest of the three, which is the only thing the
    // ordering is for. The duties vary, are never 50 % twice running, and
    // span 10 % to 90 %.
    p_us[ 0]= 6300; d_pct[ 0]=40;   p_us[ 1]= 8000; d_pct[ 1]=75;
    p_us[ 2]=10000; d_pct[ 2]=25;   p_us[ 3]= 2500; d_pct[ 3]=90;
    p_us[ 4]= 3150; d_pct[ 4]=33;   p_us[ 5]= 4000; d_pct[ 5]=10;
    p_us[ 6]= 1250; d_pct[ 6]=20;   p_us[ 7]= 1600; d_pct[ 7]=66;
    p_us[ 8]= 2000; d_pct[ 8]=80;   p_us[ 9]=  630; d_pct[ 9]=12;
    p_us[10]=  800; d_pct[10]=60;   p_us[11]= 1000; d_pct[11]=40;
    p_us[12]=  315; d_pct[12]=88;   p_us[13]=  400; d_pct[13]=45;
    p_us[14]=  500; d_pct[14]=55;   p_us[15]=   63; d_pct[15]=30;
    p_us[16]=   80; d_pct[16]=15;   p_us[17]=  100; d_pct[17]=50;

    n_edge = 0;

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== input frequency + duty meter: %0d runs, %0d driven periods,\
 %0d banked points, %0d Hz to %0d Hz ===\n",
             N_SEG, N_PTS, N_BANK, 1_000_000/p_us[0], 1_000_000/p_us[N_PTS-1]);

    for (seg = 0; seg < N_SEG; seg++) begin
      // ---- the receiver is cleared per run, and the pad is presented
      // high-idling before the firmware starts, which is what the firmware
      // requires and what a real PWM output does between frames.
      pwm  = 1'b1;
      run  = 1'b0;
      gen_epoch = gen_epoch + 1;

      seg_clks = 0;
      for (k = 0; k < N_PER_SEG; k++) seg_clks = seg_clks + p_us[seg*N_PER_SEG+k]*60;
      lim_clks = seg_clks * 2 + 4000;   // DONE lands at the start of the 4th

      fork
        gen_run(seg, gen_epoch);
        begin
          // The core is released eight stopped clocks after the pad is
          // presented, and the documented reason applies here as it does
          // everywhere else in this repository: raising run on the same
          // instant as a clock edge leaves the instruction memory's
          // registered read half-updated and the FIRST instruction is
          // silently dropped.
          repeat (8) @(posedge clk);
          #1;
          run = 1'b1;
          // The receiver is ARMED HERE, not when the pad is presented. The
          // pad is presented eight clocks early, and whether that
          // presentation is itself an edge depends on where the previous
          // run's waveform stopped -- so arming the receiver at the
          // presentation would put a spurious edge in the list on some runs
          // and not on others, and the edge indices below would be off by
          // one exactly when nobody was looking. Armed here, the list IS the
          // firmware's own view of the signal: fall, rise, fall, rise...
          n_edge = 0;
          // Poll DONE every 256 clocks rather than every clock: the firmware
          // is parked once it is set, so the values cannot change afterwards
          // and a coarse poll costs nothing but a few microseconds of
          // overshoot. A per-clock read of dut.dmem would be 2.6 M
          // hierarchical reads, which is not a cost worth paying for a flag.
          waited = 0;
          while (waited < (lim_clks/256) + 1) begin
            repeat (256) @(posedge clk);
            waited = waited + 1;
            if (dut.dmem[FM_DONE] == 8'h01) waited = 999999;
          end
          gen_epoch = gen_epoch + 1;   // the generator stops here
          run = 1'b0;
        end
      join

      check(dut.dmem[FM_DONE] == 8'h01,
            $sformatf("run %0d: the firmware banked both points (dmem[%0d] = %02h)",
                      seg, FM_DONE, dut.dmem[FM_DONE]));
      check(dut.dmem[FM_IDX] == 8'h02,
            $sformatf("run %0d: the slot index ended at 2 (dmem[%0d] = %02h)",
                      seg, FM_IDX, dut.dmem[FM_IDX]));

      // ---- read the firmware's two pairs out of dmem ------------------
      // Little-endian, low byte at the base, because the ISA has no 16-bit
      // data path: a program that stored a period high-byte-first would be
      // self-consistent and completely wrong, so the order is named here.
      for (k = 0; k < 2; k++) begin
        idx = seg*2 + k;
        fb_lo = dut.dmem[FM_PER0 + k*FM_STRIDE];
        fb_hi = dut.dmem[FM_PER0 + k*FM_STRIDE + 1];
        fh_lo = dut.dmem[FM_HI0  + k*FM_STRIDE];
        fh_hi = dut.dmem[FM_HI0  + k*FM_STRIDE + 1];
        got_p[idx] = (fb_hi << 8) | fb_lo;
        got_h[idx] = (fh_hi << 8) | fh_lo;
      end

      // ---- and the pad's own edges, measured independently -----------
      // The line starts HIGH, so the edges arrive fall, rise, fall, rise...
      // and the two banked points are the periods that END at the 2nd and
      // the 3rd rising edge the firmware saw.
      check(n_edge >= 6,
            $sformatf("run %0d: the receiver saw at least six edges (%0d)",
                      seg, n_edge));
      for (k = 0; k < 2; k++) begin
        idx = seg*2 + k;
        // Armed when the firmware was released, and the line starts HIGH, so
        // the list is fall, rise, fall, rise... : the rising edge that ends
        // banked point k is at 2k+1 and the falling edge inside it at 2k+2.
        check(e_lv[2*k+1] === 1'b1,
              $sformatf("run %0d: edge %0d is the rising edge the bank is measured from",
                        seg, 2*k+1));
        mea_p[idx] = (e_t[2*k+3] - e_t[2*k+1]) / 1000.0;   // ns -> us
        mea_h[idx] = (e_t[2*k+2] - e_t[2*k+1]) / 1000.0;
        exp_p[idx] = p_us[seg*N_PER_SEG + k + 1];          // the specification
        exp_h[idx] = (p_us[seg*N_PER_SEG + k + 1] * d_pct[seg*N_PER_SEG + k + 1]) / 100;
      end
    end

    // ---- 1. the period, against the pad's own measurement ------------
    n_bad_p = 0;
    for (idx = 0; idx < N_BANK; idx++) begin
      if (rabs(got_p[idx] - mea_p[idx]) >
          (((mea_p[idx]*TOL_PCT)/100.0 > TOL_FLOOR_US)
           ? (mea_p[idx]*TOL_PCT)/100.0 : TOL_FLOOR_US)) begin
        n_bad_p = n_bad_p + 1;
        $display("    point %2d: period %0d us, pad says %0.3f us (%0.2f %% off)",
                 idx, got_p[idx], mea_p[idx],
                 100.0*rabs(got_p[idx]-mea_p[idx])/mea_p[idx]);
      end
    end
    check(n_bad_p == 0,
          $sformatf("every period is within %0.0f %% (floor %0.1f us) of the pad's own measurement -- %0d of %0d are not",
                    TOL_PCT, TOL_FLOOR_US, n_bad_p, N_BANK));

    // ---- 2. the high time, likewise ----------------------------------
    n_bad_h = 0;
    for (idx = 0; idx < N_BANK; idx++) begin
      if (rabs(got_h[idx] - mea_h[idx]) >
          (((mea_h[idx]*TOL_PCT)/100.0 > TOL_FLOOR_US)
           ? (mea_h[idx]*TOL_PCT)/100.0 : TOL_FLOOR_US)) begin
        n_bad_h = n_bad_h + 1;
        $display("    point %2d: high time %0d us, pad says %0.3f us",
                 idx, got_h[idx], mea_h[idx]);
      end
    end
    check(n_bad_h == 0,
          $sformatf("every high time is within %0.0f %% (floor %0.1f us) of the pad's own -- %0d of %0d are not",
                    TOL_PCT, TOL_FLOOR_US, n_bad_h, N_BANK));

    // ---- 3. the duty, as a percentage ---------------------------------
    // The ratio of the two counts the firmware banked, against the ratio the
    // pad's own edges give. A firmware that measures both with the same edge
    // discipline is right here even when both are a microsecond out, and
    // that is the property this check is for.
    n_bad_d = 0;
    for (idx = 0; idx < N_BANK; idx++) begin
      got_d = (got_p[idx] > 0) ? (100.0*got_h[idx])/got_p[idx] : -1.0;
      mea_d = (mea_p[idx] > 0.0) ? (100.0*mea_h[idx])/mea_p[idx] : -1.0;
      if (rabs(got_d - mea_d) > DUTY_TOL) begin
        n_bad_d = n_bad_d + 1;
        $display("    point %2d: duty %0.1f %%, pad says %0.2f %% (spec %0d %%)",
                 idx, got_d, mea_d, d_pct[idx < 6 ? (2*idx)+1 : 0]);
      end
    end
    check(n_bad_d == 0,
          $sformatf("every duty is within %0.0f percentage points of the pad's own ratio -- %0d of %0d are not",
                    DUTY_TOL, n_bad_d, N_BANK));

    // ---- 4. order, and distinctness ----------------------------------
    // A RESULT THAT IS X IS A RESULT THAT WAS NEVER WRITTEN, and every
    // arithmetic check above is silently satisfied by one: a comparison
    // against an unknown is false in Verilog, so a firmware that banked one
    // point and left the other slot alone would pass the period, the high
    // time, the duty and the DONE check, and the only thing that noticed
    // would be this line. It is here because a mutation that finished after
    // one point is exactly the kind of defect this act can have.
    n_unwritten = 0;
    for (idx = 0; idx < N_BANK; idx++) begin
      if ((^got_p[idx] === 1'bx) || (^got_h[idx] === 1'bx)) begin
        n_unwritten = n_unwritten + 1;
        $display("    point %2d: period %0h, high time %0h -- never written",
                 idx, got_p[idx], got_h[idx]);
      end
    end
    check(n_unwritten == 0,
          $sformatf("every banked pair was actually written -- %0d of %0d are X",
                    n_unwritten, N_BANK));
    // Within a run the driven periods ascend, so a firmware that banked a
    // stale reading, or banked both slots from one period, is caught by the
    // ORDER and not only by the tolerances.
    n_distinct_p = 0; n_distinct_d = 0;
    for (idx = 0; idx < N_BANK; idx++) begin
      dup = 0;
      for (j = 0; j < idx; j++) if (got_p[j] == got_p[idx]) dup = 1;
      if (!dup) n_distinct_p = n_distinct_p + 1;
      dup = 0;
      for (j = 0; j < idx; j++) if (got_h[j] == got_h[idx]) dup = 1;
      if (!dup) n_distinct_d = n_distinct_d + 1;
    end
    check(n_distinct_p >= N_BANK-1,
          $sformatf("all %0d banked periods are distinct (%0d distinct) -- a firmware returning a stale reading must not pass",
                    N_BANK, n_distinct_p));
    check(n_distinct_d >= N_BANK-1,
          $sformatf("all %0d banked high times are distinct (%0d distinct)",
                    N_BANK, n_distinct_d));

    // ---- 5. non-vacuity on the sweep itself --------------------------
    n_big = 0; n_small = 0;
    for (idx = 0; idx < N_BANK; idx++) begin
      if (got_p[idx] > 255)   n_big   = n_big + 1;
      if (got_p[idx] <= 255)  n_small = n_small + 1;
    end
    check(n_big >= 1,
          "at least one banked period is above 255 us, so the 16-bit counter is what is under test (a byte counter reports 16 for 10 000)");
    check(n_small >= 1,
          "at least one banked period is inside a single byte, so a 16-bit counter that is really an 8-bit one with a spare high byte would be caught the other way");

    $display("");
    for (idx = 0; idx < N_BANK; idx++) begin
      kk = (idx/2)*N_PER_SEG + (idx%2) + 1;
      $display("      point %2d: period %6d us (%7.2f Hz)  high %6d us  duty %5.1f %%   [pad %8.3f us / %5.2f %%, spec %d us / %d %%]",
               idx, got_p[idx], 1.0e6/got_p[idx], got_h[idx],
               (got_p[idx] > 0) ? (100.0*got_h[idx])/got_p[idx] : -1.0,
               mea_p[idx], (mea_p[idx] > 0) ? (100.0*mea_h[idx])/mea_p[idx] : -1.0,
               exp_p[idx], d_pct[kk]);
    end
    $display("");

    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  // The ISA has no carry flag, and neither does a testbench: a real, because
  // the pad's edges are not on a whole microsecond.
  function real rabs(input real v);
    rabs = (v < 0.0) ? -v : v;
  endfunction

  initial begin
    #60_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
