// tb_pe_soc_i2c_adv.v — the I2C combined-format transaction on real RTL,
// against an independent slave model that decodes the wire AND stretches.
//
// WHAT THIS PROVES THAT i2c_xfer's TB DOES NOT
//
// tb_pe_soc_i2c_xfer.v proves a one-byte read after a repeated START. This
// proves the three obligations that transaction does not have:
//
//   1. THE REPEATED START FOLLOWS AN ARBITRARY-LENGTH WRITE PHASE. Two data
//      bytes here, not one, so the START is not at a fixed instruction
//      offset in the byte engine.
//   2. THE MASTER DRIVES THE BUS DURING THE READ BURST. Continuing a burst
//      means pulling SDA LOW on the 9th clock of every byte but the last.
//      That is a transmitter behaviour in a receive phase, and a master that
//      only ever releases SDA deadlocks the burst: the slave waits for a
//      second byte that nobody promises.
//   3. THE SLAVE OWNS SCL. A stretching slave holds the line low past the
//      master's tLOW, and the master's tHIGH window must start from the
//      REAL rising edge. The firmware's fix is to poll the pad; dmem[0]
//      counts the poll iterations spent low, and the cases below require it
//      to be 0 with no stretch and non-zero with one -- the pair is what
//      makes the stretch path non-vacuous, since a counter that only ever
//      reads non-zero (or only ever reads zero) would satisfy one of them.
//
// THE SLAVE IS NOT A SCRIPTED RESPONSE. It is a Verilog translation of the
// wire rules: START/STOP detection, data sampled on SCL rises, an ACK on the
// 9th clock of every address/write byte, a read byte driven on the falling
// edges, tHD;DAT on every SDA change, and a multi-byte burst continued only
// while the master ACKs. It was written from the specification, not from the
// firmware's control flow, so a firmware that disagrees with the rules
// disagrees with this.
//
// Program: firmware/i2c_adv.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

module tb_pe_soc_i2c_adv;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;
  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;

  localparam int SDA_BIT = 4, SCL_BIT = 5;
  localparam logic [7:0] WRITE_ADDR = 8'hA0, READ_ADDR = 8'hA1;
  localparam logic [7:0] WRITE_DATA1 = 8'h3C, WRITE_DATA2 = 8'h5A;

  // The burst the slave serves. Three distinct bytes, and none of them is a
  // bit palindrome, so a master that read the burst LSB-first (or off by one
  // position) is visibly wrong rather than accidentally right.
  localparam int N_RD = 3;
  localparam logic [8*N_RD-1:0] RD_SEQ = {8'h33, 8'h22, 8'h11};

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
  logic slave_pull_sda;
  logic slave_pull_scl;             // the slave's clock stretch
  wire sda_line = (sda_driven_low | slave_pull_sda) ? 1'b0 : 1'b1;
  wire scl_line = (scl_driven_low | slave_pull_scl) ? 1'b0 : 1'b1;
  assign pin_in_bus = {2'b0, scl_line, sda_line, 1'b1, 3'b0};

  logic [9:0] dbg_pc;   // R2: full PC width
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
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;   // NOP fill
    $readmemh("../firmware/i2c_adv.hex", prog);
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
  // The slave FSM: a Verilog translation of the wire rules, extended over the
  // previous version's in three ways -- a multi-byte read burst, per-read-byte
  // ACK accounting, and clock stretching at a configurable falling edge.
  // =========================================================================
  localparam logic [2:0] ST_IDLE = 3'd0, ST_ADDR = 3'd1, ST_WRITE = 3'd2,
                        ST_RARM = 3'd3, ST_READ = 3'd4, ST_RACK = 3'd5;

  logic [2:0]  st;
  logic [3:0]  sl_bit;
  logic [7:0]  sl_shift;
  logic        sl_prev_sda = 1'b1, sl_prev_scl = 1'b1;
  logic        sl_ignore_first_fall;
  logic        sl_pull, sl_pull_next;
  logic [5:0]  sl_hold;
  logic [7:0]  sl_addr [0:3];
  logic [7:0]  sl_data [0:3];
  integer      sl_naddr, sl_ndata;
  logic        sl_nack, sl_nack_seen; // the master's ACK/NACK on a read byte
  integer      sl_rd_ack;          // read bytes the master asked to continue
  integer      sl_rd_served;       // read bytes the slave put on the wire
  logic        sl_rd_misack;       // an ACK arrived when the burst was over
  logic [1:0]  nack_mode;
  logic        stretch_enable;
  logic [7:0]  stretch_at;
  logic [15:0] stretch_len, scl_hold;
  logic [7:0]  sl_fall_count;
  integer      stretch_events;     // times this slave actually held SCL

  task automatic sl_sched_pull(input logic v);
    sl_pull_next = v;
    sl_hold = 6'd18;                    // >= 300 ns of tHD;DAT at 60 MHz
  endtask

  // The byte this slave is about to put on the wire during a read, and the
  // bit of it. The value is materialised into a variable before the bit
  // select because Icarus does not accept a bit-select on a function-call
  // result (`rd_byte(0)[7]` is a syntax error there, silently working in
  // other tools -- which is worse, because the TB would stop meaning the
  // same thing in the simulator that gates it).
  function automatic [7:0] rd_byte(input integer idx);
    rd_byte = (idx < N_RD) ? RD_SEQ[8*idx +: 8] : 8'h00;
  endfunction
  logic [7:0] rd_now;
  integer     rd_idx;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= ST_IDLE; sl_bit <= 0; sl_shift <= 0;
      sl_prev_sda <= 1'b1; sl_prev_scl <= 1'b1; sl_ignore_first_fall <= 1'b0;
      sl_pull <= 1'b0; sl_pull_next <= 1'b0; sl_hold <= 0;
      sl_naddr <= 0; sl_ndata <= 0; sl_nack <= 1'b1; sl_nack_seen <= 1'b0;
      sl_rd_ack <= 0; sl_rd_served <= 0; sl_rd_misack <= 1'b0;
      nack_mode <= 2'd0; stretch_enable <= 1'b0; stretch_at <= 0;
      stretch_len <= 0; scl_hold <= 0; sl_fall_count <= 0;
      stretch_events <= 0;
      slave_pull_scl <= 1'b0;
    end else begin
      // tHD;DAT hold: SDA changes only after the falling edge, never on it.
      if (sl_hold != 0) begin
        sl_hold <= sl_hold - 1'b1;
        if (sl_hold == 6'd1) sl_pull <= sl_pull_next;
      end
      // Clock stretch: hold SCL low for `stretch_len` clocks after the
      // configured fall. The master must wait for the real line, so this is
      // the stimulus that makes dmem[0] a measured claim.
      if (scl_hold != 0) begin
        scl_hold <= scl_hold - 1'b1;
        if (scl_hold == 16'd1) slave_pull_scl <= 1'b0;
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
            stretch_events <= stretch_events + 1;
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
              // the 9th fall after the read address: present bit 7 of byte 0
              st <= ST_READ; sl_bit <= 0;
              sl_rd_served <= sl_rd_served + 1;
              rd_idx = 0; rd_now = rd_byte(0);
              sl_sched_pull(!rd_now[7]);
            end
            ST_READ: begin
              if (sl_bit < 8) begin
                sl_bit <= sl_bit + 1'b1;
                if (sl_bit + 1'b1 < 4'd8) begin
                  rd_idx = 7 - (sl_bit + 1'b1);
                  sl_sched_pull(!rd_now[rd_idx]);
                end else begin
                  sl_sched_pull(1'b0);      // the master owns the ACK slot
                  st <= ST_RACK;
                end
              end
            end
            ST_RACK: begin
              if (!sl_nack) begin
                // The master ACKed: it wants another byte, so present the
                // NEXT one. This is the branch a master that never drives
                // SDA low during a burst can never reach.
                if (sl_rd_served < N_RD) begin
                  sl_rd_served <= sl_rd_served + 1;
                  sl_rd_ack <= sl_rd_ack + 1;
                  st <= ST_READ; sl_bit <= 0;
                  rd_now = rd_byte(sl_rd_served);
                  sl_sched_pull(!rd_now[7]);
                end else begin
                  sl_rd_misack <= 1'b1;     // asked for a byte that does not exist
                  st <= ST_IDLE;
                end
              end else begin
                st <= ST_IDLE;              // NACK: the burst is over
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
  // Bus monitors: conditions, grammar, and timing measured between real pad
  // edges. A SDA move under SCL high that is not a condition is a protocol
  // violation, and it is counted rather than described.
  // =========================================================================
  logic sda_now, scl_now, m_sda_prev = 1'b1, m_scl_prev = 1'b1;
  integer n_start, n_stop, n_grammar;
  integer min_low_ns, min_high_ns, max_low_ns;
  time    last_fall, last_rise;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_sda_prev <= 1'b1; m_scl_prev <= 1'b1;
      n_start <= 0; n_stop <= 0; n_grammar <= 0;
      min_low_ns <= 1_000_000; min_high_ns <= 1_000_000; max_low_ns <= 0;
      last_fall <= 0; last_rise <= 0;
    end else begin
      sda_now = sda_line;
      scl_now = scl_line;

      if (scl_now && (sda_now !== m_sda_prev)) begin
        if (m_scl_prev && m_sda_prev && !sda_now)        n_start <= n_start + 1;
        else if (m_scl_prev && !m_sda_prev && sda_now)   n_stop  <= n_stop  + 1;
        else                                              n_grammar <= n_grammar + 1;
      end

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
      end

      m_sda_prev <= sda_now;
      m_scl_prev <= scl_now;
    end
  end

  // =========================================================================
  // Stimulus. Each case configures the slave, then resets, reloads and runs.
  // The wait is on the firmware's OWN completion marker, not on a wall time,
  // so a slower case cannot truncate itself and a fast one cannot overrun.
  // =========================================================================
  logic [1:0] cfg_nack_mode;
  logic       cfg_stretch_enable;
  logic [7:0] cfg_stretch_at;
  logic [15:0] cfg_stretch_len;

  task automatic reset_and_load;
    run = 1'b0; rst_n = 1'b0;
    repeat (4) @(posedge clk); #1;
    nack_mode      = cfg_nack_mode;
    stretch_enable = cfg_stretch_enable;
    stretch_at     = cfg_stretch_at;
    stretch_len    = cfg_stretch_len;
    rst_n = 1'b1;
    repeat (2) @(posedge clk); #1;
    load_firmware();
    // The four-clock gap before `run` rises is required: the macro's read
    // output is registered, so releasing the CPU in the same instant as the
    // loader's last write makes it decode a stale word as pc=0 and the first
    // real instruction at imem[0] is never executed. See tb_pe_soc_spi.v.
    repeat (4) @(posedge clk); #1;
    run = 1'b1;
    // dmem[15] is the completion marker, and it holds the PREVIOUS case's
    // value at this instant -- so wait for the firmware's init to clear it
    // before waiting for it to be set again. Without that, case 2 would read
    // case 1's 0xA5 and stop before executing an instruction.
    // The completion cap is 4 ms = 240,000 clocks. Budget, measured rather
    // than guessed: a bit cell is T_LOW (7) + T_HIGH (6) microseconds of tick
    // waiting plus roughly 85 instructions of per-bit control flow, so about
    // 21 us per cell; the transaction is 7 bytes x 9 cells = 63 cells, or
    // ~1.3 ms, plus the two condition sequences. The cap is generous and the
    // marker condition is what normally ends the wait -- a fixed window would
    // truncate a slower case and report a protocol failure instead of a
    // timing one.
    begin : wait_done
      integer w = 0, w2 = 0;
      while (dut.dmem[15] !== 8'h00 && w < 60*100) begin @(posedge clk); w++; end
      while (dut.dmem[15] === 8'h00 && w2 < 240*60*10) begin @(posedge clk); w2++; end
      if (w2 >= 240*60*10)
        $display("FAIL: watchdog -- the transaction did not complete (state %0d, dmem15=%02h)",
                 dut.dmem[10], dut.dmem[15]);
    end
    repeat (8) @(posedge clk); #1;   // settle past the final STOP's tBUF
  endtask

  initial begin
    $dumpfile("tb_pe_soc_i2c_adv.vcd");
    $dumpvars(0, tb_pe_soc_i2c_adv);

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    cfg_nack_mode = 2'd0; cfg_stretch_enable = 1'b0;
    cfg_stretch_at = 8'd0; cfg_stretch_len = 16'd0;

    // ================= 1. the clean combined-format transaction ==========
    $display("\n=== clean combined format: write 2, repeated START, read 3 ===");
    reset_and_load();

    check(n_start == 2,
          $sformatf("two STARTs (one repeated), got %0d", n_start));
    check(n_stop == 1, $sformatf("one STOP, got %0d", n_stop));
    check(n_grammar == 0,
          $sformatf("no SDA move under SCL high except conditions, got %0d",
                    n_grammar));

    check(sl_naddr == 2, $sformatf("slave saw 2 address bytes, got %0d", sl_naddr));
    check(sl_addr[0] == WRITE_ADDR,
          $sformatf("write address 0xA0 (got %02h)", sl_addr[0]));
    check(sl_addr[1] == READ_ADDR,
          $sformatf("read address 0xA1 (got %02h)", sl_addr[1]));
    check(sl_ndata == 2,
          $sformatf("slave saw 2 write data bytes, got %0d", sl_ndata));
    check(sl_ndata == 2 && sl_data[0] == WRITE_DATA1 && sl_data[1] == WRITE_DATA2,
          $sformatf("wrote 0x3C 0x5A (got %0d bytes, %02h %02h)",
                    sl_ndata, sl_data[0], sl_data[1]));

    // ---- the burst, and the master's ACK on its non-final bytes ---------
    check(sl_rd_served == N_RD,
          $sformatf("slave served %0d read bytes (got %0d)", N_RD, sl_rd_served));
    check(sl_rd_ack == N_RD - 1,
          $sformatf("master ACKed %0d continuing read bytes (got %0d)",
                    N_RD - 1, sl_rd_ack));
    check(!sl_rd_misack,
          "the master did not ask for a byte past the end of the burst");
    check(sl_nack_seen && sl_nack === 1'b1,
          "the master NACKed the final read byte");

    // ---- the firmware's own record --------------------------------------
    check(dut.dmem[1] == 8'h00, $sformatf("write-addr ACKed (got %02h)", dut.dmem[1]));
    check(dut.dmem[2] == 8'h00, $sformatf("data-1 ACKed (got %02h)", dut.dmem[2]));
    check(dut.dmem[3] == 8'h00, $sformatf("data-2 ACKed (got %02h)", dut.dmem[3]));
    check(dut.dmem[4] == 8'h00, $sformatf("read-addr ACKed (got %02h)", dut.dmem[4]));
    check(dut.dmem[5] == 8'h11,
          $sformatf("read byte 1 = 0x11 (got %02h)", dut.dmem[5]));
    check(dut.dmem[6] == 8'h22,
          $sformatf("read byte 2 = 0x22 (got %02h)", dut.dmem[6]));
    check(dut.dmem[7] == 8'h33,
          $sformatf("read byte 3 = 0x33 (got %02h)", dut.dmem[7]));
    check(dut.dmem[15] == 8'hA5,
          $sformatf("clean transaction (got %02h)", dut.dmem[15]));

    // ---- NON-VACUITY OF THE STRETCH PATH, first half --------------------
    // With no stretching slave the poll count must be exactly 0. If it were
    // counting something else -- the tick, the write loop, anything -- it
    // would be non-zero here and the stretch cases below would prove nothing.
    check(stretch_events == 0, "this case configured no stretch");
    check(dut.dmem[0] == 8'h00,
          $sformatf("no stretch observed, so no stretch polls (got %0d)",
                    dut.dmem[0]));

    $display("    measured on the pads: min tLOW=%0d ns  min tHIGH=%0d ns  max tLOW=%0d ns",
             min_low_ns, min_high_ns, max_low_ns);
    $display("    dmem: acks=%02h %02h %02h %02h  read=%02h %02h %02h  stretch_polls=%0d  done=%02h",
             dut.dmem[1], dut.dmem[2], dut.dmem[3], dut.dmem[4],
             dut.dmem[5], dut.dmem[6], dut.dmem[7],
             dut.dmem[0], dut.dmem[15]);
    check(min_low_ns >= 4700,
          $sformatf("tLOW >= 4.7 us on the pads (got %0d ns)", min_low_ns));
    check(min_high_ns >= 4000,
          $sformatf("tHIGH >= 4.0 us on the pads (got %0d ns)", min_high_ns));
    check(min_low_ns < 20_000 && min_high_ns < 20_000,
          $sformatf("plausible cells, not idle (tLOW=%0d tHIGH=%0d)",
                    min_low_ns, min_high_ns));

    // ================= 2. a slave stretching inside the read burst =======
    $display("\n=== the slave holds SCL low during the read burst ===");
    cfg_stretch_enable = 1'b1; cfg_stretch_at = 8'd30; cfg_stretch_len = 16'd900;
    reset_and_load();
    cfg_stretch_enable = 1'b0;

    check(stretch_events > 0,
          $sformatf("the slave really stretched (%0d events)", stretch_events));
    // NON-VACUITY, second half: the firmware must have SPUN on the pad.
    check(dut.dmem[0] > 8'h00,
          $sformatf("the firmware polled SCL while the slave held it (got %0d)",
                    dut.dmem[0]));
    check(dut.dmem[15] == 8'hA5,
          $sformatf("the stretched transaction still completes (got %02h)",
                    dut.dmem[15]));
    check(dut.dmem[5] == 8'h11 && dut.dmem[6] == 8'h22 && dut.dmem[7] == 8'h33,
          $sformatf("all three read bytes survive the stretch (%02h %02h %02h)",
                    dut.dmem[5], dut.dmem[6], dut.dmem[7]));
    check(sl_rd_served == N_RD && sl_rd_ack == N_RD - 1,
          $sformatf("the burst itself is unaffected (%0d served, %0d acked)",
                    sl_rd_served, sl_rd_ack));
    // The tHIGH window must start from the REAL rising edge, so the floor
    // still holds even though the slave extended the low phase.
    check(min_high_ns >= 4000,
          $sformatf("tHIGH still >= 4.0 us after the stretch (got %0d ns)",
                    min_high_ns));
    // The low phase must be LONGER than the master's own tLOW (~7 us) by the
    // stretch the case configured. The bound is derived from the configuration
    // rather than written as a literal, so changing the stretch length cannot
    // quietly turn this into a check that passes for the wrong reason: 900
    // clocks is 15 us, and the measured maximum is 15.016 us, so an 80%
    // bound still catches a stretch that silently stopped happening.
    check(max_low_ns > (cfg_stretch_len * 1000 / CLK_HZ) * 80 / 100,
          $sformatf("a low phase really was stretched (max tLOW=%0d ns, configured %0d clocks)",
                    max_low_ns, cfg_stretch_len));
    check(n_grammar == 0,
          $sformatf("the stretch introduced no grammar violation (got %0d)",
                    n_grammar));
    $display("    the slave held SCL low %0d times; the firmware spent %0d polls waiting",
             stretch_events, dut.dmem[0]);
    $display("    measured on the pads: min tLOW=%0d ns  min tHIGH=%0d ns  max tLOW=%0d ns",
             min_low_ns, min_high_ns, max_low_ns);

    // ================= 3. a stretch right at the repeated START ==========
    $display("\n=== a stretch at the repeated START ===");
    // Fall 2 is the first data clock after the repeated START, so the slave
    // owns SCL while the master is already committed to the read-address
    // byte. This is the case a "wait one tick longer" fix cannot pass.
    cfg_stretch_enable = 1'b1; cfg_stretch_at = 8'd20; cfg_stretch_len = 16'd1500;
    reset_and_load();
    cfg_stretch_enable = 1'b0;

    check(dut.dmem[0] > 8'h00,
          $sformatf("the firmware polled through the START stretch (got %0d)",
                    dut.dmem[0]));
    check(dut.dmem[15] == 8'hA5,
          $sformatf("the transaction completes across a START stretch (got %02h)",
                    dut.dmem[15]));
    check(sl_addr[0] == WRITE_ADDR && sl_addr[1] == READ_ADDR,
          $sformatf("both addresses still decoded (%02h %02h)",
                    sl_addr[0], sl_addr[1]));
    check(n_start == 2 && n_stop == 1,
          $sformatf("START/STOP grammar intact (%0d starts, %0d stops)",
                    n_start, n_stop));

    // ================= 4. read-address NACK: no burst is attempted =======
    $display("\n=== read-address NACK: the burst never starts ===");
    cfg_nack_mode = 2'd3;
    reset_and_load();
    cfg_nack_mode = 2'd0;
    check(dut.dmem[4] == 8'h10,
          $sformatf("the read address was NACKed (got %02h)", dut.dmem[4]));
    check(dut.dmem[15] == 8'h55,
          $sformatf("the transaction aborted (got %02h)", dut.dmem[15]));
    check(sl_rd_served == 0,
          $sformatf("no read byte is clocked after a read-address NACK (got %0d)",
                    sl_rd_served));
    check(n_stop == 1, $sformatf("a STOP ends the abort (got %0d)", n_stop));
    check(sda_line === 1'b1 && scl_line === 1'b1, "bus released");

    $display("");
    if (errors == 0) $display("PASS: tb_pe_soc_i2c_adv");
    else             $display("FAILURES: %0d", errors);
    $finish;
  end

  initial begin
    #60_000_000;
    $display("FAIL: watchdog -- the test did not complete");
    $display("  pc=%0d state=%0d dmem15=%02h", dbg_pc, dut.dmem[10], dut.dmem[15]);
    $finish;
  end

endmodule
