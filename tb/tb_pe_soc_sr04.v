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
//      tick. These two bytes are the one pair this file must not read while
//      the conversion is running -- they ARE the measurement -- so they are
//      read at the same instant as the answer, after the bank.
//   3. THE CONVERSION, as an equality against us*11/64 computed here.
//   4. BOTH pads' output enable: ECHO released on every clock of the trigger
//      pulse, and TRIG released whenever the program is not pulsing.
//   5. NON-VACUITY, restated for the shape the program now has: it measures
//      ONE distance per run and parks, so there are TWO RUNS, one per
//      distance, with a full reset between them, and the second distance is
//      5816 us so the capture's 16-bit counter is what is under test (an
//      8-bit capture reports 136 us for 5816).
//
// THE ANSWER IS READ AS IT IS BANKED, which is a change in this file's shape
// and not in what it claims. The version before it read both answer slots at
// the END of the run, and that is precisely what reported a correct
// conversion as 222 mm: the next conversion's scratch sat in the previous
// measurement's slot, and an end-reading can only see that as a wrong number
// with no way to say which measurement it belonged to. A sampler on the clock
// the completion flag RISES reads each answer where it was written, so a
// destroyed answer is reported as a destroyed answer. Three files in this
// block have now demanded that change independently -- the freqmeter's US
// read, this act's period check, and this one -- so it is stated here rather
// than left for the next reader to rediscover.
//
// THE LIMITS, stated rather than hidden. The model answers after 300 us, the
// HC-SR04's slowest documented response, and it recovers 1.5 ms after the echo
// ends, where the datasheet's figure is 50 ms worst case. A real device at
// 4 m would need a longer wait and the act's numbers would not change; a
// shorter recovery here is a statement about the TESTBENCH's timescale, not
// about the firmware, and the firmware is told to release both pads during it
// precisely so that a real device's re-trigger rule is not being relied upon.
//
// ONE RUN IS ONE DISTANCE, and that is a property of the FIRMWARE rather than
// a convenience this file invented: the program measures one distance, banks
// one answer at dmem[6..7] and parks, because this machine has sixteen bytes
// of data memory and two banked answers plus a four-temporary exact 16-bit
// add do not fit in it. The two distances are therefore two RUNS with a full
// reset between them, which is also the only arrangement in which the
// firmware's own init -- the thing that seeds PREV, the state and the tick's
// previous reading -- runs before each measurement. A second run WITHOUT a
// reset would measure the line as it found it, and would bank a second answer
// from a program that never re-armed. The model is RE-ARMED between runs, and
// it has to be: its recovery window is 1.5 ms and the testbench's reset takes
// about 20 us, so a model that carried its state across the reset would ignore
// the second run's trigger and that run would bank nothing -- silently,
// because a model that is deaf for a millisecond and a half looks exactly like
// a firmware that never triggered.

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
  // CLK_US exists because CLK_NS is NANOSECONDS and this TB reports in
  // microseconds. Folding one into the other is not a rounding detail: 600
  // clocks is 10 000 ns = 10.000 us, and printing "600 clocks = 10000.000 us"
  // is a claim that is wrong by 1000x. A red act's output gets quoted verbatim
  // - it is the first thing a reader sees - so a unit error in a failure message
  // is a defect in the report, not a cosmetic slip.
  localparam real CLK_US = CLK_NS / 1000.0;

  // The firmware's map, named here because this file reads those bytes.
  localparam int F_US_LO  = 2;        // the measured echo width
  localparam int F_US_HI  = 3;
  localparam int F_DONE   = 10;       // the completion flag: the program writes
                                     // 1 here when the answer is banked, and
                                     // 0 in its init, so a 0 -> 1 edge is a
                                     // real edge and not a leftover
  localparam int F_SLOT0  = 6;        // THE answer, millimetres, low byte
                                     // first -- one slot, because the program
                                     // banks one answer per run

  localparam int N_MEAS = 2;          // TWO RUNS, and N_MEAS now counts runs
  localparam int TRIG_CLOCKS = 601;   // 4*SR_TRIG_LEN + 5, counted in peasm's CONSTS
                                     // and from the listing. SR_TRIG_LEN, not
                                     // SR_TRIG: the pin constant is 0x40, and a
                                     // program that loaded it made a 261-clock
                                     // pulse = 4*64 + 5.
  localparam int RESP_US = 300;        // the model's sensor response delay
  localparam int RECOV_US = 1500;      // the model's own recovery, in us. The
  // program has NO recovery wait of its own any more -- the two-measurement
  // version did, and the header of this file used to argue that the two
  // independently fitted constants must not sit within one tick of each
  // other. That argument is gone with the second measurement, and what
  // replaces it is a per-run check that the program did not re-trigger inside
  // the window: a real HC-SR04 ignores such a trigger, and the measurement
  // that never comes back is SILENT.
  // The datasheet's own figure is 50 ms worst case; this is the testbench's
  // timescale, and the header says so.
  // A run's budget: the model's 300 us response, the longest echo (5816 us),
  // the trigger (10 us) and the conversion, with 4x headroom. Watched in
  // chunks of 256 clocks because a poll of the form `while (flag != DONE)`
  // EXITS IMMEDIATELY on X -- see the comment at the wait below.
  localparam int WAIT_CHUNKS = 4000;  // 4000 * 256 clocks = 17.07 ms per run
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
  // echo widths in microseconds. One width per RUN, taken from the table by
  // the run index, and the second is longer than 255 -- so a firmware whose
  // capture counter is a byte fails on the second run and not on the first.
  integer e_us  [0:N_MEAS-1];
  integer n_trig = 0;
  integer trig_clocks = 0;     // the measured trigger pulse, in clocks
  integer cur_clocks = 0;
  integer echo_high_clocks = 0;
  integer echo_rel_oe = 0;     // clocks in a trigger pulse with ECHO driven
  integer trig_oe_lo = 0;      // clocks TRIG was driven without a pulse
  integer n_ignored = 0;       // triggers that arrived inside the recovery
  integer n_extra = 0;         // triggers after the run's first
  integer meas_idx = 0;        // the run being served
  real    busy_until = 0.0;    // the model's own recovery window, in ns
  real    t_echo_end = 0.0;    // when this run's echo ended

  // The banked answer and the width that produced it, as they stood on the
  // clock the completion flag rose. Read there rather than at the end of the
  // run -- see the header.
  //
  // STAGED THROUGH INTEGERS, and that is not style. `(dmem[3] << 8)` is an
  // EIGHT-BIT shift in a self-determined context: a probe added to this file
  // during the restructure printed the width as 136 rather than 1160 for
  // exactly this reason -- 0x88 with the high byte shifted out of existence --
  // while the sampler beside it, whose left-hand side is an integer, was
  // right. The original version of this file staged through integers too, and
  // the inline form is correct ONLY because of the assignment's width, which is
  // the kind of correctness that survives one edit and not the next.
  integer bank_mm = 0, bank_us = 0;
  integer banked = 0;          // how many answers this file has read
  integer flag_cleared = 0;    // clocks on which the flag was seen at 0
  logic   sample_armed = 1'b0; // set once the program is running
  logic   flag_seen_high = 1'b1; // the flag's level last clock

  // Re-arm everything for one run. Called BETWEEN runs with run low, so the
  // model is parked on `@(posedge trig)` and nothing is in flight.
  task automatic arm_run(input integer idx);
    begin
      meas_idx = idx;
      n_trig = 0; n_ignored = 0;
      busy_until = 0.0; t_echo_end = 0.0;
      trig_clocks = 0; cur_clocks = 0; echo_high_clocks = 0;
      echo_rel_oe = 0; trig_oe_lo = 0; n_extra = 0;
      bank_mm = 0; bank_us = 0; banked = 0; flag_cleared = 0;
      sample_armed = 1'b0; flag_seen_high = 1'b1;
      echo = 1'b0;
    end
  endtask

  // A FULL RESET between runs: run low, reset asserted, the image reloaded,
  // then released. The reset is what re-arms the firmware's own PREV, STATE
  // and the tick's previous reading, so a run without it would measure the
  // line as it found it.
  task automatic run_reset();
    begin
      run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
      host_addr = '0; host_wdata = '0;
      rst_n = 1'b0;
      repeat (4) @(posedge clk);
      #1;
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
      load_firmware();
      repeat (4) @(posedge clk);
      #1;
    end
  endtask

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
  //
  // IT LISTENS FOR A TRIGGER CONTINUOUSLY, and that is the fix for the fault
  // this act spent three commits on. The first version waited for a trigger,
  // served it, slept out a recovery, and only THEN began listening again --
  // so a trigger arriving inside the recovery was neither answered nor
  // counted, the two sides never re-phased, and the run banked one answer and
  // stopped. A real device ignores a trigger inside its recovery too, but it
  // is still WATCHING: it answers the next one. So the model watches always,
  // answers only what arrives outside the window, and counts only what it
  // answered -- which is the difference between a model that is deaf for two
  // milliseconds and one that is merely busy.
  //
  // ONE TRIGGER PER RUN, and the run's width comes from arm_run rather than
  // from a counter: the model serves the first trigger of the run and reports
  // a second one as EXTRA, because a program that pulses twice has a defect
  // and a model that answers the second pulse hides it.
  initial begin
    forever begin
      @(posedge trig);
      if ($realtime < busy_until) begin
        // Inside the recovery: IGNORED, exactly as a real device ignores it,
        // and not counted. Counting it would report a measurement that was
        // never made, which is how a model starts lying about its own DUT.
        n_ignored = n_ignored + 1;
      end else if (n_trig == 0) begin
        n_trig = 1;
        fork
          begin
            // Count the clock edges across which TRIG is high, and nothing
            // else: the counter starts at zero and the loop is entered while
            // the pad is still high, so it counts TRIG_CLOCKS for a
            // TRIG_CLOCKS-clock pulse and not one more. The first version of
            // this seeded the counter at one and waited a clock before
            // testing, which made every pulse look one clock longer than it
            // was -- the same class of off-by-one as a counter decremented
            // before its first use.
            trig_clocks = 0;
            while (trig) begin
              @(posedge clk);
              trig_clocks = trig_clocks + 1;
              if (echo_oe) echo_rel_oe = echo_rel_oe + 1;
            end
          end
          serve(e_us[meas_idx]);
        join
        t_echo_end = $realtime;
        busy_until = t_echo_end + RECOV_US * 1000.0;
      end else begin
        n_extra = n_extra + 1;
      end
    end
  end

  // THE ANSWER, READ WHERE IT IS BANKED. A sampler on the clock the
  // completion flag RISES, rather than a read at the end of the run.
  //
  // THE EDGE, NOT THE LEVEL, and dmem is not cleared by a reset -- so on the
  // second run the flag still holds the first run's 1 at the moment the core
  // is released, and a level test sampled it 1.6 us into the run and reported
  // the PREVIOUS run's answer as this one's. That failure is not subtle: the
  // checks then ran before the firmware had even triggered, and reported a
  // 161-clock trigger that was really a pulse half-way through. So the
  // sampler requires a 1 -> 0 -> 1, and the 0 is the program's own init --
  // which also means the sampler can be armed the instant the core is
  // released, with no window in which a fast bank could be missed.
  always @(posedge clk) if (rst_n) begin
    if (dut.dmem[F_DONE] === 8'h00) flag_cleared = flag_cleared + 1;
    if (sample_armed && !flag_seen_high && dut.dmem[F_DONE] === 8'h01) begin
      integer a_lo, a_hi, u_lo, u_hi;
      a_lo = dut.dmem[F_SLOT0];
      a_hi = dut.dmem[F_SLOT0 + 1];
      u_lo = dut.dmem[F_US_LO];
      u_hi = dut.dmem[F_US_HI];
      bank_mm = (a_hi << 8) | a_lo;
      // The width bytes are LEGAL to read HERE and were not legal during the
      // conversion: dmem[2..3] IS the measurement, and the one-answer design
      // is the reason the conversion does not overwrite them. That is the
      // whole content of the design change, and it is worth saying in the
      // file that reads them rather than leaving a future reader to assume
      // the old shape.
      bank_us = (u_hi << 8) | u_lo;
      banked = banked + 1;
      sample_armed = 1'b0;
    end
    flag_seen_high <= (dut.dmem[F_DONE] === 8'h01);
  end

  // TRIG driven while not pulsing is a level, not a pulse: the datasheet's
  // trigger is a pulse, and a held-high trigger is a second measurement the
  // firmware did not intend. EVERY such clock is counted -- the first version
  // of this stopped counting after the first, so a pad HELD driven reported 1
  // and passed the very check written to catch it, which is the block's own
  // finding in miniature: a check that cannot fail is not a check.
  always @(posedge clk) if (rst_n && run) begin
    if (trig_oe && !trig) trig_oe_lo = trig_oe_lo + 1;
  end

  // ---- the checks -------------------------------------------------------
  integer seg, waited, tol_us;
  integer exp_mm, wide_seen;

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

    $display("\n=== HC-SR04 ranging: %0d runs, one distance each: %0d us and %0d us ===\n",
             N_MEAS, e_us[0], e_us[1]);

    wide_seen = 0;
    for (seg = 0; seg < N_MEAS; seg++) begin
      // Arm the model FIRST, then reset the core, then release it: the model's
      // state has to be clean before anything can trigger it, and the core's
      // reset is what re-runs the firmware's own init.
      arm_run(seg);
      run_reset();
      $display("  run %0d: model armed for a %0d us echo (%0d mm), core released",
               seg, e_us[seg], (e_us[seg] * 11) / 64);

      // The program runs only while `run` is high, so the init that clears
      // the completion flag has NOT happened yet at this point -- the first
      // version of this restructure waited for the clear BEFORE releasing the
      // core, spun for its whole budget, and reported "the program's init
      // never cleared dmem[10]" on a program that was working. The sampler is
      // armed here and takes the 1 -> 0 -> 1 edge itself, so there is no
      // window in which a bank could slip past between a poll and the arm.
      sample_armed = 1'b1;
      flag_seen_high = (dut.dmem[F_DONE] === 8'h01);
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
      // 256-clock wait, which is why the two files look the same.
      waited = 0;
      while (waited < WAIT_CHUNKS && banked == 0) begin
        repeat (256) @(posedge clk);
        waited = waited + 1;
      end
      run = 1'b0;

      check(banked == 1,
            $sformatf("run %0d: the program banked exactly one answer for a %0d us echo (%0d banks seen) -- it measures ONE distance per run and parks, so a run that banks nothing has FAILED rather than waited",
                      seg, e_us[seg], banked));
      // The sampler takes a 1 -> 0 -> 1 edge, so an answer can only be
      // attributed to a run whose init actually cleared the flag. If that
      // clear never happened the sampler stays quiet and the check above
      // fails; this one says WHY, in the program's terms rather than in the
      // testbench's.
      check(flag_cleared > 0,
            $sformatf("run %0d: the program's init cleared dmem[%0d] before banking (%0d clocks at 0) -- a program that never clears it cannot be told apart from the previous run",
                      seg, F_DONE, flag_cleared));

      // The device's own rules, per run. These are the checks a firmware that
      // pulsed twice would fail silently: a real HC-SR04 ignores a trigger
      // inside its recovery and the measurement that never comes back is
      // SILENT, and a second pulse outside the recovery is a measurement the
      // program never asked for.
      check(n_trig == 1,
            $sformatf("run %0d: the model saw exactly ONE trigger (%0d) -- the program pulses once and parks",
                      seg, n_trig));
      check(n_ignored == 0,
            $sformatf("run %0d: no trigger arrived inside the model's %0d us recovery (%0d did) -- a real device ignores one, and the measurement that never comes back is silent",
                      seg, RECOV_US, n_ignored));
      check(n_extra == 0,
            $sformatf("run %0d: no SECOND trigger outside the recovery (%0d did) -- the program pulses once per run",
                      seg, n_extra));

      // ---- 1. the trigger pulse, as an EQUALITY ------------------------
      check(trig_clocks == TRIG_CLOCKS,
            $sformatf("run %0d: the trigger pulse is EXACTLY %0d clocks = %0.3f us (measured %0d = %0.3f us), and the device asks for 10 us minimum",
                      seg, TRIG_CLOCKS, TRIG_CLOCKS*CLK_US, trig_clocks, trig_clocks*CLK_US));
      check(echo_rel_oe == 0,
            $sformatf("run %0d: ECHO was RELEASED on every clock of the trigger pulse (%0d clocks driven)",
                      seg, echo_rel_oe));
      // ONE clock of driven-at-a-level is the ARCHITECTURAL MINIMUM and not a
      // defect: the pad is claimed, the level write and the release write are
      // three separate instructions, so between the level going to 0 and the
      // release there is exactly one clock in which the pad is driven low. The
      // count is the discriminator, and it is a real one only because the
      // counter now runs to the end of the pulse: the version that stopped
      // counting after the first reported 1 for a pad held driven for
      // thousands of clocks, and passed the check written to catch it.
      check(trig_oe_lo <= 1,
            $sformatf("run %0d: TRIG is driven at a level for at most the one clock the level write and the release write are apart (%0d clocks)",
                      seg, trig_oe_lo));

      // ---- 2/3. the width and the conversion, AS THEY WERE BANKED ------
      exp_mm = (e_us[seg] * 11) / 64;     // the specification, in integer mm
      $display("    run %0d: echo %0d us -> firmware %0d us, answer %0d mm (expected %0d mm)",
               seg, e_us[seg], bank_us, bank_mm, exp_mm);
      // AN UNKNOWN VALUE IS A FAILURE, and these two checks are here because
      // an `if` with an X operand does NOT fail. The width tolerance below
      // was the one check in this file written as `if (iabs(...) > tol)`
      // rather than as a check() call, and a mutation that left the width's
      // high byte unwritten made that comparison X -- so the `if` was false
      // and the check PASSED on a program that had measured nothing at all.
      // The mm checks did not have the problem, and the reason is worth
      // stating: check() takes a `bit`, so an X argument is coerced to 0 and
      // fails, while an `if` condition stays X and takes the else path. Two
      // kinds of check in one file, disagreeing about what unknown means.
      check(^bank_us !== 1'bx,
            $sformatf("run %0d: the firmware left an UNKNOWN width in dmem[%0d..%0d] -- an unknown measurement is not a measurement",
                      seg, F_US_LO, F_US_HI));
      check(^bank_mm !== 1'bx,
            $sformatf("run %0d: the firmware banked an UNKNOWN answer in dmem[%0d..%0d]",
                      seg, F_SLOT0, F_SLOT0 + 1));
      // 1 % of the width, with a floor of 1.5 us rounded UP to 2 because the
      // tick is a whole microsecond and a floor of 1 would be tighter than
      // the instrument. This is now checked PER RUN, and it can be: the
      // version before the design change held the width in one register for
      // the whole run, so it could only be checked on the last measurement,
      // and checking it per measurement is what reported the second echo's
      // width as the first measurement's error. Written as a check() call and
      // not as an `if`, for the reason above.
      tol_us = e_us[seg] / 100;
      if (tol_us < 2) tol_us = 2;
      check(!(iabs(bank_us - e_us[seg]) > tol_us),
            $sformatf("run %0d: the measured width %0d us is outside 1 %% (floor 2 us) of the model's %0d us",
                      seg, bank_us, e_us[seg]));
      // The conversion is EXACT for 11/64, so this is an equality. The
      // tolerance that would matter is the constant's own +0.22 % against
      // the speed of sound, and that is a property of the constant, not of
      // the arithmetic, so it is reported in the header rather than
      // smuggled in as slack here.
      check(bank_mm == exp_mm,
            $sformatf("run %0d: %0d us is %0d mm, not %0d mm -- us*11/64 is exact and this is an equality",
                      seg, bank_us, bank_mm, exp_mm));
      if (bank_us > 255) wide_seen = wide_seen + 1;
    end

    check(wide_seen >= 1,
          $sformatf("at least one echo is wider than 255 us, so the capture's 16-bit counter is what is under test (a byte capture reports %0d us for %0d)",
                    wide_seen, e_us[N_MEAS-1] % 256));

    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    // TWO RUNS, so the watchdog is twice what one run needed. The longest run
    // is 5816 us of echo plus 300 us of sensor response plus the conversion,
    // and the two per-run budgets above are 17 ms each, so 34 ms of waiting
    // plus a little over 120 ms leaves the failure path room to report rather
    // than being cut off mid-sentence.
    #120_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
