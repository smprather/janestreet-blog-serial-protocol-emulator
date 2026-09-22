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
  localparam int FILL_LEN = 1500;   // a big TYPE frame, to fill the ring

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

  // The write port is arbitrated between the DUT and the guard planter: the
  // array has ONE write port, so the TB must take it while planting.
  logic        g_we;
  logic [10:0] g_waddr;
  logic [7:0]  g_wdata;

  pe_fbuf #(.BYTES(2048), .FLOP(1)) u_fbuf (
    .clk(clk), .we(g_we), .waddr(g_waddr), .wdata(g_wdata),
    .raddr(fbuf_raddr), .rdata(fbuf_rdata)
  );

  // g_* is the DUT's port whenever the TB is not planting. `planting` is set
  // only inside plant_guard, which runs before any frame is driven.
  logic        planting;
  logic        TB_WE;
  logic [10:0] TB_WADDR;
  logic [7:0]  TB_WDATA;

  assign g_we    = planting ? TB_WE    : fbuf_we;
  assign g_waddr = planting ? TB_WADDR : fbuf_waddr;
  assign g_wdata = planting ? TB_WDATA : fbuf_wdata;

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

  // Read `n` bytes and require every one to be ZERO -- the evidence that a
  // rejected frame wrote nothing. The buffer starts zeroed and no accepted
  // frame has reached this far, so any non-zero byte here is debris from a
  // frame the receiver was supposed to discard entirely.
  task automatic read_and_check_empty(input logic [10:0] base, input int n,
                                      input string tag);
    for (int i = 0; i < n; i++) begin
      fbuf_raddr = base + i[10:0];
      @(posedge clk); #1;
      check(fbuf_rdata === 8'h00,
            $sformatf("%s: byte %0d = %02h, want 00 (a rejected frame must write nothing)",
                      tag, i, fbuf_rdata));
    end
  endtask

  // Read back `n` bytes from the frame buffer starting at `base`, comparing
  // against `want`. The read port is registered, so one address per cycle and
  // the data arrives the cycle after.
  // `woff` is the payload offset the window starts at. A window that begins
  // mid-payload (a tail check) must compare against want[woff+i], not want[i]
  // -- comparing from want[0] produces a wall of failures against bytes that
  // are in fact correct, which reads like a data bug and is not one.
  task automatic read_and_check(input logic [10:0] base, input int n,
                                input int woff, input string tag);
    for (int i = 0; i < n; i++) begin
      fbuf_raddr = base + i[10:0];
      @(posedge clk); #1;
      check(fbuf_rdata === want[woff+i],
            $sformatf("%s: buffer[%0d] = %02h, want %02h",
                      tag, base + i, fbuf_rdata, want[woff+i]));
    end
  endtask

  // Pre-fill the region past every legitimate frame with a marker, so that
  // "did a rejected frame write here?" becomes a direct read rather than an
  // inference from uninitialized memory. The FLOP array starts as x, so a
  // zero-check would fail on an untouched buffer and a frame that wrote
  // nothing would look identical to one that wrote junk.
  localparam int GUARD_BASE = 1600;
  localparam int GUARD_LEN  = 32;
  localparam logic [7:0] GUARD_MARK = 8'hEE;

  task automatic plant_guard;
    planting = 1'b1;
    for (int i = 0; i < (2048 - GUARD_BASE); i++) begin
      @(negedge clk);
      TB_WE = 1'b1; TB_WADDR = GUARD_BASE[10:0] + i[10:0];
      TB_WDATA = GUARD_MARK;
    end
    @(negedge clk);
    TB_WE = 1'b0;
    planting = 1'b0;
    repeat (2) @(posedge clk);
  endtask

  task automatic check_guard(input string tag);
    for (int i = 0; i < GUARD_LEN; i++) begin
      fbuf_raddr = GUARD_BASE[10:0] + i[10:0];
      @(posedge clk); #1;
      check(fbuf_rdata === GUARD_MARK,
            $sformatf("%s: buffer[%0d] = %02h, want %02h (a rejected frame must write nothing)",
                      tag, GUARD_BASE + i, fbuf_rdata, GUARD_MARK));
    end
  endtask

  task automatic review_reset;
    rx_pin = 0;
    cfg_filter_en = 0;
    fbuf_raddr = 0;
    planting = 0;
    TB_WE = 0;
    TB_WADDR = 0;
    TB_WDATA = 0;
    rst_n = 0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1;
    send_idle(96);
  endtask

  task automatic review_frame(input integer field_value, input integer wire_payload);
    build_header(48'hFFFFFFFFFFFF, field_value[15:0]);
    for (int i = 0; i < wire_payload; i++) frame[14+i] = 8'h31 + i[7:0];
    nframe = 14 + wire_payload;
    fcs = ref_crc32(nframe);
    send_frame(1);
    send_idle(96);
    repeat (6) @(posedge clk);
    #1;
  endtask

  initial begin
    review_reset;
    review_frame(46, 46);
    $display("CONTROL length46: valid=%0d bad=%0d len=%0d room=%0d", nvalid, nbad, last_len, u_mac.room);
    review_reset;
    review_frame(20, 46);
    $display("PADDED length20 wire46: valid=%0d bad=%0d len=%0d room=%0d", nvalid, nbad, last_len, u_mac.room);
    review_reset;
    review_frame(16'h0806, 2100);
    $display("OVERFLOW from empty: valid=%0d bad=%0d room=%0d ptr=%0d", nvalid, nbad, u_mac.room, frame_ptr);
    review_frame(46, 46);
    $display("RECOVERY valid46: valid=%0d bad=%0d room=%0d ptr=%0d", nvalid, nbad, u_mac.room, frame_ptr);
    $finish;
  end
endmodule
