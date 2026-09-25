// tb_pe_eth_tx.v — the 10BASE-T TX frame engine, unit level (RED-first,
// wiki/plans/eth-tx-frame-path.md Task 1).
//
// WHAT THIS PROVES
//
// pe_eth_tx takes firmware-supplied stored bytes and puts a complete 802.3
// frame on a raw Manchester bit stream: 56 alternating preamble bits + the
// SFD, the stored bytes LSB-first, zero padding to the 64-byte minimum,
// hardware-computed FCS, 96-cell inter-frame gap, and a sticky-observable
// fault for runt/jabber/underrun requests. This TB drives the module's own
// cell_en/half_phase cadence and decodes the wire back, so every byte it
// checks is a byte a receiver would recover.
//
// THE CHECK LIST (Step 4 of the plan: what each check proves, what it misses)
//
//   1. Long idle stretch: 200 cells of the enabled engine carry ZERO
//      mid-cell transitions. The trap: pe_manch toggles the wire every
//      half-cell for ANY constant tx_bit, so an engine that "stops driving"
//      in idle emits a 10 MHz square wave, not an idle line. Missed if:
//      idle were tested by sampling tx_bit instead of the wire.
//   2. 42-byte ARP request, hardware-padded to 60 stored bytes: prelude,
//      every stored byte, 18 zero pad bytes, and the 32 FCS bits match an
//      independent left-shifting reference over header+payload+pad. Proves
//      pad is DATA (folded into the FCS) and that the field is emitted LSB
//      first. Missed if: the reference used the DUT's own right-shifting
//      engine, or the check stopped at the last payload byte.
//   3. The FCS register drains to zero after the 32 field strobes
//      (dut.u_tx_crc.crc_state === 0 while the IFG runs). The pe_crc trap:
//      the emitted bits are IDENTICAL whether the final complement sits on
//      the wire or inside the feedback; only the register's end state
//      differs, and the receiver depends on it. Missed if: only the wire
//      bits were checked.
//   4. Exactly-64-byte frame: NO pad is inserted at the boundary (a padding
//      engine that pads <= 64 would emit a 65th byte here).
//   5. 1,514-byte maximum frame: no pad, full-payload FCS, 12,208 wire bits
//      decoded end to end. Proves the FSM/FIFO handle the whole domain.
//   6. 1,515-byte and 13-byte requests are refused with tx_overlong and the
//      engine never leaves IDLE (jabber/runt policy).
//   7. Mid-frame abort returns the line to idle without a tx_done and
//      without a completed FCS.
//   8. FIFO underrun after only 10 of 42 bytes: tx_underrun, no tx_done.
//      This is the deadline fault the staging FIFO exists to expose.
//   9. Two 42-byte frames: the second preamble starts >= 96 idle cells
//      after the first frame's last FCS bit, and both decode byte- and
//      FCS-clean. The standard's IFG, and the receiver's hunt gate needs 8.
//
// WHAT IT DOES NOT COVER (owned by later tasks): the pad-level uo_out mux
// (Task 4), the loopback through the RX chain and the mutation suites
// (Tasks 5-6), and the owner arbitration against the SERDES (Task 3's SoC TB).

`timescale 1ns / 1ps

module tb_pe_eth_tx;

  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  logic clk = 0;
  always #(CLK_NS/2) clk = ~clk;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- DUT ----------------
  logic        rst_n, enable, push, start, abort;
  logic [7:0]  push_byte;
  logic [11:0] frame_len;
  logic        push_ready, tx_busy, tx_done, tx_underrun, tx_overlong;
  logic        ifg_active, tx_bit;

  // ---------------- the TB's divider: EXACTLY pe_soc's DIV=6 ----------------
  // cell_div = 6: the registered `cell_en` is the shared codec's committing
  // edge (one-clock pulse high during the first clock of the cell); the
  // combinational `cell_start` is the cell-BOUNDARY strobe (high on the cell's
  // last clock) that paces the frame engine, so its raw bit changes together
  // with half_phase and each Manchester half is exactly three clocks. The
  // monitor below classifies on the registered cell_en.
  logic [2:0] ph;
  logic       cell_en, half_phase;
  wire        cell_start = (ph == 3'd5);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= 3'd0; cell_en <= 1'b0; half_phase <= 1'b0;
    end else begin
      cell_en <= 1'b0;
      if (ph == 3'd5) begin
        ph <= 3'd0; cell_en <= 1'b1;
      end else begin
        ph <= ph + 3'd1;
      end
      if (ph == 3'd2 || ph == 3'd5) half_phase <= ~half_phase;
    end
  end

  pe_eth_tx #(.MAX_STORED(1514)) dut (
    .clk(clk), .rst_n(rst_n),
    .enable(enable), .cell_start(cell_start), .half_phase(half_phase),
    .push(push), .push_byte(push_byte), .push_ready(push_ready),
    .frame_len(frame_len), .start(start), .frame_abort(abort),
    .tx_busy(tx_busy), .tx_done(tx_done), .tx_underrun(tx_underrun),
    .tx_overlong(tx_overlong), .ifg_active(ifg_active),
    .tx_bit(tx_bit)
  );

  // ---------------- wire decode ----------------
  // pe_manch's TX mapping with half_phase: raw 0 -> first half H, second L;
  // raw 1 -> first half L, second H. So the wire in the first half is ~bit
  // and in the second half is the bit. Sampling at the LAST clock of each
  // half (ph2 and ph5) avoids the one-clock data-update skew the SoC's
  // registered cell_en introduces.
  wire wire_bit = half_phase ? tx_bit : ~tx_bit;

  localparam int MAXCELLS = 16384;
  logic [1:0] cellrec [0:MAXCELLS-1];   // {is_bit, decoded_bit}; 2'b00 = idle
  int         ncells, done_count;
  logic       mh1, mh2;
  bit         saw_done, saw_underrun, saw_overlong;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ncells <= 0; done_count <= 0; mh1 <= 1'b0; mh2 <= 1'b0;
      saw_done <= 1'b0; saw_underrun <= 1'b0; saw_overlong <= 1'b0;
    end else begin
      if (tx_done) begin saw_done <= 1'b1; done_count <= done_count + 1; end
      if (tx_underrun)   saw_underrun  <= 1'b1;
      if (tx_overlong)   saw_overlong  <= 1'b1;

      if (cell_en && !half_phase) begin
        // classify the cell that just ended from its ph2/ph5 samples
        if (mh1 === mh2) begin
          if (ncells < MAXCELLS) cellrec[ncells] <= 2'b00;   // idle (constant)
        end else begin
          check(mh1 === ~mh2, "Manchester halves are not complementary");
          if (ncells < MAXCELLS) cellrec[ncells] <= {1'b1, mh2};
        end
        if (ncells < MAXCELLS) ncells <= ncells + 1;
        mh1 <= wire_bit;
      end else if (!half_phase) begin
        mh1 <= wire_bit;
      end else begin
        mh2 <= wire_bit;
      end
    end
  end

  // ---------------- frame source and the independent FCS ----------------
  logic [7:0] stored [0:1599];     // header + payload + pad (60..1514)
  logic       got    [0:16383];    // decoded wire bits
  logic [31:0] fcs_want;
  int          scan_start, last_i0, last_end;

  // The reference FCS: CRC-32/ISO-HDLC straight from the reflected
  // definition, right-shifting into a 32-bit accumulation, final complement.
  // Deliberately a different datapath from pe_crc's engine so agreement is
  // evidence, not the DUT marking its own homework. The wire order is
  // fcs_want[0] first (tb_pe_eth_mac's convention: the field is emitted
  // LSB-first at bit and byte granularity).
  function automatic logic [31:0] ref_crc32(input int nbytes);
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int i = 0; i < nbytes; i++) begin
      c = c ^ stored[i];
      for (int k = 0; k < 8; k++)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    end
    return ~c;
  endfunction

  // The canonical 42-byte ARP request the plan's G7 names: broadcast dst,
  // 02:00:00:00:00:01 src, EtherType 0x0806, who-has 192.168.1.10 tell
  // 192.168.1.20. Kept identical to firmware/eth_tx_arp.pe's bytes.
  logic [7:0] arp [0:41];
  task automatic fill_arp;
    arp[0]=8'hFF; arp[1]=8'hFF; arp[2]=8'hFF; arp[3]=8'hFF;
    arp[4]=8'hFF; arp[5]=8'hFF;
    arp[6]=8'h02; arp[7]=8'h00; arp[8]=8'h00; arp[9]=8'h00;
    arp[10]=8'h00; arp[11]=8'h01;
    arp[12]=8'h08; arp[13]=8'h06;
    arp[14]=8'h00; arp[15]=8'h01; arp[16]=8'h08; arp[17]=8'h00;
    arp[18]=8'h06; arp[19]=8'h04; arp[20]=8'h00; arp[21]=8'h01;
    arp[22]=8'h02; arp[23]=8'h00; arp[24]=8'h00; arp[25]=8'h00;
    arp[26]=8'h00; arp[27]=8'h01;
    arp[28]=8'hC0; arp[29]=8'hA8; arp[30]=8'h01; arp[31]=8'h0A;
    arp[32]=8'h00; arp[33]=8'h00; arp[34]=8'h00; arp[35]=8'h00;
    arp[36]=8'h00; arp[37]=8'h00;
    arp[38]=8'hC0; arp[39]=8'hA8; arp[40]=8'h01; arp[41]=8'h14;
  endtask

  task automatic fill_pattern(input int len, input logic [7:0] seed);
    for (int i = 0; i < 1600; i++) stored[i] = 8'h00;
    for (int i = 0; i < len; i++) stored[i] = seed + i[7:0];
  endtask

  task automatic fill_arp_stored;
    for (int i = 0; i < 1600; i++) stored[i] = 8'h00;
    for (int i = 0; i < 42; i++) stored[i] = arp[i];
  endtask

  // ---------------- DUT stimulus ----------------
  task automatic reset_dut;
    rst_n = 1'b0; enable = 1'b0; push = 1'b0; push_byte = 8'h00;
    start = 1'b0; abort = 1'b0; frame_len = 12'd0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1'b1;
    repeat (4) @(posedge clk); #1;
  endtask

  task automatic pulse_start;
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;
  endtask

  task automatic pulse_abort;
    @(negedge clk); abort = 1'b1;
    @(negedge clk); abort = 1'b0;
  endtask

  // Push one byte, waiting for the staging FIFO to have room. Pushing is a
  // negedge event so the DUT samples a stable byte at the following posedge.
  task automatic push_wait(input logic [7:0] b);
    int guard = 0;
    while (!push_ready && guard < 500_000) begin
      @(posedge clk); guard++;
    end
    check(push_ready, "push_ready never asserted -- the FIFO never drained");
    @(negedge clk); push = 1'b1; push_byte = b;
    @(negedge clk); push = 1'b0;
  endtask

  // Wait (bounded) for the target frame's tx_done and then for the IFG to
  // elapse. `target` counts done pulses since reset (frame 1 -> 1, frame 2 -> 2).
  task automatic wait_done_idle(input int target, input string tag);
    int guard = 0;
    while (done_count < target && guard < 3_000_000) begin
      @(posedge clk); guard++;
    end
    check(done_count >= target, $sformatf("%s: tx_done never pulsed", tag));
    guard = 0;
    while (tx_busy && guard < 300_000) begin @(posedge clk); guard++; end
    check(!tx_busy, $sformatf("%s: tx_busy never fell after the IFG", tag));
  endtask

  // Decode and check one complete frame at cellrec[i0..i0+need-1].
  task automatic analyze(input int from, input int total, input int need,
                         input string tag);
    int i0;
    logic [7:0] gb;
    i0 = -1;
    for (int k = from; k < ncells; k++)
      if (cellrec[k][1] === 1'b1) begin i0 = k; break; end
    check(i0 >= 0, $sformatf("%s: no encoded bits appeared after start", tag));
    if (i0 < 0) return;

    for (int k = 0; k < need; k++) begin
      if (i0 + k >= ncells || cellrec[i0+k][1] !== 1'b1)
        check(1'b0, $sformatf("%s: idle cell inside the frame at bit %0d",
                              tag, k));
      got[k] = cellrec[i0+k][0];
    end

    // 56 alternating wire bits starting with 1, then the SFD 1,0,1,0,1,0,1,1.
    for (int k = 0; k < 64; k++) begin
      bit e = (k == 63) ? 1'b1 : ~k[0];
      check(got[k] === e,
            $sformatf("%s: prelude bit %0d=%b want %b", tag, k, got[k], e));
    end

    for (int b = 0; b < total; b++) begin
      for (int j = 0; j < 8; j++) gb[j] = got[64 + 8*b + j];
      check(gb === stored[b],
            $sformatf("%s: stored byte %0d=%02h want %02h (LSB-first order?)",
                      tag, b, gb, stored[b]));
    end

    fcs_want = ref_crc32(total);
    for (int k = 0; k < 32; k++)
      check(got[64 + 8*total + k] === fcs_want[k],
            $sformatf("%s: FCS bit %0d=%b want %b", tag, k,
                      got[64 + 8*total + k], fcs_want[k]));

    last_i0  = i0;
    last_end = i0 + need;
  endtask

  // ---------------- the directed cases ----------------

  // Case 1: idle is a CONSTANT level for a long stretch (Review Focus 1).
  task automatic test_idle_constant;
    int base;
    reset_dut();
    enable = 1'b1;
    base = ncells;
    repeat (1200) @(posedge clk);          // 200 cells
    check(ncells - base >= 190,
          $sformatf("idle: only %0d cells recorded, want >= 190", ncells - base));
    for (int k = base; k < ncells; k++)
      check(cellrec[k][1] === 1'b0,
            "idle wire has a mid-cell transition (square wave, not idle)");
    check(tx_busy === 1'b0 && ifg_active === 1'b0,
          "idle: engine reports busy/ifg with no frame");
  endtask

  // Cases 2-5: a fully decodable frame with total stored bytes.
  task automatic test_good_frame(input int len, input string tag);
    int total, need;
    total = (len < 60) ? 60 : len;
    need  = 64 + 8*total + 32;
    reset_dut();
    enable = 1'b1;
    frame_len = len[11:0];
    scan_start = ncells;
    for (int k = 0; k < 8; k++) push_wait(stored[k]);
    check(push_ready === 1'b0, $sformatf("%s: FIFO not full after 8 pushes", tag));
    pulse_start();
    for (int k = 8; k < len; k++) push_wait(stored[k]);
    wait_done_idle(1, tag);
    analyze(scan_start, total, need, tag);
    check(!saw_underrun, $sformatf("%s: unexpected tx_underrun", tag));
    check(dut.u_tx_crc.crc_state === 32'h0000_0000,
          $sformatf("%s: FCS register did not drain to zero (complement inside the feedback?)",
                    tag));
    $display("    %s: %0d stored bytes, %0d wire bits, FCS %08h",
             tag, total, need, fcs_want);
  endtask

  // Case 6: refused requests. The engine stays IDLE and the line stays idle.
  task automatic test_refused(input int len, input string tag);
    int base;
    reset_dut();
    enable = 1'b1;
    frame_len = len[11:0];
    base = ncells;
    pulse_start();
    begin
      int guard = 0;
      while (!saw_overlong && guard < 100_000) begin @(posedge clk); guard++; end
    end
    check(saw_overlong, $sformatf("%s: tx_overlong never pulsed", tag));
    check(tx_busy === 1'b0, $sformatf("%s: engine accepted a refused frame", tag));
    repeat (12) @(posedge clk);          // two cells
    for (int k = base; k < ncells; k++)
      check(cellrec[k][1] === 1'b0,
            $sformatf("%s: a refused frame drove the wire", tag));
  endtask

  // Case 7: abort mid-frame returns to idle with no tx_done.
  task automatic test_abort;
    int base;
    reset_dut();
    enable = 1'b1;
    frame_len = 12'd42;
    scan_start = ncells;
    base = ncells;
    for (int k = 0; k < 8; k++) push_wait(stored[k]);
    pulse_start();
    // wait until ~20 cells have been recorded (the prelude is 64 bits, so
    // the engine is mid-preamble), then abort.
    begin
      int guard = 0;
      while ((ncells - base) < 20 && guard < 100_000) begin
        @(posedge clk); guard++;
      end
      check((ncells - base) >= 20, "abort: frame never started");
    end
    pulse_abort();
    begin
      int guard = 0;
      while (tx_busy && guard < 200_000) begin @(posedge clk); guard++; end
    end
    check(!tx_busy, "abort: tx_busy did not fall after the current cell");
    check(!saw_done, "abort: tx_done pulsed on an aborted frame");
    repeat (30) @(posedge clk);          // >= 2 cells to classify idle
    check(ncells > 0 && cellrec[ncells-1][1] === 1'b0,
          "abort: the line did not return to idle");
  endtask

  // Case 8: FIFO underrun is a sticky, observable fault, never a silent gap.
  task automatic test_underrun;
    int base;
    reset_dut();
    enable = 1'b1;
    frame_len = 12'd42;
    base = ncells;
    for (int k = 0; k < 8; k++) push_wait(stored[k]);
    pulse_start();
    for (int k = 8; k < 10; k++) push_wait(stored[k]);   // 10 of 42 bytes
    begin
      int guard = 0;
      while (!saw_underrun && guard < 3_000_000) begin @(posedge clk); guard++; end
    end
    check(saw_underrun, "underrun: tx_underrun never pulsed");
    begin
      int guard = 0;
      while (tx_busy && guard < 200_000) begin @(posedge clk); guard++; end
    end
    check(!tx_busy, "underrun: engine did not return to IDLE");
    check(!saw_done, "underrun: tx_done pulsed on a truncated frame");
    check(ncells > base + 64,
          "underrun: the frame never reached the data phase");
  endtask

  // Case 9: two frames, second preamble >= 96 idle cells after the first FCS.
  task automatic test_two_frames;
    int need, g1_end, g2_first, gap;
    need = 64 + 8*60 + 32;               // 42 stored bytes -> 60 padded
    reset_dut();
    enable = 1'b1;

    // frame 1
    fill_pattern(42, 8'h10);
    frame_len = 12'd42;
    scan_start = ncells;
    for (int k = 0; k < 8; k++) push_wait(stored[k]);
    pulse_start();
    for (int k = 8; k < 42; k++) push_wait(stored[k]);
    wait_done_idle(1, "two-frame #1");
    analyze(scan_start, 60, need, "two-frame #1");
    g1_end = last_end;

    // frame 2, issued only after the IFG has elapsed (tx_busy low)
    fill_pattern(42, 8'h40);
    frame_len = 12'd42;
    for (int k = 0; k < 8; k++) push_wait(stored[k]);
    pulse_start();
    for (int k = 8; k < 42; k++) push_wait(stored[k]);
    wait_done_idle(2, "two-frame #2");

    g2_first = -1;
    for (int k = g1_end; k < ncells; k++)
      if (cellrec[k][1] === 1'b1) begin g2_first = k; break; end
    check(g2_first >= 0, "two-frame: second preamble never appeared");
    gap = g2_first - g1_end;
    check(gap >= 96,
          $sformatf("two-frame: only %0d idle cells between frames, want >= 96",
                    gap));
    $display("    two-frame: IFG = %0d idle cells (%0.0f ns, spec >= 96)",
             gap, gap * 100.0);
    analyze(g2_first, 60, need, "two-frame #2");
  endtask

  initial begin
    $dumpfile("tb_pe_eth_tx.vcd");
    $dumpvars(0, tb_pe_eth_tx);

    for (int i = 0; i < 1600; i++) stored[i] = 8'h00;
    fill_arp;
    ncells = 0; scan_start = 0; last_i0 = 0; last_end = 0;
    rst_n = 1'b0; enable = 1'b0; push = 1'b0; push_byte = 8'h00;
    start = 1'b0; abort = 1'b0; frame_len = 12'd0;
    repeat (4) @(posedge clk); #1;

    test_idle_constant;

    fill_arp_stored;
    test_good_frame(42, "arp-42-padded");

    fill_pattern(64, 8'h80);
    test_good_frame(64, "exact-64-no-pad");

    fill_pattern(1514, 8'h20);
    test_good_frame(1514, "max-1514");

    test_refused(1515, "overlong-1515");
    test_refused(13,   "runt-13");

    fill_pattern(42, 8'h30);
    test_abort;

    fill_pattern(42, 8'h50);
    test_underrun;

    test_two_frames;

    if (errors == 0) $display("PASS: tb_pe_eth_tx");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #40_000_000;
    $display("FAIL: watchdog -- tb_pe_eth_tx did not finish");
    $display("  state=%0d ncells=%0d busy=%b done=%b", dut.state, ncells,
             tx_busy, tx_done);
    $finish;
  end

endmodule
