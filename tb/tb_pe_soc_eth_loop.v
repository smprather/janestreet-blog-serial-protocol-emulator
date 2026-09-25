// tb_pe_soc_eth_loop.v — the 10BASE-T TX frame path closed on itself, plus
// the two directed cases deferred from Task 3
// (wiki/plans/eth-tx-frame-path.md Task 5, Manager Task 11).
//
// WHAT THIS PROVES
//
// 1. THE WIRE LOOPBACK: `pin_out_bus[7]` is wired to `pin_in_bus[7]`, so the
//    frame pe_eth_tx emits goes through the REAL receive chain
//    (pe_dru -> pe_manch -> pe_eth_mac -> pe_crc -> pe_fbuf) and firmware
//    walks it back out of the frame window. `firmware/eth_arp_echo.pe` pushes
//    the 42-byte ARP request, and the RX half is firmware/eth_rx.pe's
//    poll/walk loop. The TB checks the consumer's dmem exactly as
//    tb_pe_soc_eth does: length, EtherType, byte sum, and the rejected count
//    (an FCS failure shows up there). The chip exchanges a real frame with
//    itself.
// 2. THE TWO-FRAME MINIMUM IFG: `firmware/eth_tx_two.pe` sends two 14-byte
//    frames back-to-back -- the second start issued the moment tx_busy falls,
//    so the engine's 96-cell IFG is the only gap -- and the RX chain must
//    report exactly two clean frames. The TB measures the wire gap between
//    the frames (Review Focus 6: the receiver's own hunt gate needs only 8
//    idle cells, the standard's 96 is what makes this pass).
// 3. THE 16-23 PUSH-BANK WRAP (Task 3 deferral): `eth_tx_wrap_probe.pe`
//    pushes NINE bytes in one DATA-phase burst after writing TXLEN=42; the
//    bank must wrap 23 -> 16 so the ninth push cannot land in TXLEN. The TB
//    checks REG[24] still reads 42, REG[26] still reads the owner bit, and
//    that every push strobe was inside 16-23.
// 4. THE START-WHILE-BUSY REFUSAL (Task 3 deferral): `eth_tx_busy_probe.pe`
//    starts a SERDES word with tx_path=1 (its raw output is muxed away, so
//    the wire stays idle), and while ser_tx_busy is high issues a frame_start.
//    The SoC must refuse it -- TXSTAT bit0 stays 0 -- and a later start must
//    still succeed. The TB records the exact refusal condition
//    (`tx_frame_start_strb && ser_tx_busy && !eth_start`).
//
// The four runs reset the SoC between firmwares; the TB preloads dmem through
// the host port for the two dmem-sourced probe frames. Simulation only: no
// physical flow, DRC or LVS.

`timescale 1ns / 1ps

module tb_pe_soc_eth_loop;

  localparam int  IMEM_WORDS = 1024;
  localparam int  IAW        = $clog2(IMEM_WORDS);
  localparam int  DMEM_BYTES = 16;
  localparam int  BAUD       = 115_200;
  localparam int  CLK_HZ     = 60_000_000;
  localparam real CLK_NS     = 1e9 / CLK_HZ;

  logic clk = 0;
  always #(CLK_NS/2) clk = ~clk;

  logic           rst_n, host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  // THE LOOPBACK: the TX pad is the RX pin. Bit 7 is the 10BASE-T wire; bit 3
  // idles high so no other persona sees a UART start bit.
  wire  [7:0] pin_out_bus, pin_oe_bus;
  wire  [7:0] pin_in_bus = {pin_out_bus[7], 6'b0, 1'b1};
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

  // ---------------- firmware / dmem loading ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic load_hex(input string path);
    for (int i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh(path, prog);
    for (int i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
    // Let the ROM pre-load imem[0] before `run` rises. The macro's read is
    // registered and REN is deasserted through every loader write, so without
    // a few stopped cycles the first run cycle sees a stale/X fetch word and
    // the program's first instruction is lost (the wrap probe caught it:
    // `LDI A,24` never landed before its `OUT`).
    repeat (4) @(posedge clk); #1;
  endtask

  task automatic dmem_write(input int a, input logic [7:0] d);
    @(posedge clk); #1;
    host_we = 1'b1; host_imem_sel = 1'b0;
    host_addr = a[IAW-1:0];
    host_wdata = {8'h00, d};
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  task automatic reset_dut;
    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1'b1;
    repeat (4) @(posedge clk); #1;
  endtask

  task automatic wait_dmem(input int addr, input logic [7:0] val,
                           input string what);
    int guard = 0;
    while ((dut.dmem[addr] !== val) && (guard < 600_000)) begin
      @(posedge clk); #1;
      guard++;
    end
    check(dut.dmem[addr] === val,
          $sformatf("%s: dmem[%0d]=%02h want %02h (pc=%0d)",
                    what, addr, dut.dmem[addr], val, dbg_pc));
  endtask

  // ---------------- wire-cell recorder ----------------
  // Sample the ACTUAL loopback wire (pin_out_bus[7]) at the SoC's half-cell
  // centres; idle cells have equal halves, frame cells decode to their second
  // half. The recorder resets with rst_n, so each run starts at zero.
  localparam int MAXCELLS = 8192;
  localparam int NEED     = 64 + 8*60 + 32;   // any <=60-byte frame: 576 bits
  logic [1:0] cellrec [0:MAXCELLS-1];
  int         ncells;
  logic       mh1, mh2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ncells <= 0; mh1 <= 1'b0; mh2 <= 1'b0;
    end else begin
      if (dut.cell_en && !dut.half_phase) begin
        if (mh1 === mh2) begin
          if (ncells < MAXCELLS) cellrec[ncells] <= 2'b00;
        end else begin
          check(mh1 === ~mh2, "loopback wire: Manchester halves are not complementary");
          if (ncells < MAXCELLS) cellrec[ncells] <= {1'b1, mh2};
        end
        if (ncells < MAXCELLS) ncells <= ncells + 1;
        mh1 <= pin_out_bus[7];
      end else if (!dut.half_phase) begin
        mh1 <= pin_out_bus[7];
      end else begin
        mh2 <= pin_out_bus[7];
      end
    end
  end

  // ---------------- RX chain and window monitors ----------------
  int  n_valid, n_bad;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin n_valid <= 0; n_bad <= 0; end
    else begin
      if (dut.eth_frame_valid) n_valid <= n_valid + 1;
      if (dut.eth_frame_bad)   n_bad   <= n_bad + 1;
    end
  end

  int  wrap_pushes, bad_pushes;
  bit  refused_start;
  // Finding F2's monitor: tx_path must NEVER be high while the SERDES is
  // transmitting. The owner probe is the case that provokes it (a TXCTRL SET
  // attempted mid-SERDES).
  bit  owner_rose_mid_serdes;
  bit  serdes_word_done;
  int  clk_tick, last_push_tick, max_push_gap;
  bit  push_seen;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wrap_pushes <= 0; bad_pushes <= 0; refused_start <= 1'b0;
      owner_rose_mid_serdes <= 1'b0; serdes_word_done <= 1'b0;
      clk_tick <= 0; last_push_tick <= 0; max_push_gap <= 0;
      push_seen <= 1'b0;
    end else begin
      clk_tick <= clk_tick + 1;
      // F2: the codec owner must not move to the frame engine while a SERDES
      // word is in flight.
      if (dut.ser_tx_busy && dut.tx_path) owner_rose_mid_serdes <= 1'b1;
      if (dut.ser_tx_done) serdes_word_done <= 1'b1;
      // The push bank must never be addressed outside 16-23 (Task 3 deferral).
      if (dut.eth_push) begin
        wrap_pushes <= wrap_pushes + 1;
        if (dut.win_index < 5'd16 || dut.win_index > 5'd23)
          bad_pushes <= bad_pushes + 1;
      end
      // Push-to-push spacing during a frame: the firmware's sustainable rate
      // against the 48-clk (800 ns) per-byte drain (Task 5 Step 2).
      if (dut.eth_push && dut.eth_tx_busy) begin
        if (push_seen && (clk_tick - last_push_tick) > max_push_gap)
          max_push_gap <= clk_tick - last_push_tick;
        last_push_tick <= clk_tick;
        push_seen <= 1'b1;
      end
      // The exact start-while-busy refusal condition (Review Focus 7).
      if (dut.tx_frame_start_strb && dut.ser_tx_busy && !dut.eth_start)
        refused_start <= 1'b1;
    end
  end

  // ---------------- expected frame data ----------------
  // The canonical 42-byte ARP request, byte-identical to the firmwares.
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

  // The 42-byte ARP frame pads to 60 stored bytes, so the RX side reports
  // 60 - 14 = 46 payload bytes: the 28 ARP bytes + 18 zeros. The TB sums the
  // same 46 bytes (pad contributes 0).
  function automatic logic [7:0] want_arp_sum;
    logic [7:0] s;
    s = 8'h00;
    for (int k = 14; k < 42; k++) s = s + arp[k];
    return s;
  endfunction

  // A 14-byte header-only frame: broadcast dst, 02:00:00:00:00:01 src,
  // EtherType 0x0806. Preloaded into dmem for the two-frame and busy probes.
  logic [7:0] hdr [0:13];
  task automatic fill_hdr;
    hdr[0]=8'hFF; hdr[1]=8'hFF; hdr[2]=8'hFF; hdr[3]=8'hFF;
    hdr[4]=8'hFF; hdr[5]=8'hFF;
    hdr[6]=8'h02; hdr[7]=8'h00; hdr[8]=8'h00; hdr[9]=8'h00;
    hdr[10]=8'h00; hdr[11]=8'h01;
    hdr[12]=8'h08; hdr[13]=8'h06;
  endtask

  task automatic preload_hdr;
    for (int k = 0; k < 14; k++) dmem_write(k, hdr[k]);
  endtask

  // Find the first non-idle cell at or after `from`; -1 if none.
  function automatic int first_bit(input int from);
    for (int k = from; k < ncells; k++)
      if (cellrec[k][1] === 1'b1) return k;
    return -1;
  endfunction

  task automatic check_frame_bits(input int i0, input string tag);
    for (int k = 0; k < NEED; k++) begin
      if (i0 + k >= ncells || cellrec[i0+k][1] !== 1'b1)
        check(1'b0, $sformatf("%s: idle cell inside the frame at bit %0d", tag, k));
    end
  endtask

  // ---------------- the four runs ----------------
  task automatic run_echo;
    int i0;
    reset_dut();
    load_hex("../firmware/eth_arp_echo.hex");
    run = 1'b1; #1;
    wait_dmem(10, 8'hA5, "echo loopback");
    run = 1'b0; #1;
    check(dut.dmem[0] === 8'd46, $sformatf("echo: len=%0d want 46", dut.dmem[0]));
    check(dut.dmem[1] === 8'd0, "echo: len high");
    check(dut.dmem[2] === 8'h06, $sformatf("echo: field low=%02h want 06", dut.dmem[2]));
    check(dut.dmem[3] === 8'h08, $sformatf("echo: field high=%02h want 08", dut.dmem[3]));
    check(dut.dmem[5] === want_arp_sum(),
          $sformatf("echo: sum=%02h want %02h", dut.dmem[5], want_arp_sum()));
    check(dut.dmem[6] === 8'h00, "echo: walk counter cleared");
    check(dut.dmem[7] === 8'h5A, "echo: consumed flag");
    check(dut.dmem[8] === 8'h00, "echo: no rejected frames");
    check(dut.dmem[11] === 8'hA5, "echo: TX half never completed");
    check(n_valid === 1, $sformatf("echo: frame_valid=%0d want 1", n_valid));
    check(n_bad === 0,   $sformatf("echo: frame_bad=%0d want 0", n_bad));
    i0 = first_bit(0);
    check(i0 >= 0, "echo: no frame bits on the loopback wire");
    check(dut.eth_field === 16'h0806, "echo: SoC field is not 0x0806");
    $display("    echo: RX consumer saw len=46 field=0806 sum=%02h; push gaps max %0d clk (budget 48)",
             dut.dmem[5], max_push_gap);
  endtask

  task automatic run_two_frames;
    int i0, i1, gap;
    reset_dut();
    preload_hdr();
    load_hex("../firmware/eth_tx_two.hex");
    run = 1'b1; #1;
    wait_dmem(10, 8'hA5, "two-frame IFG");
    run = 1'b0; #1;
    check(n_valid === 2, $sformatf("two-frame: frame_valid=%0d want 2", n_valid));
    check(n_bad === 0,   $sformatf("two-frame: frame_bad=%0d want 0", n_bad));
    check(dut.dmem[0] === 8'd46, "two-frame: len=46");
    check(dut.dmem[2] === 8'h06 && dut.dmem[3] === 8'h08, "two-frame: EtherType");
    check(dut.dmem[5] === 8'h00, "two-frame: pad-only payload sum=0");
    check(dut.dmem[7] === 8'h5A, "two-frame: consumed flag");
    check(dut.dmem[8] === 8'h00, "two-frame: no rejects");
    i0 = first_bit(0);
    check(i0 >= 0, "two-frame: no first frame on the wire");
    check_frame_bits(i0, "two-frame #1");
    i1 = first_bit(i0 + NEED);
    check(i1 >= 0, "two-frame: second frame never appeared");
    check_frame_bits(i1, "two-frame #2");
    gap = i1 - (i0 + NEED);
    check(gap >= 96,
          $sformatf("two-frame: only %0d idle cells between frames, want >= 96", gap));
    $display("    two-frame: IFG = %0d idle cells, RX valid=%0d bad=%0d",
             gap, n_valid, n_bad);
  endtask

  task automatic run_wrap_probe;
    reset_dut();
    load_hex("../firmware/eth_tx_wrap_probe.hex");
    run = 1'b1; #1;
    wait_dmem(8, 8'hA5, "wrap probe");
    run = 1'b0; #1;
    check(dut.dmem[0] === 8'd42,
          $sformatf("wrap: REG[24]=%02h want 42 (ninth push escaped the bank?)",
                    dut.dmem[0]));
    check(dut.dmem[1] === 8'h04,
          $sformatf("wrap: REG[26]=%02h want 04 (tx_path readback)", dut.dmem[1]));
    check(bad_pushes === 0,
          $sformatf("wrap: %0d push(es) outside the 16-23 bank", bad_pushes));
    check(wrap_pushes === 9,
          $sformatf("wrap: %0d push strobes, want 9", wrap_pushes));
    $display("    wrap: 9 pushes, REG[24]=%02h REG[26]=%02h, bad=%0d",
             dut.dmem[0], dut.dmem[1], bad_pushes);
  endtask

  task automatic run_busy_probe;
    reset_dut();
    preload_hdr();
    load_hex("../firmware/eth_tx_busy_probe.hex");
    run = 1'b1; #1;
    wait_dmem(15, 8'hA5, "busy probe");
    run = 1'b0; #1;
    check(refused_start === 1'b1,
          "busy: the start-while-busy refusal condition never occurred");
    check((dut.dmem[14] & 8'h01) === 8'h00,
          $sformatf("busy: TXSTAT at the refused start = %02h, bit0 must be 0",
                    dut.dmem[14]));
    check(n_valid === 1, $sformatf("busy: frame_valid=%0d want 1", n_valid));
    check(n_bad === 0,   $sformatf("busy: frame_bad=%0d want 0", n_bad));
    check(dut.dmem[0] === 8'd46, "busy: the accepted frame arrived (len=46)");
    check(dut.dmem[5] === 8'h00, "busy: pad-only payload sum=0");
    check(dut.dmem[7] === 8'h5A, "busy: consumed flag");
    check(dut.dmem[8] === 8'h00, "busy: no rejects");
    $display("    busy: refused_start=%0d TXSTAT=%02h RX valid=%0d bad=%0d",
             refused_start, dut.dmem[14], n_valid, n_bad);
  endtask

  // The FINDING-F2 directed case (manager ruling 2026-09-25): the SERDES owns
  // the codec (tx_path is never set) and a TXCTRL tx_path SET is attempted
  // while ser_tx_busy is high. The symmetric guard must refuse it: the codec
  // stays with the SERDES for the whole word, and the TXCTRL readback reports
  // the ACTUAL owner (unclaimed).
  task automatic run_owner_probe;
    reset_dut();
    load_hex("../firmware/eth_tx_owner_probe.hex");
    run = 1'b1; #1;
    wait_dmem(2, 8'hA5, "owner probe");
    run = 1'b0; #1;
    check(owner_rose_mid_serdes === 1'b0,
          "owner: tx_path became 1 while the SERDES was transmitting (F2 guard missing)");
    check((dut.dmem[0] & 8'h04) === 8'h00,
          $sformatf("owner: TXCTRL readback after the refused set = %02h, bit2 must be the ACTUAL owner (0)",
                    dut.dmem[0]));
    check(serdes_word_done === 1'b1,
          "owner: the SERDES word never completed -- the claim disturbed it");
    check(dut.tx_path === 1'b0, "owner: tx_path must still be unclaimed at the end");
    $display("    owner: readback=%02h rose_mid=%0d serdes_done=%0d tx_path=%0d",
             dut.dmem[0], owner_rose_mid_serdes, serdes_word_done, dut.tx_path);
  endtask

  initial begin
    $dumpfile("tb_pe_soc_eth_loop.vcd");
    $dumpvars(0, tb_pe_soc_eth_loop);

    fill_arp;
    fill_hdr;
    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk); #1;

    run_echo;
    run_two_frames;
    run_wrap_probe;
    run_busy_probe;
    run_owner_probe;

    if (errors == 0) $display("PASS: tb_pe_soc_eth_loop");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #60_000_000;
    $display("FAIL: watchdog -- tb_pe_soc_eth_loop did not finish");
    $display("  pc=%0d dmem7=%02h dmem10=%02h dmem15=%02h",
             dbg_pc, dut.dmem[7], dut.dmem[10], dut.dmem[15]);
    $finish;
  end

endmodule
