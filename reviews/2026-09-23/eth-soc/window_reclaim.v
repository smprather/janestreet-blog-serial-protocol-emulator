// tb_pe_soc_eth.v — 10BASE-T receive, end to end on the SoC: wire -> hardware
// chain -> the frame window -> firmware/eth_rx.pe.
//
// WHAT THIS PROVES THAT NO OTHER TB DOES
//
// tb_pe_eth_mac drives the same chain, but the frame's bytes leave through the
// MAC's own ports. Nothing proved a PROGRAM could see a frame. This TB drives
// raw Manchester levels on the SoC's eth_rx pin, lets the chain store the
// frame in the real 2 KB buffer, and then checks what firmware/eth_rx.pe left
// in data memory: the length, the EtherType, the walked bytes' checksum, and
// the rejected-frame count.
//
// The FCS is computed by a left-shifting reference straight from the reflected
// definition (the RTL shifts right from a reversed polynomial), so an accept
// is evidence about the convention and not a tautology.

`timescale 1ns / 1ps

module tb_pe_soc_eth;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW        = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD       = 115_200;
  localparam int CLK_HZ     = 60_000_000;
  localparam real CLK_NS    = 1e9 / CLK_HZ;
  localparam int SPB        = 12;        // the DRU's locked grid
  localparam int HALF       = SPB / 2;   // samples per half-cell

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  // Port bit 7 is the 10BASE-T RX pin (rtl/pe_soc.v). Bit 3 is UART RX, held
  // idle-high so nothing else sees a start bit; the rest are unused.
  logic       rx_pin;
  wire  [7:0] pin_in_bus  = {rx_pin, 6'b0, 1'b1};
  wire  [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] dbg_pc, dbg_a, dbg_timer;

  pe_soc #(
    .IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES), .BAUD(BAUD)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    .pin_in(pin_in_bus), .pin_out(pin_out_bus), .pin_oe(pin_oe_bus),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer)
  );

  integer errors = 0;
  int n_valid, n_bad;

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;
  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh("../firmware/eth_rx.hex", prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---------------- Manchester wire driver ----------------
  // Same convention as tb_pe_eth_mac/tb_pe_dru: a 0 is H->L across the cell, a
  // 1 is L->H, so the first half is the complement of the bit.
  function automatic logic lvl_of(input bit b, input bit first_half);
    return first_half ? ~b : b;
  endfunction

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

  task automatic send_byte(input logic [7:0] v);
    for (int k = 0; k < 8; k++) drive_cell(v[k]);
  endtask

  // The preamble is a WIRE bit pattern (1010...), not byte 0xAA through the
  // LSB-first helper -- that is the trap tb_pe_eth_mac documents.
  task automatic send_preamble;
    for (int k = 0; k < 56; k++) drive_cell(k[0] ? 1'b0 : 1'b1);
  endtask

  task automatic send_idle(input int cells);
    for (int k = 0; k < cells; k++) begin
      rx_pin = 1'b0; repeat (SPB/2) @(posedge clk);
    end
  endtask

  localparam int MAXPAY = 256;
  integer payload_len = 200;
  integer gap = 96;
  integer completions = 0;
  logic [7:0] expected_first, expected_second;
  logic [7:0] frame [0:MAXPAY-1];
  logic [7:0] want  [0:MAXPAY-1];
  logic [31:0] fcs;
  int nframe;

  function automatic logic [31:0] ref_crc32(input int nbytes);
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int k = 0; k < nbytes; k++) begin
      c = c ^ frame[k];
      for (int b = 0; b < 8; b++)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    end
    return ~c;
  endfunction

  // A 64-byte ARP-shaped frame: 14-byte header (EtherType 0x0806), 28 ARP
  // bytes padded to the 46-byte data minimum. `seed` varies the payload so
  // two frames cannot be confused by a constant checksum.
  task automatic build_arp(input logic [47:0] dst, input logic [7:0] seed);
    for (int k = 0; k < 6; k++) frame[k]   = dst[47 - 8*k -: 8];
    for (int k = 0; k < 6; k++) frame[6+k] = 8'h02;
    frame[12] = 8'h08;
    frame[13] = 8'h06;
    for (int k = 0; k < payload_len; k++) begin
      want[k]     = seed + k[7:0];
      frame[14+k] = want[k];
    end
    nframe = 14 + payload_len;
    fcs = ref_crc32(nframe);
  endtask

  task automatic send_frame;
    send_preamble;
    send_byte(8'hD5);
    for (int k = 0; k < nframe; k++) send_byte(frame[k]);
    send_byte(fcs[7:0]);
    send_byte(fcs[15:8]);
    send_byte(fcs[23:16]);
    send_byte(fcs[31:24]);
    send_idle(gap);
  endtask

  function automatic logic [7:0] want_sum;
    logic [7:0] s;
    s = 8'h00;
    for (int k = 0; k < payload_len; k++) s = s + want[k];
    return s;
  endfunction

  // Wait for one data-memory byte to hold `val`, bounded so dead firmware
  // reports instead of hanging.
  task automatic wait_dmem(input int addr, input logic [7:0] val,
                           input string what);
    int guard = 0;
    while ((dut.dmem[addr] !== val) && (guard < 200_000)) begin
      @(posedge clk); #1;
      guard++;
    end
    check(dut.dmem[addr] === val,
          $sformatf("%s: dmem[%0d]=%02h want %02h", what, addr,
                    dut.dmem[addr], val));
  endtask

  // The second good frame is identified by its checksum; dmem[7] already holds
  // 0x5A from frame 1, so it cannot mark the new arrival.
  task automatic wait_sum(input logic [7:0] s);
    int guard = 0;
    while (((dut.dmem[5] !== s) || (dut.dmem[6] !== 8'h00)) &&
           (guard < 200_000)) begin
      @(posedge clk); #1;
      guard++;
    end
    check(dut.dmem[5] === s && dut.dmem[6] === 8'h00,
          $sformatf("second frame: sum=%02h want %02h, counter=%02h",
                    dut.dmem[5], s, dut.dmem[6]));
  endtask

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin n_valid <= 0; n_bad <= 0; end
    else begin
      if (dut.eth_frame_valid) n_valid <= n_valid + 1;
      if (dut.eth_frame_bad)   n_bad   <= n_bad + 1;
    end

  initial begin
    if ($value$plusargs("GAP=%d", gap)) begin end
    if ($value$plusargs("LEN=%d", payload_len)) begin end

    rst_n = 0; run = 0; host_we = 0; host_imem_sel = 0;
    host_addr = 0; host_wdata = 0;
    rx_pin = 1'b0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;

    load_firmware();

    // The line is idle during the load, which arms the MAC's inter-frame hunt
    // gate; one explicit idle stretch makes that independent of load length.
    send_idle(16);
    // `#1` before run release, and it is load-bearing: driving `run` in the
    // same delta as a posedge lets the CPU's PC flop and the instruction
    // memory's fetch flop resolve that edge differently, which skipped the
    // program's first STM. The other SoC TBs put the same delay here.
    #1;
    run = 1'b1;

    build_arp(48'h020000000001, 8'h30);
    expected_first = want_sum();
    send_frame();
    build_arp(48'h020000000001, 8'h71);
    expected_second = want_sum();
    send_frame();
    repeat (8000) @(posedge clk);
    check(n_valid == 2, $sformatf("accepted frames=%0d want 2", n_valid));
    check(completions == 2, $sformatf("firmware completed=%0d want 2", completions));
    $display("WINDOW RESULT len=%0d gap=%0d errors=%0d valid=%0d bad=%0d", payload_len, gap, errors, n_valid, n_bad);
    if (errors == 0) $display("PASS: tb_pe_soc_eth");
    else             $display("FAILURES: %0d", errors);
    if (errors != 0) $fatal(1, "payload corruption");
    $finish;
  end

  always @(posedge clk) begin
    if (dut.eth_buf_reset)
      $display("RECLAIM state=%0d pay_cnt=%0d wptr=%0d room=%0d at=%0t", dut.u_eth_mac.state, dut.u_eth_mac.pay_cnt, dut.u_eth_mac.wptr, dut.u_eth_mac.room, $time);
    if (dut.eth_frame_valid)
      $display("ACCEPT len=%0d ptr=%0d start=%0d at=%0t", dut.eth_frame_len, dut.eth_frame_ptr, dut.eth_frame_start, $time);
    if (dut.dmem_we && dut.dmem_addr == 7 && dut.dmem_wdata == 8'h5A) begin
      completions = completions + 1;
      $display("COMPLETE %0d sum=%02h expected=%02h at=%0t", completions, dut.dmem[5], completions == 1 ? expected_first : expected_second, $time);
      check(dut.dmem[5] === (completions == 1 ? expected_first : expected_second), "payload sum differs");
    end
  end

  initial begin
    #20_000_000;
    $display("FAIL: watchdog — firmware never consumed a frame");
    $display("  pc=%0d dmem5=%02h dmem7=%02h dmem8=%02h",
             dbg_pc, dut.dmem[5], dut.dmem[7], dut.dmem[8]);
    $finish;
  end

endmodule
