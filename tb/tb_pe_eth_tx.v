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
//      engine that pads <= 64 would emit a 65th byte here). A 60-byte frame
//      is ALSO run unpadded: 60 is the largest stored length that needs no
//      pad, so it is the only case that separates `stored < 60` from
//      `stored <= 60`. (Added when the mutation suite's `pad-extra` mutant
//      survived; the suite is the reason this boundary is now covered.)
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
//      The gap is checked TWICE: on the wire (>= 96) AND on the engine's own
//      ifg_active window (>= 96 cells), because the wire measure also
//      contains the start-alignment cell and can hide a 95-cell engine IFG.
//
//
// THE LINE DRIVER (wiki/plans/eth-tx-line-driver.md: the differential pair, the
// start-of-idle delimiter and the link pulses). `line_drive` says when the
// SoC must drive eth_tx_n as the complement of the wire; low means the pair
// sits at 0 V. It is recorded per cell beside the wire, so every check below
// is about CELLS on the wire, not about the FSM's own bookkeeping.
//
//  10. Every bit cell of every frame goes out with the pair DRIVEN, the drive
//      moves only on cell boundaries, and a driven cell that carries no bit
//      is always the POSITIVE level (802.3's TP_IDL and link pulses are both
//      positive; a negative one reads as a swapped pair). Continuous.
//  11. TP_IDL: after the last FCS cell the pair stays driven for exactly 3
//      idle-high cells (300 ns; 802.3 wants >= 250 ns) and is then released.
//      Also after an abort and after BOTH underruns (mid-DATA, and a bare
//      preamble with no header byte -- case 8b, the only case that reaches
//      that path): a truncated frame still ends with the delimiter. And a
//      frame restarted INSIDE an abort's delimiter (case 7b) must cancel it,
//      or the countdown releases the pair two cells into the new preamble.
//      Missed if: only the normal end were checked.
//  12. Link pulses (a second, fast instance: NLP_CELLS = 50): the first pulse
//      is exactly 50 cell boundaries after enable, then every 50; each is one
//      cell (6 clocks = 100 ns) wide and positive. The IFG and the frame do
//      not count toward the period (first pulse exactly 50 boundaries after
//      the engine returns to IDLE). Missed if: the period were measured from
//      pulse to pulse only (an off-by-one on the first pulse survives).
//  13. A start latched during a link pulse waits for the pulse's cell to end
//      (the pulse is never cut), and a start latched in the cell BEFORE a
//      pulse is due wins: the frame starts and no pulse is emitted. Dropping
//      `enable` mid-pulse releases the pair on the next clock.
//  14. The silicon constant: the default instance's first link pulse is
//      exactly 160,000 boundaries (16.000 ms) after enable. Measured, not
//      read from the parameter; the dump is paused for the 960k-clock wait.
//
// WHAT IT DOES NOT COVER (owned by later tasks): the pad-level uo_out mux
// (Task 4), the loopback through the RX chain and the mutation suites
// (Tasks 5-6), and the owner arbitration against the SERDES (Task 3's SoC TB).
// The pair itself (eth_tx_n = wire XOR line_drive) is composed in pe_soc and
// checked there and at the pads (tb_pe_soc_eth_tx, tb_tt_um_protocol_emulator).

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
  logic        ifg_active, tx_bit, line_drive;

  // The fast-link-pulse instance: same cadence, its own controls, so its
  // pulses can be timed without disturbing the frame cases on `dut`.
  localparam int NLP_FAST = 50;
  logic        enable_f, push_f, start_f, abort_f;
  logic        push_ready_f, busy_f, done_f, underrun_f, overlong_f;
  logic        ifg_f, tx_bit_f, line_drive_f;

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
    .tx_bit(tx_bit), .line_drive(line_drive)
  );

  pe_eth_tx #(.MAX_STORED(1514), .NLP_CELLS(NLP_FAST)) dut_f (
    .clk(clk), .rst_n(rst_n),
    .enable(enable_f), .cell_start(cell_start), .half_phase(half_phase),
    .push(push_f), .push_byte(push_byte), .push_ready(push_ready_f),
    .frame_len(frame_len), .start(start_f), .frame_abort(abort_f),
    .tx_busy(busy_f), .tx_done(done_f), .tx_underrun(underrun_f),
    .tx_overlong(overlong_f), .ifg_active(ifg_f),
    .tx_bit(tx_bit_f), .line_drive(line_drive_f)
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
  logic [1:0] lrec    [0:MAXCELLS-1];   // line_drive at the {first, second} half
  logic       lvlrec  [0:MAXCELLS-1];   // wire level of an idle cell
  int         ncells, done_count;
  logic       mh1, mh2, lh1, lh2;
  bit         saw_done, saw_underrun, saw_overlong;

  // The engine's OWN inter-frame gap, counted at the cell boundary while
  // ifg_active is high. The wire-gap measure below is not a substitute: it
  // also contains the start-alignment cell, so a 95-cell engine IFG still
  // measures >= 96 on the wire. Found by regress/mutate_eth_tx_tb.sh's
  // `ifg-95` mutation, which SURVIVED the wire-gap check.
  int ifg_cells;
  int ifg_cells_at_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ncells <= 0; done_count <= 0; mh1 <= 1'b0; mh2 <= 1'b0;
      lh1 <= 1'b0; lh2 <= 1'b0;
      saw_done <= 1'b0; saw_underrun <= 1'b0; saw_overlong <= 1'b0;
      ifg_cells <= 0; ifg_cells_at_done <= 0;
    end else begin
      if (tx_done) begin
        saw_done <= 1'b1; done_count <= done_count + 1;
        ifg_cells_at_done <= ifg_cells;
      end
      if (tx_underrun)   saw_underrun  <= 1'b1;
      if (tx_overlong)   saw_overlong  <= 1'b1;

      if (cell_en && !half_phase) begin
        if (ifg_active) ifg_cells <= ifg_cells + 1;
        // classify the cell that just ended from its ph2/ph5 samples
        if (mh1 === mh2) begin
          if (ncells < MAXCELLS) cellrec[ncells] <= 2'b00;   // idle (constant)
          // Check 10: a driven cell with no bit in it is the POSITIVE level.
          if (lh1 || lh2)
            check(mh1 === 1'b1,
                  "the pair was driven NEGATIVE outside a frame (TP_IDL/link pulse must be positive)");
        end else begin
          check(mh1 === ~mh2, "Manchester halves are not complementary");
          if (ncells < MAXCELLS) cellrec[ncells] <= {1'b1, mh2};
          // Check 10: every bit on the wire goes out with the pair driven.
          check(lh1 === 1'b1 && lh2 === 1'b1,
                "a frame bit went out with the pair undriven (line_drive low)");
        end
        check(lh1 === lh2, "line_drive moved mid-cell (it may change only on a cell boundary)");
        if (ncells < MAXCELLS) begin
          lrec[ncells]   <= {lh1, lh2};
          lvlrec[ncells] <= mh1;
        end
        if (ncells < MAXCELLS) ncells <= ncells + 1;
        mh1 <= wire_bit; lh1 <= line_drive;
      end else if (!half_phase) begin
        mh1 <= wire_bit; lh1 <= line_drive;
      end else begin
        mh2 <= wire_bit; lh2 <= line_drive;
      end
    end
  end

  // ---------------- link-pulse monitors (checks 12-14) ----------------
  // A free-running clock count and cell-boundary count; tests take DIFFERENCES,
  // so neither needs a reset. An edge of line_drive is SEEN one clock after it
  // happens (the DUT's register updates at the edge the monitor samples), and
  // that offset cancels in every difference below.
  //
  // A link pulse is a rise of line_drive while the engine is NOT busy; a rise
  // at a frame start happens together with tx_busy and is not counted. The
  // matching fall is the next fall after an NLP rise.
  localparam int MAXP = 16;
  longint cyc = 0, cs_total = 0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cell_start) cs_total <= cs_total + 1;
  end

  wire    wire_f = half_phase ? tx_bit_f : ~tx_bit_f;
  logic   ld_q, ld_f_q, busy_f_q, in_nlp, in_nlp_f;
  int     nlp_n, nlp_f_n;
  longint nlp_rise_cs  [0:MAXP-1], nlp_rise_cyc  [0:MAXP-1], nlp_fall_cyc  [0:MAXP-1];
  longint nlpf_rise_cs [0:MAXP-1], nlpf_rise_cyc [0:MAXP-1], nlpf_fall_cyc [0:MAXP-1];
  longint busyf_rise_cyc, busyf_rise_cs, busyf_fall_cs;
  bit     neg_drive_f;   // dut_f drove the pair NEGATIVE outside a frame
  bit     saw_done_f;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ld_q <= 1'b0; ld_f_q <= 1'b0; busy_f_q <= 1'b0;
      in_nlp <= 1'b0; in_nlp_f <= 1'b0;
      nlp_n <= 0; nlp_f_n <= 0; neg_drive_f <= 1'b0; saw_done_f <= 1'b0;
      busyf_rise_cyc <= -1; busyf_rise_cs <= -1; busyf_fall_cs <= -1;
    end else begin
      ld_q <= line_drive; ld_f_q <= line_drive_f; busy_f_q <= busy_f;

      // ---- dut (the silicon default period) ----
      if (line_drive && !ld_q && !tx_busy) begin
        if (nlp_n < MAXP) begin
          nlp_rise_cs[nlp_n]  <= cs_total;
          nlp_rise_cyc[nlp_n] <= cyc;
        end
        in_nlp <= 1'b1;
      end
      if (!line_drive && ld_q && in_nlp) begin
        if (nlp_n < MAXP) nlp_fall_cyc[nlp_n] <= cyc;
        nlp_n  <= nlp_n + 1;
        in_nlp <= 1'b0;
      end

      // ---- dut_f (NLP_FAST) ----
      if (line_drive_f && !ld_f_q && !busy_f) begin
        if (nlp_f_n < MAXP) begin
          nlpf_rise_cs[nlp_f_n]  <= cs_total;
          nlpf_rise_cyc[nlp_f_n] <= cyc;
        end
        in_nlp_f <= 1'b1;
      end
      // A pulse ends either by falling or by running straight into a frame
      // (a start latched inside the pulse's cell); both close it.
      if (in_nlp_f && (!line_drive_f || busy_f)) begin
        if (nlp_f_n < MAXP) nlpf_fall_cyc[nlp_f_n] <= cyc;
        nlp_f_n  <= nlp_f_n + 1;
        in_nlp_f <= 1'b0;
      end
      if (done_f) saw_done_f <= 1'b1;
      if (busy_f && !busy_f_q) begin busyf_rise_cyc <= cyc; busyf_rise_cs <= cs_total; end
      if (!busy_f && busy_f_q) busyf_fall_cs <= cs_total;

      // Check 10 on the fast instance, every clock: outside the frame states
      // (IDLE or IFG) a driven pair must be the POSITIVE level.
      if (line_drive_f && (!busy_f || ifg_f) && wire_f !== 1'b1) neg_drive_f <= 1'b1;
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
    enable_f = 1'b0; push_f = 1'b0; start_f = 1'b0; abort_f = 1'b0;
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

  // ---------------- the fast instance's stimulus ----------------
  task automatic push_wait_f(input logic [7:0] b);
    int guard = 0;
    while (!push_ready_f && guard < 500_000) begin @(posedge clk); guard++; end
    check(push_ready_f, "fast instance: push_ready never asserted");
    @(negedge clk); push_f = 1'b1; push_byte = b;
    @(negedge clk); push_f = 1'b0;
  endtask

  task automatic pulse_start_f;
    @(negedge clk); start_f = 1'b1;
    @(negedge clk); start_f = 1'b0;
  endtask

  // Bounded waits on the fast instance's monitors.
  task automatic wait_in_nlp_f(input string tag);
    int guard = 0;
    while (!in_nlp_f && guard < 20 * NLP_FAST) begin @(posedge clk); guard++; end
    check(in_nlp_f, $sformatf("%s: no link pulse within %0d clocks", tag, 20 * NLP_FAST));
  endtask

  task automatic wait_nlp_f(input int n, input string tag);
    int guard = 0;
    while (nlp_f_n < n && guard < 6 * (n + 2) * NLP_FAST) begin @(posedge clk); guard++; end
    check(nlp_f_n >= n, $sformatf("%s: only %0d of %0d link pulses came", tag, nlp_f_n, n));
  endtask

  task automatic wait_busy_f(input logic level, input string tag);
    int guard = 0;
    while (busy_f !== level && guard < 3_000_000) begin @(posedge clk); guard++; end
    check(busy_f === level, $sformatf("%s: fast instance tx_busy never went %0b", tag, level));
  endtask

  // ---------------- line-drive helpers (checks 10-11) ----------------
  // The start-of-idle delimiter: the TPIDL cells right after frame end `e`
  // are driven, carry no bit, and sit at the positive level; the next is not.
  localparam int TPIDL = 3;
  task automatic check_tpidl(input int e, input string tag);
    for (int k = e; k < e + TPIDL; k++)
      check(k < ncells && lrec[k] === 2'b11 && cellrec[k] === 2'b00 && lvlrec[k] === 1'b1,
            $sformatf("%s: TP_IDL cell +%0d is not a driven idle-high cell (drive=%b cell=%b lvl=%b)",
                      tag, k - e, lrec[k], cellrec[k], lvlrec[k]));
    check(e + TPIDL < ncells && lrec[e + TPIDL] === 2'b00,
          $sformatf("%s: the pair is still driven %0d cells after the frame (TP_IDL is %0d)",
                    tag, TPIDL + 1, TPIDL));
  endtask

  // Index one past the last bit cell recorded so far (-1 if none).
  function automatic int end_of_last_bit;
    for (int k = ncells - 1; k >= 0; k--)
      if (cellrec[k][1] === 1'b1) return k + 1;
    return -1;
  endfunction

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
    // Check 10: an idle, enabled engine leaves the pair at 0 V (released)
    // between link pulses -- none is due at the 16 ms default period.
    for (int k = base; k < ncells; k++)
      check(lrec[k] === 2'b00,
            $sformatf("idle: the pair is driven in idle cell %0d (DC across the transformer)", k));
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
    // Checks 10-11: released before the frame, driven through every frame
    // cell, then exactly TPIDL driven idle-high cells, then released.
    for (int k = scan_start; k < last_i0; k++)
      check(lrec[k] === 2'b00,
            $sformatf("%s: the pair is driven in pre-frame idle cell %0d", tag, k));
    for (int k = last_i0; k < last_end; k++)
      if (lrec[k] !== 2'b11) begin
        check(1'b0, $sformatf("%s: frame cell %0d went out with the pair undriven",
                              tag, k - last_i0));
        break;
      end
    check_tpidl(last_end, tag);
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
    for (int k = base; k < ncells; k++)
      check(lrec[k] === 2'b00,
            $sformatf("%s: a refused frame drove the pair", tag));
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
    // Check 11: a cut frame still ends with the start-of-idle delimiter.
    repeat (36) @(posedge clk);          // TPIDL + 1 cells, and then some
    check_tpidl(end_of_last_bit(), "abort");
  endtask

  // Case 7b: a frame restarted INSIDE the delimiter of an aborted one. The
  // abort starts a 3-cell TP_IDL; a start latched right away is applied at
  // the next boundary, so the new frame begins while that countdown is still
  // running. The frame start must cancel it: if it did not, the countdown
  // would reach zero two cells into the new preamble and RELEASE the pair
  // mid-frame -- check 10 catches that on the first undriven bit cell. The
  // restarted frame is then decoded end to end.
  task automatic test_restart_in_tpidl;
    int total, need;
    total = 60;
    need  = 64 + 8*total + 32;
    reset_dut();
    enable = 1'b1;
    frame_len = 12'd42;
    for (int k = 0; k < 8; k++) push_wait(stored[k]);
    pulse_start();
    begin
      int guard = 0;
      while (ncells < 10 && guard < 100_000) begin @(posedge clk); guard++; end
    end
    pulse_abort();
    begin
      int guard = 0;
      while (tx_busy && guard < 100_000) begin @(posedge clk); guard++; end
    end
    check(!tx_busy, "restart: the abort never returned the engine to IDLE");
    // The monitor classifies a cell on the clock AFTER it ends, so the cut
    // frame's last bit cell is still being recorded here; let it land before
    // marking where the new frame's scan begins (still inside TP_IDL: that
    // is 18 clocks, and the check below proves it).
    repeat (3) @(posedge clk);
    check(dut.tpidl_left != 2'd0,
          "restart: TP_IDL was not running when the restart was issued (the case is vacuous)");
    scan_start = ncells;
    pulse_start();                       // lands inside the running TP_IDL
    for (int k = 8; k < 42; k++) push_wait(stored[k]);
    wait_done_idle(1, "restart");
    analyze(scan_start, total, need, "restart");
    check_tpidl(last_end, "restart");
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
    // Check 11: the truncated frame still ends with the delimiter.
    repeat (66) @(posedge clk);
    check_tpidl(end_of_last_bit(), "underrun");
  endtask

  // Case 8b: the OTHER underrun -- the preamble ends with no header byte at
  // all. Nothing else reaches this path, and the line driver adds a claim to
  // it: the truncated frame (a bare preamble) still ends with TP_IDL.
  task automatic test_underrun_preamble;
    reset_dut();
    enable = 1'b1;
    frame_len = 12'd42;
    pulse_start();                       // no byte was ever pushed
    begin
      int guard = 0;
      while (!saw_underrun && guard < 100_000) begin @(posedge clk); guard++; end
    end
    check(saw_underrun, "preamble underrun: tx_underrun never pulsed");
    check(!saw_done, "preamble underrun: tx_done pulsed with no data");
    begin
      int guard = 0;
      while (tx_busy && guard < 100_000) begin @(posedge clk); guard++; end
    end
    check(!tx_busy, "preamble underrun: engine did not return to IDLE");
    repeat (66) @(posedge clk);
    check(end_of_last_bit() >= 64,
          $sformatf("preamble underrun: only %0d bit cells before the fault, want the 64-bit prelude",
                    end_of_last_bit()));
    check_tpidl(end_of_last_bit(), "preamble underrun");
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
    check_tpidl(g1_end, "two-frame #1");

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
    // The ENGINE's gap, not the wire's: a short engine IFG can hide inside
    // the start-alignment cell (caught by the ifg-95 mutation).
    check(ifg_cells - ifg_cells_at_done >= 96,
          $sformatf("two-frame: engine IFG was %0d cells, want >= 96",
                    ifg_cells - ifg_cells_at_done));
    $display("    two-frame: IFG = %0d idle cells (%0.0f ns, spec >= 96)",
             gap, gap * 100.0);
    $display("    two-frame: engine IFG = %0d cells (spec >= 96)",
             ifg_cells - ifg_cells_at_done);
    analyze(g2_first, 60, need, "two-frame #2");
  endtask

  // ---------------- link pulses (checks 12-14) ----------------

  // Case 12a: the period, the first pulse, the width, the polarity.
  task automatic test_nlp_period;
    longint base;
    reset_dut();
    @(negedge clk); base = cs_total; enable_f = 1'b1;
    wait_nlp_f(3, "nlp period");
    check(nlpf_rise_cs[0] - base == NLP_FAST,
          $sformatf("nlp: first link pulse %0d cell boundaries after enable, want %0d",
                    nlpf_rise_cs[0] - base, NLP_FAST));
    for (int i = 1; i < 3; i++) begin
      check(nlpf_rise_cs[i] - nlpf_rise_cs[i-1] == NLP_FAST,
            $sformatf("nlp: pulses %0d and %0d are %0d boundaries apart, want %0d",
                      i - 1, i, nlpf_rise_cs[i] - nlpf_rise_cs[i-1], NLP_FAST));
      check(nlpf_rise_cyc[i] - nlpf_rise_cyc[i-1] == 6 * NLP_FAST,
            $sformatf("nlp: pulses %0d and %0d are %0d clocks apart, want %0d",
                      i - 1, i, nlpf_rise_cyc[i] - nlpf_rise_cyc[i-1], 6 * NLP_FAST));
    end
    for (int i = 0; i < 3; i++)
      check(nlpf_fall_cyc[i] - nlpf_rise_cyc[i] == 6,
            $sformatf("nlp: pulse %0d is %0d clocks wide, want 6 (one 100 ns cell)",
                      i, nlpf_fall_cyc[i] - nlpf_rise_cyc[i]));
    check(!neg_drive_f, "nlp: a link pulse was driven NEGATIVE");
    check(busy_f === 1'b0, "nlp: link pulses made the engine report busy");
    $display("    nlp: first pulse after %0d boundaries, period %0d cells, width %0d clocks",
             nlpf_rise_cs[0] - base, nlpf_rise_cs[1] - nlpf_rise_cs[0],
             nlpf_fall_cyc[0] - nlpf_rise_cyc[0]);
  endtask

  // Case 12b: the frame and its IFG do not count toward the period.
  task automatic test_nlp_after_frame;
    reset_dut();
    fill_arp_stored;
    frame_len = 12'd42;
    @(negedge clk); enable_f = 1'b1;
    for (int k = 0; k < 8; k++) push_wait_f(stored[k]);
    pulse_start_f();
    for (int k = 8; k < 42; k++) push_wait_f(stored[k]);
    wait_busy_f(1'b1, "nlp after frame");
    wait_busy_f(1'b0, "nlp after frame");
    check(nlp_f_n == 0,
          $sformatf("nlp after frame: %0d link pulse(s) fired around the frame", nlp_f_n));
    wait_nlp_f(1, "nlp after frame");
    check(nlpf_rise_cs[0] - busyf_fall_cs == NLP_FAST,
          $sformatf("nlp after frame: first pulse %0d boundaries after the engine went IDLE, want %0d",
                    nlpf_rise_cs[0] - busyf_fall_cs, NLP_FAST));
    check(!neg_drive_f, "nlp after frame: the pair was driven NEGATIVE outside the frame");
  endtask

  // Case 13a: a start latched inside a link pulse waits for the pulse's cell.
  task automatic test_nlp_defers_start;
    reset_dut();
    fill_arp_stored;
    frame_len = 12'd42;
    @(negedge clk); enable_f = 1'b1;
    for (int k = 0; k < 8; k++) push_wait_f(stored[k]);
    wait_in_nlp_f("defer");
    pulse_start_f();                     // lands inside the pulse's cell
    for (int k = 8; k < 42; k++) push_wait_f(stored[k]);
    wait_busy_f(1'b1, "defer");
    check(busyf_rise_cyc - nlpf_rise_cyc[0] == 6,
          $sformatf("defer: the frame began %0d clocks after the link pulse, want 6 (the pulse was cut or the start lost)",
                    busyf_rise_cyc - nlpf_rise_cyc[0]));
    wait_busy_f(1'b0, "defer");
    check(saw_done_f, "defer: the frame started after the pulse never completed");
    check(!neg_drive_f, "defer: the pair was driven NEGATIVE outside the frame");
  endtask

  // Case 13b: a start latched in the cell BEFORE a pulse is due wins.
  task automatic test_start_beats_nlp;
    longint base;
    reset_dut();
    fill_arp_stored;
    frame_len = 12'd42;
    for (int k = 0; k < 8; k++) push_wait_f(stored[k]);   // FIFO fills while disabled
    @(negedge clk); base = cs_total; enable_f = 1'b1;
    while (cs_total - base < NLP_FAST - 1) @(posedge clk);
    pulse_start_f();                     // latched before boundary NLP_FAST
    for (int k = 8; k < 42; k++) push_wait_f(stored[k]);
    wait_busy_f(1'b1, "start beats nlp");
    check(busyf_rise_cs - base == NLP_FAST,
          $sformatf("start beats nlp: the frame began at boundary %0d, want %0d (where the pulse was due)",
                    busyf_rise_cs - base, NLP_FAST));
    check(nlp_f_n == 0 && !in_nlp_f,
          "start beats nlp: a link pulse fired although a start was pending");
    wait_busy_f(1'b0, "start beats nlp");
  endtask

  // Case 13c: dropping enable mid-pulse releases the pair on the next clock,
  // and re-enabling restarts the period from zero.
  task automatic test_nlp_disable;
    longint base;
    int n0;
    reset_dut();
    @(negedge clk); enable_f = 1'b1;
    wait_in_nlp_f("disable");
    @(negedge clk); enable_f = 1'b0;
    @(posedge clk); #1;
    check(line_drive_f === 1'b0, "disable: dropping enable mid-pulse left the pair driven");
    repeat (6 * NLP_FAST) @(posedge clk);
    check(line_drive_f === 1'b0 && !in_nlp_f,
          "disable: a disabled engine drove the pair");
    // Disable again MID-COUNT (20 boundaries into a period, where the count
    // is not already zero), then re-enable: the period restarts from zero, so
    // the first pulse is NLP_FAST boundaries after the second enable. A
    // disable that kept the count would pulse 20 boundaries early.
    @(negedge clk); base = cs_total; enable_f = 1'b1;
    while (cs_total - base < 20) @(posedge clk);
    @(negedge clk); enable_f = 1'b0;
    repeat (12) @(posedge clk);
    n0 = nlp_f_n;
    @(negedge clk); base = cs_total; enable_f = 1'b1;
    wait_nlp_f(n0 + 1, "disable");
    check(nlpf_rise_cs[n0] - base == NLP_FAST,
          $sformatf("disable: after a mid-count disable the first pulse came at boundary %0d, want %0d",
                    nlpf_rise_cs[n0] - base, NLP_FAST));
  endtask

  // Case 14: the silicon constant, measured on the default instance.
  task automatic test_nlp_real_constant;
    longint base;
    int n0;
    reset_dut();
    n0 = nlp_n;
    @(negedge clk); base = cs_total; enable = 1'b1;
    $dumpoff;                            // 960k idle clocks: keep the VCD small
    while (nlp_n == n0 && cs_total - base < 170_000) @(posedge clk);
    $dumpon;
    check(nlp_n == n0 + 1,
          "nlp constant: the default instance sent no link pulse within 170,000 cells");
    check(nlp_rise_cs[n0] - base == 160_000,
          $sformatf("nlp constant: first link pulse %0d boundaries after enable, want 160000 (16.000 ms)",
                    nlp_rise_cs[n0] - base));
    check(nlp_fall_cyc[n0] - nlp_rise_cyc[n0] == 6,
          $sformatf("nlp constant: pulse %0d clocks wide, want 6",
                    nlp_fall_cyc[n0] - nlp_rise_cyc[n0]));
    $display("    nlp constant: first pulse %0d boundaries (%0.3f ms) after enable, width %0d clocks",
             nlp_rise_cs[n0] - base, (nlp_rise_cs[n0] - base) * 100.0e-6,
             nlp_fall_cyc[n0] - nlp_rise_cyc[n0]);
  endtask

  initial begin
    $dumpfile("tb_pe_eth_tx.vcd");
    $dumpvars(0, tb_pe_eth_tx);

    for (int i = 0; i < 1600; i++) stored[i] = 8'h00;
    fill_arp;
    ncells = 0; scan_start = 0; last_i0 = 0; last_end = 0;
    rst_n = 1'b0; enable = 1'b0; push = 1'b0; push_byte = 8'h00;
    start = 1'b0; abort = 1'b0; frame_len = 12'd0;
    enable_f = 1'b0; push_f = 1'b0; start_f = 1'b0; abort_f = 1'b0;
    repeat (4) @(posedge clk); #1;

    test_idle_constant;

    fill_arp_stored;
    test_good_frame(42, "arp-42-padded");

    fill_pattern(64, 8'h80);
    test_good_frame(64, "exact-64-no-pad");

    // The PAD BOUNDARY: exactly 60 stored bytes is the largest frame that
    // still needs no pad, so it is the only stored length where `stored < 60`
    // and `stored <= 60` differ. Found by regress/mutate_eth_tx_tb.sh's
    // `pad-extra` mutation, which SURVIVED before this case existed.
    fill_pattern(60, 8'hC0);
    test_good_frame(60, "exact-60-no-pad");

    fill_pattern(1514, 8'h20);
    test_good_frame(1514, "max-1514");

    test_refused(1515, "overlong-1515");
    test_refused(13,   "runt-13");

    fill_pattern(42, 8'h30);
    test_abort;

    fill_pattern(42, 8'h38);
    test_restart_in_tpidl;

    fill_pattern(42, 8'h50);
    test_underrun;

    test_underrun_preamble;

    test_two_frames;

    test_nlp_period;
    test_nlp_after_frame;
    test_nlp_defers_start;
    test_start_beats_nlp;
    test_nlp_disable;
    test_nlp_real_constant;

    if (errors == 0) $display("PASS: tb_pe_eth_tx");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #100_000_000;                        // 100 ms: the 16 ms link-pulse wait included
    $display("FAIL: watchdog -- tb_pe_eth_tx did not finish");
    $display("  state=%0d ncells=%0d busy=%b done=%b", dut.state, ncells,
             tx_busy, tx_done);
    $finish;
  end

endmodule
