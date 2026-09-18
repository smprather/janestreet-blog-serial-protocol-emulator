// tb_pe_jtag.v — JTAG Shift-DR scan around pe_serdes.
//
// Minimal TAP controller model (Test-Logic-Reset -> Run-Test/Idle ->
// Select-DR -> Capture-DR -> Shift-DR -> Exit1 -> Update-DR). TDI from
// SERDES tx (MSB-first), TDO into SERDES rx. BSR model: parallel-loads
// a capture pattern, shifts TDI in / MSB out; TDO changes on TCK
// falling edge. Self-checking both directions.

`timescale 1ns / 1ps

module tb_pe_jtag;

  localparam int MAXLEN = 32;
  localparam int LENW = $clog2(MAXLEN + 1);
  localparam int H = 8;   // clk cycles per TCK half period
  localparam int NDR = 16;

  // TAP states (DR column only)
  localparam int TLR = 0, RTI = 1, SELDR = 2, CAPDR = 3,
                 SHDR = 4, EXIT1 = 5, UPD = 6, SELIR = 7;

  logic              clk, rst_n;
  logic              cfg_lsb_first, bit_en;
  logic              tx_load, tx_ser, tx_busy, tx_done;
  logic [MAXLEN-1:0] tx_data;
  logic [LENW-1:0]   tx_len;
  logic              rx_ser, rx_start, rx_busy, rx_valid;
  logic [MAXLEN-1:0] rx_data;
  logic [LENW-1:0]   rx_len;
  logic              tck, tms, tdi, tdo;

  // Sticky event flags for the single-cycle pulses.
  logic tx_done_seen, rx_valid_seen;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin tx_done_seen <= 0; rx_valid_seen <= 0; end
    else begin
      if (tx_done)  tx_done_seen  <= 1'b1;
      if (rx_valid) rx_valid_seen <= 1'b1;
    end

  int                state;
  logic [NDR-1:0]    bsr;        // boundary scan register
  logic [NDR-1:0]    cap_pattern;

  pe_serdes #(.MAXLEN(MAXLEN)) dut (.*);

  initial clk = 0;
  always #5 clk = ~clk;

  integer errors = 0;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // One TCK cycle: drive TMS/TDI during the low phase; rising edge
  // advances the TAP (capture/shift actions); falling edge updates TDO.
  task automatic tck_cycle(input bit tms_v, input bit tdi_v);
    #1; tck = 1'b0; tms = tms_v; tdi = tdi_v;
    repeat (H) @(posedge clk); #1;
    tck = 1'b1;  // rising edge: TAP samples
    case (state)
      TLR:   state = tms_v ? TLR  : RTI;
      RTI:   state = tms_v ? SELDR: RTI;
      SELDR: state = tms_v ? SELIR: CAPDR;
      CAPDR: begin
        bsr   = cap_pattern;              // parallel load
        state = tms_v ? EXIT1 : SHDR;
      end
      SHDR: begin
        bsr   = {bsr[NDR-2:0], tdi_v};    // shift TDI in, MSB out
        state = tms_v ? EXIT1 : SHDR;
      end
      EXIT1: state = tms_v ? UPD  : SHDR;
      UPD:   state = tms_v ? SELDR: RTI;
      default: state = TLR;
    endcase
    repeat (H) @(posedge clk); #1;
    tck = 1'b0;  // falling edge: TDO updates
    tdo = (state == SHDR || state == EXIT1) ? bsr[NDR-1] : 1'b0;
  endtask

  // Full scan: walk TAP to Shift-DR, shift a word through, exit to RTI.
  task automatic scan(input [NDR-1:0] w, input [NDR-1:0] pat,
                      output [NDR-1:0] captured);
    cap_pattern = pat;
    // Canonical TAP reset (5x TMS=1 lands in TLR from ANY state), then
    // TLR -> RTI -> Select-DR -> Capture-DR — deterministic per scan.
    repeat (5) tck_cycle(1, 0);
    tck_cycle(0, 0);  // -> RTI
    tck_cycle(1, 0);  // -> Select-DR
    tck_cycle(0, 0);  // -> Capture-DR (loads on its exit edge next)
    // Load SERDES: MSB-first out on TDI, capture TDO
    @(posedge clk); #1;
    cfg_lsb_first = 1'b0;
    tx_data = w; tx_len = NDR; tx_load = 1'b1;
    rx_len = NDR; rx_start = 1'b1;
    tx_done_seen = 1'b0; rx_valid_seen = 1'b0;
    @(posedge clk); #1; tx_load = 1'b0; rx_start = 1'b0;
    // Capture->Shift transition: its falling edge presents TDO = BSR
    // MSB (the capture pattern's first bit). Without this cycle the
    // first latched TDO is stale and only NDR-1 shifts occur.
    tck_cycle(0, 0);
    for (int k = 0; k < NDR; k++) begin
      // Latch TDO BEFORE this cycle's rising edge shifts the BSR.
      rx_ser = tdo;
      tck_cycle(k == NDR-1, tx_ser);  // TMS=1 on the last bit -> Exit1
      bit_en = 1'b1; @(posedge clk); #1; bit_en = 1'b0;
    end
    repeat (2) @(posedge clk); #1;  // delayed RX completion
    check(rx_valid_seen === 1'b1, "jtag: rx_valid");
    check(tx_done_seen === 1'b1, "jtag: tx_done");
    captured = rx_data[NDR-1:0];
    // Exit1-DR -> Update-DR -> Run-Test/Idle
    tck_cycle(1, 0);
    tck_cycle(0, 0);
  endtask

  logic [NDR-1:0] cap;

  initial begin
    $dumpfile("tb_pe_jtag.vcd");
    $dumpvars(0, tb_pe_jtag);
    rst_n = 0; tck = 0; tms = 1; tdi = 0; tdo = 0; bit_en = 0;
    state = TLR; bsr = '0; cap_pattern = '0;
    cfg_lsb_first = 0; tx_load = 0; tx_data = 0; tx_len = 0;
    rx_ser = 0; rx_start = 0; rx_len = 0;
    repeat (3) @(posedge clk); #1; rst_n = 1;
    @(posedge clk); #1;

    scan(16'hBEEF, 16'hA53C, cap);
    check(cap === 16'hA53C, "jtag: captured pattern matches");
    check(bsr === 16'hBEEF, "jtag: bsr fully loaded with scan word");

    scan(16'h0001, 16'h8000, cap);
    check(cap === 16'h8000, "jtag: captured MSB edge pattern");
    check(bsr === 16'h0001, "jtag: bsr LSB edge word");

    scan(16'hFFFF, 16'h0000, cap);
    check(cap === 16'h0000, "jtag: all-zero capture");
    check(bsr === 16'hFFFF, "jtag: all-ones scan");

    if (errors == 0) $display("PASS: tb_pe_jtag");
    else $display("FAILURES: %0d", errors);
    $finish;
  end

endmodule
