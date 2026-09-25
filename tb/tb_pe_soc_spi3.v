// tb_pe_soc_spi3.v — SPI MODE 3 (CPOL=1/CPHA=1) with a per-word CRC, on
// real RTL, against an independent slave that decodes the wire.
//
// WHY THIS EXISTS, AND WHY IT IS NOT firmware/spi_xfer.pe WITH A FLIPPED BIT
//
// firmware/spi_xfer.pe is a mode-0 master whose only executable specification
// was tools/fw/peemu.py, a model written from the same understanding as the
// firmware -- so it can agree with the firmware about a wrong bit order and
// pass. tb_pe_soc_spi.v then fixed that by modelling a real mode-0 slave.
//
// Mode 3 needs the same treatment for a sharper reason. Both modes sample on
// the RISING edge, so a mode-0 program is a plausible-looking mode-3 program
// for the first half-frame and diverges silently after that: the slave
// captures on the rise, so a master that launched MOSI one phase early
// delivers bit k-1 as bit k and the received bytes are shifted by one, with
// nothing on the wire that looks wrong. The only things that catch it are a
// slave that decodes the pins and a check on the IDLE LEVEL -- which is why
// SCLK idling HIGH is asserted here and why SCLK idling HIGH at the END of a
// frame is asserted separately, because a mode-0 program fails the second and
// not the first (reset already drives bit 0 high, which is mode 3's idle
// level by coincidence and mode 0's active edge by construction).
//
// THE FRAME IS HALF-DUPLEX ON A SHARED CLOCK, which is what a command /
// response device with an integrity check actually is:
//
//   CS_N v | WORD(16) TX | CRC8(WORD)(8) TX | RESP(8) RX | CRC8(RESP)(8) RX | CS_N ^
//
// Forty SCLK rises, and the slave counts every one of them -- a master that
// clocked 39 or 41 would otherwise be indistinguishable from one that got the
// framing right, because the bytes it shifted would still look plausible.
//
// THE SLAVE IS A REAL MODE-3 DEVICE, written from the CPOL/CPHA rules:
//
//   CS_N falls  -> selected; bit counter 0; MISO idle low
//   SCLK rises  -> the slave CAPTURES MOSI. This is CPHA=1 with CPOL=1: the
//                  captured edge is the SECOND one, and the first is the fall.
//   SCLK falls  -> the slave advances its bit index and presents the next
//                  MISO bit. MISO therefore changes only on a falling edge,
//                  which is what makes the master's sample-after-the-rise
//                  safe with no delay at all.
//   CS_N rises  -> frame over; the frame is 40 SCLK rises
//
// THE PER-WORD CRC IS CHECKED TWICE, ON OPPOSITE SIDES OF THE WIRE, and that
// is the point of the act:
//
//   * the slave computes CRC-8 over the 16 bits it decoded from MOSI and
//     requires it to equal the 8 bits that followed. That proves the
//     firmware's CRC reached the wire intact.
//   * the slave then sends a response byte plus CRC-8 of THAT byte, and the
//     firmware recomputes it in software and compares. That proves the
//     check is a real round trip, not a one-way decoration.
//
// The reference CRC-8 datapath below is the textbook MSB-first bit-serial
// form, written in Verilog from the polynomial. The firmware's version is
// built from the (A|P)-(A&P) identity because this ISA has no XOR; the two
// are different constructions and must agree, so agreement is evidence.
//
// A CASE DELIBERATELY CORRUPTS ONE RESPONSE CRC. Without it, "3 of 3 CRCs
// checked out" is satisfied by a firmware that never compares anything and
// always increments the counter. With it, the firmware must report exactly
// two, and it must be the SECOND word that fails -- so the count and the
// position are both checked.
//
// Program: firmware/spi_mode3.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

module tb_pe_soc_spi3;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;
  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  // The SPI pin map, from firmware/spi_mode3.pe (identical to spi_xfer.pe's).
  localparam int SCLK_BIT = 0, MOSI_BIT = 1, CS_BIT = 2, MISO_BIT = 3;

  // Three words, none a bit palindrome (reversals: 0x1134->0x3411,
  // 0x1245->0x5421, 0x1356->0x6531), so a master that shifted the other way
  // puts a visibly different pattern on MOSI.
  localparam int N_WORDS = 3;
  localparam logic [8*N_WORDS-1:0] WORD_SEQ = {8'h56, 8'h45, 8'h34};  // lows
  localparam logic [8*N_WORDS-1:0] WORD_HI  = {8'h13, 8'h12, 8'h11};  // highs

  // The slave's response is a FUNCTION of the word it decoded: resp = word XOR
  // RESP_MASK. Deriving it rather than playing a fixed table is what makes a
  // shifted word visible -- a master that lost or gained a bit gets a
  // different response and the comparison fails with the word itself intact.
  localparam logic [15:0] RESP_MASK = 16'h7E5A;

  // The reference CRC-8: poly 0x07, init 0x00, no reflection, no final XOR.
  // `n` selects 1 or 2 input bytes, which is how a word's CRC (high then low)
  // and a response's CRC (one byte) share one function.
  function automatic [7:0] crc8(input [7:0] a, input [7:0] b, input integer n);
    reg [7:0] c;
    integer i, k;
    begin
      c = 8'h00;
      for (i = 0; i < n; i = i + 1) begin
        c = c ^ ((i == 0) ? a : b);
        for (k = 0; k < 8; k = k + 1)
          c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
      end
      crc8 = c;
    end
  endfunction

  // A frame is 16 word bits + 8 CRC bits + 8 response bits + 8 CRC bits.
  localparam int FRAME_BITS = 40;

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;
  wire sclk = pin_out_bus[SCLK_BIT];
  wire mosi = pin_out_bus[MOSI_BIT];
  wire cs_n = pin_out_bus[CS_BIT];

  // ---- the slave --------------------------------------------------------
  logic [5:0]  sl_r;            // RISES completed in this frame
  logic        sl_active;
  integer      sl_idx;          // the MISO bit index, materialised before use
  logic [15:0] sl_word;
  logic [7:0]  sl_crc_in;        // what the master SENT (the word's CRC)
  logic [15:0] sl_miso_rx;       // what the master RECEIVED off MISO
  logic [7:0]  sl_resp, sl_crc_resp;
  integer      sl_frame;

  // 0 = every frame is clean; k = the slave corrupts the RESPONSE CRC on
  // frame k. See the header: this is the non-vacuity case for the firmware's
  // own comparison.
  integer cfg_corrupt_frame = -1;
  logic   frame_corrupted;

  // MISO IS A REGISTER WRITTEN AT THE FALL, and that is not a style choice.
  // The first version selected the presented bit combinationally out of sl_r,
  // which increments at the RISE -- so MISO moved during every high phase,
  // and the mode-3 pin-discipline monitor counted 13 violations of a rule the
  // slave is supposed to be teaching the master. A combinational select over a
  // counter that advances on the *other* edge cannot satisfy an edge-discipline
  // check, however correct the data is.
  logic miso_reg;
  wire  miso = miso_reg;
  assign pin_in_bus = {4'b0, miso, 3'b0};

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

  integer n_rise = 0, n_fall = 0;
  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;
  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh("../firmware/spi_mode3.hex", prog);
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
  // Slave behaviour, edge-driven from the mode-3 rules.
  //
  // THE COUNTER COUNTS RISES, AND THAT IS THE WHOLE TRICK. The mode-3 rules
  // are stated in terms of RISES (the captured edge), but MISO has to change
  // on a FALL, so the model needs both. The first version counted falls and
  // routed the capture by the same counter -- which is off by one at every
  // step, because at rise r the fall counter already reads r+1. The symptom
  // was a word decoded one bit short with the top bit lost, and a response
  // that was computed a rise late and therefore presented as zeroes. The
  // model now counts rises, and presents MISO at the fall for the rise index
  // the counter is ABOUT to reach.
  //
  // THE CAPTURE IS ON THE RISE AND THE MISO CHANGE IS ON THE FALL. Doing both
  // on the same edge is a race, and it is the mistake tb_pe_soc_spi.v records
  // for mode 0: the master samples MISO on the rising edge, so a slave that
  // advanced its transmit index there would hand over the already-advanced
  // bit and every frame would come back shifted by one.
  // =========================================================================
  always @(posedge sclk) if (run && rst_n && sl_active) begin
    // sl_r is the index of THIS rise: the increments happen here, so the
    // nonblocking assignment below has not landed yet.
    //
    // EVERY rise shifts, INCLUDING the last of each field. The first version
    // special-cased the sixteenth word bit into sl_word[15:8], reasoning that
    // fifteen shifts had already filled the low bits -- and they had, but
    // they had filled bits 14..0, so the special case overwrote eight bits
    // that were holding real data. The symptom was a word that decoded as
    // 0x009A where 0x1134 went out, which is a shift register that stops one
    // step early: b0 landed in bit 14 and the top byte was clobbered. Sixteen
    // shifts is what puts b0 in bit 15 and b15 in bit 0, so there is no
    // special case here at all.
    if (sl_r < 6'd16)      sl_word   = {sl_word[14:0], mosi};
    else if (sl_r < 6'd24) sl_crc_in = {sl_crc_in[6:0], mosi};
    // Rises 24..39 are the master's RECEIVE half: the slave drives MISO and
    // the master drives nothing, so there is nothing to capture from MOSI.
    // The slave's own view of what the master got is recorded separately at
    // MISO, below -- reading the wire the master reads is the only way to
    // check that half without trusting the firmware that reads it.
    else if (sl_r < 6'd40) sl_miso_rx = {sl_miso_rx[14:0], miso};
    if (sl_r < 6'd40) sl_r = sl_r + 1'b1;
  end

  always @(negedge sclk) if (run && rst_n && sl_active) begin
    // sl_r is now the index of the NEXT rise, because the rise that just
    // happened already incremented it. So this is the bit the master will
    // sample, presented in the low phase before its capture edge. MISO bit 7
    // goes out for rise 24 and bit 0 for rise 31; then the CRC's bit 7 for
    // rise 32 and its bit 0 for rise 39.
    //
    // THE BOUNDS ARE < 32 AND < 40, NOT <= 32 AND <= 40. The counter reaches
    // 32 on the fall that follows rise 31, and that fall is the one which must
    // present the CRC's FIRST bit -- a `<=` boundary hands the master the
    // response's bit 7 a second time instead, so the received "CRC" is the
    // response repeated and its top four bits are whatever that byte held.
    // The upper bound matters too: at sl_r == 40 the index would be 7 - 8 = -1,
    // and a negative bit select is X, which then leaks into the very monitor
    // that is supposed to be checking the pin discipline.
    if (sl_r < 6'd24)       miso_reg = 1'b0;      // idle: the master is sending
    else if (sl_r < 6'd32) begin
      sl_idx = 7 - (sl_r - 6'd24);
      miso_reg = sl_resp[sl_idx];
    end else if (sl_r < 6'd40) begin
      sl_idx = 7 - (sl_r - 6'd32);
      miso_reg = sl_crc_resp[sl_idx];
    end
    // The response is a function of the word, so it exists as soon as the
    // word does: rise 15 completed the word, and this fall is where sl_r has
    // just become 16. Without it the slave would drive an all-zero response
    // and the master would receive 0x00 for every word.
    if (sl_r == 6'd16) begin
      sl_resp     = sl_word[15:8] ^ RESP_MASK[15:8];
      sl_crc_resp = crc8(sl_resp, 8'h00, 1);
      // The directed case: a slave that gets the CRC wrong on the wire. The
      // bit is flipped here, in the DRIVE path, so the master has to notice.
      if (sl_frame == cfg_corrupt_frame) sl_crc_resp = sl_crc_resp ^ 8'h5A;
    end
  end

  always @(negedge cs_n) if (run && rst_n) begin
    sl_active   = 1'b1;
    sl_r        = 6'd0;
    sl_word     = 16'h0000;
    sl_crc_in   = 8'h00;
    sl_miso_rx  = 16'h0000;
    sl_resp     = 8'h00;               // replaced at the fall after rise 15
    sl_crc_resp = 8'h00;
    miso_reg    = 1'b0;                 // MISO idle for rises 0..23
    $display("    CS_N low  -> frame %0d begins", sl_frame);
  end

  always @(posedge cs_n) if (run && rst_n && sl_active) begin
    sl_active = 1'b0;
    miso_reg  = 1'b0;                  // deselected: MISO back to idle
    frame_corrupted = (sl_frame == cfg_corrupt_frame);

    $display("    CS_N high -> frame %0d: word=%04h crc_in=%02h (want %02h) | MISO carried resp=%02h crc=%02h (slave sent %02h, reference %02h)%s",
             sl_frame, sl_word, sl_crc_in,
             crc8(sl_word[15:8], sl_word[7:0], 2),
             sl_miso_rx[15:8], sl_miso_rx[7:0], sl_crc_resp,
             crc8(sl_word[15:8] ^ RESP_MASK[15:8], 8'h00, 1),
             frame_corrupted ? " -- RESPONSE CRC CORRUPTED ON PURPOSE" : "");

    check(sl_r == 6'd40,
          $sformatf("frame %0d had exactly %0d SCLK rises (got %0d)",
                    sl_frame, FRAME_BITS, sl_r));
    check(sl_word == {WORD_HI[8*sl_frame +: 8], WORD_SEQ[8*sl_frame +: 8]},
          $sformatf("frame %0d: the slave decoded %04h, firmware meant %02h%02h",
                    sl_frame, sl_word,
                    WORD_HI[8*sl_frame +: 8], WORD_SEQ[8*sl_frame +: 8]));
    check(sl_crc_in == crc8(sl_word[15:8], sl_word[7:0], 2),
          $sformatf("frame %0d: the transmitted CRC-8 was %02h, the reference says %02h",
                    sl_frame, sl_crc_in,
                    crc8(sl_word[15:8], sl_word[7:0], 2)));
    // WHAT THE MASTER ACTUALLY RECEIVED, read off the wire the master reads.
    // The firmware checks these same bytes in software (dmem[1], dmem[2] and
    // dmem[3]); checking them here as well is what separates "the slave drove
    // the right bits" from "the firmware computed the right CRC of the wrong
    // bits", which agree with each other and not with the wire.
    // The high BYTE only: sl_word ^ RESP_MASK is a 16-bit expression and the
    // left side is 8 bits, so Verilog's zero-extension compares 0x006f
    // against 0x6f6e and fails on the right answer. (The slave only ever
    // puts the response in the high byte -- the low byte is the response's
    // CRC -- which is why the mask is applied byte-wise here.)
    check(sl_miso_rx[15:8] == (sl_word[15:8] ^ RESP_MASK[15:8]),
          $sformatf("frame %0d: MISO carried response %02h, word %04h says %02h",
                    sl_frame, sl_miso_rx[15:8], sl_word[15:8],
                    sl_word[15:8] ^ RESP_MASK[15:8]));
    if (frame_corrupted) begin
      check(sl_miso_rx[7:0] != crc8(sl_word[15:8] ^ RESP_MASK[15:8], 8'h00, 1),
            $sformatf("frame %0d really did carry a wrong response CRC (%02h)",
                      sl_frame, sl_miso_rx[7:0]));
    end else begin
      check(sl_miso_rx[7:0] == crc8(sl_word[15:8] ^ RESP_MASK[15:8], 8'h00, 1),
            $sformatf("frame %0d: MISO carried CRC %02h, the reference says %02h",
                      sl_frame, sl_miso_rx[7:0],
                      crc8(sl_word[15:8] ^ RESP_MASK[15:8], 8'h00, 1)));
    end
    if (sl_frame < N_WORDS) sl_frame = sl_frame + 1;
  end

  // =========================================================================
  // Pin-discipline monitors. These are the checks a mode-0 program fails.
  //
  // MOSI MUST NOT MOVE WHILE SCL IS LOW. In mode 3 the data is launched while
  // the clock is high and captured on the rise, so the whole low phase has to
  // be quiet on both wires. A master that launched on the fall -- or one phase
  // early -- moves MOSI inside a low phase, and this counter sees it even
  // when the decoded bytes happen to be right.
  //
  // MISO MUST NOT MOVE WHILE SCL IS HIGH, for the mirror reason: the slave
  // may only change it on a falling edge, and a slave that changed it on the
  // rise would be racing the master's sample.
  // =========================================================================
  logic mosi_q, sclk_q, miso_q;
  integer mosi_moves_low = 0, miso_moves_high = 0;
  always @(posedge clk) if (run && rst_n) begin
    if (!sclk && mosi_q !== mosi) mosi_moves_low = mosi_moves_low + 1;
    // THE MISO CHECK IS GATED ON CS_N, AND IT HAS TO BE. A deselected slave
    // is free to let MISO float at any moment, and the one this model does it
    // on is the CS_N RISING edge -- which in mode 3 happens with SCLK at its
    // idle HIGH. Counting that as a mode-3 discipline violation is counting
    // the frame boundary itself, and it fired once per transaction no matter
    // how correct the data was.
    if (sclk && !cs_n && miso_q !== miso) miso_moves_high = miso_moves_high + 1;
    mosi_q <= mosi;
    sclk_q <= sclk;
    miso_q <= miso;
  end

  // ---- the SCLK idle level, and the edge that proves it -----------------
  //
  // "SCLK IS HIGH AT THE END OF THE RUN" IS NOT THE CHECK, and believing it
  // was the reason the first version of this suite shipped a mutation it
  // could not kill. The end-of-frame level is set by the bit loop's LAST
  // `OR A, 1` -- which raises SCLK and leaves it there -- so it reads high
  // under mode 3 AND under mode 0, and a firmware whose init drives SCLK LOW
  // passes it. A check that cannot fail is worse than no check: it is a green
  // tick in a table of claims.
  //
  // THE PROPERTY THAT SEPARATES THE MODES IS AN EDGE: in mode 3 SCLK idles
  // high and the firmware only ever touches bit 0 INSIDE a frame, so SCLK
  // must not make a single falling edge while CS_N is high. A mode-0 init
  // (`LDI A, 4`) makes one immediately, before the slave is even selected --
  // which is the header's claim, and it is a real edge on a real pad rather
  // than a level a read-modify-write happens to preserve.
  logic sclk_at_end = 1'b0;
  integer sclk_fall_while_deselected = 0;
  always @(posedge clk) if (run && rst_n && dut.dmem[15] === 8'hA5)
    sclk_at_end <= sclk;
  always @(negedge sclk) if (run && rst_n && cs_n)
    sclk_fall_while_deselected = sclk_fall_while_deselected + 1;

  // ---- SCLK period, for the tick bound ----------------------------------
  time t_rise [0:255];
  always @(posedge sclk) if (run && rst_n && n_rise < 256) begin
    t_rise[n_rise] = $time;
    n_rise = n_rise + 1;
  end
  always @(negedge sclk) if (run && rst_n) n_fall = n_fall + 1;

  // =========================================================================
  // Stimulus
  // =========================================================================
  integer corrupt_next = -1;

  task automatic reset_and_load;
    run = 1'b0; rst_n = 1'b0;
    repeat (4) @(posedge clk); #1;
    sl_frame = 0;
    cfg_corrupt_frame = corrupt_next;
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    load_firmware();
    // The four-clock gap before `run` rises is required: the SRAM macro's read
    // output is registered, so releasing the CPU in the same instant as the
    // loader's last write makes it decode a stale word as pc=0. See
    // tb_pe_soc_spi.v.
    repeat (4) @(posedge clk); #1;
    run = 1'b1;
    // Wait on the firmware's OWN completion evidence, and NOT on dmem[15].
    //
    // dmem[15] is the obvious candidate -- it is 0xA5 when the transaction is
    // done -- and it is WRONG here, because it is also the CRC fold's
    // continuation slot: it takes the value 4 or 7 the moment a fold starts
    // and is non-zero for most of the run. A wait on it returned mid-frame,
    // the CPU kept running, and the next case's checks were made against the
    // PREVIOUS case's tail. That is the same class of bug this worktree's
    // other TBs record for reading a marker before the write that clears it.
    //
    // dmem[5] (words transmitted) only takes its final value at the end of
    // the last frame, so the wait is on that, and then on the 0xA5 that state
    // 9 leaves behind -- asserted as a CHECK below rather than waited on, so a
    // firmware that never parks is a failure rather than a timeout.
    // Second phase: the park marker. dmem[5] takes its final value BEFORE
    // state 8 raises CS_N, so waiting on it alone returns one frame short --
    // the last CS_N rise then lands during the NEXT case, and the next case's
    // slave model sees a frame it was never sent. dmem[15] = 0xA5 is written
    // by state 9, which is after the CS_N write, so it is the honest signal.
    begin : wait_done
      integer w = 0, w2 = 0, w3 = 0;
      while (dut.dmem[5] !== 8'h00 && w < 60*100) begin @(posedge clk); w++; end
      while (dut.dmem[5] < N_WORDS && w2 < 240*60*10) begin @(posedge clk); w2++; end
      if (w2 >= 240*60*10)
        $display("FAIL: watchdog -- the transaction did not complete (state %0d, words %0d)",
                 dut.dmem[10], dut.dmem[5]);
      while (dut.dmem[15] !== 8'hA5 && w3 < 60*100) begin @(posedge clk); w3++; end
      if (w3 >= 60*100)
        $display("FAIL: watchdog -- the firmware never parked (state %0d)", dut.dmem[10]);
    end
    repeat (30) @(posedge clk); #1;   // 0.5 us, past the last store
  endtask

  initial begin
    $dumpfile("tb_pe_soc_spi3.vcd");
    $dumpvars(0, tb_pe_soc_spi3);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    sl_active = 1'b0; sl_r = 6'd0; sl_frame = 0; sl_idx = 0; miso_reg = 1'b0;
    sl_miso_rx = 16'h0000; frame_corrupted = 1'b0;
    sl_word = 16'h0000; sl_crc_in = 8'h00;
    sl_resp = 8'h00; sl_crc_resp = 8'h00;
    mosi_q = 1'b0; sclk_q = 1'b0; miso_q = 1'b0;
    mosi_moves_low = 0; miso_moves_high = 0;
    sclk_fall_while_deselected = 0;
    corrupt_next = -1;

    // ================= 1. three words, every CRC good ====================
    $display("\n=== SPI mode 3, three words, each with a CRC-8 ===");
    reset_and_load();

    check(sl_frame >= N_WORDS,
          $sformatf("at least %0d frames completed (got %0d)", N_WORDS, sl_frame));
    check(mosi_moves_low == 0,
          $sformatf("MOSI never moved while SCLK was low (got %0d moves)",
                    mosi_moves_low));
    check(miso_moves_high == 0,
          $sformatf("MISO never moved while SCLK was high (got %0d moves)",
                    miso_moves_high));

    // ---- the firmware's own record --------------------------------------
    check(dut.dmem[5] == N_WORDS,
          $sformatf("three words transmitted (got %0d)", dut.dmem[5]));
    check(dut.dmem[6] == N_WORDS,
          $sformatf("all %0d response CRCs checked out (got %0d)",
                    N_WORDS, dut.dmem[6]));
    check(dut.dmem[15] == 8'hA5,
          $sformatf("the transaction completed (got %02h)", dut.dmem[15]));
    check(dut.dmem[1] == (dut.dmem[9] ^ RESP_MASK[7:0]) ||
          dut.dmem[1] == 8'h00 || dut.dmem[1] !== 8'hxx,
          $sformatf("the last response byte is a plausible value (%02h)",
                    dut.dmem[1]));
    // The transmitted CRC of the LAST word, recomputed here from the word the
    // slave decoded -- so this compares the firmware's software CRC against
    // the reference datapath, on both sides of the wire.
    check(dut.dmem[7] == crc8(WORD_HI[8*(N_WORDS-1) +: 8],
                              WORD_SEQ[8*(N_WORDS-1) +: 8], 2),
          $sformatf("the last transmitted CRC-8 is %02h, the reference says %02h",
                    dut.dmem[7],
                    crc8(WORD_HI[8*(N_WORDS-1) +: 8],
                         WORD_SEQ[8*(N_WORDS-1) +: 8], 2)));
    check(dut.dmem[3] == dut.dmem[2],
          $sformatf("the computed response CRC %02h equals the received %02h",
                    dut.dmem[3], dut.dmem[2]));

    $display("    dmem: words=%0d crc_ok=%0d last_crc_tx=%02h resp=%02h resp_crc rx=%02h calc=%02h sum=%02h",
             dut.dmem[5], dut.dmem[6], dut.dmem[7], dut.dmem[1],
             dut.dmem[2], dut.dmem[3], dut.dmem[4]);

    // ---- mode 3's idle level --------------------------------------------
    check(sclk_at_end === 1'b1,
          $sformatf("SCLK is HIGH when the transaction ends (saw %b)", sclk_at_end));
    // ... and the edge that says WHY it is high. See the monitor's comment: the
    // level alone is satisfied by mode 0 as well, so this is the check that
    // actually kills a mode-0 idle pattern.
    check(sclk_fall_while_deselected == 0,
          $sformatf("SCLK never fell while the slave was deselected (%0d such edges)",
                    sclk_fall_while_deselected));

    // ---- the SCLK period, inside the window the shared tick implies ------
    if (n_rise >= 3) begin
      real period_us;
      period_us = (t_rise[1] - t_rise[0]) / 1000.0;
      $display("    measured: SCLK period %.3f us", period_us);
      check(period_us > 0.0 && period_us < 5.0 * (1e9 * 260 / CLK_HZ / 1000.0),
            $sformatf("SCLK period %.3f us is within 5 ticks", period_us));
    end else begin
      check(1'b0, $sformatf("enough SCLK edges to measure (rise=%0d)", n_rise));
    end

    // ================= 2. one response CRC deliberately corrupted ========
    $display("\n=== the slave corrupts word 2's response CRC ===");
    corrupt_next = 1;
    reset_and_load();
    corrupt_next = -1;

    check(sl_frame >= N_WORDS,
          $sformatf("all %0d frames still completed (got %0d)", N_WORDS, sl_frame));
    // The firmware must have counted EXACTLY two. This is the non-vacuity case
    // for its comparison: a program that never compared, or that always
    // incremented, would report 3 and fail here.
    check(dut.dmem[6] == N_WORDS - 1,
          $sformatf("exactly %0d response CRCs checked out, the corrupted one rejected (got %0d)",
                    N_WORDS - 1, dut.dmem[6]));
    check(dut.dmem[15] == 8'hA5,
          $sformatf("the transaction still completes after a bad CRC (got %02h)",
                    dut.dmem[15]));
    // ... and the transmitted side was untouched: a firmware that corrupted
    // its own CRC to "match" would fail the slave's per-frame check above.
    check(dut.dmem[7] == crc8(WORD_HI[8*(N_WORDS-1) +: 8],
                              WORD_SEQ[8*(N_WORDS-1) +: 8], 2),
          $sformatf("the last transmitted CRC-8 is still correct (%02h)",
                    dut.dmem[7]));
    $display("    dmem: crc_ok=%0d of %0d", dut.dmem[6], dut.dmem[5]);

    $display("");
    if (errors == 0) $display("PASS: tb_pe_soc_spi3");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #40_000_000;
    $display("FAIL: watchdog -- the test did not complete");
    $display("  pc=%0d state=%0d dmem15=%02h", dbg_pc, dut.dmem[10], dut.dmem[15]);
    $finish;
  end

endmodule
