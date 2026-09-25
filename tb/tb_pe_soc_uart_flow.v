// tb_pe_soc_uart_flow.v — the software UART with RTS/CTS flow control, on
// real RTL, against a receiver that says no for a while.
//
// WHY THIS IS NOT tb_pe_soc_uart.v WITH ONE MORE PIN
//
// tb_pe_soc_uart.v proves the bit-level UART: framing, timing, assembly. It has
// no notion of a receiver that is not ready, so a program with the flow-control
// logic REMOVED would pass it unchanged. That is the point of this TB: its
// subject is not the bits, it is the relationship between a pin this program
// drives and a pin it obeys.
//
// THE CLAIM, stated as an invariant over time rather than as an event:
//
//   THE WIRE IS IDLE FOR EVERY INSTANT IN WHICH CTS IS LOW.
//
// "The program eventually transmits" is satisfied by a bare echo. "The program
// waits for CTS before its first start bit" is satisfied by a one-shot test
// that happens to see a well-behaved receiver, and by a program whose wait is
// in the wrong place as long as the receiver raises CTS early enough. The
// invariant above is the one a receiver with a full buffer can rely on, and it
// is checked by WATCHING THE LINE rather than by looking at a counter.
//
// TWO CASES, AND THE PAIR IS WHAT MAKES THE WAIT NON-VACUOUS:
//
//   1. CTS LOW FOR A WINDOW, THEN RELEASED. The line must be high throughout
//      the window, the first start bit must be at or after the CTS rising
//      edge, and the three bytes must decode. dmem[3] (the wait's poll count)
//      must be NON-ZERO: a program that never consulted CTS would leave it 0
//      and pass every other check here.
//   2. CTS LOW FOR EVER. The line must never leave idle, dmem[2] must be 0 and
//      the program must not have finished. dmem[3] must be large. This is the
//      direction that catches a program which checks CTS once, at a fixed
//      point, and then ignores it.
//
// THE ORDER IS CHECKED TOO, because it is the part that deadlocks: RTS must be
// asserted BEFORE CTS is read, and released only after the last stop bit. A
// program that waited for CTS first would sit in the first case's wait loop
// forever if the receiver only raises CTS in response to RTS, and the second
// case is what a receiver in that state looks like.
//
// Program: firmware/uart_flow.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

module tb_pe_soc_uart_flow;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD       = 115_200;
  localparam int CLK_HZ     = 60_000_000;
  localparam real CLK_NS   = 1e9 / CLK_HZ;
  localparam real BIT_NS   = 1e9 / BAUD;

  // The pin map, from firmware/uart_flow.pe: bit 0 TX, bit 3 RX, bit 4 RTS,
  // bit 5 CTS. The TB drives CTS and reads TX and RTS.
  localparam int TX_BIT = 0, RX_BIT = 3, RTS_BIT = 4, CTS_BIT = 5;

  localparam int N_PAYLOAD = 3;
  localparam logic [7:0] PAYLOAD0 = 8'h00, PAYLOAD1 = 8'hFF, PAYLOAD2 = 8'hA5;

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  wire tx_pin = pin_out_bus[TX_BIT];
  wire rts    = pin_out_bus[RTS_BIT];

  // CTS is driven by this TB -- it is the RECEIVER's pin, so the receiver
  // models it. 0 = not ready, 1 = go.
  logic cts = 1'b0;
  assign pin_in_bus = {2'b0, cts, 1'b0, 1'b1, 3'b0};   // CTS bit5, RX bit3 high

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

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;
  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh("../firmware/uart_flow.hex", prog);
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
  // THE INVARIANT MONITOR: TX must never leave idle while CTS is low.
  //
  // This is a per-clock sample of the LINE, not a poll of a counter, which is
  // what makes it a claim about the wire. A program that drives a start bit
  // while CTS is low is caught on the very clock it happens, whatever its
  // internal state says afterwards.
  // =========================================================================
  integer tx_low_while_cts_low = 0;
  integer cts_low_samples = 0;
  // RTS MUST BE HIGH FOR EVERY INSTANT TX IS NOT IDLE. TX low means this
  // program is mid-frame -- in the start bit or in a zero data bit -- and RTS
  // low at that instant tells the receiver the line is free while we are
  // driving it. That is the failure a "release RTS when the buffer is empty"
  // implementation makes, and it is invisible to a check that only compares
  // the first and last edge of the handshake.
  integer rts_low_while_tx_low = 0;
  always @(posedge clk) if (run && rst_n && !cts && !tx_pin)
    tx_low_while_cts_low = tx_low_while_cts_low + 1;
  always @(posedge clk) if (run && rst_n && !cts)
    cts_low_samples = cts_low_samples + 1;
  always @(posedge clk) if (run && rst_n && !tx_pin && !rts)
    rts_low_while_tx_low = rts_low_while_tx_low + 1;

  // =========================================================================
  // The 8N1 receiver. Decodes the pins, not a counter, so a transmitter that
  // clocks the wrong number of bits or in the wrong order fails here.
  // =========================================================================
  logic [7:0] rx_bytes [0:7];
  integer     n_rx = 0;
  time        t_first_start = 0;

  // A start-bit edge, latched for the drain loop below.
  //
  // THE DRAIN LOOP USED TO WAIT ON `@(negedge tx_pin)` DIRECTLY, WITH A
  // `waited` GUARD THAT WAS NEVER INCREMENTED. The guard was inert, so the
  // loop had no bound at all -- and the first mutation that made the firmware
  // stop early (it sent its three bytes during the CTS-low window and then
  // parked) left the testbench waiting for a fourth start bit that was never
  // coming. The failure surfaced as the 40 ms watchdog rather than as a
  // diagnosis, which is the worst possible shape: a testbench that cannot say
  // what went wrong. A latched edge plus a clock-counted bound turns it into
  // "only 0 of 3 bytes arrived", which is an answer.
  logic tx_start_edge = 1'b0;
  time  t_tx_start = 0;
  always @(negedge tx_pin) if (run && rst_n && n_rx < N_PAYLOAD) begin
    tx_start_edge = 1'b1;
    t_tx_start = $time;
  end

  // Called with the start bit's FALLING EDGE as t = 0. Data bit 0's centre is
  // 1.5 bit periods later, bit k's is (1.5 + k) periods, and the stop bit's is
  // 9.5.
  //
  // THE 1.5, NOT THE 0.5. The first version waited half a bit period and
  // sampled -- which is the middle of the START bit, so every byte came back as
  // the start bit's own value with the rest shifted. 0x00 decoded as 0x02 and
  // 0xFF as 0x04, which is exactly a one-bit rotation of the payload, and it
  // is worth naming that shape: it looks like a bit-order bug in the
  // transmitter, and the transmitter was fine.
  task automatic decode_byte;
    reg [7:0] b;
    integer k;
    begin
      #(BIT_NS * 1.5);
      b = 8'h00;
      for (k = 0; k < 8; k = k + 1) begin
        b[k] = tx_pin;
        #(BIT_NS);
      end
      if (n_rx < 8) rx_bytes[n_rx] = b;
      n_rx = n_rx + 1;
      $display("    decoded %02h (stop=%b) at %0t", b, tx_pin, $time);
    end
  endtask

  // =========================================================================
  // The handshake monitor: CTS edges, RTS edges, and the order between them.
  // =========================================================================
  time t_cts_rise = 0, t_cts_fall = 0;
  time t_rts_rise = 0, t_rts_fall = 0;
  integer n_rts_rise = 0, n_rts_fall = 0;
  integer rts_high_at_cts_rise = 0;   // 1 if every CTS rise saw RTS asserted

  always @(posedge cts) begin
    t_cts_rise = $time;
    if (n_rts_rise > n_rts_fall) rts_high_at_cts_rise = rts_high_at_cts_rise + 1;
  end
  always @(negedge cts) t_cts_fall = $time;
  always @(posedge rts) begin
    if (t_rts_rise == 0) t_rts_rise = $time;
    n_rts_rise = n_rts_rise + 1;
  end
  always @(negedge rts) begin
    t_rts_fall = $time;
    n_rts_fall = n_rts_fall + 1;
  end

  // =========================================================================
  // Stimulus
  // =========================================================================
  // cfg_cts_low_us: how long the receiver holds CTS low after run rises.
  // A negative value means "for ever".
  integer cfg_cts_low_us = 0;

  task automatic reset_and_load;
    run = 1'b0; rst_n = 1'b0;
    cts = 1'b0;
    repeat (4) @(posedge clk); #1;
    n_rx = 0; tx_low_while_cts_low = 0; cts_low_samples = 0; tx_start_edge = 1'b0;
    rts_low_while_tx_low = 0;
    t_tx_start = 0;
    t_cts_rise = 0; t_cts_fall = 0; t_rts_rise = 0; t_rts_fall = 0;
    n_rts_rise = 0; n_rts_fall = 0; rts_high_at_cts_rise = 0;
    t_first_start = 0;
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    load_firmware();
    // The four-clock gap before `run` rises is required: the SRAM macro's read
    // output is registered, so releasing the CPU in the same instant as the
    // loader's last write makes it decode a stale word as pc=0.
    repeat (4) @(posedge clk); #1;
    run = 1'b1;
  endtask

  initial begin
    $dumpfile("tb_pe_soc_uart_flow.vcd");
    $dumpvars(0, tb_pe_soc_uart_flow);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;

    // ================= 1. CTS low for a window, then released =============
    // The window is 400 us. A byte is 10 bit cells at ~8.68 us, so 400 us
    // covers more than three whole frames -- a transmitter that ignored CTS
    // would have finished the whole payload inside it, which is what makes the
    // window a real test rather than a formality.
    $display("\n=== CTS held low for 400 us, then released ===");
    cfg_cts_low_us = 400;
    reset_and_load();
    // Hold CTS low while the firmware runs into its wait, then release.
    begin : hold
      integer waited = 0;
      while (waited < 400 * 60) begin @(posedge clk); waited = waited + 1; end
      cts = 1'b1;
      $display("    CTS released at %0t; RTS has been asserted %0d times", $time, n_rts_rise);
    end

    // Now let the payload go out.
    begin : drain
      integer waited = 0;
      while (n_rx < N_PAYLOAD && waited < 600 * 60) begin
        @(posedge clk);
        waited = waited + 1;
        if (tx_start_edge) begin
          tx_start_edge = 1'b0;
          // The falling edge IS the start of the start bit. Recording it as
          // `$time - BIT_NS` (which the first version did, to "account for"
          // the 0.5-bit lead-in) put the reported start 8.7 us BEFORE the CTS
          // rising edge and turned the flow-control check into a false failure
          // that looked like a one-bit timing error in the firmware.
          if (t_first_start == 0) t_first_start = t_tx_start;
          decode_byte();
        end
      end
      if (n_rx < N_PAYLOAD)
        $display("FAIL: only %0d of %0d bytes arrived before the drain window closed",
                 n_rx, N_PAYLOAD);
    end
    // A settle period past the last stop bit and the RTS release.
    repeat (200 * 60) @(posedge clk);

    // ---- 1. the invariant ------------------------------------------------
    check(cts_low_samples > 0,
          $sformatf("CTS really was low for a while (%0d clocks sampled low)",
                    cts_low_samples));
    check(tx_low_while_cts_low == 0,
          $sformatf("TX never left idle while CTS was low (%0d clocks saw it low)",
                    tx_low_while_cts_low));

    // ---- 2. the handshake order -----------------------------------------
    check(t_rts_rise != 0, "RTS was asserted");
    check(t_rts_rise < t_cts_rise,
          $sformatf("RTS is asserted BEFORE CTS is read (rts %0t, cts %0t)",
                    t_rts_rise, t_cts_rise));
    check(rts_high_at_cts_rise >= 1,
          "every CTS rising edge was seen with RTS already asserted");
    check(t_first_start >= t_cts_rise,
          $sformatf("the first start bit is at or after the CTS rise (start %0t, cts %0t)",
                    t_first_start, t_cts_rise));
    check(n_rts_fall >= N_PAYLOAD,
          $sformatf("RTS was released once per frame (%0d releases for %0d bytes)",
                    n_rts_fall, N_PAYLOAD));
    check(rts_low_while_tx_low == 0,
          $sformatf("RTS stayed asserted for every instant TX was not idle (%0d clocks saw it low)",
                    rts_low_while_tx_low));
    check(rts === 1'b0,
          $sformatf("RTS is released when the payload is done (saw %b)", rts));

    // ---- 3. the bytes ----------------------------------------------------
    check(n_rx == N_PAYLOAD,
          $sformatf("exactly %0d bytes arrived (got %0d)", N_PAYLOAD, n_rx));
    if (n_rx > 0) check(rx_bytes[0] == PAYLOAD0,
          $sformatf("byte 0 = %02h, sent %02h", rx_bytes[0], PAYLOAD0));
    if (n_rx > 1) check(rx_bytes[1] == PAYLOAD1,
          $sformatf("byte 1 = %02h, sent %02h", rx_bytes[1], PAYLOAD1));
    if (n_rx > 2) check(rx_bytes[2] == PAYLOAD2,
          $sformatf("byte 2 = %02h, sent %02h", rx_bytes[2], PAYLOAD2));

    // ---- 4. the firmware's own record -----------------------------------
    check(dut.dmem[2] == N_PAYLOAD,
          $sformatf("the firmware counted %0d bytes sent (got %0d)",
                    N_PAYLOAD, dut.dmem[2]));
    check(dut.dmem[12] == 8'hA5,
          $sformatf("the firmware finished (got %02h)", dut.dmem[12]));
    // NON-VACUITY, first half: a program that never read CTS leaves this 0.
    check(dut.dmem[3] > 8'h00,
          $sformatf("the CTS wait actually spun (%0d polls)", dut.dmem[3]));
    check(dut.dmem[4] == 8'h00,
          $sformatf("RTS was left released (dmem[4]=%02h)", dut.dmem[4]));
    $display("    dmem: sent=%0d cts_polls=%0d rts_last=%02h done=%02h",
             dut.dmem[2], dut.dmem[3], dut.dmem[4], dut.dmem[12]);

    // ================= 2. CTS low for ever ===============================
    $display("\n=== CTS held low for ever: the wire must never move ===");
    cfg_cts_low_us = -1;
    reset_and_load();
    // Long enough for the whole payload, several times over.
    repeat (600 * 60) @(posedge clk);

    check(cts_low_samples > 0, "CTS was low throughout");
    check(tx_low_while_cts_low == 0,
          $sformatf("TX never left idle while CTS was low (%0d clocks saw it low)",
                    tx_low_while_cts_low));
    check(n_rx == 0,
          $sformatf("no byte was transmitted at all (got %0d)", n_rx));
    check(t_first_start == 0, "no start bit was ever seen");
    check(dut.dmem[2] == 8'h00,
          $sformatf("the firmware sent nothing (got %0d)", dut.dmem[2]));
    check(dut.dmem[12] != 8'hA5,
          $sformatf("the firmware did not finish (got %02h)", dut.dmem[12]));
    // NON-VACUITY, second half: the wait is not a single check that happened
    // to see CTS high, it is a loop that is still spinning.
    check(dut.dmem[3] > 8'h10,
          $sformatf("the wait is a loop, still spinning (%0d polls)", dut.dmem[3]));
    check(rts === 1'b1,
          $sformatf("RTS stays asserted while the receiver says no (saw %b)", rts));
    $display("    dmem: sent=%0d cts_polls=%0d done=%02h (RTS held high)",
             dut.dmem[2], dut.dmem[3], dut.dmem[12]);

    $display("");
    if (errors == 0) $display("PASS: tb_pe_soc_uart_flow");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  // Watchdog. A firmware that spins forever in the CTS wait is the EXPECTED
  // behaviour of case 2, so the watchdog is long enough to cover it and is
  // never reached; it exists for the case where the load itself fails and the
  // program never runs at all.
  initial begin
    #40_000_000;
    $display("FAIL: watchdog -- the test did not complete");
    $finish;
  end

endmodule
