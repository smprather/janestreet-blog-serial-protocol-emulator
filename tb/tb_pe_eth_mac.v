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

  // One half-cell: HALF consecutive samples at one level, walking the sample
  // edges explicitly (the DDR front end samples both edges of the 60 MHz
  // clock). The level is set just after the previous edge so it can never race
  // the DUT's capture.
  task automatic drive_half(input logic lvl);
    for (int k = 0; k < HALF; k++) begin
      rx_pin = lvl;
      if (k % 2 == 0) @(posedge clk); else @(negedge clk);
    end
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

  // ---- independently timed driver ---------------------------------------
  // Fixed delays, NOT the DUT clock. The edge-walking driver above cannot
  // expose a relative frequency error (it tracks the DUT), which is exactly
  // how a single-latch DDR capture stayed hidden until review 2. These tasks
  // drive a real wire whose half-cells need not equal 50 ns.
  task automatic drive_half_async(input logic lvl, input real half_ns);
    rx_pin = lvl;
    #(half_ns);
  endtask

  task automatic drive_cell_async(input bit b, input real half_ns);
    drive_half_async(lvl_of(b, 1'b1), half_ns);
    drive_half_async(lvl_of(b, 1'b0), half_ns);
  endtask

  task automatic send_byte_async(input logic [7:0] v, input real half_ns);
    for (int i = 0; i < 8; i++) drive_cell_async(v[i], half_ns);
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

  // Buffer ownership is driven by the TB. `buf_reset` returns the ring to
  // empty (only legal with nothing in flight); `buf_consume` advances the
  // consumer's read pointer to the address the TB names. Everything else
  // treats both as idle.
  logic        buf_reset = 1'b0;
  logic        buf_consume = 1'b0;
  logic [10:0] buf_consume_addr = 11'd0;

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
    .buf_consume(buf_consume), .buf_consume_addr(buf_consume_addr),
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

  // A type frame with `extra` (1-7) bits past the final byte boundary, and an
  // FCS recomputed so the CRC residue STILL MATCHES. The residue is not a
  // frame-length check: only byte alignment distinguishes this from a valid
  // frame. (F1 of reviews/2026-09-23/FIX-VERIFICATION.md.)
  task automatic partial_frame(input integer extra);
    logic [31:0] c;
    bit b;
    build_header(48'hFFFFFFFFFFFF, 16'h0806);
    for (int i = 0; i < 46; i++) frame[14+i] = 8'h31 + i[7:0];
    nframe = 60;
    c = ~ref_crc32(nframe);
    for (int k = 0; k < extra; k++) begin
      b = k[0];
      c = (c[0] ^ b) ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    end
    fcs = ~c;
    send_preamble;
    send_byte(8'hD5);
    for (int i = 0; i < nframe; i++) send_byte(frame[i]);
    for (int k = 0; k < extra; k++) drive_cell(k[0]);
    send_byte(fcs[7:0]);
    send_byte(fcs[15:8]);
    send_byte(fcs[23:16]);
    send_byte(fcs[31:24]);
    send_idle(24);
    repeat (6) @(posedge clk); #1;
  endtask


  task automatic send_frame_async(input real half_ns);
    for (int i = 0; i < 56; i++)
      drive_cell_async(i[0] ? 1'b0 : 1'b1, half_ns);   // 101010... wire pattern
    send_byte_async(8'hD5, half_ns);
    for (int i = 0; i < nframe; i++) send_byte_async(frame[i], half_ns);
    send_byte_async(fcs[7:0], half_ns);
    send_byte_async(fcs[15:8], half_ns);
    send_byte_async(fcs[23:16], half_ns);
    send_byte_async(fcs[31:24], half_ns);
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

    fbuf_raddr = '0;
    // Mark the region no legitimate frame reaches, so a rejected frame's
    // failure to write is directly observable. See plant_guard.
    TB_WE = 1'b0; TB_WADDR = '0; TB_WDATA = '0;
    plant_guard;

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
      read_and_check(11'd0, pay, 0, "frame 1");

      // ---- buffer ownership: a consume is non-destructive ----------------
      // The producer's pointer must not move; only room and rptr do.
      check(u_mac.rptr === 11'd0, "rptr starts at 0");
      buf_consume = 1'b1; buf_consume_addr = 11'd23;
      @(posedge clk); #1;
      buf_consume = 1'b0;
      repeat (2) @(posedge clk); #1;
      check(u_mac.rptr === 11'd23,
            $sformatf("consume: rptr=%0d want 23", u_mac.rptr));
      check(frame_ptr === 11'd46,
            $sformatf("consume moved the WRITE pointer to %0d", frame_ptr));
      check(u_mac.room === 12'd2025,
            $sformatf("consume: room=%0d want 2025", u_mac.room));

      // A duplicate consume frees nothing ...
      buf_consume = 1'b1; buf_consume_addr = 11'd23;
      @(posedge clk); #1;
      buf_consume = 1'b0;
      repeat (2) @(posedge clk); #1;
      check(u_mac.room === 12'd2025, "duplicate consume over-credited room");

      // ... and a backward address is ignored, not clamped: rptr and room
      // must stay consistent (over-crediting would hand out live memory).
      buf_consume = 1'b1; buf_consume_addr = 11'd0;
      @(posedge clk); #1;
      buf_consume = 1'b0;
      repeat (2) @(posedge clk); #1;
      check(u_mac.rptr === 11'd23, "backward consume moved rptr");
      check(u_mac.room === 12'd2025, "backward consume over-credited room");

    end

    // ================= frame 2: an ARP reply (EtherType) ================
    // THE ACCEPTANCE TEST. A 28-byte ARP payload, padded to 46 data bytes so
    // the frame meets 802.3's 64-byte minimum, field 0x0806 -- a TYPE, not a
    // length. A receiver that read it as a length would demand 2,054 bytes and
    // reject this frame, so this is the case that proves the two-kind handling.
    // (The pad is real: a TYPE frame's receiver cannot tell data from pad, so
    // frame_len reports the padded length, which is exactly what the wire
    // carried.)
    begin
      int pay  = 28;
      int data = 46;                 // 28 ARP + 18 pad = the 64-byte minimum
      for (int i = 0; i < pay; i++)  want[i] = 8'h10 + i[7:0];
      for (int i = pay; i < data; i++) want[i] = 8'hC0 + i[7:0];   // pad
      build_header(48'h020000000001, 16'h0806);          // ARP EtherType
      for (int i = 0; i < data; i++) frame[14+i] = want[i];
      nframe = 14 + data;            // 60 bytes + 4 FCS = 64
      fcs = ref_crc32(nframe);
    // Pulse buf_consume WHILE frame 2 is mid-payload, advancing partway
    // through the previous frame. A consume that
      // touched wptr would rebase this frame, and the read-back below would
      // return shifted bytes.
      fork
        begin
          // Bounded for the same reason as the collision watcher below: a
          // mutant that rejects this ARP frame at its header never reaches
          // S_PAYLOAD, and an unbounded wait would hang the whole TB (and be
          // mis-counted as a detected mutation by the timeout).
          bit hit;
          logic [10:0] wptr_before;
          hit = 1'b0;
          for (int guard = 0; guard < 20_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd2 && u_mac.pay_cnt >= 16'd5) begin
              hit = 1'b1;
              break;
            end
          end
          if (!hit) begin
            check(1'b0,
                  "mid-payload consume: no S_PAYLOAD after 20,000 cycles");
          end else begin
            wptr_before = frame_ptr;
            buf_consume      = 1'b1;
            buf_consume_addr = 11'd30;
            @(posedge clk); #1;
            buf_consume      = 1'b0;
            check(frame_ptr === wptr_before,
                  "mid-payload consume: producer pointer unchanged");
          end
        end
        send_frame(1'b1);
      join
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 2, $sformatf("ARP: frame_valid count = %0d, want 2", nvalid));
      check(nbad === 0,   $sformatf("ARP: frame_bad count = %0d, want 0", nbad));
      check(last_is_type === 1'b1, "ARP: frame_is_type must be 1");
      check(last_len === 16'd46, $sformatf("ARP: len = %0d, want 46 (data+pad)", last_len));
      // The payload starts where frame 1's payload ended.
      read_and_check(11'd46, data, 0, "ARP");

      // Consume frame 2 as well: rptr to 92, room back to full, wptr fixed.
      buf_consume = 1'b1; buf_consume_addr = 11'd92;
      @(posedge clk); #1;
      buf_consume = 1'b0;
      repeat (2) @(posedge clk); #1;
      check(u_mac.rptr === 11'd92,
            $sformatf("frame 2 consume: rptr=%0d want 92", u_mac.rptr));
      check(frame_ptr === 11'd92, "frame 2 consume moved the write pointer");
      check(u_mac.room === 12'd2048, "frame 2 consume: room back to full");
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

    // ================= frame 5: a big TYPE frame, ACCEPTED ==============
    // Fills the ring so the next test can reach the header bounds check. A
    // TYPE frame is used because it is the only kind that can be large: a
    // LENGTH field is below 0x0600, so a legal length frame tops out at 1,535
    // bytes and always fits a 2,048-byte ring that is only 92 bytes used.
    begin
      int pay = FILL_LEN;            // 1500
      for (int i = 0; i < pay; i++) want[i] = 8'h90 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);   // a TYPE field
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 3, $sformatf("fill frame: frame_valid = %0d, want 3", nvalid));
      check(nbad === 2,   $sformatf("fill frame: frame_bad = %0d, want 2 (unchanged)", nbad));
      // A type frame DOES store its FCS then wind back, so the start of the
      // next frame is header-less payload only: 92 + 1500.
      check(frame_ptr === 11'd92 + FILL_LEN[10:0],
            $sformatf("fill frame: pointer = %0d, want %0d", frame_ptr, 92 + FILL_LEN));
      read_and_check(11'd92, 32, 0, "fill frame (head)");
      read_and_check(FILL_LEN[10:0] + 11'd92 - 11'd32, 32, FILL_LEN - 32,
                     "fill frame (tail)");
    end

    // ================= frame 6: an oversize LENGTH frame is REJECTED =====
    // Now the ring is nearly full (92 + 1500 = 1592 used, 456 free), so a
    // legal 1,500-byte LENGTH frame cannot fit. It must be rejected AT THE
    // HEADER, before a single byte is written.
    //
    // THE POINT OF THIS TEST IS THAT THE BUFFER IS UNTOUCHED. The payload loop
    // has its own `room == 0` check, but by then bytes have landed, so a
    // rejected frame would leave debris inside the ring. Only the header check
    // keeps it out, and without this assertion removing the header check is
    // undetectable -- measured: that mutation survived an earlier version of
    // this TB that only checked the frame_bad count.
    begin
      int pay = 1500;
      for (int i = 0; i < pay; i++) want[i] = 8'h80 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h05DC);   // 1500: a LENGTH, and too big
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 3, $sformatf("oversize len: frame_valid = %0d, want 3 (unchanged)", nvalid));
      check(nbad === 3,   $sformatf("oversize len: frame_bad = %0d, want 3", nbad));
      check(frame_ptr === 11'd92 + FILL_LEN[10:0],
            $sformatf("oversize len: pointer = %0d, want %0d (untouched)",
                      frame_ptr, 92 + FILL_LEN));
      // THE ASSERTION THAT MATTERS: the region the rejected frame WOULD have
      // written must still hold the marker. With the header check removed, this
      // frame is accepted there and overwrites it -- which is exactly the
      // mutation this test exists to catch.
      check_guard("oversize len: no debris");
    end

    // ================= frame 7: a long TYPE frame is REJECTED ============
    // The other reachable overflow, and the one the per-byte room check is for:
    // a TYPE frame has no length to check at the header, so the bound is
    // enforced as the payload arrives and the pointer rolls back.
    begin
      int pay = BUF_OVER;
      for (int i = 0; i < pay; i++) want[i] = 8'h50 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);   // a TYPE field
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 3, $sformatf("oversize type: frame_valid = %0d, want 3 (unchanged)", nvalid));
      check(nbad === 4,   $sformatf("oversize type: frame_bad = %0d, want 4", nbad));
      check(frame_ptr === 11'd92 + FILL_LEN[10:0],
            $sformatf("oversize type: pointer = %0d, want %0d (rolled back)",
                      frame_ptr, 92 + FILL_LEN));
    end

    // ================= frame 8: a PADDED short LENGTH frame is ACCEPTED ===
    // 802.3 pads a length field under 46 bytes up to the 64-byte minimum, and
    // the FCS covers the pad. A receiver that jumps from the declared length
    // straight to the FCS folds the pad as if it were the FCS and rejects a
    // correctly formed frame -- measured before the S_PAD state existed: this
    // exact frame failed while the 46-byte control above passed.
    begin
      int pay      = 20;                 // declared length
      int wire_pay = 46;                 // 20 data + 26 pad = the minimum
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'h40 + i[7:0];
        frame[14+i] = want[i];
      end
      for (int i = pay; i < wire_pay; i++)
        frame[14+i] = 8'hC0 + i[7:0];    // pad, deliberately distinct from data
      build_header(48'hFFFFFFFFFFFF, 16'd20);
      nframe = 14 + wire_pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 4, $sformatf("padded: frame_valid = %0d, want 4", nvalid));
      check(nbad === 4,   $sformatf("padded: frame_bad = %0d, want 4 (unchanged)", nbad));
      check(last_len === 16'd20, "padded: frame_len must be the DECLARED length");
      check(last_is_type === 1'b0, "padded: a length field");
      // Only the 20 declared bytes are stored: a receiver that banked the pad
      // would report 46 and advance the pointer by 46.
      check(frame_ptr === 11'd92 + FILL_LEN[10:0] + 11'd20,
            $sformatf("padded: pointer = %0d, want %0d (pad not stored)",
                      frame_ptr, 92 + FILL_LEN + 20));
      read_and_check(11'd92 + FILL_LEN[10:0], pay, 0, "padded frame");
    end

    // ============ frame 9: oversize from EMPTY, then RECOVERY =============
    // THE BUG THIS CATCHES: the reclaim was `room + {1'b0, pay_cnt[AW-1:0]}`.
    // A frame that fills the whole 2,048-byte ring leaves pay_cnt = 2048 =
    // 11'h000, so the truncation added ZERO bytes back: room stayed 0 and every
    // later frame failed its header check until a reset. The 2,100-byte frame
    // below is what makes pay_cnt exactly 2,048 at the rejection. Frame 7 could
    // not catch it -- it starts with only 456 bytes free, so its pay_cnt is 456
    // and the low 11 bits are non-zero.
    begin
      int pay = 2100;                    // > BUF_BYTES
      buf_reset = 1'b1;
      repeat (2) @(posedge clk); #1;
      buf_reset = 1'b0;
      send_idle(24);                     // re-arm the inter-frame hunt gate
      repeat (4) @(posedge clk); #1;
      check(frame_ptr === 11'd0,
            $sformatf("after reclaim: pointer = %0d, want 0", frame_ptr));
      check(u_mac.room === 12'd2048,
            $sformatf("after reclaim: room = %0d, want 2048", u_mac.room));

      for (int i = 0; i < pay; i++) want[i] = 8'h70 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);   // a TYPE field: no header bound
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 4, "overflow from empty: frame_valid unchanged");
      check(nbad === 5,   $sformatf("overflow from empty: frame_bad = %0d, want 5", nbad));
      check(frame_ptr === 11'd0, "overflow from empty: pointer rolled back to 0");
      check(u_mac.room === 12'd2048,
            $sformatf("overflow from empty: room = %0d, want 2048 (reclaimed)",
                      u_mac.room));

      // RECOVERY: a valid frame immediately after must be accepted and stored.
      // With the truncating reclaim this frame is rejected at its header, so
      // the check below is the one that fails on the pre-fix RTL.
      for (int i = 0; i < 46; i++) begin
        want[i] = 8'h90 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      nframe = 14 + 46;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 5, $sformatf("recovery: frame_valid = %0d, want 5", nvalid));
      check(last_len === 16'd46, "recovery: len = 46");
      check(frame_ptr === 11'd46, $sformatf("recovery: pointer = %0d, want 46", frame_ptr));
      read_and_check(11'd0, 46, 0, "recovery frame");
    end

    // ============ frame 10: a valid-CRC RUNT must be REJECTED ============
    // The header is 14 bytes; this frame is ONLY those 14 bytes plus a correct
    // FCS, so the FCS bytes are consumed AS the length/type field and no payload
    // is stored. The folded bits are a complete, self-consistent 14-byte stream,
    // so the CRC residue matches -- CRC residue proves the bits are consistent,
    // not that a frame was there. Before structural validation the type-frame
    // success path then wound the write pointer back 4 bytes that had never been
    // stored: wptr underflowed to 2,044 and room grew to 2,052 in a 2,048-byte
    // buffer (measured, reviews/2026-09-22/REVIEW-2.md R2-2). The check that
    // matters is the ALLOCATION one: a rejected frame must leave room and
    // pointer exactly as they were.
    begin
      buf_reset = 1'b1;
      repeat (2) @(posedge clk); #1;
      buf_reset = 1'b0;
      send_idle(24);
      repeat (4) @(posedge clk); #1;
      for (int i = 0; i < 10; i++) frame[i] = 8'h31 + i[7:0];
      nframe = 10;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 5, "runt: frame_valid unchanged");
      check(nbad === 6,   $sformatf("runt: frame_bad = %0d, want 6", nbad));
      check(u_mac.room === 12'd2048,
            $sformatf("runt: room = %0d, want 2048 (untouched)", u_mac.room));
      check(frame_ptr === 11'd0,
            $sformatf("runt: pointer = %0d, want 0 (untouched)", frame_ptr));
    end

    // ============ frame 11: an INDEPENDENTLY timed frame ============
    // 49.995 ns half-cells (the review's faster-wire case), driven with fixed
    // delays so the waveform is not tied to the DUT clock at all. A single
    // transparent-high latch lost the falling-edge sample here whenever the
    // two captures raced at a rising edge; the review's sweep failed 34 of 102
    // phase/duration trials, every faster-wire one. The two-latch capture is
    // what makes this pass, and this is its permanent regression.
    begin
      int pay = 46;
      buf_reset = 1'b1;
      repeat (2) @(posedge clk); #1;
      buf_reset = 1'b0;
      send_idle(24);
      repeat (4) @(posedge clk); #1;
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'hB0 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame_async(49.995);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === 6, $sformatf("async: frame_valid = %0d, want 6", nvalid));
      check(last_len === 16'd46, "async: len = 46");
      check(frame_ptr === 11'd46,
            $sformatf("async: pointer = %0d, want 46", frame_ptr));
      read_and_check(11'd0, pay, 0, "async frame");
    end

    // ====== frames 12-15: 802.3 minimum size and byte alignment ==========
    // F1 of reviews/2026-09-23/FIX-VERIFICATION.md. The CRC residue matches on
    // all of these because the FCS was computed for them; what makes them
    // invalid is STRUCTURE. A type frame under 64 bytes total (14 header + 46
    // data + 4 FCS) is a runt, and a frame ending 1-7 bits into a byte is not
    // a frame. Rejected frames must leave the allocation untouched.
    begin
      // (a) 18 bytes total: header + FCS only.
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      nframe = 14;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nvalid === 6, "18-byte type runt: no frame_valid");
      check(nbad === 7,   $sformatf("18-byte type runt: frame_bad = %0d, want 7", nbad));
      check(u_mac.room === 12'd2048 && frame_ptr === 11'd0,
            "18-byte type runt: allocation untouched");

      // (b) 63 bytes total: header + 45 data + FCS, one byte under.
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < 45; i++) frame[14+i] = 8'h31 + i[7:0];
      nframe = 14 + 45;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nvalid === 6, "63-byte type runt: no frame_valid");
      check(nbad === 8,   $sformatf("63-byte type runt: frame_bad = %0d, want 8", nbad));
      check(u_mac.room === 12'd2048 && frame_ptr === 11'd0,
            "63-byte type runt: allocation untouched");

      // (c/d) a full-size TYPE frame that ends 1 and 7 bits into a byte.
      for (int extra = 1; extra <= 7; extra += 6) begin
        buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
        send_idle(24); repeat (4) @(posedge clk); #1;
        partial_frame(extra);
        check(nvalid === 6,
              $sformatf("partial byte +%0d: no frame_valid", extra));
        check(nbad === 9 + ((extra == 1) ? 0 : 1),
              $sformatf("partial byte +%0d: rejected", extra));
        check(u_mac.room === 12'd2048 && frame_ptr === 11'd0,
              $sformatf("partial byte +%0d: allocation untouched", extra));
      end
    end

    // ===== E1-1: a release that WRAPS the ring frees exactly its bytes =====
    // The producer reaches address 1996 (a 1996-byte TYPE payload stores 1996
    // bytes: the receiver also counts the 4 FCS bytes it receives, then winds
    // them back); the consumer releases it. A second 196-byte payload then
    // starts at 1996 and ends, after the same windback, at 144, so its release
    // wraps. The forward distance must be measured modulo BUF_BYTES (196). A
    // 12-bit (AW+1) subtraction instead produces 2244, which the
    // `freed <= used` guard rejects -- leaking all 196 bytes for the life of
    // the ring.
    begin
      int pay_a = 1996;              // stores 1996 bytes (TYPE frame)
      int pay_b = 196;               // stores 196 bytes, wrapping
      int nv0, nb0;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;

      // Frame A: fills the ring up to address 1996.
      for (int i = 0; i < pay_a; i++) want[i] = 8'h30 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);   // TYPE: no header bound
      for (int i = 0; i < pay_a; i++) frame[14+i] = want[i];
      nframe = 14 + pay_a;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 1, "wrap: frame A accepted");
      check(frame_ptr === 11'd1996,
            $sformatf("wrap: pointer after A = %0d, want 1996", frame_ptr));
      check(u_mac.room === 12'd52,
            $sformatf("wrap: room after A = %0d, want 52", u_mac.room));

      // Release frame A; the consumer is now at 1996.
      buf_consume = 1'b1; buf_consume_addr = 11'd1996;
      @(posedge clk); #1;
      buf_consume = 1'b0;
      repeat (2) @(posedge clk); #1;
      check(u_mac.rptr === 11'd1996,
            $sformatf("wrap: rptr after A = %0d, want 1996", u_mac.rptr));
      check(u_mac.room === 12'd2048,
            $sformatf("wrap: room after A release = %0d, want 2048", u_mac.room));

      // Frame B: 196 stored bytes, from 1996 across the wrap, ending at 144.
      for (int i = 0; i < pay_b; i++) want[i] = 8'h50 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      for (int i = 0; i < pay_b; i++) frame[14+i] = want[i];
      nframe = 14 + pay_b;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 2, "wrap: frame B accepted");
      check(frame_ptr === 11'd144,
            $sformatf("wrap: pointer after B = %0d, want 144", frame_ptr));
      check(u_mac.room === 12'd1852,
            $sformatf("wrap: room after B = %0d, want 1852", u_mac.room));

      // THE WRAP RELEASE: distance 196 with the address numerically below
      // rptr. Both rptr and room must move.
      buf_consume = 1'b1; buf_consume_addr = 11'd144;
      @(posedge clk); #1;
      buf_consume = 1'b0;
      repeat (2) @(posedge clk); #1;
      check(u_mac.rptr === 11'd144,
            $sformatf("wrap release: rptr = %0d, want 144 (release rejected)",
                      u_mac.rptr));
      check(u_mac.room === 12'd2048,
            $sformatf("wrap release: room = %0d, want 2048 (196 freed, was 1852)",
                      u_mac.room));
      check(nbad === nb0, "wrap: no rejects");
    end

    // ===== E1-2: consume coincident with a payload byte keeps both deltas ===
    // The consumer and the producer both update `room` on the same edge. The
    // consumer's rptr and the producer's wptr/pay_cnt updates must survive,
    // and `room` must move by +freed-1 -- not by the producer's -1 alone.
    // Before the fix the later S_PAYLOAD assignment overwrote the consume's
    // +freed (nonblocking: last assignment wins).
    begin
      int pay = 46;
      int nv0, nb0;
      bit synced;
      logic [11:0] room_before;
      logic [10:0] wptr_before;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;

      // Frame A: accepted and deliberately NOT released, so the consumer has
      // a nonzero distance to release while frame B is arriving. A LENGTH
      // frame: its FCS is not stored, so the allocation is exactly 46 bytes.
      for (int i = 0; i < pay; i++) want[i] = 8'h60 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 1, "collision: frame A accepted");
      check(frame_ptr === 11'd46, "collision: pointer after A = 46");
      check(u_mac.rptr === 11'd0 && u_mac.room === 12'd2002,
            $sformatf("collision: A left ring allocated (rptr=%0d room=%0d)",
                      u_mac.rptr, u_mac.room));

      // Frame B: pulse a nonzero consume exactly on a payload byte-write edge.
      for (int i = 0; i < pay; i++) want[i] = 8'h80 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      for (int i = 0; i < pay; i++) frame[14+i] = want[i];
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      fork
        begin
          // The byte that commits at the next posedge: fbuf_we is the DUT's
          // combinational byte-write enable, sampled in the cycle before it.
          // BOUNDED: a design that never reaches S_PAYLOAD (e.g. a mutant that
          // mis-sizes the TYPE field) would otherwise spin here forever and
          // the mutation harness would count the timeout as a detected
          // failure. The budget is far above the ~1.1k clocks a 64-byte frame
          // needs to reach its first payload byte.
          synced = 1'b0;
          for (int guard = 0; guard < 20_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd2 && u_mac.bit_cnt == 3'd7 && fbuf_we) begin
              synced = 1'b1;
              break;
            end
          end
          if (!synced) begin
            check(1'b0,
                  "collision: no payload byte-write edge within 20,000 cycles");
          end else begin
            room_before = u_mac.room;
            wptr_before = frame_ptr;
            buf_consume = 1'b1; buf_consume_addr = 11'd46;
            @(posedge clk); #1;
            buf_consume = 1'b0;
            repeat (2) @(posedge clk); #1;
            check(u_mac.rptr === 11'd46,
                  $sformatf("collision: rptr = %0d, want 46", u_mac.rptr));
            check(frame_ptr === wptr_before + 11'd1,
                  $sformatf("collision: wptr = %0d, want %0d",
                            frame_ptr, wptr_before + 11'd1));
            check(u_mac.room === room_before + 12'd46 - 12'd1,
                  $sformatf("collision: room = %0d, want %0d (=%0d+46-1)",
                            u_mac.room, room_before + 12'd46 - 12'd1,
                            room_before));
          end
        end
        send_frame(1'b1);
      join
      send_idle(24);
      repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 2, "collision: frame B accepted");
      check(nbad === nb0, "collision: no rejects");
    end

    // ===== E1-2: consumer credit survives producer settle/rollback =========
    // A consume may coincide with the final S_SETTLE room assignment or with
    // S_ERR's reclaim. These are separate nonblocking assignments from the
    // payload-byte case above; dropping consume_credit at any site advances
    // rptr without returning the released space to room.
    begin
      int pay = 46;
      int nv0, nb0;
      logic [11:0] room_before;
      bit synced;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'h96 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 1, "settle type: release target accepted");
      check(frame_ptr === 11'd46, "settle type: release target ends at 46");
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'hA6 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      fork
        begin
          synced = 1'b0;
          for (int guard = 0; guard < 20_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd5 && u_mac.settle == 2'd2) begin
              synced = 1'b1;
              break;
            end
          end
          if (!synced) check(1'b0, "settle type: no verdict cycle");
          else begin
            room_before = u_mac.room;
            buf_consume = 1'b1; buf_consume_addr = 11'd46;
            @(posedge clk); #1;
            buf_consume = 1'b0;
            repeat (2) @(posedge clk); #1;
            check(u_mac.rptr === 11'd46, "settle type: rptr");
            check(u_mac.room === room_before + 12'd46 + 12'd4,
                  "settle type: room keeps consume credit and FCS reclaim");
          end
        end
        send_frame(1'b1);
      join
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 2, "settle type: frame accepted");
      check(nbad === nb0, "settle type: no rejects");
      check(u_mac.published_used === 12'd46,
            $sformatf("settle type: published_used=%0d, want 46",
                      u_mac.published_used));
    end

    // A length-frame completion and consume can share the same settle edge.
    // The old committed frame is released as the new frame is published, so
    // published_used must finish at exactly the new frame's 46 bytes.
    begin
      int pay = 46;
      int nv0, nb0;
      logic [11:0] room_before;
      bit synced;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'hD6 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(u_mac.published_used === 12'd46,
            "settle length: prior frame published");

      for (int i = 0; i < pay; i++) begin
        want[i] = 8'hE6 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      fork
        begin
          synced = 1'b0;
          for (int guard = 0; guard < 20_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd5 && u_mac.settle == 2'd2) begin
              synced = 1'b1;
              break;
            end
          end
          if (!synced) check(1'b0, "settle length: no verdict cycle");
          else begin
            room_before = u_mac.room;
            buf_consume = 1'b1; buf_consume_addr = 11'd46;
            @(posedge clk); #1;
            buf_consume = 1'b0;
            check(u_mac.rptr === 11'd46, "settle length: rptr");
            check(u_mac.published_used === 12'd46,
                  $sformatf("settle length: published_used=%0d, want 46",
                            u_mac.published_used));
            check(u_mac.room === room_before + 12'd46,
                  "settle length: consumer credit retained");
          end
        end
        send_frame(1'b1);
      join
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 2, "settle length: both frames accepted");
      check(nbad === nb0, "settle length: no rejects");
    end

    begin
      int pay = 46;
      int nv0, nb0;
      logic [11:0] room_before;
      bit synced;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'hB6 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(u_mac.room === 12'd2002, "settle bad: setup allocation");
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'hC6 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe) ^ 32'h0000_0001;
      fork
        begin
          synced = 1'b0;
          for (int guard = 0; guard < 20_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd5 && u_mac.settle == 2'd2) begin
              synced = 1'b1;
              break;
            end
          end
          if (!synced) check(1'b0, "settle bad: no verdict cycle");
          else begin
            room_before = u_mac.room;
            buf_consume = 1'b1; buf_consume_addr = 11'd23;
            @(posedge clk); #1;
            buf_consume = 1'b0;
            repeat (2) @(posedge clk); #1;
            check(u_mac.rptr === 11'd23, "settle bad: rptr");
            check(u_mac.room === room_before + 12'd23 + 12'd50,
                  "settle bad: room keeps consume credit and frame reclaim");
            check(u_mac.published_used === 12'd23,
                  $sformatf("settle bad: published_used=%0d, want 23",
                            u_mac.published_used));
          end
        end
        send_frame(1'b1);
      join
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nbad === nb0 + 1, "settle bad: frame rejected");
      check(nvalid === nv0 + 1, "settle bad: setup frame accepted");
    end

    begin
      int nv0, nb0;
      logic [11:0] room_before;
      logic [11:0] reclaim_before;
      bit synced;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < 1500; i++) begin
        want[i] = 8'h40 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd1500);
      nframe = 14 + 1500;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(u_mac.room === 12'd548, "S_ERR collision: setup allocation");
      for (int i = 0; i < 1000; i++) frame[14+i] = 8'h80 + i[7:0];
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      nframe = 14 + 1000;
      fcs = ref_crc32(nframe);
      fork
        begin
          synced = 1'b0;
          for (int guard = 0; guard < 200_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd6) begin
              synced = 1'b1;
              break;
            end
          end
          if (!synced) check(1'b0, "S_ERR collision: no error cycle");
          else begin
            room_before = u_mac.room;
            reclaim_before = u_mac.pay_cnt[11:0];
            check(reclaim_before != 0,
                  "S_ERR collision: partial payload was allocated");
            buf_consume = 1'b1; buf_consume_addr = 11'd23;
            @(posedge clk); #1;
            buf_consume = 1'b0;
            repeat (2) @(posedge clk); #1;
            check(u_mac.rptr === 11'd23, "S_ERR collision: rptr");
            check(u_mac.room === room_before + 12'd23 + reclaim_before,
                  "S_ERR collision: room keeps consume credit and partial reclaim");
            check(u_mac.published_used === 12'd1477,
                  $sformatf("S_ERR collision: published_used=%0d, want 1477",
                            u_mac.published_used));
            check(frame_ptr === 11'd1500,
                  "S_ERR collision: partial frame rolled back");
          end
        end
        send_frame(1'b1);
      join
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nbad === nb0 + 1, "S_ERR collision: oversized frame rejected");
      check(nvalid === nv0 + 1, "S_ERR collision: setup frame accepted");
    end

    // A bad full-size TYPE frame allocates all 2,048 bytes before its CRC
    // verdict. The bad-settle reclaim must retain pay_cnt[AW], or room remains
    // zero and every later frame is rejected. Corrupt the FCS, check the
    // full-width reclaim, and prove a short recovery frame is accepted.
    begin
      int pay = 2044;
      int nv0, nb0;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'hD0 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe) ^ 32'h0000_0001;
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nbad === nb0 + 1, "bad full ring: corrupted TYPE frame rejected");
      check(u_mac.pay_cnt === 16'd2048,
            $sformatf("bad full ring: pay_cnt = %0d, want 2048", u_mac.pay_cnt));
      check(u_mac.room === 12'd2048,
            $sformatf("bad full ring: room = %0d, want full reclaim", u_mac.room));
      check(frame_ptr === 11'd0, "bad full ring: write pointer rolled back");

      for (int i = 0; i < 46; i++) begin
        want[i] = 8'hE0 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'd46);
      nframe = 14 + 46;
      fcs = ref_crc32(nframe);
      send_frame(1'b1);
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 1, "bad full ring: recovery frame accepted");
      check(frame_ptr === 11'd46, "bad full ring: recovery pointer");
    end

    // A consumer address must stop at the last published frame. The existing
    // `freed <= used` check also counts bytes of the frame currently arriving,
    // so an over-read can credit those bytes here and the later rollback or
    // TYPE FCS windback credits them a second time.
    begin
      int pay = 96;
      int nv0, nb0;
      bit synced;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'h31 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe) ^ 32'h0000_0001;
      fork
        begin
          synced = 1'b0;
          for (int guard = 0; guard < 200_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd2 && u_mac.pay_cnt == 16'd50) begin
              synced = 1'b1;
              break;
            end
          end
          if (!synced) check(1'b0, "unpublished bad frame: no 50-byte point");
          else begin
            buf_consume = 1'b1; buf_consume_addr = 11'd50;
            @(posedge clk); #1;
            buf_consume = 1'b0;
          end
        end
        send_frame(1'b1);
      join
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nbad === nb0 + 1, "unpublished bad frame: rejected");
      check(u_mac.rptr === 11'd0,
            "unpublished bad frame: consumer release ignored");
      check(u_mac.room === 12'd2048,
            $sformatf("unpublished bad frame: room=%0d, want 2048",
                      u_mac.room));
      check(frame_ptr === 11'd0, "unpublished bad frame: producer rolled back");
      check(nvalid === nv0, "unpublished bad frame: no published frame");
    end

    begin
      int pay = 96;
      int nv0, nb0;
      bit synced;
      nv0 = nvalid; nb0 = nbad;
      buf_reset = 1'b1; repeat (2) @(posedge clk); #1; buf_reset = 1'b0;
      send_idle(24); repeat (4) @(posedge clk); #1;
      for (int i = 0; i < pay; i++) begin
        want[i] = 8'h41 + i[7:0];
        frame[14+i] = want[i];
      end
      build_header(48'hFFFFFFFFFFFF, 16'h0806);
      nframe = 14 + pay;
      fcs = ref_crc32(nframe);
      fork
        begin
          synced = 1'b0;
          for (int guard = 0; guard < 200_000; guard++) begin
            @(posedge clk); #1;
            if (u_mac.state == 3'd5 && u_mac.settle == 2'd2) begin
              synced = 1'b1;
              break;
            end
          end
          if (!synced) check(1'b0, "unpublished type frame: no verdict cycle");
          else begin
            // This endpoint includes the four transient FCS bytes. It is not
            // consumable until the frame commits and the MAC winds them back.
            buf_consume = 1'b1; buf_consume_addr = 11'd100;
            @(posedge clk); #1;
            buf_consume = 1'b0;
          end
        end
        send_frame(1'b1);
      join
      send_idle(24); repeat (6) @(posedge clk); #1;
      check(nvalid === nv0 + 1, "unpublished type frame: accepted");
      check(nbad === nb0, "unpublished type frame: no rejects");
      check(u_mac.rptr === 11'd0,
            "unpublished type frame: consumer release ignored");
      check(frame_ptr === 11'd96,
            $sformatf("unpublished type frame: pointer=%0d, want 96", frame_ptr));
      check(u_mac.room === 12'd1952,
            $sformatf("unpublished type frame: room=%0d, want 1952",
                      u_mac.room));
      check(frame_len === 16'd96, "unpublished type frame: published length");
      check(u_mac.published_used === 12'd96,
            $sformatf("unpublished type frame: published_used=%0d, want 96",
                      u_mac.published_used));

      // The newly committed bytes become consumable after the verdict edge.
      buf_consume = 1'b1; buf_consume_addr = 11'd96;
      @(posedge clk); #1;
      buf_consume = 1'b0;
      repeat (2) @(posedge clk); #1;
      check(u_mac.rptr === 11'd96,
            "published type frame: consumer release accepted");
      check(u_mac.room === 12'd2048,
            $sformatf("published type frame: room=%0d, want 2048", u_mac.room));
    end

    if (errors == 0) $display("PASS: all checks");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
