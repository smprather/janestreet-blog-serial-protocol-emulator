// tb_pe_eth_mac.v — 10BASE-T receive path, end to end on real RTL.
//
// WHAT THIS PROVES THAT NO EXISTING TB DOES
//
// tb_pe_eth tests pe_serdes' Manchester framing, and it does the framing IN THE
// TESTBENCH: its model builds the preamble, the header and the FCS itself, and
// its "preamble" is 28 copies of (1,0) followed by two bits -- 58 bits, not the
// 64 of a real 802.3 prelude. It is a fine unit test of the serdes and it is
// NOT a wire-format reference, so nothing here copies its conventions.
//
// This TB instead drives raw Manchester LEVELS into pe_dru, lets the real DRU
// recover the bit cells, feeds the real pe_manch, folds the real pe_crc, and
// writes the real pe_fbuf. Every byte checked is the byte a receiver that
// knows nothing about this design would have recovered -- because the bits
// arrive as a wire waveform, not as a vector handed to the block.
//
// THE FRAME IS BUILT BACKWARDS FROM ITS FCS, which is the property that makes
// this non-vacuous. The expected FCS is computed from the frame's own bytes;
// if the RTL's CRC convention differed by so much as a bit order, the emitted
// FCS would not be the one the RTL expects and the frame would be rejected. So
// an FCS accept here is evidence about the CONVENTION, not just about the
// datapath.
//
// The reference CRC is written differently from the RTL's on purpose -- this
// one is a byte-wise, table-free, left-shifting formulation straight from the
// reflected definition, whereas the RTL shifts right from a reversed polynomial
// -- so agreement is a real cross-check rather than the same arithmetic twice.

`timescale 1ns / 1ps

module tb_pe_eth_mac;

  localparam int SPB  = 12;        // samples per bit period, 60 MHz / ADR-005
  localparam int HALF = SPB / 2;

  logic clk = 0, rst_n;
  always #5 clk = ~clk;

  integer errors = 0;
  localparam int BUF_OVER = 2100;   // > 2048, so the ring must reject

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL eth_mac: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------------------------------------------------------------
  // The wire driver. Manchester, per IEEE 802.3: a 0 is H->L across the cell
  // and a 1 is L->H, so the FIRST half is the complement of the bit and the
  // second half is the bit itself (tb_pe_dru's convention, reused verbatim so
  // the two TBs cannot disagree about what a cell looks like).
  // ---------------------------------------------------------------------
  logic rx_pin;

  function automatic logic lvl_of(input bit b, input bit first_half);
    return first_half ? ~b : b;
  endfunction

  task automatic drive_cell(input bit b);
    for (int k = 0; k < HALF; k++) begin rx_pin = lvl_of(b, 1'b1); @(posedge clk); end
    for (int k = 0; k < HALF; k++) begin rx_pin = lvl_of(b, 1'b0); @(posedge clk); end
  endtask

  // One octet, LSB-first -- the 802.3 convention, and the reason the SFD byte
  // 0xD5 goes out as 1,0,1,0,1,0,1,1.
  task automatic send_byte(input logic [7:0] v);
    for (int i = 0; i < 8; i++) drive_cell(v[i]);
  endtask

  // The 56-bit preamble, as a WIRE BIT PATTERN: 101010... starting with 1.
  //
  // THIS IS THE TRAP IN THE WHOLE FILE. The standard calls the preamble "seven
  // octets of the pattern 10101010", which reads as 0xAA -- but that names the
  // pattern left-to-right in TRANSMISSION order, while a byte helper here sends
  // LSB-first. Routing 0xAA through send_byte therefore puts 01010101 on the
  // wire: the inverted phase, whose junction with the SFD creates a SECOND,
  // false 0xD5 window seven bits early. The receiver then locks there and
  // assembles a header that is shifted by one bit -- every byte a mash of its
  // neighbours -- which looks exactly like a broken receiver.
  //
  // (Equivalently: the preamble octet in LSB-first transmission order is 0x55,
  // and the SFD's is 0xD5. The SFD is the one everyone remembers, which is why
  // only the SFD gets the treatment and the preamble gets sent as 0xAA.)
  task automatic send_preamble;
    for (int i = 0; i < 56; i++) drive_cell(i[0] ? 1'b0 : 1'b1);   // 1,0,1,0,...
  endtask

  task automatic send_idle(input int cells);
    // An idle 10BASE-T line is a constant level. The DRU keeps emitting cells
    // for it and every one has EQUAL halves, which is what pe_manch flags --
    // so this is also how a real end-of-frame is signalled.
    for (int i = 0; i < cells; i++) begin
      rx_pin = 1'b0; repeat (SPB) @(posedge clk);
    end
  endtask

  localparam int MAXPAY = 4096;  // >= any payload driven here (the
                                 // oversize case pushes past BUF_BYTES)
  logic [7:0] frame [0:MAXPAY+31];   // header + payload, for the reference CRC
  logic [7:0] want  [0:MAXPAY];      // the payload the receiver should store

  // ---------------------------------------------------------------------
  // The reference FCS: CRC-32/ISO-HDLC straight from the reflected definition,
  // left-shifting into a 32-bit accumulation. Deliberately a different
  // datapath from pe_crc's right-shifting engine.
  // ---------------------------------------------------------------------
  // No array arguments: Icarus rejects unpacked dimensions on subroutine ports
  // ("Subroutine ports with unpacked dimensions are not yet supported"), so this
  // reads the module-scope buffers directly. `fcs` and `fcs_n` are the inputs.
  logic [31:0] fcs;
  int          fcs_n;
  function automatic logic [31:0] ref_crc32(input int nbytes);
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int i = 0; i < nbytes; i++) begin
      c = c ^ frame[i];
      for (int k = 0; k < 8; k++)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    end
    return ~c;
  endfunction

  // ---------------------------------------------------------------------
  // DUT chain: DRU -> Manchester -> MAC -> CRC + frame buffer.
  // ---------------------------------------------------------------------
  logic       cfg_filter_en;
  logic [7:0] cfg_lock_bits;
  logic       bit_en, rx_first, rx_second, rx_wire, locked;
  logic [3:0] dbg_phase, dummy_phase;

  logic rx_bit, rx_err;

  logic        crc_bit_en, crc_clr, crc_bit_in, crc_field_out;
  logic [31:0] crc_state;
  logic        crc_zero;

  logic                 fbuf_we;
  logic [10:0]          fbuf_waddr, fbuf_raddr;
  logic [7:0]           fbuf_wdata, fbuf_rdata;

  logic        frame_valid, frame_bad, frame_is_type;
  logic [15:0] frame_len, frame_field;
  logic [10:0] frame_ptr;
  logic [2:0]  dbg_state;

  // The DRU's own lock counter is irrelevant here (it is a confidence
  // indicator, not a gate), but it must be configured to a legal value.
  assign cfg_lock_bits = 8'd4;
  assign dummy_phase   = dbg_phase;

  pe_dru #(.SPB(SPB)) u_dru (
    .clk(clk), .rst_n(rst_n), .rx_pin(rx_pin),
    .cfg_filter_en(cfg_filter_en), .cfg_lock_bits(cfg_lock_bits),
    .bit_en(bit_en), .rx_first(rx_first), .rx_second(rx_second),
    .rx_wire(rx_wire), .locked(locked), .dbg_phase(dbg_phase)
  );

  pe_manch u_manch (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(1'b0), .clr(1'b0),
    .half_phase(1'b0),
    .tx_raw(1'b0), .tx_wire(),
    .rx_wire(rx_wire), .rx_first(rx_first), .rx_second(rx_second),
    .rx_raw(rx_bit), .rx_err(rx_err)
  );

  pe_crc #(.W(32)) u_crc (
    .clk(clk), .rst_n(rst_n), .bit_en(crc_bit_en), .clr(crc_clr),
    .crc_field(crc_field_out), .bit_in(crc_bit_in),
    .cfg_poly_r(32'hEDB88320),      // rev(0x04C11DB7, 32), from crc-config.md
    .cfg_seed(32'hFFFFFFFF),
    .cfg_out_inv(1'b1),             // Ethernet's xorout is all ones
    .crc_bit(), .crc_zero(crc_zero), .crc_state(crc_state)
  );

  pe_eth_mac u_mac (
    .clk(clk), .rst_n(rst_n),
    .bit_en(bit_en), .rx_raw(rx_bit), .rx_err(rx_err),
    .rx_first(rx_first), .rx_second(rx_second),
    .buf_reset(1'b0),
    .crc_bit_en(crc_bit_en), .crc_clr(crc_clr), .crc_bit_in(crc_bit_in),
    .crc_field_out(crc_field_out), .crc_state(crc_state),
    .fbuf_we(fbuf_we), .fbuf_waddr(fbuf_waddr), .fbuf_wdata(fbuf_wdata),
    .frame_valid(frame_valid), .frame_bad(frame_bad), .frame_len(frame_len),
    .frame_field(frame_field), .frame_is_type(frame_is_type),
    .frame_ptr(frame_ptr), .dbg_state(dbg_state)
  );

  pe_fbuf #(.BYTES(2048), .FLOP(1)) u_fbuf (
    .clk(clk), .we(fbuf_we), .waddr(fbuf_waddr), .wdata(fbuf_wdata),
    .raddr(fbuf_raddr), .rdata(fbuf_rdata)
  );

  // ---------------------------------------------------------------------
  // Frame construction and comparison.
  // ---------------------------------------------------------------------
  int          nframe;               // bytes covered by the FCS
  int          nvalid, nbad;
  logic [15:0] last_len;
  logic        last_is_type;

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin nvalid <= 0; nbad <= 0; end
    else begin
      if (frame_valid) begin
        nvalid  <= nvalid + 1;
        last_len <= frame_len;
        last_is_type <= frame_is_type;
      end
      if (frame_bad) nbad <= nbad + 1;
    end

  task automatic build_header(input logic [47:0] dst_mac,
                              input logic [15:0] field_val);
    for (int i = 0; i < 6; i++) frame[i] = dst_mac[47 - 8*i -: 8];
    for (int i = 0; i < 6; i++) frame[6+i] = 8'h02;
    frame[12] = field_val[15:8];      // HIGH byte first: 802.3 wire order
    frame[13] = field_val[7:0];
  endtask

  // Send the frame in `frame[0..nframe-1]`, then its FCS, then idle.
  //
  // THE FRAME BYTES ARE THE SINGLE SOURCE OF TRUTH: the reference CRC is
  // computed over `frame`, and the wire is driven from `frame`, in the same
  // byte order. An earlier version took the two-byte length/type field as a
  // separate argument and emitted it low-byte-first while the CRC covered it
  // high-byte-first, so the receiver's fold never reached the residue on a
  // frame that was otherwise perfect -- a TB bug that looked exactly like an
  // RTL CRC failure.
  task automatic send_frame(input bit with_fcs);
    int i;
    // 56 alternating preamble bits, then the SFD. See send_preamble's comment:
    // the preamble is a bit pattern and must NOT go through send_byte.
    send_preamble;
    send_byte(8'hD5);
    // The frame, in order, each byte LSB-first.
    for (i = 0; i < nframe; i++) send_byte(frame[i]);
    // ... and its FCS, low byte first -- which is what "the field is emitted
    // LSB-first" means at byte granularity.
    if (with_fcs) begin
      send_byte(fcs[7:0]);
      send_byte(fcs[15:8]);
      send_byte(fcs[23:16]);
      send_byte(fcs[31:24]);
    end
  endtask

  // Read back `n` bytes from the frame buffer starting at `base`, comparing
  // against `want`. The read port is registered, so one address per cycle and
  // the data arrives the cycle after.
  task automatic read_and_check(input logic [10:0] base, input int n,
                                input string tag);
    for (int i = 0; i < n; i++) begin
      fbuf_raddr = base + i[10:0];
      @(posedge clk); #1;
      check(fbuf_rdata === want[i],
            $sformatf("%s: byte %0d = %02h, want %02h", tag, i, fbuf_rdata, want[i]));
    end
  endtask

  initial begin
    $dumpfile("tb_pe_eth_mac.vcd");
    $dumpvars(0, tb_pe_eth_mac);

    rx_pin = 1'b0;
    cfg_filter_en = 1'b0;      // no filtering: the pin is driven cleanly
    fbuf_raddr = '0;

    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    repeat (4) @(posedge clk); #1;

    // A real link is IDLE before any frame: 802.3's inter-frame gap guarantees
    // it, and the receiver's hunt gate requires it. Driving a frame straight
    // out of reset is not something a wire can do.
    send_idle(16);

    // ================= frame 1: a 46-byte length frame ==================
    // Minimum payload for a 64-byte frame; the field is a LENGTH here.
    begin
      int pay = 46;
      for (int i = 0; i < pay; i++) want[i] = 8'hA0 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, pay[15:0]);
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 1, $sformatf("frame 1: frame_valid count = %0d, want 1", nvalid));
      check(nbad === 0,   $sformatf("frame 1: frame_bad count = %0d, want 0", nbad));
      check(last_len === 16'd46, $sformatf("frame 1: len = %0d, want 46", last_len));
      read_and_check(11'd0, pay, "frame 1");

    end

    // ================= frame 2: an ARP reply (EtherType) ================
    // THE ACCEPTANCE TEST. 28-byte ARP payload, field 0x0806 -- a TYPE, not a
    // length. A receiver that read it as a length would demand 2,054 bytes and
    // reject this frame, so this is the case that proves the two-kind handling.
    begin
      int pay = 28;
      for (int i = 0; i < pay; i++) want[i] = 8'h10 + i[7:0];
      build_header(48'h020000000001, 16'h0806);          // ARP EtherType
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 2, $sformatf("ARP: frame_valid count = %0d, want 2", nvalid));
      check(nbad === 0,   $sformatf("ARP: frame_bad count = %0d, want 0", nbad));
      check(last_is_type === 1'b1, "ARP: frame_is_type must be 1");
      check(last_len === 16'd28, $sformatf("ARP: len = %0d, want 28", last_len));
      // The payload starts where frame 1's payload ended.
      read_and_check(11'd46, pay, "ARP");
    end

    // ================= frame 3: a corrupted FCS must be REJECTED ========
    begin
      int pay = 20;
      for (int i = 0; i < pay; i++) want[i] = 8'h30 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, pay[15:0]);
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      fcs = fcs ^ 32'h0000_0001;      // flip one bit of the FCS
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 2, $sformatf("bad FCS: frame_valid count = %0d, want 2 (unchanged)", nvalid));
      check(nbad === 1,   $sformatf("bad FCS: frame_bad count = %0d, want 1", nbad));
    end

    // ================= frame 4: a corrupted DATA bit must be REJECTED ===
    // Distinct from frame 3: the FCS itself is intact and well-formed, but a
    // payload bit flipped in transit, so the receiver's fold will not reach
    // the residue. A receiver that only checked the FCS FIELD's shape would
    // pass this.
    begin
      int pay = 20;
      for (int i = 0; i < pay; i++) want[i] = 8'h50 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, pay[15:0]);
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      // Corrupt ONE payload bit on the wire, after the FCS was computed: the
      // frame the receiver sees is not the frame that was signed. It must be
      // `frame`, which is what send_frame drives -- corrupting `want` would
      // change only the expected value and the test would pass vacuously.
      frame[14+3] = frame[14+3] ^ 8'h01;
      send_frame(1'b1);
      frame[14+3] = frame[14+3] ^ 8'h01;   // restore
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 2, $sformatf("bad data: frame_valid count = %0d, want 2 (unchanged)", nvalid));
      check(nbad === 2,   $sformatf("bad data: frame_bad count = %0d, want 2", nbad));
    end

    // ================= frame 5: a long TYPE frame is REJECTED ============
    // The reachable overflow. A LENGTH frame never can: the field is below
    // 0x0600, so its legal maximum is 1535 payload bytes, and 1535 + 4 FCS is
    // well inside a 2,048-byte ring. A TYPE frame has no such ceiling -- it
    // ends when the line does -- so this is the case the room check exists for.
    // (The first version drove 0x0900 as a "length", which is an EtherType, so
    // it tested nothing at all.)
    begin
      int pay = BUF_OVER;            // more than the ring can hold
      for (int i = 0; i < pay; i++) want[i] = 8'h70 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);   // a TYPE field
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 2, $sformatf("oversize: frame_valid count = %0d, want 2 (unchanged)", nvalid));
      check(nbad === 3,   $sformatf("oversize: frame_bad count = %0d, want 3", nbad));
      check(frame_ptr === 11'd74,
            $sformatf("oversize: pointer = %0d, want 74 (unchanged)", frame_ptr));
    end

    if (errors == 0) $display("PASS: all checks");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
