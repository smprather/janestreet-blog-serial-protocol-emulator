// tb_pe_soc_dmx512.v — a DMX512-A receiver, at 250 kbaud, on real RTL, driven
// by firmware/dmx512.pe.
//
// WHAT THIS PROVES THAT A SLOT-PATTERN CHECK WOULD NOT
//
// The claim of firmware/dmx512.pe is four things, and they fail differently:
//
//   1. THE RATE. A DMX bit is 4 us and the SoC's shared tick is 4.3333 us, so
//      the bit is 0.923 of a tick and the timer cannot be used even ONCE. The
//      program builds the cell from counted instructions instead, and this TB
//      MEASURES the cell on the pin and checks it. An unmeasured delay in a
//      UART is the classic error that decodes anyway and therefore survives
//      review; at 250 kbaud it is worse, because a DMX receiver resynchronises
//      per SLOT and a per-slot resynchronisation cannot repair a transmitter
//      whose cell is wrong by a fixed fraction -- it just moves the error.
//
//   2. THE BREAK AND THE MARK. A DMX receiver will not look at a frame that
//      does not begin with a LOW of at least 87.5 us followed by a HIGH of at
//      least 8 us. These are floors, not targets, and both are measured here
//      and checked against the floor -- a frame that is merely slow is not a
//      frame at all.
//
//   3. THE START CODE. 513 slots go out: a start code and 512 data slots. The
//      start code is what tells a receiver what the slots MEAN, and 512 slots
//      with no start code is the most common way to end up with a working
//      fixture that lights nothing.
//
//   4. THE SLOT COUNT, as a second and independent witness. This one was
//      written wrong first -- "a receiver that loses a slot still sees a valid
//      pattern, and only a count gives that away" -- and running the
//      dmx-ramp-steps-by-two mutation by hand is what showed it: a wrong slot
//      value produces hundreds of PER-SLOT failures, because the ramp is
//      0, 1, 2, ... so one wrong slot makes every later value wrong. The
//      per-slot comparison is the defence against a payload error. The count is
//      here for the other reason: it reads the CPU-s own memory while the
//      per-slot comparison reads the wire, so the two are independent witnesses
//      and their disagreement is itself the signal. See the note at the dmem
//      checks below.
//
// AND THE BIT ORDER IS NOT A PALINDROME ANYWHERE. Slot 1 is 0x01 and slot 128
// is 0x80, so a transmitter that shifted the wrong way produces 0x80 and
// 0x01 -- swapped, not identical. That is the property that makes the
// per-slot comparison worth anything, and it is why the payload is a ramp and
// not a constant.
//
// WHY THIS RECEIVER IS NOT THE MIDI RECEIVER -- AND THE REASON I FIRST GAVE
// FOR THAT WAS WRONG, so the correction is here rather than in a changelog.
//
// tb_pe_soc_midi.v oversamples: a free-running strobe every EIGHTH bit (8x,
// 4 us), never
// blocking, so a rejected candidate costs the search nothing. That is the
// right shape for 31.25 kbaud, where the whole frame is 320 us. I first wrote
// that following it literally here "would have cost 5.7 million strobe events
// across 22.6 ms of frame -- the testbench would have spent more time on its
// own sampler than on the DUT".
//
// MEASURED, THAT IS FALSE BY A FACTOR OF 125. The variant was built and timed
// rather than left as arithmetic: the same testbench plus a free-running
// 1/8-bit strobe over the whole frame fires 45,753 strobes, not 5,700,000,
// and runs in 27 s against this one's 28 s -- no measurable difference at all.
// The 5.7M came from scaling 22.8 ms by a nanosecond-scale interval instead of
// by half a cell. 22.8 ms / 0.5 us is 45,600, and that is the whole number.
//
// So the lean design does NOT pay for itself in simulation time, and it is
// kept for the two reasons that survive measurement:
//
//   1. It has less state. A background process that must be serviced correctly
//      for 22.8 ms is a second thing that can be wrong; this has none.
//   2. Every sample point here is computed from the slot's OWN start edge, so
//      the receiver never has to reason about a grid that has to be re-anchored
//      across a quarter of a second of wire.
//
// And the honest note, which is the useful part: a design justified by a
// performance claim that turns out to be unmeasured is a design waiting to be
// believed. The claim was in this comment and in the findings file for a whole
// commit before anything timed it.
//
// So this receiver samples only WHILE DECODING A SLOT: eleven waits per slot,
// 5,643 in the whole frame, and the idle time between slots costs nothing at
// all. What it keeps from the MIDI receiver is the property that matters --
// a frame is ACCEPTED ONLY IF BOTH STOP BITS READ HIGH -- and the reason is
// the same: the mark between slots is not a start bit, and a transition
// inside a slot is not a start bit.
//
// AND THE NON-VACUITY, run both ways. Driven by firmware/dmx512.hex this
// passes; driven by firmware/midi_xfer.hex -- a real 8N1 stream at 31.25 kbaud
// on the same pin -- it fails, and the detail is worth recording: THE BREAK AND
// MARK CHECKS PASS on the wrong protocol. A 31.25 kbaud frame's long low run
// measures 159.99 us and its idle high measures 32.00 us, which clears the
// 87.5 us break floor and the 8 us mark floor without meaning it. What
// actually rejects it is the stop-bit verification and the per-slot
// comparison. A floor is a floor: it says "not shorter than", and a wrong
// protocol is not shorter.
//
// HOW A SLOT'S START BIT IS FOUND, since a falling edge is not one. DMX is
// easier than MIDI in one specific way: within a slot of 8N2, the last
// possible falling edge is at cell 8, because cells 9 and 10 are both stop
// bits and so cannot fall. A fall at least 9.5 cells after the current slot's
// start bit is therefore NOT inside that slot, and the next slot's start bit
// is the only thing it can be. The first slot is anchored on the BREAK, which
// is 88 us of LOW and is not confusable with anything.
//
// Program: firmware/dmx512.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

module tb_pe_soc_dmx512;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD       = 115_200;          // the SoC's, NOT DMX's
  localparam int CLK_HZ     = 60_000_000;
  localparam real CLK_NS   = 1e9 / CLK_HZ;

  // The DMX rate. 4.000 us per bit cell, and 250,000 baud exactly.
  //
  // THE TOLERANCE IS 0.3% FOR THE SAME REASON AS IN tb_pe_soc_midi.v, and the
  // arithmetic is the same shape: the transmitter is a counted-instruction
  // divider on a known clock, its cell is 21 + 1 + 2N, and the only values it
  // can produce near 4 us are 238 clocks (3966.7 ns), 240 (4000.0) and 242
  // (4033.3) -- 0.83% apart. A window wide enough to admit DMX's own
  // tolerance would admit all three and the rate check would be decorative.
  localparam real DMX_BIT_NS  = 4_000.0;
  localparam real RATE_TOL    = 0.003;           // +/-0.3%
  // The floors from the standard, as minimums and not as targets. Note WHAT
  // EACH IS MEASURED OVER, because firmware/dmx512.pe's header states the LOOPS
  // as 88.0 us and 12.0 us and this TB prints 88.06 and 12.38 -- both correct,
  // different intervals, and until the header said so the two files simply
  // disagreed by 3.2% on the mark:
  //
  //   break  fall to first rise    = the loop PLUS the 4 clocks of LDI/STM/OUT
  //                                  before it
  //   mark   break's end to the FIRST START BIT, not to the mark loop's end
  //                                  = the loop PLUS the frame layer's whole
  //                                  22-instruction prologue (0.367 us)
  //
  // So the numbers compared against the floors below are the ones a receiver
  // would actually see, which is the whole reason the floors are checked here
  // and not in the firmware.
  localparam real BREAK_MIN_NS = 87_500.0;
  localparam real MARK_MIN_NS  =  8_000.0;
  // 8N2: start + 8 data + 2 stop.
  localparam int CELLS_PER_SLOT = 11;
  localparam int N_SLOTS = 513;                 // 1 start code + 512 data

  localparam int TX_BIT = 0;

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus = 8'hFF;
  wire tx_pin = pin_out_bus[TX_BIT];

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

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;
  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh("../firmware/dmx512.hex", prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // =========================================================================
  // THE EDGE MONITOR, and the cell measurement built on it.
  //
  // Timing only. It does not decide that any edge is a start bit -- the two
  // stop bits do that, by being verified -- and keeping those two jobs apart
  // is the distinction tb_pe_soc_midi.v's four failed receivers were about.
  real    edge_t   [0:31];
  integer edge_w   = 0;
  always @(tx_pin) if (run && rst_n) begin
    edge_t[edge_w] = $realtime;
    edge_w = (edge_w == 31) ? 0 : edge_w + 1;
  end

  // The level a cell of a slot is supposed to be on: cell 0 is the start bit,
  // cells 1..8 are the data bits LSB first, cells 9 and 10 are the two stops.
  function automatic bit cell_level(input integer c, input [7:0] by);
    if (c == 0)                             cell_level = 1'b0;
    else if (c >= CELLS_PER_SLOT - 2)        cell_level = 1'b1;
    else                                     cell_level = by[c-1];
  endfunction

  // The first cell boundary after the start bit where the level changes, and
  // therefore how many cells the start bit's edge and the next edge are apart.
  function automatic integer first_transition(input [7:0] by);
    integer c;
    first_transition = -1;
    for (c = 1; c <= CELLS_PER_SLOT - 2; c = c + 1)
      if (cell_level(c, by) !== cell_level(c-1, by)) begin
        first_transition = c;
        c = 999;                      // leave the loop; Icarus wants no break
      end
  endfunction

  // The measured cell, per slot. Slots 0 and 128 are the two the checks below
  // lean on for a spread, but EVERY slot is measured and EVERY measurement is
  // checked, so a transmitter that drifts across the frame cannot hide inside
  // an average.
  real    cell_meas [0:N_SLOTS-1];
  integer n_meas = 0;

  // What slot n must contain. Slot 0 is the start code; the rest are the ramp,
  // so slot n is (n-1) mod 256 -- computed here rather than written out as a
  // 513-entry constant, because Icarus rejects an unpacked array parameter
  // ("unpacked array parameters are not supported yet") and a hand-written
  // list of 513 literals would be a second copy of the firmware's own ramp to
  // keep in step with it.
  function automatic [7:0] exp_slot(input integer n);
    if (n == 0) exp_slot = 8'h00;             // the all-slot start code
    else        exp_slot = 8'((n - 1) & 8'hFF);
  endfunction

  // =========================================================================
  // THE RECEIVER.
  // =========================================================================
  real cell_ns = DMX_BIT_NS;          // the cell, refined from measured slots

  // Receive one slot from its start bit's falling edge, which the caller has
  // already found. Samples the eleven cell centres and RETURNS whether both
  // stop bits read high -- the one check a back-to-back stream can make, and
  // the one that makes a rejected candidate cost nothing but the slot.
  task automatic receive_slot(input real t_start, output [7:0] b,
                              output bit ok);
    real t;
    integer k;
    begin
      b  = 8'h00;
      ok = 1'b1;
      t  = t_start + 0.5 * cell_ns;          // the start bit's own centre
      for (k = 1; k < CELLS_PER_SLOT; k = k + 1) begin
        t = t + cell_ns;                     // the centre of cell k
        if (t > $realtime) #(t - $realtime);
        if (k <= 8) b[k-1] = tx_pin;         // the eight data bits, LSB first
        // THE VERIFICATION: cells 9 and 10 are the two stop bits, and a
        // candidate whose stop reads low is not a slot.
        else if (!tx_pin) ok = 1'b0;
      end
    end
  endtask

  // =========================================================================
  // Stimulus
  // =========================================================================
  task automatic reset_and_load;
    run = 1'b0; rst_n = 1'b0;
    repeat (4) @(posedge clk); #1;
    n_meas = 0; edge_w = 0; cell_ns = DMX_BIT_NS;
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    load_firmware();
    // The four-clock gap before `run` rises is required: the SRAM macro's read
    // output is registered, so releasing the CPU in the same instant as the
    // loader's last write makes it decode a stale word as pc=0.
    repeat (4) @(posedge clk); #1;
    run = 1'b1;
  endtask

  real    t_brk_start = 0.0, t_mark_start = 0.0, t_first_start = 0.0;
  real    t_slot = 0.0;
  logic [7:0] slot_byte;
  bit          slot_ok;

  initial begin
    // THE DUMP IS DELIBERATELY THE TB SCOPE ONLY, AND THE REASON IS
    // ARITHMETIC, not taste. One DMX frame is 1.37 million clocks, and a
    // full-hierarchy $dumpvars(0) of this design across that span is a file of
    // hundreds of megabytes -- which the regression would write on every run
    // of this testbench, for a waveform whose only moving part is a 4 us
    // square wave that the assertions below already measure on the pin. The TX
    // pin, the measured times and every receiver variable are all in the file,
    // because they are all in this scope.
    $dumpfile("tb_pe_soc_dmx512.vcd");
    $dumpvars(1, tb_pe_soc_dmx512);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;

    $display("\n=== DMX512-A 250 kbaud 8N2, break + mark + 513 slots ===");
    reset_and_load();

    // ---- the BREAK: 88 us of LOW, and the floor is 87.5 us -------------
    //
    // The window is DERIVED FROM THE RATE, which is the discipline this whole
    // act is about. A DMX512-A frame is 513 slots x 11 cells x 4.000 us =
    // 22.572 ms, plus the break and the mark and the inter-slot work, so the
    // drain window is 26 ms: 15% of headroom over a number that is computed
    // rather than guessed. The first version of a testbench that guessed
    // allowed 900 us, which is a twentieth of the frame, and reported a
    // truncated stream as if it were a protocol failure.
    @(negedge tx_pin);                    // the break begins
    t_brk_start = $realtime;
    @(posedge tx_pin);                    // the break ends
    t_mark_start = $realtime;
    check(($realtime - t_brk_start) >= BREAK_MIN_NS,
          $sformatf("the break is at least 87.5 us (%.2f us)",
                    ($realtime - t_brk_start) / 1000.0));
    $display("    break %.2f us (floor 87.5)", ($realtime - t_brk_start)/1000.0);

    // ---- the MARK, and then the first slot -----------------------------
    //
    // The start code is 0x00, so its eight data bits are all low: the line is
    // LOW from the start bit through cell 8 and HIGH for cells 9 and 10. The
    // first fall after the mark is therefore the start code's start bit and
    // nothing else could be, because the mark is preceded by 88 us of LOW --
    // and the fall at cell 9, nine cells later, is a ruler: the cell is
    // measured from those two edges.
    //
    // SLOT 0 IS DECODED ON THE NOMINAL CELL AND THE MEASUREMENT IS TAKEN
    // AFTERWARDS, and the order matters. The obvious version finds the fall,
    // waits for the cell-9 rise to measure the cell, and only then decodes --
    // and by then the simulation clock is nine cells past the slot it is about
    // to sample, so every one of the eleven samples lands in the past, takes
    // no delay, and reads whatever the line happens to be doing. That version
    // decoded the start code as 0xff: eight ones, from eight samples taken at
    // a single instant. Sampling on the nominal cell and refining afterwards
    // costs at most 0.0017 us per cell here, which is 0.04% of a cell at the
    // far end of the slot, and it cannot consume the timeline it is measuring.
    @(negedge tx_pin);
    t_first_start = $realtime;
    check(($realtime - t_mark_start) >= MARK_MIN_NS,
          $sformatf("the mark is at least 8.0 us (%.2f us)",
                    ($realtime - t_mark_start) / 1000.0));
    $display("    mark  %.2f us (floor  8.0)", ($realtime - t_mark_start)/1000.0);

    // ---- the 513 slots --------------------------------------------------
    //
    // Slot 0 is decoded from the fall already found. Every later slot's start
    // bit is the first fall at least 9.5 cells after the current one: the last
    // fall INSIDE a slot of 8N2 is at cell 8, because cells 9 and 10 are both
    // stop bits and cannot fall, so anything later than that is the next
    // slot's start bit and nothing else. The upper bound catches a frame that
    // has stopped rather than letting the loop wait for ever.
    t_slot = t_first_start;
    for (int s = 0; s < N_SLOTS; s++) begin
      if (s > 0) begin
        real t_want;
        t_want = t_slot + 9.5 * cell_ns;
        begin : find_next
          forever begin
            @(negedge tx_pin);
            if (($realtime - t_want) >= 0.0) disable find_next;
          end
        end
        t_slot = $realtime;
        check(($realtime - t_want) < 4.0 * cell_ns,
              $sformatf("slot %0d's start bit follows within 4 cells of 9.5 (it is %0.2f cells late)",
                        s, ($realtime - t_want) / cell_ns));
      end

      receive_slot(t_slot, slot_byte, slot_ok);
      check(slot_ok, $sformatf("slot %0d: both stop bits read high", s));
      if (slot_byte !== exp_slot(s))
        check(1'b0, $sformatf("slot %0d is %02h, expected %02h", s,
                              slot_byte, exp_slot(s)));

      // The cell, measured from two edges INSIDE this slot. Differencing slot
      // starts would not do: the inter-slot work belongs to no bit, and it
      // varies with which branch the frame layer takes.
      if (n_meas < N_SLOTS) begin
        integer k1, e;
        real t1, span;
        k1 = first_transition(slot_byte);
        t1 = -1.0;
        for (e = 0; e < 32; e = e + 1)
          if (edge_t[e] > t_slot && (t1 < 0.0 || edge_t[e] < t1)) t1 = edge_t[e];
        if (k1 > 0 && t1 > 0.0) begin
          span = (t1 - t_slot) / k1;
          cell_meas[n_meas] = span;
          n_meas = n_meas + 1;
          cell_ns = span;
        end
      end
    end

    // ---- wait for the firmware to finish the frame, THEN read dmem -----
    //
    // THE ORDER MATTERS AND GETTING IT WRONG IS EASY. The last receive_slot
    // ends half a cell before the last slot's final stop bit, so at that
    // instant the frame layer has not run at all: the transmitter is still in
    // its loop, dmem[3] is 0, dmem[9] has never been written and dmem[10] is
    // still 0. The first version of this test checked dmem right there and
    // reported slots_low=0, pages=x, finished=00 for a frame that had just
    // gone out complete and correct on the wire -- three failures that all
    // pointed at a firmware that had not been given the chance to run.
    //
    // The wait is bounded at 20 cells, which is five times the frame layer's
    // whole inter-slot path, so a firmware that stops early still fails the
    // assertions below rather than hanging the test.
    begin : settle
      realtime t_deadline;
      t_deadline = $realtime + 20.0 * DMX_BIT_NS;
      while (dut.dmem[10] != 8'hA5 && $realtime < t_deadline) @(posedge clk);
    end

    // ---- the rate, and the two floors, measured on the pin --------------
    if (n_meas >= 2) begin
      real cmin, cmax, csum;
      cmin = cell_meas[0];
      cmax = cell_meas[0];
      csum = 0.0;
      for (int j = 0; j < n_meas; j++) begin
        if (cell_meas[j] < cmin) cmin = cell_meas[j];
        if (cell_meas[j] > cmax) cmax = cell_meas[j];
        csum = csum + cell_meas[j];
      end
      $display("    measured over %0d slots: cell %.4f us (%.0f baud), spread %.4f us -- nominal 250000",
               n_meas, (csum / n_meas) / 1000.0, 1.0e9 / (csum / n_meas),
               (cmax - cmin) / 1000.0);
      // A HISTOGRAM OF THE DISTINCT MEASUREMENTS, because a rate that is
      // 0.4% fast on every OTHER slot and exact on the rest is not a rate, it
      // is a per-cell-length bug, and only the distribution says so. The
      // summary line above would have reported the mean and the spread and
      // left the reader to guess.
      begin : hist
        real lo; integer n, z;
        for (z = 0; z < 20; z = z + 1) begin
          lo = DMX_BIT_NS * (1.0 - 0.01) + z * 0.0025;
          n = 0;
          for (int j = 0; j < n_meas; j = j + 1)
            if (cell_meas[j] >= lo && cell_meas[j] < lo + 0.0025) n = n + 1;
          if (n > 0)
            $display("      %0d slots measure %.4f us (%.2f clocks)", n,
                     lo + 0.00125, (lo + 0.00125) * 60.0);
        end
      end
      for (int j = 0; j < n_meas; j++) begin
        check(cell_meas[j] > DMX_BIT_NS * (1.0 - RATE_TOL) &&
              cell_meas[j] < DMX_BIT_NS * (1.0 + RATE_TOL),
              $sformatf("slot %0d: cell %.4f us is outside 4.000 us +/- %.1f%%",
                        j, cell_meas[j] / 1000.0, RATE_TOL * 100.0));
      end
      // EVERY CELL IS THE SAME LENGTH, and it is a separate check from the
      // window because it catches a different defect. The window is +/-0.3%
      // and the delay loop's quantisation is 0.83%, so the window sees a
      // change in the LOOP COUNT and is blind to a one-clock change in a
      // single cell's PADDING. The spread sees that: the half of the slots
      // whose first transition is cell 0 measure that cell directly, so an
      // extra NOP in sb_start moves exactly half the measurements and the
      // frame stops having one rate. This check found the real thing during
      // development -- cells of 241, 240 and 1917 clocks in one frame, a mean
      // of 4.0114 us and a spread of 0.0148 us, which is not a rate at all.
      check((cmax - cmin) < 0.001,
            $sformatf("every cell is the same length (the measurements span %.4f us)",
                      (cmax - cmin) / 1000.0));
    end else begin
      check(1'b0, $sformatf("enough slots measured to check a rate (%0d)", n_meas));
    end

    // ---- the firmware's own record --------------------------------------
    //
    // The COUNT as well as the pattern, and the reason is worth stating
    // precisely because I first wrote it wrongly.
    //
    // I had this comment saying "a transmitter that dropped a slot would still
    // produce a valid-looking pattern, and only a count gives that away". BOTH
    // HALVES ARE WRONG, and running the dmx-ramp-steps-by-two mutation by hand
    // is what showed it: a slot carrying the wrong value produces hundreds of
    // "slot N is fe, expected ff" PER-SLOT failures. The per-slot comparison is
    // the defence against a payload error, because the ramp is 0, 1, 2, ... so
    // one wrong or missing slot makes every later value wrong. A payload error
    // is emphatically NOT a valid-looking pattern.
    //
    // So what is the count actually for, and the honest answer is: it is a
    // SECOND, INDEPENDENT path, not a primary one. The per-slot comparison
    // reads the wire; these read the CPU-s own memory. They are computed from
    // different places, so a fault that corrupts one but not the other is
    // caught by the disagreement -- and a firmware that finished its frame
    // while its own counters said otherwise, or the reverse, is exactly that.
    // The transmission is the claim; dmem is the firmware's account of it, and
    // a receiver that never cross-checks the two is trusting one witness.
    //
    // 513 DOES NOT FIT IN ONE BYTE, and the firmware says so rather than
    // pretending: 513 = 0x201, so dmem[3] -- an 8-bit count -- is 1 and
    // dmem[9], the number of 256-slot pages, is 2. Checking only the low byte
    // would pass a firmware that sent 1 slot; checking only the page count
    // would pass one that sent 511 of each page. The wire count above is the
    // real evidence and these two are the firmware agreeing with it.
    check(dut.dmem[3] == 1,
          $sformatf("the firmware's slot count is 513 = 0x201, so its low byte is 1 (got %0d)",
                    dut.dmem[3]));
    check(dut.dmem[9] == 2,
          $sformatf("the firmware finished 2 pages of 256 data slots (got %0d)",
                    dut.dmem[9]));
    check(dut.dmem[10] == 8'hA5,
          $sformatf("the firmware finished (got %02h)", dut.dmem[10]));
    $display("    dmem: slots_low=%0d pages=%0d finished=%02h",
             dut.dmem[3], dut.dmem[9], dut.dmem[10]);

    $display("");
    if (errors == 0) $display("PASS: tb_pe_soc_dmx512");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    // 26 ms of frame plus settling, and then some: the watchdog is not a
    // substitute for a correctly derived drain window, it is the backstop for
    // a hang.
    #30_000_000;
    $display("FAIL: watchdog -- the test did not complete");
    $display("  pc=%0d slots measured=%0d", dbg_pc, n_meas);
    $finish;
  end

endmodule
