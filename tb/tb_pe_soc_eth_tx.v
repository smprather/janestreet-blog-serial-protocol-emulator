// tb_pe_soc_eth_tx.v — the 10BASE-T TX frame engine inside the SoC:
// firmware -> the extended 0xF window -> pe_eth_tx -> the owner mux ->
// u_tx_codec -> the Manchester wire. (wiki/plans/eth-tx-frame-path.md Task 3.)
//
// WHAT THIS PROVES THAT THE UNIT TB DOES NOT
//
// tb_pe_eth_tx proves the engine against a TB-driven cadence. Nothing proves
// the integration: the 5-bit window whose upper bank is the push/length/control
// bank, the owner mux that swaps u_tx_codec.tx_bit from the SERDES to the frame
// engine and back, the DIV=6 cadence firmware selects, the pad overlay driven
// from the frame bits, and that firmware/eth_tx_arp.pe can push a real frame
// with FIFO backpressure through the CPU's 16-byte data memory.
//
// The TB loads the committed image, runs it, waits for its dmem[8] done flag,
// and then decodes the real Manchester waveform on `dut.eng_tx_wire` (the
// codec output before the pad): 64 prelude bits, the 42 ARP bytes LSB-first,
// 18 hardware pad bytes, and 32 FCS bits against an independent left-shifting
// reference over header+payload+pad. It also checks the SoC-level overlay:
// while the engine owns pin 7 and the overlay is on, pin_out[7] must BE the
// codec output.
//
// RED EVIDENCE (pre-change SoC): the old window ignores io_wdata[4], so the
// firmware's index-24/26/16 writes alias indices 8/10/0 and the push bytes
// land in CTRL/register space; no frame reaches the wire and dmem[8] is never
// written, which the bounded wait below turns into a FAIL, not a hang. This TB
// therefore uses only hierarchical signals that existed BEFORE the change
// (eng_en/eng_txsel/eng_ov_en/cell_en/half_phase/cell_div/manch_mode/
// eng_tx_wire/dmem), so the RED run is the planned aliasing failure rather
// than a compile error.
//
// WHAT IT DOES NOT COVER: the wrapper's uo_out[2] pad mux and its reset
// fallback (Task 4), the wire loopback through the RX chain (Task 5), and the
// owner-arbitration directed cases (Task 6's integration mutations).

`timescale 1ns / 1ps

module tb_pe_soc_eth_tx;

  localparam int  IMEM_WORDS = 1024;
  localparam int  IAW        = $clog2(IMEM_WORDS);
  localparam int  DMEM_BYTES = 16;
  localparam int  BAUD       = 115_200;
  localparam int  CLK_HZ     = 60_000_000;
  localparam real CLK_NS     = 1e9 / CLK_HZ;

  logic clk = 0;
  always #(CLK_NS/2) clk = ~clk;

  logic rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  // Port bit 3 is UART RX, held idle-high. Bit 7 is the TX pad (the overlay);
  // the RX chain listens on it too, but this TB decodes the codec output.
  wire  [7:0] pin_in_bus  = 8'b0000_1000;
  wire  [7:0] pin_out_bus, pin_oe_bus;
  logic [9:0] dbg_pc;   // R2: full PC width (pe_soc exposes PCW bits)
  logic [7:0] dbg_a, dbg_timer;

  pe_soc #(
    .IMEM_WORDS(IMEM_WORDS), .DMEM_BYTES(DMEM_BYTES), .BAUD(BAUD)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata), .run(run),
    // R2: the host read port is idle in this TB (tied low, not floating:
    // an undriven input would make the address mux X and break the CPU read).
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
    $readmemh("../firmware/eth_tx_arp.hex", prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
    // Let the ROM pre-load imem[0] before `run` rises (the macro holds A_DOUT
    // through loader writes, so one cycle is not enough). Same settle as
    // tb_pe_soc_serdes; without it the program's first instruction is lost.
    repeat (4) @(posedge clk); #1;
  endtask

  // ---------------- wire decode ----------------
  // Same cell model as the unit TB: classify each wire cell from the ph2/ph5
  // samples of the SoC's own divider, with the codec's Manchester mapping.
  localparam int MAXCELLS = 4096;
  logic [1:0] cellrec [0:MAXCELLS-1];   // {is_bit, decoded_bit}; 2'b00 = idle
  int         ncells;
  logic       mh1, mh2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ncells <= 0; mh1 <= 1'b0; mh2 <= 1'b0;
    end else begin
      // The pad overlay is part of the integration: while the engine owns
      // pin 7 and the overlay is on, the matrix output must be the codec
      // output.
      if (dut.eng_ov_en[7] && dut.pin_oe[7] && (dut.pin_out[7] !== dut.eng_tx_wire))
        check(1'b0, "pad overlay: pin_out[7] is not the codec output");

      if (dut.cell_en && !dut.half_phase) begin
        if (mh1 === mh2) begin
          if (ncells < MAXCELLS) cellrec[ncells] <= 2'b00;
        end else begin
          check(mh1 === ~mh2, "Manchester halves are not complementary");
          if (ncells < MAXCELLS) cellrec[ncells] <= {1'b1, mh2};
        end
        if (ncells < MAXCELLS) ncells <= ncells + 1;
        mh1 <= dut.eng_tx_wire;
      end else if (!dut.half_phase) begin
        mh1 <= dut.eng_tx_wire;
      end else begin
        mh2 <= dut.eng_tx_wire;
      end
    end
  end

  // ---------------- expected frame ----------------
  // The canonical 42-byte ARP request, kept byte-identical to
  // firmware/eth_tx_arp.pe and tb_pe_eth_tx.v (three copies on purpose: the
  // wire decode then cross-checks the firmware's immediates).
  logic [7:0] arp [0:41];
  logic [7:0] stored [0:59];
  logic       got [0:575];
  logic [31:0] fcs_want;

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
    for (int k = 0; k < 42; k++) stored[k] = arp[k];
    for (int k = 42; k < 60; k++) stored[k] = 8'h00;   // hardware pad
  endtask

  function automatic logic [31:0] ref_crc32(input int nbytes);
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int k = 0; k < nbytes; k++) begin
      c = c ^ stored[k];
      for (int b = 0; b < 8; b++)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    end
    return ~c;
  endfunction

  // Wait for one data-memory byte to hold `val`, bounded so a pre-change SoC
  // (or dead firmware) reports instead of hanging.
  task automatic wait_dmem(input int addr, input logic [7:0] val,
                           input string what);
    int guard = 0;
    while ((dut.dmem[addr] !== val) && (guard < 400_000)) begin
      @(posedge clk); #1;
      guard++;
    end
    check(dut.dmem[addr] === val,
          $sformatf("%s: dmem[%0d]=%02h want %02h (pc=%0d eng_en=%b)",
                    what, addr, dut.dmem[addr], val, dbg_pc, dut.eng_en));
  endtask

  localparam int NEED = 64 + 8*60 + 32;   // 576 wire bits

  initial begin
    $dumpfile("tb_pe_soc_eth_tx.vcd");
    $dumpvars(0, tb_pe_soc_eth_tx);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = 0; host_wdata = 0;
    fill_arp;
    repeat (4) @(posedge clk); #1;
    rst_n = 1'b1;
    @(posedge clk); #1;

    load_firmware();

    // run release with a #1, as every other SoC TB does: driving it in the
    // same delta as a posedge can skip the program's first store.
    #1;
    run = 1'b1;

    wait_dmem(8, 8'hA5, "firmware never reported done");
    // The done flag is written during the IFG; give the monitor two more
    // cells to classify the last FCS cell before decoding.
    repeat (24) @(posedge clk);

    // ---- window/length/control landed in the EXTENDED bank ----
    check(dut.eng_en === 1'b1, "engine was never enabled");
    check(dut.eng_txsel === 1'b0, "overlay selector is not the bit-7 default");
    check(dut.win_regs[1] === 8'h04,
          $sformatf("CFG=%02h want 04 (Manchester)", dut.win_regs[1]));
    check(dut.win_regs[2] === 8'h06,
          $sformatf("DIVL=%02h want 06", dut.win_regs[2]));
    check(dut.cell_div === 16'd6,
          $sformatf("cell divider=%0d want 6", dut.cell_div));
    check(dut.manch_mode === 1'b1, "Manchester mode is not selected");
    check(dut.win_regs[24] === 8'd42,
          $sformatf("TXLENL=%02h want 42", dut.win_regs[24]));
    check(dut.win_regs[25] === 8'h00,
          $sformatf("TXLENH=%02h want 00", dut.win_regs[25]));

    // ---- decode the frame from the codec output ----
    begin
      int i0;
      i0 = -1;
      for (int k = 0; k < ncells; k++)
        if (cellrec[k][1] === 1'b1) begin i0 = k; break; end
      check(i0 >= 0, "no encoded bits ever appeared on the TX wire");
      if (i0 >= 0) begin
        for (int k = 0; k < NEED; k++) begin
          if (i0 + k >= ncells || cellrec[i0+k][1] !== 1'b1)
            check(1'b0, $sformatf("idle cell inside the frame at bit %0d", k));
          got[k] = cellrec[i0+k][0];
        end
        for (int k = 0; k < 64; k++) begin
          bit e;
          e = (k == 63) ? 1'b1 : ~k[0];
          check(got[k] === e,
                $sformatf("prelude bit %0d=%b want %b", k, got[k], e));
        end
        for (int b = 0; b < 60; b++) begin
          logic [7:0] gb;
          for (int j = 0; j < 8; j++) gb[j] = got[64 + 8*b + j];
          check(gb === stored[b],
                $sformatf("stored byte %0d=%02h want %02h", b, gb, stored[b]));
        end
        fcs_want = ref_crc32(60);
        for (int k = 0; k < 32; k++)
          check(got[64 + 480 + k] === fcs_want[k],
                $sformatf("FCS bit %0d=%b want %b", k,
                          got[64 + 480 + k], fcs_want[k]));
        $display("    decoded %0d wire bits, FCS %08h", NEED, fcs_want);
      end
    end

    if (errors == 0) $display("PASS: tb_pe_soc_eth_tx");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: watchdog -- tb_pe_soc_eth_tx did not finish");
    $display("  pc=%0d dmem8=%02h eng_en=%b ncells=%0d",
             dbg_pc, dut.dmem[8], dut.eng_en, ncells);
    $finish;
  end

endmodule
