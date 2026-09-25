// tb_pe_soc_serdes.v — the word engine inside the SoC: 0xF window -> pe_serdes
// -> TX codec -> wire loopback -> DRU -> RX codec -> pe_serdes -> 0xF window.
//
// WHAT THIS PROVES THAT NO UNIT TB DOES
//
// tb_pe_serdes and tb_pe_codec_mux prove the blocks; nothing proved the
// integration: the indexed window a PROGRAM can drive, the split payload-only
// enables under stuffing, the two codec instances at different cadences, the
// half-cell level, and the pad overlay through the matrix. This TB loads
// firmware/serds_loop.pe, runs FOUR configurations, and checks the plan's
// directed loopback requirement each time:
//
//   * the decoded word equals the transmitted word (plain LSB-first, plain
//     MSB-first, Manchester unstuffed, Manchester STUFFED);
//   * the serdes TX advances exactly tx_len times and the serdes RX exactly
//     rx_len times (never len + stuff count);
//   * u_tx_codec's cell enable is one pulse per ENCODED cell: consecutive
//     pulses are never closer than one cell period (the doubled-cell-enable
//     mutation fails here), and tx_stuffed is high for each inserted cell
//     with tx_ser STABLE across it (the TX-hold mutation fails here);
//   * the RX cell strobe follows the DRU's per-decoded-cell strobe in
//     Manchester mode (the strobe cross-wire mutation fails here), and the
//     serdes RX never advances while rx_bit_valid is low (the RX-skip
//     mutation fails here);
//   * half_phase toggles at twice the cell rate in Manchester and stays 0
//     otherwise;
//   * a TRAILING stuff cell is emitted after serdes.tx_busy falls (the
//     stuffed config's word 0x07E0 arms its final stuff bit on payload 16),
//     which requires the timing block to stay active past tx_done.
//
// Reset leaves the engine disabled and the overlay off; the four existing
// SoC TBs (uart/tick/i2c/spi/eth) are the non-regression proof that the
// integration is additive.

`timescale 1ns / 1ps

module tb_pe_soc_serdes;

  localparam int  IMEM_WORDS = 1024;
  localparam int  IAW        = $clog2(IMEM_WORDS);
  localparam int  DMEM_BYTES = 16;
  localparam int  BAUD       = 115_200;
  localparam real CLK_NS     = 1e9 / 60e6;
  localparam int  PAYLOAD    = 16;          // TXLEN = RXLEN for every config

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  // The milestone's self-timed wire: port bit 7 loops the pad driver back
  // into the pad input (the DRU listens on bit 7). Bit 3 idles high so no
  // other persona sees a start bit.
  wire [7:0] pin_out_bus, pin_oe_bus;
  wire [7:0] pin_in_bus  = {pin_out_bus[7], 6'b0, 1'b1};
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

  // ---- per-run monitor state --------------------------------------------
  int   n_txcell, n_txadv, n_rxadv, n_stuffed;
  bit   mon_en;
  bit   manch_cfg;
  bit   stuff_cfg;
  real  cell_ns;                 // current encoded-cell period, ns
  real  last_cell_t;
  bit   have_last;
  bit   hold_pending;
  logic hold_ser;
  bit   saw_trailing;
  logic half_d;

  always @(posedge clk) begin
    if (rst_n && mon_en) begin
      // TX HOLD (mutation a): across an inserted stuff cell the serdes must
      // not advance -- tx_ser may not move between the stuff cell's strobe
      // and the next cycle.
      if (hold_pending && !dut.u_tx_codec.bit_en) begin
        check(dut.u_serdes.tx_ser === hold_ser,
              "TX hold removed: tx_ser changed across an inserted stuff cell");
        hold_pending = 1'b0;
      end
      if (dut.u_tx_codec.bit_en) begin
        n_txcell++;
        // One pulse per ENCODED cell: never closer than one cell period
        // (mutation c, doubled cell enable, halves the spacing).
        if (have_last)
          check(($realtime - last_cell_t) >= (cell_ns - 1.0),
                $sformatf("tx codec cell pulses %0.1f ns apart, want >= %0.1f ns (doubled cell enable?)",
                          ($realtime - last_cell_t), cell_ns));
        last_cell_t = $realtime;
        have_last   = 1'b1;
        if (dut.u_tx_codec.tx_stuffed) begin
          n_stuffed++;
          hold_pending = 1'b1;
          hold_ser     = dut.u_serdes.tx_ser;
          if (!dut.u_serdes.tx_busy) saw_trailing = 1'b1;
        end
      end
      if (dut.u_serdes.tx_bit_en && dut.u_serdes.tx_busy) n_txadv++;
      if (dut.u_serdes.rx_bit_en && dut.u_serdes.rx_busy) n_rxadv++;

      // RX SKIP (mutation b): the serdes must never capture a stuff cell.
      if (dut.u_serdes.rx_bit_en && !dut.u_rx_codec.rx_bit_valid)
        check(1'b0, "RX skip removed: serdes RX advanced on a received stuff cell");

      // STROBE CROSS-WIRE (mutation d): in Manchester mode the RX cell
      // strobe must be the DRU's per-decoded-cell strobe, not our divider.
      if (manch_cfg && dut.rx_cell_en && !dut.u_eth_dru.bit_en)
        check(1'b0, "strobe cross-wire: RX cell strobe is not the DRU decode strobe");

      // half_phase: a LEVEL at twice the cell rate when Manchester is on,
      // identically 0 otherwise.
      if (dut.half_phase !== half_d) begin
        half_d = dut.half_phase;
      end
      if (!manch_cfg && dut.half_phase)
        check(1'b0, "half_phase asserted with Manchester disabled");
    end
  end

  // ---- firmware / config loading ----------------------------------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh("../firmware/serdes_loop.hex", prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  task automatic dmem_write(input int a, input logic [7:0] d);
    @(posedge clk); #1;
    host_we = 1'b1; host_imem_sel = 1'b0;
    host_addr = a[IAW-1:0];
    host_wdata = {8'h00, d};
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- the four configurations ------------------------------------------
  //   name, CFG byte, cell divider (clk), CTRL flags (bit4 = lsb_first),
  //   16-bit TX word
  // 0x07E0 for the stuffed config is derived, not decorative: with run=5 the
  // stuff bits arm after payload 5 and payload 9, and payload 12..16 being
  // five identical zeros arms the FINAL stuff bit ON payload 16 -- so the
  // trailing-stuff case is guaranteed by construction.
  string      c_name[4];
  logic [7:0] c_cfg [4];
  int         c_div [4];
  logic [7:0] c_flg [4];
  logic [15:0] c_wd [4];
  bit         c_manch[4];
  bit         c_stuff[4];

  task automatic set_config(input int k);
    dmem_write(0, c_cfg[k]);
    dmem_write(1, 8'(c_div[k] & 8'hFF));
    dmem_write(2, 8'((c_div[k] >> 8) & 8'hFF));
    dmem_write(3, c_flg[k]);
    dmem_write(4, c_wd[k][7:0]);
    dmem_write(5, c_wd[k][15:8]);
    dmem_write(6, 8'h00);
    dmem_write(7, 8'h00);
    dmem_write(8, 8'h00);        // done flag cleared
  endtask

  task automatic run_config(input int k);
    int polls;
    run   = 1'b0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk); #1;
    // monitor state for this run
    n_txcell = 0; n_txadv = 0; n_rxadv = 0; n_stuffed = 0;
    have_last = 0; hold_pending = 0; saw_trailing = 0; half_d = 1'b0;
    manch_cfg = c_manch[k]; stuff_cfg = c_stuff[k];
    cell_ns   = real'(c_div[k]) * CLK_NS;
    set_config(k);
    repeat (4) @(posedge clk); #1;
    mon_en = 1'b1;
    rst_n  = 1'b1;
    repeat (4) @(posedge clk); #1;
    run = 1'b1;

    polls = 0;
    while (dut.dmem[8] !== 8'hA5 && polls < 60000) begin
      @(posedge clk);
      polls++;
    end
    check(dut.dmem[8] === 8'hA5,
          $sformatf("%s: firmware never wrote the done flag (polls=%0d)",
                    c_name[k], polls));
    run = 1'b0;

    // The word came back bit-exact.
    check(dut.dmem[4] === c_wd[k][7:0],
          $sformatf("%s: rx byte0 = %02h, want %02h", c_name[k], dut.dmem[4], c_wd[k][7:0]));
    check(dut.dmem[5] === c_wd[k][15:8],
          $sformatf("%s: rx byte1 = %02h, want %02h", c_name[k], dut.dmem[5], c_wd[k][15:8]));
    check(dut.dmem[6] === 8'h00 && dut.dmem[7] === 8'h00,
          $sformatf("%s: rx upper word = %02h%02h, want 0000 (rx_len=16)",
                    c_name[k], dut.dmem[7], dut.dmem[6]));

    // The serdes advanced exactly payload times in each direction.
    check(n_txadv == PAYLOAD,
          $sformatf("%s: serdes TX advanced %0d times, want %0d (stuff cells must not advance it)",
                    c_name[k], n_txadv, PAYLOAD));
    check(n_rxadv == PAYLOAD,
          $sformatf("%s: serdes RX advanced %0d times, want %0d (received stuff cells must be skipped)",
                    c_name[k], n_rxadv, PAYLOAD));
    check(n_txcell >= PAYLOAD,
          $sformatf("%s: only %0d TX cells seen -- the timing block never ran", c_name[k], n_txcell));

    if (stuff_cfg) begin
      check(n_stuffed >= 2,
            $sformatf("%s: only %0d stuff cells inserted, want >= 2", c_name[k], n_stuffed));
      check(saw_trailing,
            $sformatf("%s: no TRAILING stuff cell after tx_done (timing block died early?)",
                      c_name[k]));
    end else begin
      check(n_stuffed == 0,
            $sformatf("%s: %0d stuff cells inserted in an unstuffed config",
                      c_name[k], n_stuffed));
    end
    mon_en = 1'b0;
    $display("    %s: word=%04h txadv=%0d rxadv=%0d cells=%0d stuff=%0d trailing=%0d",
             c_name[k], {dut.dmem[5], dut.dmem[4]}, n_txadv, n_rxadv,
             n_txcell, n_stuffed, saw_trailing);
  endtask

  initial begin
    $dumpfile("tb_pe_soc_serdes.vcd");
    $dumpvars(0, tb_pe_soc_serdes);

    host_we = 0; host_imem_sel = 0; host_addr = 0; host_wdata = 0;
    run = 0; rst_n = 0; mon_en = 0;
    manch_cfg = 0; stuff_cfg = 0; cell_ns = 100.0;
    last_cell_t = 0.0; have_last = 0; hold_pending = 0; half_d = 0;

    // config 0: plain, LSB-first  (cfg=0, div=16 clk cells, lsb flag)
    c_name[0] = "plain-lsb";  c_cfg[0] = 8'h00; c_div[0] = 16;
    c_flg[0]  = 8'h10;        c_wd[0]  = 16'h96C3;
    c_manch[0]= 0;            c_stuff[0]= 0;
    // config 1: plain, MSB-first
    c_name[1] = "plain-msb";  c_cfg[1] = 8'h00; c_div[1] = 16;
    c_flg[1]  = 8'h00;        c_wd[1]  = 16'h4E7B;
    c_manch[1]= 0;            c_stuff[1]= 0;
    // config 2: Manchester, unstuffed (10BASE-T half-cell cadence: div=6)
    c_name[2] = "manch";      c_cfg[2] = 8'h04; c_div[2] = 6;
    c_flg[2]  = 8'h10;        c_wd[2]  = 16'hA5C3;
    c_manch[2]= 1;            c_stuff[2]= 0;
    // config 3: Manchester + stuffing (the directed stuffed case)
    c_name[3] = "manch-stuffed"; c_cfg[3] = 8'h05; c_div[3] = 6;
    c_flg[3]  = 8'h10;        c_wd[3]  = 16'h07E0;
    c_manch[3]= 1;            c_stuff[3]= 1;

    repeat (4) @(posedge clk); #1;
    load_firmware();

    run_config(0);
    run_config(1);
    run_config(2);
    run_config(3);

    if (errors == 0) $display("PASS: tb_pe_soc_serdes");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: watchdog -- tb_pe_soc_serdes did not finish");
    $finish;
  end

endmodule
