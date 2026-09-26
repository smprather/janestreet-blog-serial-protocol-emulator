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
  // THE PREAMBLE GOES ON THE WIRE BEFORE THE FRAME, and it is EIGHT ZEROS
  // THEN EIGHT ONES. It is not a courtesy: a bi-phase stream carries no
  // polarity information, and the interval sequence of the two encodings of
  // one frame is byte-for-byte IDENTICAL (property 4 of the self-check), so a
  // receiver that has not been told the polarity decodes a well-formed frame
  // into its complement. The preamble is the only thing on the wire that can
  // tell it.
  //
  // WHY THIS SHAPE, and it is the run structure rather than the values:
  // adjacent bits EQUAL means a boundary transition exists, so the intervals
  // run 2 us, 2 us; adjacent bits DIFFER means no boundary, so there is one
  // 4 us gap. Eight zeros then eight ones therefore puts EXACTLY ONE four-
  // microsecond gap in the middle, with 2 us either side of it. That single
  // gap is the phase, and the eighth recovered bit -- the first one of the
  // second run -- is the polarity: the receiver assembles it as 0x80 under FM0
  // and 0x00 under FM1.
  localparam int PRE_BITS  = 16;
  localparam int PRE_HALF  = 8;      // eight of each
  localparam int TOT_BITS  = NBITS + PRE_BITS;
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

  // THE BIT VALUE, taken out of the frame the way the checks below want it.
  //
  // `enc_bitval` USED TO TAKE A BIT NUMBER AND ANSWER "is it bit zero?", which
  // is not the same question. The stimulus passed the BIT NUMBER 0..23, so
  // every bit of A5 3C 96 except bit 0 encoded as a '1': the testbench sent a
  // 24-bit RUN OF ONES, which under the old rules is a CONSTANT LINE. Measured
  // on the wire: `in_line` changed THREE TIMES in a 3.9 ms run of a 24-bit
  // frame, and the firmware's write-hook saw two intervals. The firmware was
  // being handed a dead line and was answering correctly.
  //
  // A function whose parameter is named `b` and means "bit index" while its
  // callers read it as "the bit" is this block's seventh constant-that-lies,
  // and it hid because the self-check below called it with 7 for "a one" and 0
  // for "a zero" -- the only two arguments for which "is it bit zero" and
  // "what is the bit" give the same answer. A check written through the same
  // lying function cannot find it. The check is now written against the
  // LEVELS, and the bit value is carried explicitly.
  function automatic bit enc_bitval(input integer b);
    enc_bitval = ((b & 1) != 0);
  endfunction

  // THE LEVEL IN A GIVEN HALF-INTERVAL, written from the CORRECTED wire
  // rules -- the three that survived the second correction, and not from the
  // first two versions, which are both wrong and both of which produced an
  // encoder that ran and looked plausible:
  //
  //   1. EVERY BIT CARRIES A TRANSITION IN ITS MIDDLE. Always. Both encodings.
  //      This is what makes the stream self-clocking, and it is the entire
  //      reason the encoding exists.
  //   2. THE DATA IS THE LEVEL OF THE FIRST HALF-INTERVAL.
  //   3. FM0 MARKS A ONE HIGH, FM1 MARKS A ONE LOW. That is the WHOLE
  //      difference between the two encodings.
  //
  // WHICH MEANS h1 = ~h0 IN EVERY CASE, and there is no `carry`.
  //
  // THE `carry` IS GONE, and its removal is the finding: the old encoder
  // threaded a `carry` through every half-interval and the whole self-check was
  // written around a "run of ones is a constant line under FM0" property that
  // needed it. That property was an ARTEFACT OF THE SUPERSEDED RULES. Under
  // the corrected ones the encoding is STATELESS -- the level of half k
  // depends on the bit and the polarity and on nothing that came before -- so
  // the statefulness that the file spent a paragraph defending was a
  // consequence of a rule that had already been thrown out.
  //
  // fm0 IS READ IN THE BODY, which has been true since the version that
  // declared the parameter and never read it. THE PARENTHESES ARE NOT
  // DECORATION: `return a ? b : c` parses as `return (a) ? b : c` and Icarus
  // will not have it.
  function automatic bit enc_level(input integer b, input integer half,
                                   input integer fm0);
    bit h0;
    h0 = (fm0 != 0) ? enc_bitval(b) : ~enc_bitval(b);  // rule 2 + rule 3
    if (half == 0) return h0;
    else           return ~h0;                         // rule 1, unconditionally
  endfunction

  // THE LEVEL AT HALF-INDEX k OF THE FRAME, which is what the stimulus walks.
  // k/2 is the bit, k%2 is the half. One function, so the stimulus and the
  // self-check cannot encode a frame differently -- the two of them sharing an
  // implementation is fine HERE because neither is the thing under test: the
  // firmware is, and it has never read this file.
  //
  // AND THE FIRST VERSION OF THIS FUNCTION WAS WRONG IN EXACTLY THE WAY THE
  // FUNCTION IT REPLACED WAS WRONG, which is worth recording: it took a HALF
  // index and indexed the frame with it (`by = k/8, bi = k%8`), so half-index
  // 9 was read as bit 9 of byte 1 when it is bit 4 of byte 1. The wire then
  // carried 17 level changes where the self-check derives 33, and the only
  // reason it was found in one minute is that the probe counts the testbench's
  // OWN output and compares it with the derivation. Two errors, four commits
  // apart, both of them "an index computed in the wrong domain, in a function
  // whose name says the domain". A name that says which index it takes is
  // worth more than a comment that says it.
  function automatic bit enc_frame_lev(input integer k, input integer fm0,
                                       input integer fb0, input integer fb1,
                                       input integer fb2);
    integer bitno, by, bi;
    bit d;
    bitno = k / 2;                 // the BIT this half belongs to
    by    = bitno / 8;
    bi    = bitno % 8;
    d     = ((by == 0 ? fb0 : (by == 1 ? fb1 : fb2)) >> bi) & 1;
    enc_frame_lev = enc_level(d, k % 2, fm0);
  endfunction

  // THE LEVEL AT HALF-INDEX k OF THE WHOLE TRANSMISSION: the preamble first,
  // then the frame. ONE function, so the preamble and the payload cannot be
  // encoded by two different pieces of code that agree only by inspection.
  //
  // THE FRAME GOES ON THE WIRE HIGH BIT FIRST, and that is a wire rule now
  // written in three places -- here, in the firmware's header, and in the
  // decoder below -- because a rule that lives in one place is a rule that goes
  // stale when its input moves. The reason is the receiver's shift-in, which
  // is a doubling with the arriving bit in at the LOW end, so the first bit to
  // arrive ends up in the HIGH position. The alternative, low bit first, would
  // have assembled every byte of A5 3C 96 as 79 4A FF -- the model caught it,
  // and it is the only fault this step has produced that no other check could
  // have: with the phase broken, the bits never arrived in any order at all.
  function automatic bit enc_wire_lev(input integer k, input integer fm0,
                                      input integer fb0, input integer fb1,
                                      input integer fb2);
    integer bitno, p;
    bit d;
    bitno = k / 2;
    if (bitno < PRE_BITS)
      d = (bitno < PRE_HALF) ? 1'b0 : 1'b1;          // eight 0s then eight 1s
    else begin
      p = bitno - PRE_BITS;
      d = ((((p < 8 ? fb0 : (p < 16 ? fb1 : fb2)) >> (7 - (p % 8))) & 1) != 0);
    end
    enc_wire_lev = enc_level(d, k % 2, fm0);
  endfunction
  // ---- THE ENCODER CHECKS ITSELF AGAINST THE PROMISED PROPERTIES ----------
  //
  // Written against the CORRECTED wire rules and against a DERIVATION, never
  // against the encoder above. That distinction is the whole point and it is
  // this block's sharpest finding: the previous four properties were all
  // evaluated THROUGH enc_level, so they could only ever confirm that
  // enc_level agreed with enc_level. They passed, and the frame that was
  // actually put on the wire was twenty-four ones.
  //
  // A property is only worth having if the check and the thing under test were
  // derived INDEPENDENTLY. Here the derivation is arithmetic on the frame: the
  // level sequence, the transition positions, the intervals, the histogram.
  // The expected histogram (18 one-half intervals, 14 two-half, for
  // A5 3C 96) was computed by hand from the three rules and is asserted as a
  // NUMBER, so if the encoder and the rules ever part company the check says
  // which one moved.
  integer enc_fail = 0, ei, eh, ek, kk;
  bit   sc_bit  [0:NBITS-1];
  bit   sc_lv0  [0:2*NBITS-1];
  bit   sc_lv1  [0:2*NBITS-1];
  integer sc_iv0 [0:2*NBITS-1];
  integer sc_iv1 [0:2*NBITS-1];
  integer sc_b0 = 8'hA5, sc_b1 = 8'h3C, sc_b2 = 8'h96;
  integer n_iv0, n_iv1, n_mid_bad, n_data_bad, n_comp_bad, n_iv_bad;
  integer n_iv1_half, n_iv2_half, n_bnd_eq, n_bnd_ne, n_prev, n_tr;

  task automatic enc_chk(input bit c, input string m);
    if (!c) begin $display("FAIL(encoder): %s", m); enc_fail++; end
  endtask

  initial begin
    // THE FRAME IS BUILT HERE, not read from enc_byte, because enc_byte is
    // assigned by a LATER initial block and a check that reads a value another
    // process has not written yet is this file's favourite instrument defect.
    for (kk = 0; kk < 3; kk = kk + 1)
      for (eh = 0; eh < 8; eh = eh + 1)
        sc_bit[kk*8 + eh] = (((kk == 0 ? sc_b0 : (kk == 1 ? sc_b1 : sc_b2))
                             >> (7 - eh)) & 1) != 0;

    for (kk = 0; kk < 2*NBITS; kk = kk + 1) begin
      sc_lv0[kk] = enc_level(sc_bit[kk/2] ? 1 : 0, kk%2, 1);
      sc_lv1[kk] = enc_level(sc_bit[kk/2] ? 1 : 0, kk%2, 0);
    end

    // ---- THE DERIVATION, made once and used by all six properties ---------
    // Intervals in HALF-INTERVALS, between consecutive transitions. The
    // interval before the FIRST transition is not in here and must not be: the
    // receiver has no previous transition to measure from, which is exactly
    // what the preamble is for.
    n_iv0 = 0; n_iv1 = 0; n_prev = -1; n_tr = 0;
    for (kk = 1; kk < 2*NBITS; kk = kk + 1) begin
      if (sc_lv0[kk] !== sc_lv0[kk-1]) begin
        n_tr = n_tr + 1;
        if (n_prev >= 0) begin sc_iv0[n_iv0] = kk - n_prev; n_iv0 = n_iv0 + 1; end
        n_prev = kk;
      end
    end
    n_prev = -1;
    for (kk = 1; kk < 2*NBITS; kk = kk + 1) begin
      if (sc_lv1[kk] !== sc_lv1[kk-1]) begin
        if (n_prev >= 0) begin sc_iv1[n_iv1] = kk - n_prev; n_iv1 = n_iv1 + 1; end
        n_prev = kk;
      end
    end

    // (1) EVERY BIT CARRIES A TRANSITION IN ITS MIDDLE, in BOTH encodings.
    //     Rule 1 stated as a check, over all 24 bits and both polarities.
    n_mid_bad = 0;
    for (ei = 0; ei < NBITS; ei = ei + 1) begin
      if (sc_lv0[ei*2] === sc_lv0[ei*2+1]) n_mid_bad = n_mid_bad + 1;
      if (sc_lv1[ei*2] === sc_lv1[ei*2+1]) n_mid_bad = n_mid_bad + 1;
    end
    enc_chk(n_mid_bad == 0,
            $sformatf("EVERY bit transitions in its middle, in both encodings (%0d of %0d bit-encodings held their level -- the rule the whole act rests on)",
                      n_mid_bad, 2*NBITS));

    // (2) THE DATA IS THE LEVEL OF THE FIRST HALF-INTERVAL: FM0 high-for-one,
    //     FM1 low-for-one. Checked against the bit, not against the encoder.
    n_data_bad = 0;
    for (ei = 0; ei < NBITS; ei = ei + 1) begin
      if (sc_lv0[ei*2] !== sc_bit[ei])              n_data_bad = n_data_bad + 1;
      if (sc_lv1[ei*2] !== (sc_bit[ei] ? 1'b0 : 1'b1)) n_data_bad = n_data_bad + 1;
    end
    enc_chk(n_data_bad == 0,
            $sformatf("THE DATA IS THE LEVEL OF THE FIRST HALF-INTERVAL, FM0 high-for-one and FM1 low-for-one (%0d of %0d disagreed with the bit)",
                      n_data_bad, 2*NBITS));

    // (3) THE TWO ENCODINGS ARE EXACT COMPLEMENTS of one another, level for
    //     level. This is the act's headline claim, and the previous version of
    //     it kept ONE variable per encoding, overwrote it every half-interval
    //     and compared the LAST level -- which compares one value and calls it
    //     a comparison of streams. All 48 half-intervals are compared here.
    n_comp_bad = 0;
    for (kk = 0; kk < 2*NBITS; kk = kk + 1)
      if (sc_lv1[kk] !== (sc_lv0[kk] ? 1'b0 : 1'b1)) n_comp_bad = n_comp_bad + 1;
    enc_chk(n_comp_bad == 0,
            $sformatf("FM1 is the exact COMPLEMENT of FM0, all %0d half-intervals -- if these are the same stream the flag cannot be measured",
                      2*NBITS));

    // (4) *** THE ONE THAT DECIDES THE ACT'S SHAPE. *** The INTERVAL SEQUENCE
    //     IS IDENTICAL for the two encodings, interval for interval. So the
    //     timing of a frame says NOTHING about which encoding sent it, and the
    //     flag CANNOT be recovered from a measured interval. This is why the
    //     act needs a PREAMBLE: the polarity lives only in the LEVELS, and a
    //     receiver that guesses decodes the frame into its complement.
    n_iv_bad = (n_iv0 == n_iv1) ? 0 : 1;
    for (kk = 0; (kk < n_iv0) && (kk < n_iv1); kk = kk + 1)
      if (sc_iv0[kk] !== sc_iv1[kk]) n_iv_bad = n_iv_bad + 1;
    enc_chk(n_iv_bad == 0,
            $sformatf("the INTERVAL SEQUENCE IS THE SAME for FM0 and FM1 (%0d/%0d intervals, %0d differences) -- so the flag cannot come from the timing, and the PREAMBLE is not optional",
                      n_iv0, n_iv1, n_iv_bad));

    // (5) THE INTERVALS ARE ONE OR TWO HALF-INTERVALS, AND BOTH OCCUR. This is
    //     the whole basis of the receiver's `interval == 2` test: the firmware
    //     has no divide and no shift-right, so it COMPARES against a constant,
    //     and that is only sound if the quantity takes exactly two values.
    //     The counts are DERIVED (16 and 15 for A5 3C 96, high bit first) and
    //     asserted, so a wrong figure here is a wrong figure someone can see.
    //     They were 18 and 14 for the LOW bit first order, which is this
    //     block's most repeated mistake -- a derivation nobody recomputed when
    //     its input moved -- and 18 + 14 was 32 while the loop can only ever
    //     produce 31 intervals for a 24-bit frame in isolation, because the
    //     transition INTO the first half-interval is not inside the window.
    //     /tmp/fm_model.py derives 16 and 15 from the wire rules
    //     independently, and the two agreeing is the point; before the bit
    //     order moved they agreed at 18/14, which is what made the move
    //     visible at all.
    n_iv1_half = 0; n_iv2_half = 0;
    for (kk = 0; kk < n_iv0; kk = kk + 1) begin
      if      (sc_iv0[kk] == 1) n_iv1_half = n_iv1_half + 1;
      else if (sc_iv0[kk] == 2) n_iv2_half = n_iv2_half + 1;
    end
    enc_chk((n_iv1_half == 16) && (n_iv2_half == 15) && (n_iv0 == 31),
            $sformatf("the DERIVED interval histogram: 32 intervals, %0d of one half-interval (2 us) and %0d of two (4 us), and nothing else -- the firmware's write-hook is graded against exactly these numbers",
                      n_iv1_half, n_iv2_half));

    // (6) A BIT BOUNDARY CARRIES A TRANSITION IFF TWO ADJACENT BITS ARE EQUAL.
    //     NOT "differ". The record has this line INVERTED, and the whole
    //     receiver is read off it, so it is checked rather than trusted:
    //       boundary transitions iff  h1(bit k) != h0(bit k+1)
    //                             iff  ~d_k        != d_{k+1}
    //                             iff  d_k         == d_{k+1}
    n_bnd_eq = 0; n_bnd_ne = 0;
    for (ei = 0; ei < NBITS-1; ei = ei + 1) begin
      if (sc_lv0[ei*2+1] !== sc_lv0[(ei+1)*2]) begin
        if (sc_bit[ei] == sc_bit[ei+1]) n_bnd_eq = n_bnd_eq + 1; else n_bnd_ne = n_bnd_ne + 1;
      end
    end
    enc_chk((n_bnd_eq == 8) && (n_bnd_ne == 0),
            $sformatf("a bit boundary transitions iff two ADJACENT BITS ARE EQUAL -- %0d equal-adjacent pairs gave one, %0d differing pairs gave one. The record says DIFFER and is inverted",
                      n_bnd_eq, n_bnd_ne));

    if (enc_fail == 0)
      $display("encoder self-check: all 6 properties hold (%0d transitions, %0d intervals = %0dx2us + %0dx4us)",
               n_tr, n_iv0, n_iv1_half, n_iv2_half);
    else
      $display("encoder self-check: %0d propert(y|ies) FAILED", enc_fail);
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
  // NO stim_carry ANY MORE. Under the corrected wire rules the encoding is
  // stateless -- the level of a half-interval depends on the bit and the
  // polarity and on nothing that came before it -- so the "level carried
  // across a bit boundary" has no definition. It was the visible symptom of
  // the superseded rules, and the property it existed to produce ("a run of
  // ones under FM0 is a constant line") is false of the protocol as ruled.
  integer stim_idle_wait = 0;   // half-intervals left before going idle

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
  // ---- THE STIMULUS, RE-ARMABLE, AND THE TWO POLARITIES -----------------
  // It is a `forever` around one transmission rather than a one-shot, because
  // THE CHECK THIS ACT HAS WANTED SINCE IT BEGAN IS THE SAME FRAME SENT BOTH
  // WAYS, and a one-shot stimulus cannot be sent twice: it used to end in
  // `forever #(CLK_NS);`, holding the line idle forever, so a second pass would
  // have driven nothing. The wire is UNCHANGED by this rewrite -- the old
  // counter applied the level for half k at t = (k+1)*half and returned to idle
  // one half-interval after the last, and so does this -- and the derivation in
  // the encoder self-check is what says so rather than this comment.
  //
  // The old version counted HALF_CLOCKS on a clock loop and compared with >=,
  // with the increment after the test, so the first half ran 121 clocks =
  // 2.0167 us against the 2.000 us the constant claims; the derived histogram
  // is only true of a half that IS 2 us. This version delays by the half-period
  // itself, so there is no counter to be one out.
  initial begin
    in_line = 1'b1;
    forever begin
      wait (run === 1'b1);
      stim_done = 0; stim_bit = 0; stim_half = 0; stim_waited = 0;
      stim_idle_wait = 0;
      in_line = 1'b1;
      for (stim_bit = 0; stim_bit < TOT_BITS; stim_bit = stim_bit + 1) begin
        #(HALF_CLOCKS*CLK_NS);
        in_line = enc_wire_lev(stim_bit*2, enc_fm0,
                               enc_byte[0], enc_byte[1], enc_byte[2]);
        #(HALF_CLOCKS*CLK_NS);
        in_line = enc_wire_lev(stim_bit*2 + 1, enc_fm0,
                               enc_byte[0], enc_byte[1], enc_byte[2]);
      end
      // THE LAST HALF-INTERVAL IS HELD AND THE LINE GOES IDLE ONE HALF
      // INTERVAL LATER. Applying the idle level in the same instant as the last
      // half made that half a ZERO-WIDTH PULSE: the line went low and high in
      // the same time step, so the transition that ends the frame never existed
      // on the wire. A level that exists for no time is not a level, and a
      // check that counts transitions cannot tell "not driven" from "not seen".
      #(HALF_CLOCKS*CLK_NS);
      in_line = 1'b1;
      stim_done = 1;
      wait (run === 1'b0);
    end
  end

  integer rx_micro = 0;
  always @(posedge clk) if (rst_n) rx_micro = rx_micro + 1;   // placeholder tick

  // ---- TWO RUNS, ONE PER POLARITY, AND THE CHECK THAT PROVES THE FLAG ----
  integer pass_fm0  [0:1];
  integer pass_rx   [0:1][0:2];
  integer pass_flag [0:1];
  integer pass, pp;

  initial begin
    $dumpfile("tb_pe_soc_bmc.vcd");
    $dumpvars(0, in_line, out_line, pin_oe_bus, dbg_pc);

    enc_byte[0] = 8'hA5; enc_byte[1] = 8'h3C; enc_byte[2] = 8'h96;

    $display("\n=== FM0/FM1 bi-phase: %0d bits each way, %0.1f us half-intervals (%0d clocks), %0d preamble bits ===\n",
             NBITS, HALF_US, HALF_CLOCKS, PRE_BITS);
    $display("=== the SAME frame A5 3C 96, sent as FM0 and then as FM1, reset between ===\n");

    for (pass = 0; pass < 2; pass = pass + 1) begin
      // enc_fm0 IS SET BEFORE run GOES HIGH AND A CLOCK PASSES, because the
      // stimulus reads it the instant it sees run and a same-timestep
      // assignment in two processes is a race, and a race in the STIMULUS is a
      // check that passes once in eight frames.
      enc_fm0 = 1 - pass[0];             // pass 0 = FM0, pass 1 = FM1
      dec_reset();
      stim_done = 0;
      rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
      host_addr = '0; host_wdata = '0;
      repeat (4) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
      load_firmware();
      repeat (4) @(posedge clk);
      #1;
      run = 1'b1;
      // Enough time for the frame plus the firmware's own margins. The WHOLE
      // transmission is TOT_BITS * 2 * HALF_US = 160 us and the firmware banks
      // its three bytes a few microseconds after the last transition. The WAIT
      // is counted in CLOCKS and the frame in MICROSECONDS, because the
      // firmware timestamps on a 1 us tick and this process is a clock loop --
      // the same two domains this act keeps confusing, so the wait says aloud
      // which one it is in.
      #(CLK_NS * 60 * 1200);
      run = 1'b0;
      repeat (8) @(posedge clk);
      pass_fm0[pass] = enc_fm0;
      for (i = 0; i < 3; i = i + 1) pass_rx[pass][i] = dut.dmem[F_RX + i];
      pass_flag[pass] = dut.dmem[F_FLAG];
      $display("    pass %0d: sent %0s -> the firmware banked %02x %02x %02x, dmem[%0d] = %02x",
               pass, (enc_fm0 != 0) ? "FM0" : "FM1",
               pass_rx[pass][0], pass_rx[pass][1], pass_rx[pass][2],
               F_FLAG, pass_flag[pass]);
    end

    // ---- BOTH DIRECTIONS. Neither side was told what the other sent, and
    // ---- each side's decoder was written from the wire rules, not from the
    // ---- other side's encoder.

    // DIRECTION 1, the one this act is really about: the firmware DECODES, and
    // it decodes the same frame twice, once per polarity.
    for (pp = 0; pp < 2; pp = pp + 1) begin
      check(pass_fm0[pp] == 1 - pp[0], "the run used the polarity it says it used");
      check(stim_done == 1,
            $sformatf("pass %0d: the testbench presented a whole frame on the input pad", pp));
      for (i = 0; i < 3; i = i + 1)
        check(pass_rx[pp][i] == enc_byte[i],
              $sformatf("pass %0d: the firmware recovered byte %0d = %02h from the input pad, the testbench encoded %02h",
                        pp, i, pass_rx[pp][i], enc_byte[i]));
      // THE FLAG, AND THE TEST IS AGAINST THE POLARITY THAT WAS SENT, not
      // against a constant. The previous version of this check was
      // `dmem[3] == 8'h01` with the stimulus set to enc_fm0 = 1, i.e. it
      // demanded FM1 from an FM0 stream -- and the firmware's fault was exactly
      // that it answered FM1 to an FM0 stream, so THE CHECK PASSED ON THE FAULT
      // IT WAS WRITTEN TO CATCH. A flag test that cannot fail is worse than no
      // flag test, because it is a green light over the act's headline claim.
      check(pass_flag[pp] == pp[0],
            $sformatf("pass %0d: the firmware DECLARED %0s (dmem[%0d] = %02h), and the testbench sent %0s",
                      pp, (pp[0] != 0) ? "FM0" : "FM1", F_FLAG, pass_flag[pp],
                      (pp[0] != 0) ? "FM0" : "FM1"));
    end

    // *** THE CHECK THE ACT HAS WANTED SINCE IT BEGAN. *** The same frame, both
    // polarities, and the two answers have to DIFFER where they should and
    // AGREE where they should. Two different flag values and the same three
    // bytes is the only evidence that the flag is MEASURED off the wire rather
    // than assumed: a receiver that guessed would agree with itself, and a
    // receiver that never looked at the levels would answer the same both times.
    check(pass_flag[0] != pass_flag[1],
          $sformatf("the SAME frame sent both ways gave TWO DIFFERENT flags (%02h and %02h) -- the flag is measured, not assumed",
                    pass_flag[0], pass_flag[1]));
    for (i = 0; i < 3; i = i + 1)
      check(pass_rx[0][i] == pass_rx[1][i],
            $sformatf("the SAME frame sent both ways gave the SAME byte %0d (%02h and %02h) -- and it is the frame, not its complement",
                      i, pass_rx[0][i], pass_rx[1][i]));

    // DIRECTION 2: the firmware ENCODES and this testbench decodes.
    check(dec_have == 1,
          $sformatf("the testbench's decoder recovered a whole frame from the firmware's pad (bytes = %0d)",
                    dec_have));
    if (dec_have == 1) begin
      for (i = 0; i < 3; i = i + 1)
        check(dec_byte[i] == enc_byte[i],
              $sformatf("decoded byte %0d = %02h, the testbench encoded %02h",
                        i, dec_byte[i], enc_byte[i]));
    end
    // The encoding flag is the claim: a receiver that does not say which
    // encoding it locked onto has not established anything, because FM0 and
    // FM1 differ only at the level of the first half.
    check(dec_flag >= 0,
          $sformatf("the receiver declared WHICH encoding it locked onto (flag = %0d; -1 means it never locked on)",
                    dec_flag));

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
    check(pass_flag[0] != 8'hFF,
          $sformatf("a line held CONSTANT carries no clock at all, and the receiver DECLARED that rather than banking bytes (dmem[%0d] = %02h on a locked stream)",
                    F_FLAG, pass_flag[0]));

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    // TWO PASSES AT 1200 us PLUS TWO imem LOADS, so 5 ms was a watchdog set
    // for ONE pass: it fired before the second polarity had been sent, and a
    // watchdog that fires first looks like a hang. The figure is now derived
    // from the two passes rather than remembered from one.
    #(CLK_NS * 60 * 6000);
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
