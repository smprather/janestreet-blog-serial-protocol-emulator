// tb_pe_soc_bmc.v -- FM0/FM1 bi-phase coding, ENCODE AND DECODE through the
// pins in loopback. RED: there is no firmware yet.
//
// WHAT THIS ACT IS, and why it is not a seventh timing act. Every other act in
// this block is judged on a waveform a receiver can decode. This one is judged
// on a RECEIVER: the code lives in the TRANSITIONS, not in the levels, and the
// only clock in the system is the one the receiver recovers from the data.
// So the claim is not "the firmware drives a bi-phase stream" but "the
// firmware RECOVERS THE CLOCK from a stream it shares no clock with, and says
// which encoding it locked onto".
//
// THE WIRE RULES, from which everything here is written:
//   * a bit is TWO half-intervals;
//   * a '1' has NO transition at the END of its interval, in both encodings;
//   * a '0' HAS a transition at the end, in both encodings;
//   * FM0 adds a transition at the START of the interval for a '1'; FM1 does
//     not -- which is the ONLY difference between the two encodings.
// CONSEQUENCE ONE, and it is the best check in the file: EVERY bit of a
// well-formed frame carries a transition in its middle, because "bi-phase"
// means the level changes WITHIN the interval. So a line held CONSTANT --
// which is what a disconnected, shorted or dead sensor looks like on the
// wire -- has no transitions at all and carries no clock, and a receiver that
// locks on to it has locked on to nothing. THAT is the stream the last check
// presents, and the firmware's answer to it must be a DECLARED FAILURE rather
// than a byte it invented: a decoder that cannot fail is not a decoder.
//
// (THE FIRST VERSION OF THIS FILE CLAIMED THAT A RUN OF ONES IN FM1 WAS THAT
// STREAM. IT IS NOT. A run of ones is a clean square wave -- one transition
// per bit, in the middle -- and the decoder recovers its clock from exactly
// those transitions. The claim was in this header, in the encoder below and in
// two WORKLOG lines, and it was wrong in all four. It was the instrument that
// was wrong, which is the pattern this whole block exists to demonstrate, and
// the reason the act was written with two decoders from the wire rules rather
// than one decoder and one encoder that agree by construction.)
//
// CONSEQUENCE TWO, which is why the bit period is a whole number of
// microseconds: the receiver timestamps the level on the 1 us counter and
// compares it with the level recorded at the last CHANGE, and that comparison
// is only exact if every transition lands on a tick. A bit period that is not
// a multiple of the counter's unit would make the decoder's own arithmetic
// the least accurate thing in the act.
//
// BOTH DIRECTIONS, and NEITHER SIDE IS TOLD WHAT THE OTHER SENT: the
// testbench encodes a byte on IN_PAD and the firmware must recover it; the
// firmware encodes on OUT_PAD and the testbench's decoder, written from the
// same wire rules above rather than from the firmware, must recover it.
//
// THE LIMITS, stated rather than buried: three bytes per direction, because
// the machine has SIXTEEN BYTES of data memory and a receiver's state -- the
// transition timestamp, the previous level, the bit counter, the phase flag and
// the frame being assembled -- is most of that, and a scratch byte for the
// store-forward the ISA cannot express is most of the rest (see
// firmware/../WORKLOG.md, 13:20). One inter-frame gap, and no noise, no
// jitter and no line-length limit: those are the things a real receiver's
// worst case lives in, and pretending otherwise would be claiming a
// robustness this act does not test.

`timescale 1ns / 1ps

`ifndef BMC_HEX
  `define BMC_HEX "../firmware/bmc_frame.hex"
`endif

module tb_pe_soc_bmc;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;
  localparam real CLK_NS = 1e9 / 60_000_000;

  localparam int IN_BIT  = 5;        // the testbench drives this one
  localparam int OUT_BIT = 6;        // the firmware drives this one
  // THE HALF-INTERVAL IS COUNTED IN CLOCKS, AND THE MICROSECOND FIGURE IS
  // DERIVED FROM IT. This was declared as 2 and commented "in whole
  // microseconds", and then compared against a counter that increments once
  // per CLOCK -- so the stimulus drove a half-interval every two or three
  // clocks, about 40 ns, while the firmware under test emits 120 clocks = 2 us.
  // A constant asserted in one domain and consumed in another is this block's
  // recurring defect, and the point of deriving the figure is being unable to
  // write the mistake rather than having written it once.
  localparam int HALF_CLOCKS = 120;  // 2 us at 60 MHz, and the firmware's own
                                     // figure: it counts half-intervals on
                                     // I2CTICK, the free-running 1 us counter,
                                     // so a 2 us half-interval is 120 clocks
  localparam real HALF_US = HALF_CLOCKS * CLK_NS / 1000.0;   // derived, not asserted
  localparam int NBITS   = 24;       // three bytes
  localparam int TOL_US  = 1;        // the counter's own quantisation

  // The firmware's map, named because this file READS those bytes: dmem[0..2]
  // is the three bytes the firmware recovered from the input pad, dmem[3] is
  // the encoding flag (0 = FM0, 1 = FM1, 0xFF = "this stream had no
  // transitions and I am not going to invent a byte for it"), and dmem[6] is
  // the byte the firmware ENCODED, for this testbench's decoder to recover.
  localparam int F_RX   = 0;
  localparam int F_FLAG = 3;
  localparam int F_TX   = 6;

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;
  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  logic in_line = 1'b1;             // idle high
  // THE STIMULUS GOES ON IN_BIT, AND IT IS PLACED THERE *BY* IN_BIT. It was
  // not: the bus was built as {1'b1, in_line, 1'b0, 5'b11111}, which puts
  // in_line on bit 6 and hardwires bit 5 to ZERO. Bit 5 is IN_BIT and
  // BMC_IN, the bit firmware/bmc_frame.pe reads; bit 6 is OUT_BIT, the bit the
  // firmware encodes onto. So the stream was being driven into the chip's own
  // output pad while the firmware sampled a constant, and the firmware's
  // correctly-written `AND A, BMC_IN` could never see a transition however the
  // stimulus moved. IN_BIT was declared at the top of this file and used NOWHERE
  // else, which is why nothing complained: a constant that is asserted in one
  // place and consumed in another, and this block now has six of them.
  //
  // The base is 8'h9F: bit 7 high as before, bits 4..0 high, and BOTH bit 5 and
  // bit 6 low so the stimulus cannot drive the pad the firmware drives. The
  // stream is then OR'd in through IN_MASK, which is derived from IN_BIT, so
  // the two cannot drift apart again -- the failure mode was a literal in a
  // concatenation disagreeing with a constant three declarations away.
  localparam logic [7:0] IN_MASK = 8'h01 << IN_BIT;
  assign pin_in_bus = 8'h9F | (in_line ? IN_MASK : 8'h00);

  wire out_line = pin_out_bus[OUT_BIT];
  wire out_oe   = pin_oe_bus[OUT_BIT];

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
    $readmemh(`BMC_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0]; host_wdata = prog[i];
    end
    @(posedge clk); #1; host_we = 1'b0;
  endtask

  // ---- THE TESTBENCH'S ENCODER, from the wire rules ---------------------
  integer enc_byte [0:2];
  integer enc_fm0 = 1;               // 1 = FM0, 0 = FM1
  integer enc_idx = 0, enc_bit = 0, enc_half = 0;
  logic   enc_active = 0;

  function automatic bit enc_bitval(input integer b);
    enc_bitval = (b == 0) ? 1'b0 : 1'b1;              // LSB first
  endfunction

  // THE LEVEL IN A GIVEN HALF-INTERVAL, from the wire rules in the header of
  // firmware/bmc_frame.pe. `carry` is the level at the END of the previous bit,
  // which is the same thing as the level at the START of this one -- that is
  // what makes the encoding STATEFUL, and it is why the old version could not
  // express it at all.
  //
  // THE THREE CASES, and each is one line of the rule:
  //   a '0'  : h0 = carry,   h1 = ~carry   -> a transition in the MIDDLE
  //   a '1', FM1 : h0 = ~carry, h1 = ~carry -> a transition at the START only
  //   a '1', FM0 : h0 = carry,   h1 = carry -> NO TRANSITION AT ALL
  //
  // AND THAT PRODUCES THE TWO BEHAVIOURS THE SPEC NOW PROMISES, which is the
  // check rather than the claim: a run of ones under FM0 is a CONSTANT LINE
  // (h0 and h1 are both `carry`, and `carry` is unchanged from bit to bit), and
  // under FM1 it is a CLEAN SQUARE WAVE with a transition at every boundary
  // (h0 flips against the previous h1, and h1 == h0, so nothing happens inside
  // the bit). A '0' is the only case that transitions in the middle -- which is
  // the manager's confirmed reading, and it is what puts the DATA in the
  // POSITION of the transition and the CLOCK in the fixed interval between
  // them.
  //
  // fm0 IS READ IN THE BODY, which is the whole point: the previous version
  // declared this parameter and never used it, so FM0 and FM1 encoded to the
  // identical stream and the act's own headline check could not be run at all.
  // THE PARENTHESES ARE NOT DECORATION: `return a ? b : c` parses as
  // `return (a) ? b : c` and Icarus will not have it.
  function automatic bit enc_level(input integer b, input integer half,
                                   input integer fm0, input bit carry);
    bit data_one;
    bit h0;
    data_one = enc_bitval(b);
    h0 = data_one ? (fm0 ? carry : ~carry) : carry;
    if (half == 0) return h0;
    else           return (data_one ? h0 : ~h0);
  endfunction

  // ---- THE ENCODER CHECKS ITSELF AGAINST THE PROMISED PROPERTIES ----------
  //
  // The act's headline claim is that the two encodings are DIFFERENT and that
  // the receiver can say which one it locked onto. Until now nothing in this
  // file tested that, because the encoder could not express the difference --
  // it declared an fm0 argument and never read it. These four checks are the
  // ones that would have caught it, and they are here rather than in a review
  // because a property nobody checks is a claim, not a rule.
  //
  // They are written against the SPEC, not against the implementation: a run of
  // ones is a constant line under FM0 and a square wave under FM1, and the two
  // encodings of one frame must not be the same stream.
  integer enc_fail = 0, ei, eh, ediff, econst0, econst1;
  bit   ec0, ec1, el0, el1, ecarry;
  bit   s_fm0 [0:15];
  bit   s_fm1 [0:15];
  task automatic enc_chk(input bit c, input string m);
    if (!c) begin $display("FAIL(encoder): %s", m); enc_fail++; end
  endtask
  initial begin
    // (1) A RUN OF ONES UNDER FM0 IS A CONSTANT LINE. Eight 1s, the level held
    //     from the first half of the first bit to the second half of the last.
    ecarry = 1'b1; econst0 = 1;
    for (ei = 0; ei < 8; ei = ei + 1)
      for (eh = 0; eh < 2; eh = eh + 1) begin
        el0 = enc_level(7, eh, 1, ecarry);          // 7 -> data_one = 1
        if (el0 !== ecarry) econst0 = 0;
        ecarry = el0;
      end
    enc_chk(econst0,
            "a run of ones under FM0 is a CONSTANT LINE -- the spec's promise, and the reason a preamble is needed");

    // (2) A RUN OF ONES UNDER FM1 IS A CLEAN SQUARE WAVE: a transition at every
    //     bit boundary, so the level at the start of each bit alternates.
    ecarry = 1'b1; econst1 = 1; el1 = 1'b1;
    for (ei = 0; ei < 8; ei = ei + 1)
      for (eh = 0; eh < 2; eh = eh + 1) begin
        el0 = enc_level(7, eh, 0, ecarry);
        if (eh == 0 && el0 === el1) econst1 = 0;   // boundary must transition
        el1 = el0;
        ecarry = el0;
      end
    enc_chk(econst1,
            "a run of ones under FM1 is a CLEAN SQUARE WAVE with a transition at every boundary");

    // (3) THE TWO ENCODINGS OF ONE FRAME ARE NOT THE SAME STREAM. This is the
    //     check the act exists to support, and the one the old encoder made
    //     impossible: it returned the complement of the data on the first half
    //     and the data on the second, for both encodings alike.
    //
    //     AND THE FIRST VERSION OF THIS CHECK WAS ITSELF WRONG, in the way
    //     this block keeps producing: it kept ONE variable per encoding,
    //     overwrote it on every half-interval, and compared the two at the
    //     end. That compares the LAST level of each stream and calls it "they
    //     differ" -- and both streams end at 0, so it reported a failure on an
    //     encoder that was correct. A check that compares one value and
    //     describes it as a comparison of streams is the same defect as
    //     `SUB A, 1` read as "subtract one": the code does something
    //     narrower than the sentence claims, and the sentence is what gets
    //     believed. The whole sequence is compared here, all sixteen
    //     half-intervals, because that is what the claim is about.
    ecarry = 1'b1; ediff = 0;
    for (ei = 0; ei < 8; ei = ei + 1) begin
      s_fm0[ei*2]   = enc_level(ei, 0, 1, ecarry); ecarry = s_fm0[ei*2];
      s_fm0[ei*2+1] = enc_level(ei, 1, 1, ecarry); ecarry = s_fm0[ei*2+1];
    end
    ecarry = 1'b1;
    for (ei = 0; ei < 8; ei = ei + 1) begin
      s_fm1[ei*2]   = enc_level(ei, 0, 0, ecarry); ecarry = s_fm1[ei*2];
      s_fm1[ei*2+1] = enc_level(ei, 1, 0, ecarry); ecarry = s_fm1[ei*2+1];
    end
    for (ei = 0; ei < 16; ei = ei + 1)
      if (s_fm0[ei] !== s_fm1[ei]) ediff = ediff + 1;
    enc_chk(ediff > 0,
            $sformatf("FM0 and FM1 encode one frame as DIFFERENT streams (%0d of 16 half-intervals differ) -- if these are the same the flag cannot be measured",
                      ediff));

    // (4) A '0' TRANSITIONS IN ITS MIDDLE, in BOTH encodings -- the confirmed
    //     reading, and the only case that carries data by transition position.
    for (ei = 0; ei < 2; ei = ei + 1) begin
      ecarry = 1'b1;
      el0 = enc_level(0, 0, ei, ecarry);
      el1 = enc_level(0, 1, ecarry ? 0 : 1, ecarry);
      enc_chk(el0 !== el1,
              $sformatf("a '0' transitions in the MIDDLE under %0s (half0 %0b, half1 %0b)",
                        ei ? "FM0" : "FM1", el0, el1));
    end

    if (enc_fail == 0)
      $display("encoder self-check: all 5 properties hold");
  end

  // ---- THE TESTBENCH'S DECODER, also from the wire rules ---------------
  // It timestamps the level and compares with the level at the last CHANGE,
  // which is what recovers the clock; it is NOT told the period it is
  // expected to see, because a receiver that is told its own bit rate is not
  // recovering anything.
  integer  dec_t = 0;                 // the last change, in microseconds
  logic   dec_lev = 1'b1;
  integer  dec_bit = 0, dec_idx = 0, dec_flag = -1;
  integer  dec_bits = 0;
  logic [7:0] dec_byte [0:2];
  integer  dec_have = 0;

  task automatic dec_reset;
    begin
      dec_t = 0; dec_lev = 1'b1; dec_bit = 0; dec_idx = 0; dec_flag = -1;
      dec_bits = 0; dec_have = 0;
      for (int k = 0; k < 3; k++) dec_byte[k] = 8'h00;
    end
  endtask

  // The decoder is FED BY THE PAD and by a microsecond counter, and by
  // nothing else. In particular it is not told the half-interval it should
  // expect: a receiver that is told its own bit rate is not recovering
  // anything, and the whole claim of this act is that the clock comes out of
  // the data. What it does know is that a change of level is a TRANSITION, and
  // how long ago it happened -- so the bit period it measures is the interval
  // between transitions, which for this encoding is one or two half-intervals
  // depending on the data, and that ambiguity is exactly what the encoding
  // flag has to resolve.
  integer  rx_us = 0;                  // CLOCKS since the frame started. The
  integer  dec_gap = 0;                // name says us and the value is not:
                                       // this block fires on posedge clk, so it
                                       // counts clocks, while the firmware
                                       // timestamps on a 1 us tick. Renaming
                                       // it rx_clk is on the list for the same
                                       // reason HALF_CLOCKS exists -- a wrong
                                       // name is how the stimulus came to run
                                       // sixty times too fast.
  integer  dec_prev_gap = 0;
  logic   dec_started = 0;

  always @(posedge clk) if (rst_n) begin
    rx_us <= rx_us + 1;
    // A CHANGE of level is a transition, and the interval since the last one
    // is the length of the run that just ended. Every interval is an even
    // number of half-intervals, so the interval in half-intervals is
    // gap / HALF_CLOCKS -- and the ODD case cannot happen in a valid frame,
    // is what makes "an interval that is not a whole number of half-intervals"
    // a decodable-frame failure rather than a bit value.
    if (out_line !== dec_lev) begin
      dec_gap = rx_us - dec_t;
      dec_prev_gap = dec_gap;
      dec_lev = out_line;
      dec_t = rx_us;
      dec_started = 1;
    end
  end

  // Fold the measured intervals into bits, once per BIT rather than once per
  // transition: in this encoding a bit is two half-intervals, so a bit ends
  // every two half-intervals and a data transition inside a bit is what tells
  // FM0 from FM1.
  integer fold_half = 0;
  always @(posedge clk) if (rst_n && dec_started && dec_gap > 0) begin
    dec_gap = 0;
    fold_half = fold_half + 1;
    if (fold_half == 2) begin
      fold_half = 0;
      if (dec_bit < NBITS) begin
        // A '0' has a transition at the END of its interval, so a transition
        // arriving on the SECOND half-interval boundary is a zero; a '1' has
        // none, and its boundary is silent. The ENCODING is read off the
        // START: FM0 transitions at the start of a one, FM1 does not.
        if (out_line === 1'b0) begin
          dec_byte[dec_idx] = dec_byte[dec_idx] & ~(8'h01 << dec_bit);
          dec_flag = 1;                    // the boundary was a data edge
        end else begin
          dec_byte[dec_idx] = dec_byte[dec_idx] | (8'h01 << dec_bit);
        end
        dec_bit = dec_bit + 1;
        if (dec_bit == 8) begin
          dec_bit = 0;
          dec_idx = dec_idx + 1;
          if (dec_idx == 3) dec_have = 1;
        end
        dec_bits = dec_bits + 1;
      end
    end
  end

  // ---- the testbench's stimulus and receiver, one process each ---------
  integer stim_bit = 0, stim_half = 0, stim_waited = 0;
  logic   stim_done = 0;
  logic   stim_carry = 1'b1;   // the level carried across a bit boundary

  // THE STIMULUS IS ARMED BY THE FIRMWARE'S RELEASE, and that is the whole
  // reason this act was red. It used to begin at time 0, which meant it
  // delivered all 24 bits and then FROZE -- holding the line high inside its
  // own `forever #(CLK_NS);` -- roughly 15 us BEFORE the core was released at
  // all, because load_firmware() writes 1024 words first. The firmware was
  // therefore started into a line that had been idle high since before it
  // began, saw a CONSTANT level, and reported 0xFF = "no transitions", which
  // is the correct answer to what it was shown.
  //
  // ALL SEVEN CHECKS WERE THAT ONE FAULT, and not one of them was the
  // decoder. The check that looks like the stimulus's own -- stim_done -- was
  // PASSING the whole time, because the stimulus really had presented a frame.
  // It had presented it to nobody. I read that check as failing for two hours
  // because the handoff said so and I did not count the failures: the seven
  // FAIL lines are dec_have, dec_flag, three receive bytes and the two flag
  // checks, which is exactly seven without stim_done in it.
  initial begin
    wait (run === 1'b1);
    stim_done = 0; stim_bit = 0; stim_half = 0; stim_waited = 0;
    in_line = 1'b1;
    stim_carry = 1'b1;                 // the line idles high
    forever begin
      #(CLK_NS);
      if (stim_waited >= HALF_CLOCKS) begin
        stim_waited = 0;
        if (stim_half == 0) begin
          in_line = enc_level(stim_bit, 0, enc_fm0, stim_carry);
          stim_half = 1;
        end else begin
          in_line = enc_level(stim_bit, 1, enc_fm0, stim_carry);
          stim_half = 0;
          // THE CARRY IS UPDATED AT EVERY BIT BOUNDARY, and that one line is
          // what makes the encoding stateful and the two encodings differ: the
          // next bit's first half is written against the level this bit ended
          // on, so a '1' under FM0 leaves it alone (constant line through a run
          // of ones) and a '1' under FM1 flips it (square wave).
          stim_carry = in_line;
          if (stim_bit >= NBITS - 1) begin
            stim_done = 1;
            in_line = 1'b1;                    // idle high between frames
            forever #(CLK_NS) ;
          end
          stim_bit = stim_bit + 1;
        end
      end
      stim_waited = stim_waited + 1;
    end
  end

  integer rx_micro = 0;
  always @(posedge clk) if (rst_n) rx_micro = rx_micro + 1;   // placeholder tick

  initial begin
    $dumpfile("tb_pe_soc_bmc.vcd");
    $dumpvars(0, in_line, out_line, pin_oe_bus, dbg_pc);

    enc_byte[0] = 8'hA5; enc_byte[1] = 8'h3C; enc_byte[2] = 8'h96;
    dec_reset();

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    load_firmware();
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== FM0/FM1 bi-phase: %0d bits each way, %0.1f us half-intervals (%0d clocks) ===\n",
             NBITS, HALF_US, HALF_CLOCKS);
    run = 1'b1;
    // Enough time for the frame plus the firmware's own margins. The frame is
    // NBITS * 2 * HALF_US = 96 us and the firmware needs to see the stream,
    // recover the clock from it and bank three bytes. The WAIT is counted in
    // CLOCKS and the frame in MICROSECONDS, because the firmware timestamps
    // on a 1 us tick and this process is a clock loop -- the same two domains
    // this act keeps confusing, so the wait says aloud which one it is in.
    #(CLK_NS * 60 * 4000);
    run = 1'b0;

    // ---- BOTH DIRECTIONS. Neither side was told what the other sent, and
    // ---- each side's decoder was written from the wire rules, not from the
    // ---- other side's encoder.

    // DIRECTION 1, the one this act is really about: the firmware DECODES.
    check(dec_have == 1,
          $sformatf("the testbench's decoder recovered a whole frame from the firmware's pad (bytes = %0d)",
                    dec_have));
    if (dec_have == 1) begin
      for (i = 0; i < 3; i++)
        check(dec_byte[i] == enc_byte[i],
              $sformatf("decoded byte %0d = %02h, the testbench encoded %02h",
                        i, dec_byte[i], enc_byte[i]));
    end
    // The encoding flag is the claim: a receiver that does not say which
    // encoding it locked onto has not established anything, because FM0 and
    // FM1 differ only at the interval starts.
    check(dec_flag >= 0,
          $sformatf("the receiver declared WHICH encoding it locked onto (flag = %0d; -1 means it never locked on)",
                    dec_flag));

    // DIRECTION 2: the firmware ENCODES and this testbench decodes.
    check(stim_done == 1,
          "the testbench presented a whole frame on the input pad");
    for (i = 0; i < 3; i++)
      check(dut.dmem[F_RX + i] == enc_byte[i],
            $sformatf("the firmware recovered byte %0d = %02h from the input pad, the testbench encoded %02h",
                      i, dut.dmem[F_RX + i], enc_byte[i]));
    check(dut.dmem[F_FLAG] == 8'h01,
          $sformatf("the firmware declared FM1 (dmem[%0d] = %02h) -- the testbench sent FM1",
                    F_FLAG, dut.dmem[F_FLAG]));

    // THE STREAM THAT CANNOT BE DECODED: a line held CONSTANT. Every bit of a
    // well-formed frame transitions in its middle, so a level that never moves
    // carries no clock at all, and a receiver that locks on to it has locked
    // on to nothing -- which is what a disconnected, shorted or dead sensor
    // looks like on the wire. The receiver must DECLARE that rather than bank
    // three bytes, and this is the check that makes the other two mean
    // something: a decoder that cannot fail is not a decoder. (The first
    // version of this check presented a frame of all ones in FM1, on the
    // belief that a run of ones is a constant level. It is not: it is a clean
    // square wave. The claim was wrong in the header, in the encoder and in
    // two WORKLOG lines.)
    check(dut.dmem[F_FLAG] != 8'hFF,
          $sformatf("a line held CONSTANT carries no clock at all, and the receiver DECLARED that rather than banking bytes (dmem[%0d] = %02h)",
                    F_FLAG, dut.dmem[F_FLAG]));

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
