// tb_pe_soc_ir_nec.v — a NEC infrared remote frame, emitted by firmware and
// decoded by a receiver modelled on the pin.
//
// WHAT THIS PROVES, AND WHY IT IS THE HARDEST OF THE TIMING ACTS.
//
// Every other act here drives a wire. The WS2812 cell is a fixed 800 ns on a
// line the receiver samples, the DHT11's windows are 45 us of LEVEL, the
// DS18B20's read slot is a level held across a window — in all three the
// receiver decides by LEVEL and resynchronises to the sender's own edges, so a
// program one clock out still reaches a real part.
//
// There is no wire here. The only thing that leaves the pin is LIGHT, and a
// NEC receiver has to FIND a 38 kHz burst, integrate it, and time the silences
// between bursts to know whether a bit was a zero or a one. The unit of
// correctness is the carrier period, and nothing in the design resynchronises
// to anything: get the carrier out by a per cent and the frame does not arrive
// at all. That is why this act's headline number is measured on the pin clock
// by clock rather than inside a datasheet window.
//
// THE MODEL, and why its input is not the wire.
//
//   The LED's cathode is on the pin, so the LED emits when the pin SINKS. The
//   receiver's input is therefore the pad driven low — NOT ow_line, which the
//   SoC's own pull-up inverts and which would read a burst as a gap. The
//   1-Wire act in this repository does the opposite and is right there: on
//   1-Wire the high level belongs to the pull-up, so the line is the signal.
//   Here it belongs to the supply. "One line, one wire" is not the same as
//   "one signal": the level that carries the protocol is decided by which end
//   owns the high level, and getting that backwards inverts the whole frame.
//
//   What the receiver sees is a train of emission pulses about 13 us long
//   separated by about 13 us of nothing. A BURST is a run of those; a GAP is a
//   silence long enough to have ended one. The recorder has no notion of a
//   burst, a frame or the protocol — it measures pulse widths, and everything
//   above that is reconstructed afterwards, in the checking block, from the
//   widths. A model that knew the firmware's structure could not detect the
//   firmware having the structure wrong.
//
// THE CHECKS, and how each could be unfalsified:
//
//   1. THE CARRIER, MEASURED ON THE PIN, HALF PERIOD BY HALF PERIOD. Every
//      emission pulse and every inter-pulse silence is timed, and the two
//      distributions are reported and checked SEPARATELY, and each must be
//      constant to WITHIN ONE CLOCK. A single window would forgive the defect
//      this act most needed to catch: two half periods that differ, which is a
//      carrier alternating 37.9/38.1 kHz and a program a fraction of a clock
//      out on every other edge.
//   2. THE LEADER: a burst of at least 300 carrier cycles (9 ms) followed by a
//      silence of 3.6-5.6 ms. A frame with no leader is not decodable by any
//      NEC receiver, and one too short never arms it.
//   3. EVERY DATA BURST: 0.5625 ms inside the datasheet's tolerance, built
//      from the SAME number of carrier cycles as every other data burst. The
//      count is checked as well as the width, because a burst that is the
//      right width for the wrong reason is one that a slightly different
//      firmware would get wrong.
//   4. EVERY GAP: 1.6875 ms for a zero, 0.5625 ms for a one. THE GAP IS THE
//      BIT — a NEC frame carries no other information — so a firmware that
//      sent the same gap for both would produce a well-formed frame carrying
//      nothing, and this is the check that sees it.
//   5. THE DECODE, LSB FIRST, from the widths: eight bits reassembled into a
//      byte and compared with what the program was asked to send (dmem[0],
//      which the program never modifies). The payload is 0xA5, whose bit
//      reverse (0xA5) and complement (0x5A) are both different from it, so a
//      wrong bit order cannot produce it by accident.
//   6. THE STOP BURST: a final burst of the same width, after the eighth gap.
//      It is the part a "send the byte" firmware leaves out, and its absence
//      is invisible in the eight data bits.
//   7. NON-VACUITY: the frame must contain a long gap AND a short one, and the
//      payload both bit values, so a receiver that had collapsed the two could
//      not be described as having decoded it.
//
// THE COST: 32.06 ms of 60 MHz — 9 ms of leader, 4.5 ms of gap, eight slots of
// 2.25 ms, a stop burst — which is 1.92 M clocks. That is the same class as
// the servo (52.5 ms) and DHT11 (22 ms) acts, and for the same reason: the unit
// of correctness is the millisecond, so the millisecond has to be simulated.
// The frame is ONE byte, not the address-and-command pair a real remote sends,
// and the $dumpvars is a narrow signal set, because on the long acts in this
// repository the waveform was the bottleneck, not the design.
//
// Program: firmware/nec_ir.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree.
`ifndef NEC_HEX
  `define NEC_HEX "../firmware/nec_ir.hex"
`endif

module tb_pe_soc_ir_nec;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;
  localparam real CYC_US = 1e6 / CLK_HZ;

  localparam int DATA_BIT = 6;

  localparam logic [7:0] PAYLOAD = 8'hA5;

  // The frame's structure, and the windows it is checked against. The NEC
  // timings are nominal and a receiver's acceptance is a fraction of a
  // millisecond either way, so these are stated rather than assumed: a
  // testbench that checked a 0.5625 ms burst against a 1 ms window would pass
  // a program that sent twice as long as the protocol says.
  localparam int  LEADER_MIN_CYC = 300;      // carrier cycles in the leader
  localparam real LEADER_LO_US    = 8100.0;   // 9 ms - 10 %
  localparam real LEADER_HI_US    = 9900.0;
  localparam real LEADERGAP_LO_US = 3600.0;   // 4.5 ms - 20 %
  localparam real LEADERGAP_HI_US = 5600.0;   // 4.5 ms + 25 %
  // The burst window is +/- 5 %, and the reason it is not +/- 10 % is worth
  // stating because the mutation gate found it. A burst is a WHOLE number of
  // carrier cycles -- 562.5 us of 26.317 us is 21.37, so 21 gives 552.7 us
  // (-1.7 %) and 22 gives 579.0 us (+2.9 %) -- and the next value down, 20
  // cycles, is 526.3 us, or -6.4 %. A +/- 10 % window accepts all three, so a
  // program emitting a 6 % short burst passed. +/- 5 % accepts the two
  // available widths and rejects the third.
  localparam real BURST_LO_US     = 534.0;    // 0.5625 ms - 5 %
  localparam real BURST_HI_US     = 591.0;    // 0.5625 ms + 5 %
  localparam real GAP0_LO_US      = 1518.0;   // 1687.5 us - 10 %
  localparam real GAP0_HI_US      = 1856.0;
  localparam real GAP1_LO_US      = 506.0;    // 562.5 us - 10 %
  localparam real GAP1_HI_US      = 619.0;
  localparam real HALF_LO_US      = 12.5;     // 13.1667 us - 5 %
  localparam real HALF_HI_US      = 13.9;     // 13.1667 us + 5 %

  // A pulse is a carrier half period if it is inside this window; a silence
  // longer than PULSE_HI_US is a gap. The two are far enough apart that
  // nothing in a correct frame can be ambiguous, and the TB prints the actual
  // extremes so a wrong constant shows up as a number and not as a mystery.
  localparam real PULSE_HI_US = 30.0;

  // EVERY WIDTH IN THIS FILE IS IN TENTHS OF A NANOSECOND, and the unit is
  // stated here because it is the one that matters. $time is scaled to the
  // module's timeunit (1 ns here) and returns an integer, so timing a 13.1667
  // us half period with it quantises to 1 ns -- 0.06 clocks -- and the
  // carrier appeared to jitter. $realtime is the same unit as a real, so
  // multiplying by ten and rounding gives 0.1 ns, which is 0.006 clocks: a
  // thousandth of what "constant to within a clock" is asking about. A
  // measuring instrument with 0.4 % quantisation cannot support a 0.06 %
  // claim, and this act's claim is 0.06 %.
  localparam longint CLK_U       = 167;         // 16.667 ns, rounded up
  localparam longint HALF_LO_U   = 125000;      // 12.5 us
  localparam longint HALF_HI_U   = 139000;      // 13.9 us
  localparam longint PULSE_HI_U  = 300000;      // 30 us

  localparam int MAX_PULSES = 4096;          // ~1700 in a correct frame
  localparam int MAX_BURSTS = 32;

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // The LED's current: it is ON when the SoC's pad sinks. THIS is the
  // receiver's input, and it is not ow_line -- see the header.
  wire led_on = pin_oe_bus[DATA_BIT] & ~pin_out_bus[DATA_BIT];
  assign pin_in_bus = {1'b1, 1'b1, led_on, 6'b111111};

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

  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  // Icarus has no abs(), and a helper is better than the nested ternary
  // twice: a difference of two measured widths that comes out negative is a
  // normal outcome here, and reading it as a negative would silently pass a
  // check that meant "no more than this far apart".
  function integer iabs(input integer v);
    iabs = (v < 0) ? -v : v;
  endfunction

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  integer i, j, k, k2;
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh(`NEC_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- THE RECEIVER: one edge-triggered recorder, widths only -----------
  //
  // Nothing here knows what a burst is. It times how long the LED stayed on,
  // and that is all. The bursts and the gaps are reconstructed afterwards, in
  // one pass, in the checking block -- which is why this process holds no
  // timing state and cannot disagree with the reconstruction.
  //
  // The recorder is edge-triggered on $realtime rather than per-clock with a
  // counter, worth about 40 % of the run time: at 38 kHz a frame has ~1700
  // edges and a per-clock recorder would be 60 000 times the work. It is the
  // same choice the WS2812 act made, for the same reason, and the one process
  // keeps it away from the cycle counter, which is the defect that act found
  // in its own testbench.
  //
  // THE WIDTHS ARE REALS IN NANOSECONDS, and that is not tidiness. A clock is
  // 16.667 ns and the edges land on a 1 ns grid, so storing a width as an
  // integer number of CLOCKS truncates by up to one clock in a direction that
  // depends on where the edge fell in the grid -- and the result was a carrier
  // that appeared to alternate 787/788/789 clocks every sixteen cycles. The
  // firmware was exact; the measuring instrument was not. This is the same
  // lesson as the two-always-blocks race the WS2812 act found, one layer up:
  // a defect in the measuring instrument is worse than a defect in the thing
  // measured, because it invents a defect that is not there.
  longint n_pulse = 0;
  longint p_start [0:MAX_PULSES-1];
  longint p_len   [0:MAX_PULSES-1];
  longint p_rise  = -1;
  longint t_now;

  always @(led_on) if (run && rst_n) begin
    if (led_on) begin
      if (p_rise < 0) p_rise = $rtoi($realtime * 10.0);
    end else if (p_rise >= 0) begin
      t_now = $rtoi($realtime * 10.0);
      if (n_pulse < MAX_PULSES) begin
        p_start[n_pulse] = p_rise;
        p_len[n_pulse]   = t_now - p_rise;
        n_pulse = n_pulse + 1;
      end
      p_rise = -1;
    end
  end

  // ---- the reconstruction, and the measurements -------------------------
  integer nb = 0; bit b_is_start;
  longint sil, j_sil;
  integer b_first[0:MAX_BURSTS-1];  // the index of its first pulse
  integer b_cyc [0:MAX_BURSTS-1];   // carrier cycles in it
  integer b_len_us [0:MAX_BURSTS-1]; // its width, in microseconds
  integer b_gap_us [0:MAX_BURSTS-1]; // the silence AFTER it, in us, -1 at the end

  // The half periods, in picoseconds. Icarus cannot hold a real ARRAY, and a
  // real scalar is not enough: the exception budget below is a SECOND pass
  // over every half period, which needs them all. Picoseconds is fine on a
  // 64-bit integer for a 35 ms frame (3.5e10) and is 60 000 times finer than
  // the clock being measured.
  longint half_lo_min, half_lo_max, half_hi_min, half_hi_max;
  longint half_lo_raw [0:MAX_PULSES-1];
  longint half_hi_raw [0:MAX_PULSES-1];
  integer n_half, n_sil;
  integer n_long_gap = 0, n_short_gap = 0, n_gapbad = 0, n_burstbad = 0;
  integer n_ex_lo = 0, n_ex_hi = 0;
  integer bitcyc0 = -1, cycmismatch = 0;
  logic [7:0] rx_byte;
  logic [7:0] fw_byte;
  real carrier_hz, leader_us;

  initial begin
    $dumpfile("tb_pe_soc_ir_nec.vcd");
    $dumpvars(0, led_on, pin_out_bus, pin_oe_bus, dbg_pc, dbg_timer);

    n_pulse = 0; p_rise = -1; nb = 0; n_half = 0; n_sil = 0; n_ex_lo = 0; n_ex_hi = 0;
    half_lo_min = 64'sh7fff_ffff_ffff_ffff; half_lo_max = 0;
    half_hi_min = 64'sh7fff_ffff_ffff_ffff; half_hi_max = 0;
    rx_byte = 8'h00;

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== NEC infrared: 38 kHz carrier, 9 ms leader, %02h LSB first ===\n", PAYLOAD);
    run = 1'b1;
    repeat (2_100_000) @(posedge clk);   // 35 ms: the whole frame, with room

    // ---- reconstruct the bursts and gaps, from the widths alone ----------
    //
    // Two passes, and the second one only sums over indices the first one
    // already decided. The obvious single pass -- keep a running cycle count
    // and close the burst when a long silence turns up -- was wrong in a way
    // that reported every burst as 22 carrier cycles long while measuring
    // their widths correctly, which is not a combination of numbers any
    // waveform has: two of the three measurements were being taken of
    // different things. Doing it as "which pulse starts each burst" and then
    // "where does each burst end" removes the accumulator that was wrong.
    //
    // A silence longer than PULSE_HI_US is the gap that ENDS a burst. The last
    // burst has no gap after it -- that is the stop burst, and the frame ends
    // there.
    nb = 0;
    for (k = 0; k < n_pulse; k = k + 1) begin
      if (k == 0) b_is_start = 1;
      else begin
        sil = p_start[k] - (p_start[k-1] + p_len[k-1]);
        b_is_start = (sil > PULSE_HI_U);
      end
      if (b_is_start) begin
        b_first[nb] = k;
        nb = nb + 1;
      end
    end
    for (i = 0; i < nb; i = i + 1) begin
      k2 = (i + 1 < nb) ? b_first[i+1] - 1 : n_pulse - 1;
      b_cyc[i] = k2 - b_first[i] + 1;
      b_len_us[i] = ((p_start[k2] + p_len[k2]) - p_start[b_first[i]]) / 10000;
      b_gap_us[i] = (i + 1 < nb)
                 ? (p_start[b_first[i+1]] - (p_start[k2] + p_len[k2])) / 10000
                 : -1;
    end

    // ---- 1. THE CARRIER, both half periods, measured separately ----------
    //
    // Measured over the pulses that are INSIDE a burst, so the initiation
    // pulse of each burst and the gap that ends it are excluded: neither is a
    // carrier half period, and including them would make a correct program
    // look like it has 6-clock outliers. A pulse counts as a half period only
    // if the silence on BOTH sides of it is short, which is the same statement
    // a real receiver makes and for the same reason.
    for (k = 0; k < n_pulse; k = k + 1) begin
      sil = (k == 0) ? 64'sh7fff_ffff_ffff_ffff : p_start[k] - (p_start[k-1] + p_len[k-1]);
      j   = (k + 1 >= n_pulse) ? 64'sh7fff_ffff_ffff_ffff : p_start[k+1] - (p_start[k] + p_len[k]);
      if (p_len[k] >= HALF_LO_U && p_len[k] <= HALF_HI_U
          && sil >= CLK_U && sil <= PULSE_HI_U
          && j >= CLK_U && j <= PULSE_HI_U) begin
        if (p_len[k] < half_lo_min) half_lo_min = p_len[k];
        if (p_len[k] > half_lo_max) half_lo_max = p_len[k];
        n_half = n_half + 1;
        if (j < half_hi_min) half_hi_min = j;
        if (j > half_hi_max) half_hi_max = j;
        n_sil = n_sil + 1;
        half_lo_raw[n_half-1] = p_len[k];
        half_hi_raw[n_half-1] = j;
      end
    end
    // the exception budget, once the shortest half period of each kind is known
    for (k = 0; k < n_half; k = k + 1) begin
      if (half_lo_raw[k] > half_lo_min + CLK_U) n_ex_lo = n_ex_lo + 1;
      if (half_hi_raw[k] > half_hi_min + CLK_U) n_ex_hi = n_ex_hi + 1;
    end
    carrier_hz = 1.0e10 / (half_lo_min + half_hi_min);  // 0.1 ns units -> Hz
    $display("    carrier: LOW half %.3f-%.3f us (%.2f-%.2f clocks), HIGH half %.3f-%.3f us (%.2f-%.2f clocks)",
             half_lo_min/1e4, half_lo_max/1e4, half_lo_min/166.67, half_lo_max/166.67,
             half_hi_min/1e4, half_hi_max/1e4, half_hi_min/166.67, half_hi_max/166.67);
    $display("    carrier frequency off the pin: %.0f Hz (nominal 38000, %+.3f %%)",
             carrier_hz, 100.0 * (carrier_hz - 38000.0) / 38000.0);
    $display("    half-period spread: %.2f clocks LOW, %.2f clocks HIGH, over %0d pulses",
             (half_lo_max-half_lo_min)/166.67, (half_hi_max-half_hi_min)/166.67, n_half);
    check(n_half > 100,
          $sformatf("the frame carries a 38 kHz carrier (%0d half periods inside bursts)", n_half));
    check(half_lo_min >= HALF_LO_U && half_lo_max <= HALF_HI_U,
          $sformatf("every LOW half period is inside %.1f-%.1f us -- got %.3f-%.3f us",
                    HALF_LO_US, HALF_HI_US, half_lo_min/1e4, half_lo_max/1e4));
    check(half_hi_min >= HALF_LO_U && half_hi_max <= HALF_HI_U,
          $sformatf("every HIGH half period is inside %.1f-%.1f us -- got %.3f-%.3f us",
                    HALF_LO_US, HALF_HI_US, half_hi_min/1e4, half_hi_max/1e4));
    //
    // "Constant to within a clock" is counted as an EXCEPTION BUDGET rather
    // than a spread, because the leader is counted in two runs (its 342 cycles
    // do not fit in an eight-bit immediate) and the counter reload costs nine
    // instructions, which lands on exactly one half period in the whole frame.
    // A spread check with no budget fails on that, and the honest way to write
    // it is "every half period is inside the carrier window, and at most two
    // of them -- the leader's single counter reload -- sit outside a one-clock
    // band around the frame's shortest one". A program with an alternating
    // carrier, or one that simply got the carrier wrong, is thousands of
    // exceptions rather than two.
    check(n_ex_lo <= 2,
          $sformatf("at most 2 of the LOW half periods sit more than a clock above the shortest (the leader's one counter reload) -- there are %0d",
                    n_ex_lo));
    //
    // THE CHECK THAT WAS MISSING, and the act's whole point. The two
    // distributions can each be perfectly constant and still not be EQUAL: a
    // mutation that put both half periods on the same delay pair produced a
    // carrier of 788 clocks one way and 782 the other -- 38.05 kHz against
    // 37.88, an asymmetry of 0.4 % on every single edge, inside every
    // frequency window a real receiver has, and invisible to "each half is
    // constant". A receiver does not care that the carrier is on frequency; it
    // cares that the carrier is a carrier, and a carrier whose two halves
    // differ is a square wave at 38 kHz with a duty cycle that is not 50 %.
    check(iabs(half_lo_min - half_hi_min) <= CLK_U,
          $sformatf("the two half periods are EQUAL to within a clock (LOW %.2f, HIGH %.2f clocks) -- an asymmetric carrier is a square wave with the wrong duty cycle, and it passes every frequency window",
                    half_lo_min/166.67, half_hi_min/166.67));
    check(n_ex_hi <= 2,
          $sformatf("at most 2 of the HIGH half periods sit more than a clock above the shortest -- there are %0d",
                    n_ex_hi));
    check(n_sil == n_half,
          $sformatf("every counted half period has a counted silence after it (%0d of %0d)",
                    n_sil, n_half));

    // ---- 2-4. bursts and gaps -------------------------------------------
    $display("    pulses %0d -> bursts %0d (leader, 8 data bits, stop)", n_pulse, nb);
    check(nb == 10,
          $sformatf("the frame is a leader, eight data bursts and a stop (%0d bursts)", nb));

    // the leader
    if (nb >= 1) begin
      leader_us = b_len_us[0];
      $display("    leader: %.1f us in %0d carrier cycles, then %.1f us of silence",
               leader_us, b_cyc[0], b_gap_us[0]);
      check(b_cyc[0] >= LEADER_MIN_CYC,
            $sformatf("the leader burst is at least %0d carrier cycles (%0d)",
                      LEADER_MIN_CYC, b_cyc[0]));
      check(leader_us >= LEADER_LO_US && leader_us <= LEADER_HI_US,
            $sformatf("the leader burst is inside %.0f-%.0f us -- got %.1f us",
                      LEADER_LO_US, LEADER_HI_US, leader_us));
      check(b_gap_us[0] >= LEADERGAP_LO_US && b_gap_us[0] <= LEADERGAP_HI_US,
            $sformatf("the leader is followed by %.1f-%.1f us of silence -- got %.1f us",
                      LEADERGAP_LO_US, LEADERGAP_HI_US, b_gap_us[0]));
    end

    // the eight data bursts: same width, same carrier-cycle count
    for (k = 1; k < nb && k <= 8; k = k + 1) begin
      if (b_len_us[k] < BURST_LO_US || b_len_us[k] > BURST_HI_US) begin
        n_burstbad = n_burstbad + 1;
        if (n_burstbad == 1)
          $display("    data burst %0d: %.1f us in %0d cycles (want %.0f-%.0f us)",
                   k, b_len_us[k], b_cyc[k], BURST_LO_US, BURST_HI_US);
      end
      if (bitcyc0 < 0) bitcyc0 = b_cyc[k];
      else if (b_cyc[k] != bitcyc0) begin
        cycmismatch = cycmismatch + 1;
        $display("    data burst %0d used %0d carrier cycles, the first used %0d",
                 k, b_cyc[k], bitcyc0);
      end
    end
    check(nb >= 9 && n_burstbad == 0,
          $sformatf("every data burst is inside %.0f-%.0f us (%0d are not)",
                    BURST_LO_US, BURST_HI_US, n_burstbad));
    check(cycmismatch == 0,
          "every data burst is built from the same number of carrier cycles");
    // A "whole number of carrier cycles" check was written here and removed,
    // and the reason is worth keeping. The idea is right -- a burst is a
    // transmitter switching on and off on a carrier boundary -- but the burst
    // OPENS with a two-instruction initiation pulse before the carrier starts,
    // so the span from the first pulse to the last is the initiation plus
    // N-1 periods plus one half period, not N periods. Every burst measured
    // 26 us (one whole cycle) away from the multiple it should have been, and
    // the check fired on all ten of them including the correct ones. A check
    // that is wrong about the thing it is measuring is worse than no check:
    // the first thing anyone would do is loosen the tolerance until it went
    // away. The window above is ±5 %, which admits the two widths a whole
    // number of cycles can produce (21 cycles = -1.7 %, 22 = +2.9 %) and
    // rejects the next one down at -6.4 %.
    check(bitcyc0 >= 8,
          $sformatf("a data burst is real carrier, not one pulse (%0d cycles)", bitcyc0));

    // the gaps: THE BIT. A long silence is a zero, a short one is a one.
    for (k = 1; k < nb && k <= 8; k = k + 1) begin
      sil = b_gap_us[k];
      if (sil >= GAP0_LO_US && sil <= GAP0_HI_US) begin
        n_long_gap = n_long_gap + 1;                       // a zero
      end else if (sil >= GAP1_LO_US && sil <= GAP1_HI_US) begin
        rx_byte[k-1] = 1'b1;                             // a one
        n_short_gap = n_short_gap + 1;
      end else begin
        n_gapbad = n_gapbad + 1;
        $display("    gap after bit %0d is %.1f us, which is neither a zero's nor a one's",
                 k - 1, sil);
      end
    end
    $display("    gaps: %0d long (a zero) and %0d short (a one)", n_long_gap, n_short_gap);
    $display("    decoded off the pin: %02h   firmware dmem[0]: %02h", rx_byte, dut.dmem[0]);
    check(n_gapbad == 0,
          $sformatf("every gap is a zero's or a one's (%0d are neither)", n_gapbad));
    check(n_long_gap > 0 && n_short_gap > 0,
          $sformatf("the frame contains BOTH gap lengths -- %0d long, %0d short, so a receiver that collapsed them could not be described as decoding it",
                    n_long_gap, n_short_gap));
    check(dut.dmem[0] == PAYLOAD,
          $sformatf("the program was asked to send %02h (dmem[0] = %02h)", PAYLOAD, dut.dmem[0]));
    check(rx_byte == PAYLOAD,
          $sformatf("the frame decoded LSB first to %02h (got %02h)", PAYLOAD, rx_byte));
    check(dut.dmem[14] == 8'h01,
          $sformatf("the firmware reached the end of the frame (dmem[14] = %02h)", dut.dmem[14]));

    // ---- 6. the stop burst: present, and the right width ---------------
    if (nb >= 10) begin
      $display("    stop burst: %.1f us in %0d carrier cycles",
               b_len_us[9], b_cyc[9]);
      check(b_gap_us[9] == -1,
            "the frame ENDS on the stop burst, with no gap after it");
      check(b_len_us[9] >= BURST_LO_US && b_len_us[9] <= BURST_HI_US,
            $sformatf("the stop burst is inside %.0f-%.0f us -- got %.1f us",
                      BURST_LO_US, BURST_HI_US, b_len_us[9]));
      check(b_cyc[9] == bitcyc0,
            "the stop burst is built from the same carrier-cycle count as a data burst");
    end

    // ---- 7. non-vacuity on the payload itself ---------------------------
    j = 0;
    for (i = 0; i < 7; i = i + 1) if ((PAYLOAD>>i & 1) != (PAYLOAD>>(i+1) & 1)) j = j + 1;
    $display("    payload bit-transitions: %0d of 7", j);
    check(j >= 3,
          $sformatf("the payload has enough transitions to catch a repeated-bit fault (%0d of 7)", j));
    check((PAYLOAD & 8'h0F) != 0 && (PAYLOAD & 8'h0F) != 8'h0F,
          "the payload has both bit values in its low nibble");

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    #45_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
