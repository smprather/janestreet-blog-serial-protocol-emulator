// tb_pe_soc_i2c_xfer.v — the I2C transaction layer on real RTL, against an
// independent slave model that decodes the wire.
//
// WHAT THIS PROVES THAT THE EMULATOR CHECK DOES NOT
//
// tools/checks/i2c_xfer_check.py runs firmware/i2c_xfer.pe on the cycle-accurate
// emulator, which is the fast loop. This TB runs the SAME program on the real
// CPU, the real pin matrix, the real open-drain pads and the real 1 us tick,
// with a slave FSM written in Verilog from the wire rules rather than from the
// firmware's assumptions. The two must agree byte-for-byte; a disagreement is
// a signal (STATUS gotcha 11).
//
// THE SLAVE IS NOT A SCRIPTED RESPONSE. It decodes START/STOP, samples data on
// SCL rises, ACKs the 9th clock, holds SDA for tHD;DAT after every fall, and
// drives a fixed read byte on the read address. The TB then asserts on the
// slave's records, the firmware's dmem observables, the timing floors measured
// on the pads, and the bus grammar -- none of which the firmware can fake.
//
// The second run pulls SDA low through the first transmitted 1 so the
// firmware's arbitration branch is exercised rather than dead code.

`timescale 1ns / 1ps

module tb_pe_soc_i2c_xfer;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;
  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  localparam int SDA_BIT = 4, SCL_BIT = 5;
  localparam logic [7:0] SDA = 8'h10, SCL = 8'h20;
  localparam logic [7:0] WRITE_ADDR = 8'hA0, READ_ADDR = 8'hA1;
  localparam logic [7:0] WRITE_DATA = 8'hA5, READ_DATA = 8'h5A;

  logic clk = 0, rst_n;
  always #(CLK_NS/2) clk = ~clk;

  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  // ---- the open-drain bus ------------------------------------------------
  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;
  wire sda_driven_low = pin_oe_bus[SDA_BIT] & ~pin_out_bus[SDA_BIT];
  wire scl_driven_low = pin_oe_bus[SCL_BIT] & ~pin_out_bus[SCL_BIT];
  logic slave_pull_sda;                 // the slave's open-drain pull
  logic slave_pull_scl;                 // the slave's clock stretch
  logic other_pulls_sda_low = 1'b0;     // the contention run's second device
  wire sda_line = (sda_driven_low | slave_pull_sda | other_pulls_sda_low) ? 1'b0 : 1'b1;
  wire scl_line = (scl_driven_low | slave_pull_scl) ? 1'b0 : 1'b1;
  assign pin_in_bus = {2'b0, scl_line, sda_line, 1'b1, 3'b0};

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
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  // ---------------- firmware load ----------------
  logic [15:0] prog [0:IMEM_WORDS-1];
  integer i;
  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh("../firmware/i2c_xfer.hex", prog);
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
  // The slave FSM. A Verilog translation of the wire rules: START/STOP,
  // sample on SCL rises, ACK on the 9th clock, drive the read byte on falls,
  // and hold every SDA change for tHD;DAT after the falling edge.
  // =========================================================================
  localparam logic [2:0] ST_IDLE = 3'd0, ST_ADDR = 3'd1, ST_WRITE = 3'd2,
                        ST_RARM = 3'd3, ST_READ = 3'd4, ST_RACK = 3'd5;

  logic [2:0]  st;              // 3 bits: six states
  logic [3:0]  sl_bit;
  logic [7:0]  sl_shift;
  logic        sl_prev_sda = 1'b1, sl_prev_scl = 1'b1;
  logic        sl_ignore_first_fall;
  logic        sl_pull, sl_pull_next;
  logic [5:0]  sl_hold;
  logic [7:0]  sl_addr [0:3];
  logic [7:0]  sl_data [0:3];
  integer      sl_naddr, sl_ndata;
  logic        sl_nack, sl_nack_seen;
  // Test configuration: which byte to NACK (0 none, 1 write address, 2 data,
  // 3 read address) and clock stretching on the Nth SCL fall.
  logic [1:0]  nack_mode;
  logic        stretch_enable;
  logic [3:0]  stretch_at;
  logic [9:0]  stretch_len, scl_hold;
  logic [7:0]  sl_fall_count;

  task automatic sl_sched_pull(input logic v);
    sl_pull_next = v;
    sl_hold = 6'd18;                    // >= 300 ns of tHD;DAT at 60 MHz
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= ST_IDLE; sl_bit <= 0; sl_shift <= 0;
      sl_prev_sda <= 1'b1; sl_prev_scl <= 1'b1; sl_ignore_first_fall <= 1'b0;
      sl_pull <= 1'b0; sl_pull_next <= 1'b0; sl_hold <= 0;
      sl_naddr <= 0; sl_ndata <= 0; sl_nack <= 1'b1; sl_nack_seen <= 1'b0;
      nack_mode <= 2'd0; stretch_enable <= 1'b0; stretch_at <= 0;
      stretch_len <= 0; scl_hold <= 0; sl_fall_count <= 0;
      slave_pull_scl <= 1'b0;
    end else begin
      // tHD;DAT hold: SDA changes only after the falling edge, never on it.
      if (sl_hold != 0) begin
        sl_hold <= sl_hold - 1'b1;
        if (sl_hold == 6'd1) sl_pull <= sl_pull_next;
      end
      // Clock stretch: hold SCL low for `stretch_len` clocks after the
      // configured fall.
      if (scl_hold != 0) begin
        scl_hold <= scl_hold - 1'b1;
        if (scl_hold == 10'd1) slave_pull_scl <= 1'b0;
      end

      // START / STOP
      if (sl_prev_scl && scl_line && sl_prev_sda && !sda_line) begin
        st <= ST_ADDR; sl_bit <= 0; sl_shift <= 0; sl_ignore_first_fall <= 1'b1;
        sl_sched_pull(1'b0);
      end
      if (sl_prev_scl && scl_line && !sl_prev_sda && sda_line)
        st <= ST_IDLE;

      // SCL rising: sample, unless this slave owns the bit (read phase).
      if (!sl_prev_scl && scl_line) begin
        if (st == ST_RACK) begin
          sl_nack <= sda_line;
          sl_nack_seen <= 1'b1;
        end else if ((st == ST_ADDR || st == ST_WRITE) && sl_bit < 8) begin
          sl_shift <= {sl_shift[6:0], sda_line};
        end
      end

      // SCL falling: advance.
      if (sl_prev_scl && !scl_line) begin
        if (stretch_enable && !slave_pull_scl) begin
          sl_fall_count <= sl_fall_count + 1'b1;
          if (sl_fall_count + 1'b1 == stretch_at) begin
            slave_pull_scl <= 1'b1;
            scl_hold <= stretch_len;
          end
        end
        if (sl_ignore_first_fall) begin
          sl_ignore_first_fall <= 1'b0;
        end else begin
          case (st)
            ST_ADDR, ST_WRITE: begin
              if (sl_bit < 8) begin
                sl_bit <= sl_bit + 1'b1;
                if (sl_bit + 1'b1 == 4'd8) begin
                  // byte complete: record it and ACK the 9th clock
                  if (st == ST_ADDR) begin
                    sl_addr[sl_naddr] <= sl_shift;
                    sl_naddr <= sl_naddr + 1;
                    if (nack_mode == 2'd1 ||
                        (nack_mode == 2'd3 && sl_shift[0])) begin
                      st <= ST_IDLE;            // NACK: no ACK, no read arm
                      sl_sched_pull(1'b0);
                    end else begin
                      if (sl_shift[7:1] == 7'h50 && sl_shift[0])
                        st <= ST_RARM;          // read address
                      sl_sched_pull(1'b1);
                    end
                  end else begin
                    sl_data[sl_ndata] <= sl_shift;
                    sl_ndata <= sl_ndata + 1;
                    // a data-phase NACK leaves SDA released on the 9th clock
                    sl_sched_pull(nack_mode == 2'd2 ? 1'b0 : 1'b1);
                  end
                end
              end else begin
                // the 9th fall: release the ACK and pick the next phase
                sl_bit <= 0; sl_shift <= 0;
                sl_sched_pull(1'b0);
                if (st == ST_ADDR) st <= ST_WRITE;
              end
            end
            ST_RARM: begin
              // the 9th fall after the read address: present bit 7
              st <= ST_READ; sl_bit <= 0;
              sl_sched_pull(!READ_DATA[7]);
            end
            ST_READ: begin
              if (sl_bit < 8) begin
                sl_bit <= sl_bit + 1'b1;
                if (sl_bit + 1'b1 < 4'd8)
                  sl_sched_pull(!READ_DATA[7 - (sl_bit + 1'b1)]);
                else begin
                  sl_sched_pull(1'b0);      // the master owns the ACK slot
                  st <= ST_RACK;
                end
              end
            end
            ST_RACK: begin
              if (!sl_nack) begin
                st <= ST_READ; sl_bit <= 0;
                sl_sched_pull(!READ_DATA[7]);
              end else begin
                st <= ST_IDLE;
              end
            end
            default: ;
          endcase
        end
      end

      sl_prev_sda <= sda_line;
      sl_prev_scl <= scl_line;
    end
  end

  assign slave_pull_sda = sl_pull;

  // =========================================================================
  // Bus monitors: conditions, grammar, timing on the pads, contention.
  // =========================================================================
  logic sda_now, scl_now, m_sda_prev = 1'b1, m_scl_prev = 1'b1;
  integer n_start, n_stop, n_grammar;
  integer min_low_ns, min_high_ns, max_low_ns;
  time    last_fall, last_rise;
  logic   arm_contend, contend_done, contend_enable, contend_released, contend_asserted;
  logic [15:0] contend_left;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_sda_prev <= 1'b1; m_scl_prev <= 1'b1;
      n_start <= 0; n_stop <= 0; n_grammar <= 0;
      min_low_ns <= 1_000_000; min_high_ns <= 1_000_000; max_low_ns <= 0;
      last_fall <= 0; last_rise <= 0;
      arm_contend <= 1'b0; contend_left <= 0;
      contend_done <= 1'b0; other_pulls_sda_low <= 1'b0;
      contend_released <= 1'b0; contend_asserted <= 1'b0;
    end else begin
      sda_now = sda_line;
      scl_now = scl_line;

      // Conditions and the grammar rule: SDA may only move under SCL high when
      // it IS a condition (START = falling, STOP = rising).
      if (scl_now && (sda_now !== m_sda_prev)) begin
        if (m_scl_prev && m_sda_prev && !sda_now) begin
          // The contention source's OWN pull is also a wire START; tag and skip
          // it, so the counts below are the master's.
          if (contend_asserted) contend_asserted <= 1'b0;
          else begin
            n_start <= n_start + 1;
            if (contend_enable && !contend_done) begin
              arm_contend <= 1'b1; contend_done <= 1'b1;
            end
          end
        end else if (m_scl_prev && !m_sda_prev && sda_now) begin
          // A STOP the CONTENTION SOURCE makes by releasing SDA under SCL
          // high is wire-visible but is not the master's: tag and skip it so
          // n_stop==0 below really means "the losing master did not STOP".
          if (contend_released) contend_released <= 1'b0;
          else                  n_stop <= n_stop + 1;
        end else begin
          n_grammar <= n_grammar + 1;
        end
      end

      // Timing, measured between real pad edges.
      if (m_scl_prev && !scl_now) begin
        if (last_rise != 0 && ($time - last_rise) < min_high_ns)
          min_high_ns <= $time - last_rise;
        last_fall <= $time;
      end
      if (!m_scl_prev && scl_now) begin
        if (last_fall != 0) begin
          if (($time - last_fall) < min_low_ns) min_low_ns <= $time - last_fall;
          if (($time - last_fall) > max_low_ns) max_low_ns <= $time - last_fall;
        end
        last_rise <= $time;
        if (arm_contend) begin
          // TRANSIENT CONTENTION, not a second master: the source pulls SDA
          // low through the master's arbitration sample (~6 us into the high
          // phase) and releases it on a countdown. The release happens under
          // SCL high, so the WIRE shows a STOP; the monitor tags that one as
          // stimulus (see contend_released), so the TB can still require that
          // the losing MASTER generates none. The firmware releases and parks
          // immediately -- there is no bus-free wait to exercise, because a
          // single both-high sample cannot prove idle -- and this stimulus
          // does not model a winner's continuing clocks or STOP.
          other_pulls_sda_low <= 1'b1;
          contend_asserted <= 1'b1;
          contend_left <= 16'd900;      // 15 us at 60 MHz
          arm_contend <= 1'b0;
        end
      end
      if (contend_left != 0) begin
        contend_left <= contend_left - 1'b1;
        if (contend_left == 16'd1) begin
          other_pulls_sda_low <= 1'b0;
          contend_released <= 1'b1;
        end
      end

      m_sda_prev <= sda_now;
      m_scl_prev <= scl_now;
    end
  end

  // =========================================================================
  // Stimulus.
  // =========================================================================
  // =========================================================================
  // Stimulus. Each case configures the slave and the contention source, then
  // resets, reloads and runs; reset_and_load is the one place that sequencing
  // lives (including the four-clock SRAM read-at-zero gap before run rises).
  // =========================================================================
  logic [1:0] cfg_nack_mode;
  logic       cfg_stretch_enable, cfg_contend;
  logic [3:0] cfg_stretch_at;
  logic [9:0] cfg_stretch_len;

  task automatic reset_and_load;
    run = 1'b0; rst_n = 1'b0;
    repeat (4) @(posedge clk); #1;
    nack_mode      = cfg_nack_mode;
    stretch_enable = cfg_stretch_enable;
    stretch_at     = cfg_stretch_at;
    stretch_len    = cfg_stretch_len;
    contend_enable = cfg_contend;
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    load_firmware();
    repeat (4) @(posedge clk); #1;
    run = 1'b1;
    repeat (45_000) @(posedge clk); #1;
  endtask

  initial begin
    $dumpfile("tb_pe_soc_i2c_xfer.vcd");
    $dumpvars(0, tb_pe_soc_i2c_xfer);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    cfg_nack_mode = 2'd0; cfg_stretch_enable = 1'b0; cfg_contend = 1'b0;
    cfg_stretch_at = 4'd0; cfg_stretch_len = 10'd0;

    // ================= 1. the clean transaction =========================
    $display("\n=== clean transaction ===");
    reset_and_load();

    check(n_start == 2, $sformatf("two STARTs (repeated START), got %0d", n_start));
    check(n_stop == 1, $sformatf("one STOP, got %0d", n_stop));
    check(n_grammar == 0,
          $sformatf("no SDA move under SCL high except conditions, got %0d", n_grammar));

    check(sl_naddr == 2, $sformatf("slave saw 2 address bytes, got %0d", sl_naddr));
    check(sl_addr[0] == WRITE_ADDR,
          $sformatf("write address 0xA0 (got %02h)", sl_addr[0]));
    check(sl_addr[1] == READ_ADDR,
          $sformatf("read address 0xA1 (got %02h)", sl_addr[1]));
    check(sl_ndata == 1 && sl_data[0] == WRITE_DATA,
          $sformatf("wrote 0xA5 (got %0d bytes, %02h)", sl_ndata, sl_data[0]));
    check(sl_nack_seen && sl_nack == 1'b1,
          "the master NACKed the read byte");

    check(dut.dmem[0] == 8'h00, $sformatf("write-addr ACKed (got %02h)", dut.dmem[0]));
    check(dut.dmem[1] == 8'h00, $sformatf("write-data ACKed (got %02h)", dut.dmem[1]));
    check(dut.dmem[2] == 8'h00, $sformatf("read-addr ACKed (got %02h)", dut.dmem[2]));
    check(dut.dmem[3] == READ_DATA,
          $sformatf("read byte 0x5A (got %02h)", dut.dmem[3]));
    check(dut.dmem[4] == 8'h01, $sformatf("NACK recorded (got %02h)", dut.dmem[4]));
    check(dut.dmem[5] == 8'hA5, $sformatf("transaction completed (got %02h)", dut.dmem[5]));
    check(dut.dmem[6] == 8'h00, $sformatf("clean outcome (got %02h)", dut.dmem[6]));
    check(dut.dmem[7] == 8'h00, $sformatf("no arbitration loss (got %02h)", dut.dmem[7]));

    $display("    measured on the pads: min tLOW=%0d ns  min tHIGH=%0d ns",
             min_low_ns, min_high_ns);
    check(min_low_ns >= 4700,
          $sformatf("tLOW >= 4.7 us on the pads (got %0d ns)", min_low_ns));
    check(min_high_ns >= 4000,
          $sformatf("tHIGH >= 4.0 us on the pads (got %0d ns)", min_high_ns));
    check(min_low_ns < 20_000 && min_high_ns < 20_000,
          $sformatf("plausible cells, not idle (tLOW=%0d tHIGH=%0d)",
                    min_low_ns, min_high_ns));

    // ================= 2. arbitration loss: release, do NOT complete =====
    // Transient contention, not a second master: the source pulls SDA low
    // through the sample and releases it on a countdown. Its own release under
    // SCL high is a WIRE STOP that the monitor tags as stimulus, so the
    // n_stop==0 check below is about the MASTER. No STOP-qualified bus-free
    // wait or retry is implemented, so there is no live-winner path to
    // exercise; this stimulus does not model a winner's continuing clocks or
    // STOP.
    $display("\n=== arbitration lost to transient contention ===");
    cfg_contend = 1'b1;
    reset_and_load();
    cfg_contend = 1'b0;
    check(dut.dmem[7] > 8'h00,
          $sformatf("arbitration loss counted (got %02h)", dut.dmem[7]));
    check(dut.dmem[6] == 8'h01,
          $sformatf("outcome = arbitration (got %02h)", dut.dmem[6]));
    check(dut.dmem[5] == 8'h55,
          $sformatf("aborted, not completed (got %02h)", dut.dmem[5]));
    check(n_start == 1, $sformatf("one START only, got %0d", n_start));
    check(n_stop == 0,
          $sformatf("a losing master generates NO STOP, got %0d", n_stop));
    check(sl_naddr == 0 && sl_ndata == 0,
          "no complete address or data byte is recorded after the abort");
    check(sda_line === 1'b1 && scl_line === 1'b1,
          "bus released after losing arbitration");

    // ================= 3. write-address NACK ============================
    $display("\n=== write-address NACK: abort with a STOP ===");
    cfg_nack_mode = 2'd1;
    reset_and_load();
    check(dut.dmem[6] == 8'h02,
          $sformatf("outcome = write-addr NACK (got %02h)", dut.dmem[6]));
    check(dut.dmem[5] == 8'h55,
          $sformatf("aborted (got %02h)", dut.dmem[5]));
    check(n_stop == 1, $sformatf("a STOP ends the abort, got %0d", n_stop));
    check(sl_naddr == 1 && sl_ndata == 0,
          "no data byte is sent after an address NACK");
    check(sda_line === 1'b1 && scl_line === 1'b1, "bus released");

    // ================= 4. write-data NACK ===============================
    $display("\n=== data NACK: record, then STOP ===");
    cfg_nack_mode = 2'd2;
    reset_and_load();
    check(dut.dmem[6] == 8'h03,
          $sformatf("outcome = data NACK (got %02h)", dut.dmem[6]));
    check(dut.dmem[5] == 8'h55,
          $sformatf("aborted (got %02h)", dut.dmem[5]));
    check(n_stop == 1, $sformatf("a STOP ends the abort, got %0d", n_stop));
    check(sl_naddr == 1 && sl_ndata == 1 && sl_data[0] == WRITE_DATA,
          "the data byte reached the slave before its NACK");

    // ================= 5. read-address NACK =============================
    $display("\n=== read-address NACK: no read attempt ===");
    cfg_nack_mode = 2'd3;
    reset_and_load();
    check(dut.dmem[6] == 8'h04,
          $sformatf("outcome = read-addr NACK (got %02h)", dut.dmem[6]));
    check(dut.dmem[5] == 8'h55,
          $sformatf("aborted (got %02h)", dut.dmem[5]));
    check(n_stop == 1, $sformatf("a STOP ends the abort, got %0d", n_stop));
    check(sl_naddr == 2 && sl_ndata == 1 && !sl_nack_seen,
          "the read byte is never clocked after a read-address NACK");

    // ================= 6. clock stretching ==============================
    $display("\n=== a slave holding SCL low (clock stretch) ===");
    cfg_nack_mode = 2'd0;
    cfg_stretch_enable = 1'b1; cfg_stretch_at = 4'd3; cfg_stretch_len = 10'd600;
    reset_and_load();
    cfg_stretch_enable = 1'b0;
    check(dut.dmem[5] == 8'hA5,
          $sformatf("stretched transaction completes (got %02h)", dut.dmem[5]));
    check(dut.dmem[3] == READ_DATA,
          $sformatf("read byte 0x5A across the stretch (got %02h)", dut.dmem[3]));
    check(max_low_ns > 8000,
          $sformatf("the slave really stretched (max tLOW=%0d ns)", max_low_ns));
    check(min_high_ns >= 4000,
          $sformatf("tHIGH still meets the floor after the stretch (got %0d ns)",
                    min_high_ns));

    $display("");
    if (errors == 0) $display("PASS: tb_pe_soc_i2c_xfer");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: watchdog — the transaction did not complete");
    $display("  pc=%0d state=%0d dmem5=%02h", dbg_pc, dut.dmem[10], dut.dmem[5]);
    $finish;
  end

endmodule
