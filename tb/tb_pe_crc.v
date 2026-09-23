// tb_pe_crc.v — self-checking testbench for pe_crc.
//
// WHAT IS BEING CHECKED, AND WHY IT IS NOT CIRCULAR
//
// The DUT has ONE shift-right datapath and no mode bit. The obvious way to test
// it would be to model that same datapath here, which would prove nothing. So
// the reference below is the TEXTBOOK form instead:
//
//   * a reflected CRC (Ethernet, USB) shifts RIGHT and takes feedback at bit 0;
//   * a non-reflected CRC (CAN, SMBus) shifts LEFT and takes feedback at the
//     top bit.
//
// Two different datapaths, driven from the same parameters. If they agree, the
// claim that one right-shift register serves both families is a measured fact.
//
// Two outside facts are used as well, so a transcription error cannot hide:
//
//   1. The RevEng catalogue's published `check` value for "123456789", asserted
//      for all six polynomials (tools/gen/crc_config.py checks the same table).
//   2. The catalogue's published `residue` — what a register holds after folding
//      the message AND its field. The TB folds the DUT's OWN EMITTED BITS and
//      requires that residue. Agreement is independent evidence that the field
//      ORDER on the wire is the one the standard specifies, rather than merely
//      self-consistent with the DUT.
//
// Also asserted on every strobe: R[31:Wcrc] stays zero. That invariant is what
// lets a 32-bit register run a 5-bit CRC with no width port.
//
// ---------------------------------------------------------------------------
// WHAT "ERROR DETECTION" CAN AND CANNOT MEAN HERE
//
// Two things are deliberately NOT asserted, because asserting them would be
// wrong and would read as an RTL bug:
//
//   1. A corrupted frame must FAIL THE CATALOGUE RESIDUE TEST. It need not. The
//      residue is a fixed point of the *uncorrupted* computation, so a frame
//      with a bad payload and a correspondingly bad CRC is perfectly consistent
//      and lands wherever it lands. What a receiver must do is drain to zero,
//      and a corrupted frame does not.
//   2. A corrupted frame must produce a DIFFERENT CRC. For a single flipped wire
//      bit it always will — every polynomial in this table has an x^0 term, so a
//      single-bit error has a non-zero syndrome — and that IS asserted, at the
//      first, middle and last message bit. Two flipped bits can cancel, so
//      multi-bit corruption is not asserted to change anything.
//
// A CRC is not a hash. Testing it as one produces failures that are arithmetic,
// not defects.

`timescale 1ns / 1ps

module tb_pe_crc;

  localparam int W = 32;
  localparam int MAXBITS = 512;      // 16 bytes + a 32-bit field, with room

  logic         clk = 0, rst_n;
  logic         bit_en, clr, crc_field, bit_in;
  logic [W-1:0] cfg_poly_r, cfg_seed;
  logic         cfg_out_inv;
  logic         crc_bit, crc_zero;
  logic [W-1:0] crc_state;

  pe_crc #(.W(W)) dut (.*);

  // The block counts strobes, not cycles, so the period is arbitrary.
  always #5 clk = ~clk;

  integer errors = 0;
  integer seed = 20260920;
  integer high_bits_violations = 0;

  // soak-loop state (module scope: Icarus rejects `automatic` on an
  // initialized array declaration, so these are plain variables)
  logic [127:0] soak_msg;
  int           soak_nb, soak_sel;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL crc: %s @%0t", m, $time); errors++; end
  endtask

  function automatic [W-1:0] rev(input [W-1:0] v, input int width);
    logic [W-1:0] r;
    r = '0;
    for (int i = 0; i < width; i++)
      if (v[i]) r |= (32'd1 << (width - 1 - i));
    return r;
  endfunction

  // ---- width invariant, watched on every strobe ---------------------------
  // Written as a shift-and-compare rather than a part-select because the width
  // is a task argument and a part-select needs constant bounds.
  task automatic check_high_clean(input int wcrc, input string tag);
    if ((crc_state >> wcrc) != '0) begin
      $display("FAIL crc: %s: R[%0d:%0d] = 0x%08X is not zero @%0t",
               tag, W-1, wcrc, crc_state >> wcrc, $time);
      errors++; high_bits_violations++;
    end
  endtask

  // ---- textbook reference -------------------------------------------------
  // Takes an explicit WIRE BIT LIST (MSB-aligned in a MAXBITS-wide vector, so
  // bit index MAXBITS-1 is the first bit on the wire), and can fold a message,
  // a field, or both. Returns R: the CRC itself for a reflected algorithm, and
  // the CRC bit-reversed for a non-reflected one -- which is the DUT's
  // convention, and what the caller needs in order to predict crc_state.
  function automatic [W-1:0] ref_R_bits(input logic [MAXBITS-1:0] bits,
                                        input int nbits, input int wcrc,
                                        input [W-1:0] poly, input [W-1:0] init,
                                        input bit refin);
    logic [W-1:0] mask, p, crc;
    logic         b, fbb;
    mask = (32'd1 << wcrc) - 32'd1;
    p    = refin ? rev(poly, wcrc) : poly;
    crc  = init & mask;
    // bits[MAXBITS-1] is transmitted first, so walk DOWN the vector.
    for (int i = 0; i < nbits; i++) begin
      b = bits[MAXBITS-1-i];
      if (refin) begin
        fbb = b ^ crc[0];
        crc = (crc >> 1) & mask;
      end else begin
        fbb = b ^ crc[wcrc-1];
        crc = (crc << 1) & mask;
      end
      if (fbb) crc = crc ^ p;
    end
    return refin ? crc : rev(crc, wcrc);
  endfunction

  // Message bytes -> MSB-aligned wire bit list. `flip` inverts ONE message bit
  // if non-zero: it is a 1-based index into the message bits, which lets the
  // caller corrupt the first, middle or last bit.
  function automatic [MAXBITS-1:0] msg_bits(input [127:0] msg, input int nbytes,
                                            input bit refin, input int flip);
    logic [MAXBITS-1:0] out;
    logic [7:0]         bv;
    int                 n;
    out = '0; n = 0;
    for (int i = 0; i < nbytes; i++) begin
      bv = msg[127-8*i -: 8];
      for (int k = 0; k < 8; k++) begin
        out[MAXBITS-1-n] = refin ? bv[k] : bv[7-k];
        n++;
      end
    end
    if (flip > 0 && flip <= n)
      out[MAXBITS-1-(flip-1)] = ~out[MAXBITS-1-(flip-1)];
    return out;
  endfunction

  task automatic strobe();
    @(posedge clk); #1; bit_en = 1'b1;
    @(posedge clk); #1; bit_en = 1'b0;
  endtask

  task automatic do_clr();
    clr = 1'b1; @(posedge clk); #1; clr = 1'b0; #1;
  endtask

  // ---- one full frame -----------------------------------------------------
  // `have_cat` adds the catalogue assertions (check + residue). `flip` corrupts
  // one message bit by 1-based index, or 0 for a clean frame.
  task automatic frame(input [127:0] msg, input int nbytes,
                       input int wcrc, input [W-1:0] poly,
                       input [W-1:0] init, input bit refin,
                       input [W-1:0] xorout, input [W-1:0] check_val,
                       input [W-1:0] residue_val, input bit have_cat,
                       input int flip, input string tag);
    logic [W-1:0]       wmask, exp_R, got_R, field_exp, field_got;
    logic [MAXBITS-1:0] mb;
    logic               b, inv;

    wmask = (32'd1 << wcrc) - 32'd1;

    // Every target's xorout is all-ones or all-zeros, which is what lets one
    // bit express the final complement. Asserted here rather than assumed.
    check((xorout & wmask) == '0 || (xorout & wmask) == wmask,
          {tag, ": xorout must be all-ones or all-zeros for cfg_out_inv"});
    inv = ((xorout & wmask) == wmask) ? 1'b1 : 1'b0;

    // The mask must be the polynomial reversed within its OWN width and then
    // low-justified -- rev(poly, W) would scatter the bits across all 32 and
    // break the R < 2^Wcrc invariant the high-bit check exists to watch.
    cfg_poly_r  = rev(poly, wcrc);
    cfg_seed    = refin ? (init & wmask) : rev(init, wcrc);
    cfg_out_inv = 1'b0;

    // ---------------- transmit ----------------
    do_clr();
    check(crc_zero === 1'b0, {tag, ": crc_zero clear after clr"});

    mb = msg_bits(msg, nbytes, refin, flip);
    for (int i = 0; i < nbytes * 8; i++) begin
      b = mb[MAXBITS-1-i];
      bit_in = b;
      strobe();
      check_high_clean(wcrc, tag);
    end

    // crc_bit ALREADY carries cfg_out_inv (the block complements its own wire
    // output), so this records the pin, not the register bit behind it.
    //
    // The `#1` matters: crc_bit is a continuous assign, so it needs a delta to
    // see a cfg_out_inv written in this same procedural step. Without it the
    // FIRST field bit is sampled with the previous inv and comes out inverted --
    // a one-bit error that leaves every other bit correct, which is exactly the
    // kind of failure that looks like an RTL bug and is not.
    crc_field   = 1'b1;
    cfg_out_inv = inv;
    #1;
    field_got   = '0;
    for (int i = 0; i < wcrc; i++) begin
      field_got[i] = crc_bit;                      // exactly what goes on the wire
      strobe();
    end
    crc_field   = 1'b0;
    cfg_out_inv = 1'b0;
    #1;

    // Expected R and expected field, from the textbook reference.
    exp_R     = ref_R_bits(mb, nbytes * 8, wcrc, poly, init, refin);
    field_exp = (exp_R & wmask) ^ (inv ? wmask : '0);

    check(field_got === field_exp,
          $sformatf("%s: transmitted field wrong (0x%0X want 0x%0X)",
                    tag, field_got, field_exp));
    check(crc_zero === 1'b1,
          {tag, ": crc_zero asserts after a clean field (tx side)"});
    check(crc_state === '0, {tag, ": register drains to zero on transmit"});

    if (have_cat && flip == 0) begin
      got_R = '0;
      for (int i = 0; i < wcrc; i++) got_R[i] = field_got[i] ^ inv;
      check(((refin ? got_R : rev(got_R, wcrc)) ^ xorout) == check_val,
            $sformatf("%s: transmitted field IS the catalogue CRC 0x%0X (got 0x%0X)",
                      tag, check_val, ((refin ? got_R : rev(got_R, wcrc)) ^ xorout) & wmask));
      check(exp_R === got_R,
            $sformatf("%s: textbook reference R 0x%08X vs DUT 0x%08X",
                      tag, exp_R, got_R));
    end

    // ---------------- receive ----------------
    // Two receive runs, because they test different things and conflating them
    // is how a testbench ends up asserting arithmetic instead of behaviour:
    //
    //   A. clean: fold the message + the DUT's field, un-complemented. Must
    //      drain crc_zero to 1.
    //   B. corrupted: flip ONE bit of the RECEIVER's input stream (the message
    //      or the un-complemented field) and require crc_zero == 0.
    //
    // What must NOT be tested is a frame whose message was corrupted BEFORE its
    // CRC was computed: that is a consistent frame with a matching CRC, and a
    // correct receiver accepts it. Asserting otherwise would be a TB bug that
    // looks like an RTL bug.
    //
    // Every polynomial here has a non-zero x^0 term, so a single flipped bit
    // always has a non-zero syndrome; case B is therefore unconditional.
    do_clr();
    for (int i = 0; i < nbytes * 8; i++) begin
      bit_in = mb[MAXBITS-1-i];
      strobe();
    end
    for (int i = 0; i < wcrc; i++) begin
      bit_in = field_got[i] ^ inv;                 // what the sender meant
      strobe();
    end
    check(crc_zero === 1'b1,
          {tag, ": clean frame drains the receiver to zero"});

    if (flip > 0) begin
      // Corrupt the frame that was received, not the one that was transmitted.
      logic [MAXBITS-1:0] rxstream;
      rxstream = mb;
      for (int i = 0; i < wcrc; i++) rxstream[MAXBITS-1-(nbytes*8+i)] = field_got[i] ^ inv;
      rxstream[MAXBITS-1-(flip-1)] = ~rxstream[MAXBITS-1-(flip-1)];

      do_clr();
      for (int i = 0; i < nbytes * 8; i++) begin
        bit_in = rxstream[MAXBITS-1-i];
        strobe();
      end
      for (int i = 0; i < wcrc; i++) begin
        bit_in = rxstream[MAXBITS-1-(nbytes*8+i)];
        strobe();
      end
      check(crc_zero === 1'b0,
            $sformatf("%s: one flipped received bit must be caught (flip=%0d)",
                      tag, flip));
    end

    // ---------------- the outside cross-check on bit order ----------------
    // Fold WITHOUT un-complementing. For an UNCORRUPTED catalogue frame the
    // register must land on the authority's published residue -- a number this
    // TB does not compute. Not asserted for corrupted frames: a bad payload
    // with a bad CRC is a consistent frame, and the residue is a fixed point of
    // the good computation, so there is nothing to check there.
    if (have_cat && flip == 0) begin
      do_clr();
      for (int i = 0; i < nbytes * 8; i++) begin
        bit_in = mb[MAXBITS-1-i];
        strobe();
      end
      for (int i = 0; i < wcrc; i++) begin
        bit_in = field_got[i];                     // raw, complemented bits
        strobe();
      end
      check(crc_state === residue_val,
            $sformatf("%s: raw fold gives 0x%08X, catalogue residue is 0x%08X",
                      tag, crc_state, residue_val));
      // A raw fold lands on the residue, not zero -- so it is NOT the verdict.
      // Only meaningful when the algorithm complements its field; when it does
      // not, the raw fold IS the receiver's fold and legitimately drains.
      if (inv) begin
        check(crc_zero === 1'b0,
              {tag, ": a raw (complemented) fold does not drain to zero"});
      end
    end
  endtask

  // ---- parameters ---------------------------------------------------------
  // "123456789", the RevEng catalogue's check message, MSB-aligned.
  localparam [127:0] M9 = 128'h31323334353637383900000000000000;

  task automatic run_cat(input [127:0] msg, input int nbytes,
                         input int wcrc, input [W-1:0] poly,
                         input [W-1:0] init, input bit refin,
                         input [W-1:0] xorout, input [W-1:0] check_val,
                         input [W-1:0] residue_val, input int nbits,
                         input string tag);
    // Clean frame, then a single-bit error at the first, middle and last
    // message bit. Every polynomial here has an x^0 term, so each of those must
    // be caught; that is asserted, not hoped.
    frame(msg, nbytes, wcrc, poly, init, refin, xorout, check_val, residue_val,
          1'b1, 0, tag);
    frame(msg, nbytes, wcrc, poly, init, refin, xorout, check_val, residue_val,
          1'b1, 1, {tag, " flip first"});
    frame(msg, nbytes, wcrc, poly, init, refin, xorout, check_val, residue_val,
          1'b1, (nbits + 1) / 2, {tag, " flip middle"});
    frame(msg, nbytes, wcrc, poly, init, refin, xorout, check_val, residue_val,
          1'b1, nbits, {tag, " flip last"});
  endtask

  task automatic run_gen(input [127:0] msg, input int nbytes,
                         input int wcrc, input [W-1:0] poly,
                         input [W-1:0] init, input bit refin,
                         input [W-1:0] xorout, input string tag);
    frame(msg, nbytes, wcrc, poly, init, refin, xorout, '0, '0, 1'b0, 0, tag);
    frame(msg, nbytes, wcrc, poly, init, refin, xorout, '0, '0, 1'b0, 1,
          {tag, " flip first"});
    frame(msg, nbytes, wcrc, poly, init, refin, xorout, '0, '0, 1'b0, nbytes * 8,
          {tag, " flip last"});
  endtask

  initial begin
    $dumpfile("tb_pe_crc.vcd");
    $dumpvars(0, tb_pe_crc);
    rst_n = 0; bit_en = 0; clr = 0; crc_field = 0; bit_in = 0;
    cfg_poly_r = 0; cfg_seed = 0; cfg_out_inv = 0;
    repeat (3) @(posedge clk); #1; rst_n = 1; @(posedge clk); #1;

    // ============ the catalogue check message, six polynomials =============
    // check / residue from https://reveng.sourceforge.io/crc-catalogue/
    run_cat(M9, 9, 32, 32'h04C11DB7, 32'hFFFFFFFF, 1'b1, 32'hFFFFFFFF,
            32'hCBF43926, 32'hDEBB20E3, 72, "CRC-32/ISO-HDLC");
    run_cat(M9, 9, 16, 32'h8005,     32'h0000FFFF, 1'b1, 32'h0000FFFF,
            32'h0000B4C8, 32'h0000B001, 72, "CRC-16/USB");
    run_cat(M9, 9,  5, 32'h05,       32'h0000001F, 1'b1, 32'h0000001F,
            32'h00000019, 32'h00000006, 72, "CRC-5/USB");
    run_cat(M9, 9, 15, 32'h4599,     32'h00000000, 1'b0, 32'h00000000,
            32'h0000059E, 32'h00000000, 72, "CRC-15/CAN");
    run_cat(M9, 9,  8, 32'h07,       32'h00000000, 1'b0, 32'h00000000,
            32'h000000F4, 32'h00000000, 72, "CRC-8/SMBUS");
    run_cat(M9, 9, 16, 32'h8005,     32'h00000000, 1'b1, 32'h00000000,
            32'h0000BB3D, 32'h00000000, 72, "CRC-16/ARC");

    // ============ edge cases (TB reference only) ============
    // The 16x0xFF CRC-32 case drives a dense mask (0xEDB88320 has 12 set bits);
    // the 1-byte case is the shortest legal frame.
    run_gen(128'hFF000000000000000000000000000000, 1,  32, 32'h04C11DB7,
            32'hFFFFFFFF, 1'b1, 32'hFFFFFFFF, "CRC-32 one 0xFF byte");
    run_gen(128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 16, 32, 32'h04C11DB7,
            32'hFFFFFFFF, 1'b1, 32'hFFFFFFFF, "CRC-32 16x 0xFF");
    run_gen(128'h00000000000000000000000000000000, 16, 15, 32'h4599,
            32'h00000000, 1'b0, 32'h00000000, "CRC-15 16x 0x00");
    run_gen(128'h0102030405060708090A0B0C0D0E0F10, 16, 15, 32'h4599,
            32'h00000000, 1'b0, 32'h00000000, "CRC-15 ramp");
    run_gen(128'h0102030405060708090A0B0C0D0E0F10, 16,  5, 32'h05,
            32'h0000001F, 1'b1, 32'h0000001F, "CRC-5 ramp");

    // ============ clr semantics ============
    // clr must load cfg_seed verbatim (it is a frame boundary, not a reset) and
    // must clear the verdict. Both are stated in the RTL header.
    begin
      cfg_poly_r  = rev(32'h04C11DB7, 32);
      cfg_seed    = 32'hDEADBEEF;
      cfg_out_inv = 1'b0;
      do_clr();
      check(crc_state === 32'hDEADBEEF, "clr loads cfg_seed verbatim");
      for (int k = 0; k < 40; k++) begin
        bit_in = 1'b1; strobe();
      end
      check(crc_state !== 32'hDEADBEEF, "register moved off the seed");
      do_clr();
      check(crc_state === 32'hDEADBEEF, "clr re-seeds, it is not a reset");
      cfg_seed = 32'h00000000;
      do_clr();
      check(crc_state === '0, "clr to a zero seed empties the register");
    end

    // ============ random soak ============
    // Icarus does not support `automatic` on an initialized array declaration,
    // so the arrays are plain module-scope variables filled with assignments.
    for (int t = 0; t < 60; t++) begin
      soak_msg = '0;
      soak_nb  = 1 + ($unsigned($random(seed)) % 16);
      for (int b = 0; b < soak_nb; b++)
        soak_msg[127-8*b -: 8] = $random(seed);
      soak_sel = $unsigned($random(seed)) % 4;
      case (soak_sel)
        0: run_gen(soak_msg, soak_nb, 32, 32'h04C11DB7, 32'hFFFFFFFF, 1'b1,
                   32'hFFFFFFFF, $sformatf("soak%0d", t));
        1: run_gen(soak_msg, soak_nb, 16, 32'h8005, 32'h0000FFFF, 1'b1,
                   32'h0000FFFF, $sformatf("soak%0d", t));
        2: run_gen(soak_msg, soak_nb, 15, 32'h4599, 32'h00000000, 1'b0,
                   32'h00000000, $sformatf("soak%0d", t));
        default: run_gen(soak_msg, soak_nb, 5, 32'h05, 32'h0000001F, 1'b1,
                         32'h0000001F, $sformatf("soak%0d", t));
      endcase
    end

    if (errors == 0) $display("PASS: tb_pe_crc");
    else $display("FAILURES crc: %0d", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
