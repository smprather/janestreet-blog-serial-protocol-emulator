// Review 2 probe, derived from tb/tb_pe_eth_mac.v at 628e309.
// Active frame levels use fixed delays independent of the DUT clock.
`timescale 1ns / 1ps

module tb_pe_eth_mac;

  localparam int SPB  = 12;        // samples per bit period, 60 MHz / ADR-005
  localparam int HALF = SPB / 2;   // samples per half-cell (6)
  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;   // 16.667 ns; real, not rounded

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

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

  // Nominal 50 ns half-cell, independent of the DUT clock.
  task automatic drive_half(input logic lvl);
    rx_pin = lvl;
    #50;
  endtask

  task automatic drive_cell(input bit b);
    drive_half(lvl_of(b, 1'b1));
    drive_half(lvl_of(b, 1'b0));
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
      rx_pin = 1'b0; repeat (SPB/2) @(posedge clk);
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

  // Buffer reclaim is driven by the TB so the recovery test can return the
  // ring to empty without a full reset. Everything else treats it as idle.
  logic        buf_reset = 1'b0;

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
    .buf_reset(buf_reset),
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
    #2;
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
    $display("CONTROL valid46: valid=%0d bad=%0d len=%0d room=%0d ptr=%0d", nvalid, nbad, last_len, u_mac.room, frame_ptr);
    review_reset;
    review_frame(20, 46);
    $display("PADDED valid20: valid=%0d bad=%0d len=%0d room=%0d ptr=%0d", nvalid, nbad, last_len, u_mac.room, frame_ptr);
    check(nvalid == 1 && nbad == 0 && last_len == 20, "padded frame control");
    review_reset;
    for (int i = 0; i < 10; i++) frame[i] = 8'h31 + i[7:0];
    nframe = 10;
    fcs = ref_crc32(nframe);
    $display("RUNT transmitted tail FCS=%h, interpreted type=%h", fcs, {fcs[23:16], fcs[31:24]});
    send_frame(1);
    send_idle(96);
    repeat (6) @(posedge clk);
    #1;
    $display("RUNT only14 total: valid=%0d bad=%0d len=%0d room=%0d ptr=%0d type=%b", nvalid, nbad, last_len, u_mac.room, frame_ptr, last_is_type);
    check(nvalid == 0 && nbad == 1 && u_mac.room == 2048 && frame_ptr == 0, "runt must be rejected without changing buffer accounting");
    review_frame(46, 46);
    $display("POSTRUNT valid46: valid=%0d bad=%0d len=%0d room=%0d ptr=%0d", nvalid, nbad, last_len, u_mac.room, frame_ptr);
    check(nvalid == 1 && last_len == 46 && u_mac.room == 2002 && frame_ptr == 46, "valid frame after runt");
    if (errors != 0) $fatal(1, "MAC runt checks failed");
    $finish;
  end
endmodule
