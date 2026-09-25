// tb_pe_soc_ds18b20.v — a DS18B20 on 1-Wire, driven and read by firmware.
//
// WHAT THIS PROVES, AND WHY IT IS A DIFFERENT SHAPE OF PROBLEM FROM THE DHT11.
//
// The DHT11 act samples BETWEEN two windows: a 0's release is over by 78 us and a
// 1's is not over until 120, so the host waits and looks in the gap. A DS18B20
// read slot is sampled INSIDE the slot and the bit order is LSB first — the
// opposite of the DHT11 on both counts. On top of that this is the only act
// where the DEVICE initiates: after the host's reset pulse the sensor drives a
// presence pulse back, and every read slot begins with the sensor's own
// response. So this exercises the pin matrix's read-back and its edge-wait
// loops in a way nothing else here does.
//
// THE CHECKS, and how each could be unfalsified:
//
//   1. THE RESET PULSE, MEASURED ON THE PIN: the line is low for >= 480 us. This
//      is a COUNTED delay and the reset is the one thing on 1-Wire that nothing
//      announces, so it is the one thing that has to be counted.
//   2. THE HOST RELEASED for the presence pulse, checked on the SoC's own pin_oe
//      on every clock of the pulse, so the wire model cannot hide a host that
//      forgot to let go — and the pulse itself inside the datasheet's 60-240 us.
//   3. THE WRITE SLOTS: 0xCC (SKIP ROM) and 0xBE (READ SCRATCHPAD) are decoded
//      FROM THE PADS, and each slot's low period is inside the datasheet's own
//      band (1-15 us for a 1, 60-120 us for a 0). The model watches the line for
//      the write-slot pattern, so a firmware that sends the wrong command, the
//      wrong bit order, or a slot of the wrong length fails here rather than
//      "working" against a model that agreed with it by construction.
//   4. THE READ SLOTS, DECODED: the two temperature bytes come back LSB-first
//      into dmem[0..1] and are compared against the payload the model sent.
//   5. THE READ SLOT COUNT: exactly 16. The loop is bounded by a counter, and a
//      counter that starts at zero (which it did) reads 255 slots and then
//      walks the byte index round onto its own slots.
//   6. THE READ SLOT WIDTHS, MEASURED BOTH SIDES: every read slot's initiation
//      pulse is inside the datasheet's 1-15 us, and the sample instant is
//      inside the sensor's data window with >= 2 us of margin at BOTH ends —
//      the response side, which is the datasheet's own 15 us maximum, and the
//      hold side. A firmware that samples before the sensor can have answered
//      gets the line high for every bit; one that samples after the hold ends
//      gets it low. Both are caught, and neither is caught by the decode alone
//      being "about right".
//   7. NON-VACUITY: the payload is chosen with both bit values in every byte
//      and bit-transitions throughout, and the TB asserts the transition count.
//      A firmware that sampled at the wrong instant, or read the bits in the
//      wrong order, or with the wrong POLARITY, cannot produce it by accident —
//      the polarity one produced the exact bit-complement of the payload, which
//      had the right bit count and no visible symptom at all.
//
// THE COST: about 2.2 ms of 60 MHz, which is the reset (486 us), sixteen write
// slots (~62 us each) and sixteen read slots (~33 us each). That is well under
// a second of simulation, and the $dumpvars is a narrow signal set rather than
// the whole DUT, because for the two long acts in this repository the waveform
// was the bottleneck, not the design.
//
// Program: firmware/ds18b20.pe, assembled by tools/fw/peasm.py.

`timescale 1ns / 1ps

// The image under test. Overridable so the mutation harness can compile ONE
// testbench against a mutated image without editing the tree.
`ifndef DS18B20_HEX
  `define DS18B20_HEX "../firmware/ds18b20.hex"
`endif

module tb_pe_soc_ds18b20;

  localparam int IMEM_WORDS = 1024;
  localparam int IAW = $clog2(IMEM_WORDS);
  localparam int DMEM_BYTES = 16;
  localparam int BAUD = 115_200;

  localparam int  CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;
  localparam real CYC_US = 1e6 / CLK_HZ;      // microseconds per clock (1e6: ns-scale, NOT 1e3)
  localparam real NS_PER_CYC = 1e9 / CLK_HZ;

  localparam int DATA_BIT = 6;

  localparam logic [7:0] CMD_SKIP_ROM = 8'hCC;
  localparam logic [7:0] CMD_READ     = 8'hBE;

  // The scratchpad the sensor model will return. The first two bytes are the
  // temperature, 0x2B 0x01 = 43.0 C, and both bit values appear in both bytes.
  // The other seven are here so that a firmware which reads too MANY slots
  // banks real, checkable data over its own dmem[0..1] instead of reading back
  // its own leftovers: the tail of a 9-byte scratchpad (TH, TL, config,
  // reserved, all-ones, and the user's alarm bytes).
  localparam int SCRATCH_N = 9;
  logic [7:0] scratch [0:SCRATCH_N-1];
  localparam logic [7:0] SCRATCH_LSB = 8'h2B;
  localparam logic [7:0] SCRATCH_MSB = 8'h01;

  // The datasheet's windows, and where inside each the model drives.
  localparam real RESET_MIN_US   = 480.0;
  localparam real PRES_LO_MIN_US = 60.0;
  localparam real PRES_LO_MAX_US = 240.0;
  localparam real W1_LO_MIN_US   = 1.0;        // a write-1's low pulse
  localparam real W1_LO_MAX_US   = 15.0;
  localparam real W0_LO_MIN_US   = 60.0;       // a write-0's low pulse
  localparam real W0_LO_MAX_US   = 120.0;
  localparam real RD_INIT_MIN_US = 1.0;        // a read slot's initiation pulse
  localparam real RD_INIT_MAX_US = 15.0;
  localparam real SAMPLE_MARGIN_MIN_US = 2.0;  // either side of the data window

  // The SENSOR's own timings inside a read slot, from the datasheet.
  //
  // tRDV is driven at its MAXIMUM (15 us). That is the adversarial direction:
  // the sensor answers as late as the datasheet allows, so a host that samples
  // early reads a line no one is driving and takes every bit for a zero. It is
  // also the only side of the read slot that can be driven at a bound.
  //
  // tLOW and tHIGH are mid-band (30 us, 10 us) and NOT worst case, and the
  // reason is worth stating because it is a fact about 1-Wire rather than a
  // convenience: a one is released at tRDV + tLOW + tHIGH and a zero at
  // tRDV + tLOW, and with tLOW in 15-60 and tHIGH in 1-15 the two windows
  // OVERLAP. A single sample instant that is correct for every legal sensor
  // timing does not exist — the guaranteed window is one microsecond wide.
  // So the model drives a real sensor's real timing and the TB MEASURES the
  // margin on each side of the sample rather than asserting a band the
  // protocol cannot guarantee. Claiming the worst case here would be a
  // stronger-sounding and false statement.
  localparam int TRDV_CYC  = 15 * (CLK_HZ / 1_000_000);
  localparam int TLOW_CYC  = 30 * (CLK_HZ / 1_000_000);
  localparam int THIGH_CYC = 10 * (CLK_HZ / 1_000_000);

  logic clk = 0, rst_n;
  logic           host_we, host_imem_sel, run;
  logic [IAW-1:0] host_addr;
  logic [15:0]    host_wdata;

  wire [7:0] pin_out_bus, pin_oe_bus;
  logic [7:0] pin_in_bus;

  // THE WIRE. A pull-up, the SoC's pads, and the sensor's open-drain pull-down.
  // Three drivers; the line is low if any of them pulls it.
  logic sensor_low = 1'b0;
  wire  soc_drives_low = pin_oe_bus[DATA_BIT] & ~pin_out_bus[DATA_BIT];
  wire  ow_line = (soc_drives_low | sensor_low) ? 1'b0 : 1'b1;
  assign pin_in_bus = {1'b1, ow_line, 6'b111111};

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
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_timer(dbg_timer),
    // R3 debug control, idle. These two ports arrived with the R3 block, and a
    // testbench that predates them leaves them UNCONNECTED -- which arrives as
    // Z, makes the core's execute gate X, and the firmware then never executes
    // a single instruction: every dmem read comes back x and the pin never
    // moves. rtl/pe_cpu.v now defaults them defensively too; this tie-off is
    // the act not DEPENDING on that, so the two repairs cannot mask each other.
    .dbg_hold(1'b0), .dbg_step(1'b0)
  );

  always #(CLK_NS/2) clk = ~clk;

  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  integer errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL: %s @%0t", m, $time); errors++; end
  endtask

  integer i, j, t_fall, n_edge, n_oe, trans;
  integer e_cyc [0:255];
  bit     e_lvl [0:255];
  integer e_oe_cyc [0:255];
  bit     e_oe     [0:255];
  logic [15:0] prog [0:IMEM_WORDS-1];

  task automatic load_firmware();
    for (i = 0; i < IMEM_WORDS; i++) prog[i] = 16'hF000;
    $readmemh(`DS18B20_HEX, prog);
    for (i = 0; i < IMEM_WORDS; i++) begin
      @(posedge clk); #1;
      host_we = 1'b1; host_imem_sel = 1'b1;
      host_addr = i[IAW-1:0];
      host_wdata = prog[i];
    end
    @(posedge clk); #1;
    host_we = 1'b0;
  endtask

  // ---- the 1-Wire sensor model: ONE state machine, ONE driver -----------
  //
  // A real DS18B20 counts what the host sends and switches to answering reads
  // after the command bytes, so this does the same: the read slots are GATED ON
  // HAVING SEEN THE COMMAND BYTES RELEASE, not on a timer. The first version
  // fired the read slots 500 us after the presence pulse, which is out of phase
  // with a host that spends ~1 ms sending two command bytes -- the model then
  // answered "reads" during the writes, the firmware never saw a read slot, and
  // the TB reported 0 write bits and a 0.5 us reset against a firmware that was
  // actually correct. A model that does not follow the protocol cannot test it.
  localparam int X_IDLE = 0, X_PRES_WAIT = 1, X_PRES_LO = 2, X_PRES_HI = 3,
                 X_WRITE = 4, X_SETTLE = 5, X_READY = 6,
                 X_WAIT_REL = 7, X_RESP = 8, X_HOLD = 9;
  integer xs = X_IDLE, xend_cyc = 0;
  logic   xarmed = 1'b0, xsaw_start = 1'b0, host_was_low = 1'b0;
  integer xlow_start = -1;

  integer w_bits [0:15];
  integer n_wbits = 0, w_cmd1 = -1, w_cmd2 = -1;
  integer r_slots = 0;
  logic   cur_bit = 1'b0;
  integer win_open_cyc = 0, win_close_cyc = 0;

  // Measurements. Every one of these is a NUMBER this TB prints and checks; a
  // check that reads a constant back out of the DUT is not a check.
  integer pres_lo_cyc0 = -1, pres_hi_cyc = -1, pres_oe_bad = 0;
  integer w1_lo_cyc = 1 << 30, w1_lo_hi = 0, w0_lo_cyc = 1 << 30, w0_lo_hi = 0;
  integer rd_init_lo = 1 << 30, rd_init_hi = 0;
  integer marg_open_min = 1 << 30, marg_close_min = 1 << 30, n_sampled = 0;
  integer last_bit3 = 0;
  logic [7:0] r_byte [0:1];
  integer n_rbyte = 0;

  // The payload, in bits, LSB first, as the model will drive it.
  task automatic reset_measurements();
    n_wbits = 0; n_rbyte = 0; r_slots = 0; n_sampled = 0;
    w_cmd1 = -1; w_cmd2 = -1; xlow_start = -1;
    pres_lo_cyc0 = -1; pres_hi_cyc = -1; pres_oe_bad = 0;
    w1_lo_cyc = 1 << 30; w1_lo_hi = 0; w0_lo_cyc = 1 << 30; w0_lo_hi = 0;
    rd_init_lo = 1 << 30; rd_init_hi = 0;
    marg_open_min = 1 << 30; marg_close_min = 1 << 30;
    last_bit3 = 0;
    host_was_low = 1'b0;
    xsaw_start = 1'b0; xarmed = 1'b0; xs = X_IDLE;
    sensor_low = 1'b0;
    for (i = 0; i < 16; i++) w_bits[i] = -1;
    for (i = 0; i < 2; i++) r_byte[i] = 8'h00;
  endtask

  // Reconstruct a byte from 8 reconstructed write bits (LSB first).
  function [7:0] pack8(input integer base);
    integer b;
    begin
      pack8 = 8'h00;
      for (b = 0; b < 8; b = b + 1)
        if (w_bits[base + b] == 1) pack8 = pack8 | (8'h01 << b);
    end
  endfunction

  // The bit the model will present for read slot `s`, LSB first within its byte.
  function integer payload_bit(input integer s);
    begin
      payload_bit = (scratch[s / 8] >> (s % 8)) & 1;
    end
  endfunction

  integer r_pull0 = 0, r_lo_cyc;

  // THE ONLY DRIVER of sensor_low in the whole testbench (the tick_flag lesson).
  always @(posedge clk) begin
    if (run && rst_n) begin
      if (soc_drives_low) xsaw_start = 1'b1;

      // ---- arm on the host's release at the end of the reset pulse ----
      if (!xarmed && xsaw_start && !pin_oe_bus[DATA_BIT]) begin
        xarmed   = 1'b1;
        xs       = X_PRES_WAIT;
        xend_cyc = cyc + (10 * (CLK_HZ / 1_000_000));   // the sensor's response
      end

      // ---- time every low period the HOST drives, to decode its write bits
      if (soc_drives_low) begin
        if (xlow_start < 0) xlow_start = cyc;
      end else if (xlow_start >= 0) begin
        r_lo_cyc = cyc - xlow_start;
        if (xs == X_WRITE && n_wbits < 16) begin
          // a short low is a 1, a ~60 us low is a 0
          w_bits[n_wbits] = (r_lo_cyc < (30 * (CLK_HZ / 1_000_000))) ? 1 : 0;
          if (w_bits[n_wbits] == 1) begin
            if (r_lo_cyc < w1_lo_cyc) w1_lo_cyc = r_lo_cyc;
            if (r_lo_cyc > w1_lo_hi)   w1_lo_hi   = r_lo_cyc;
          end else begin
            if (r_lo_cyc < w0_lo_cyc) w0_lo_cyc = r_lo_cyc;
            if (r_lo_cyc > w0_lo_hi)   w0_lo_hi   = r_lo_cyc;
          end
          n_wbits = n_wbits + 1;
          if (n_wbits == 8)  w_cmd1 = pack8(0);
          if (n_wbits == 16) w_cmd2 = pack8(8);
        end
        xlow_start = -1;
      end

      // ---- the read slot's two edges, detected from the PADS and not from
      // the state machine's position. The master pulls the line low to ask for
      // a bit and then releases; the release IS the request. Detecting it here
      // rather than in X_WAIT_REL is what makes the model survive its own
      // hold: the master's next release arrives while the model is still
      // inside the previous bit's window (a one is held for tLOW + tHIGH and
      // the master only waits tRDV + 25 us), so a state machine that only
      // listened inside X_WAIT_REL missed it and the run stopped at eight
      // slots -- the firmware banked the right first byte and then read a
      // second one off a model that had stopped answering.
      if (xs == X_READY || xs == X_WAIT_REL || xs == X_RESP || xs == X_HOLD) begin
        if (soc_drives_low) begin
          if (!host_was_low) r_pull0 = cyc;      // the initiation pulse starts
          host_was_low = 1'b1;
        end else if (host_was_low) begin
          host_was_low = 1'b0;                    // released: a bit is wanted
          r_lo_cyc = cyc - r_pull0;
          if (r_lo_cyc < rd_init_lo) rd_init_lo = r_lo_cyc;
          if (r_lo_cyc > rd_init_hi) rd_init_hi = r_lo_cyc;
          cur_bit       = payload_bit(r_slots);
          win_open_cyc  = cyc + TRDV_CYC;
          win_close_cyc = win_open_cyc + TLOW_CYC + (cur_bit ? THIGH_CYC : 0);
          r_slots       = r_slots + 1;
          xs = X_RESP;
        end
      end

      case (xs)
        // ---- the presence pulse: the sensor answers the reset ----
        X_PRES_WAIT: if (cyc >= xend_cyc) begin
          xs = X_PRES_LO;
          xend_cyc = cyc + (120 * (CLK_HZ / 1_000_000));  // mid-band
          pres_lo_cyc0 = cyc;
        end
        X_PRES_LO: begin
          // the host MUST have let go, or the sensor could not be driving
          if (pin_oe_bus[DATA_BIT]) pres_oe_bad = pres_oe_bad + 1;
          if (cyc >= xend_cyc) begin
            pres_hi_cyc = cyc;
            // the sensor releases and the host writes immediately: there is no
            // extra high hold here, because the real device does not insert one
            xs = X_PRES_HI;
            xend_cyc = cyc + (2 * (CLK_HZ / 1_000_000));
          end
        end
        X_PRES_HI: if (cyc >= xend_cyc) xs = X_WRITE;

        // ---- the write phase ends on the host's RELEASE, not on a bit count.
        // Gating on a bit-count is fragile: one extra or missing low period
        // desyncs the model, and it then reads the firmware's remaining WRITE
        // lows as read initiations -- the send register was found half-shifted
        // because the model had moved on while the firmware was still writing
        // the second command. This is the same edge the firmware's wr_done
        // makes, and it is a release, so both sides agree by construction.
        X_WRITE: if (n_wbits >= 16 && !soc_drives_low && !pin_oe_bus[DATA_BIT]) begin
          xs = X_SETTLE;
          xend_cyc = cyc + (30 * (CLK_HZ / 1_000_000));
        end
        X_SETTLE: if (cyc >= xend_cyc) xs = X_READY;

        X_READY: ;                                       // released, waiting
        // Between the master's release and tRDV the sensor is SILENT and the
        // pull-up owns the line. That three-state window is the point of the
        // whole model: a master that samples in it reads high for every bit,
        // and a model that presented the data immediately could not tell the
        // difference between that firmware and a correct one.
        X_RESP:  if (cyc >= win_open_cyc)  xs = X_HOLD;
        X_HOLD:  if (cyc >= win_close_cyc) xs = X_READY;
        default: ;
      endcase

      // ---- THE ONLY assignment to sensor_low (one driver, always). ----
      case (xs)
        X_PRES_LO: sensor_low = 1'b1;    // the presence pulse
        X_PRES_HI: sensor_low = 1'b0;    // released
        // The data LEVEL: low for a one, released for a zero. On a wired-AND
        // bus the master's own pull-down is invisible to this, so the hold is
        // the sensor's own timer and is NOT cut short by the master starting
        // the next slot: the master has already taken its sample by then.
        X_HOLD:    sensor_low = cur_bit;
        default:   sensor_low = 1'b0;    // released: the master owns the line
      endcase

      // ---- THE SAMPLE INSTANT. The firmware reads the level at ph4 (its
      // `IN A, PIN`) and decrements dmem[3] three instructions later, so the
      // DECREMENT is used as the marker: it is a data-memory change, so it
      // survives an edit that moves the sample in the source, where a
      // hardcoded program counter would silently go on measuring nothing.
      // It has to be the decrement and not merely a change -- the byte
      // boundary reloads dmem[3] back to 8, which is also a change, and
      // counting it measured a "sample" 13 us after the window had closed.
      // The three-clock lag makes both margins slightly pessimistic.
      if (dut.dmem[3] != last_bit3) begin
        if (last_bit3 != 0 && dut.dmem[3] == last_bit3 - 1) begin
        if (r_slots > 0 && win_close_cyc > win_open_cyc) begin
          if ((cyc - win_open_cyc)  < marg_open_min)  marg_open_min  = cyc - win_open_cyc;
          if ((win_close_cyc - cyc) < marg_close_min) marg_close_min = win_close_cyc - cyc;
          n_sampled = n_sampled + 1;
          if (n_rbyte < 2) begin
            if (ow_line == 1'b0)                      // a one: the line is LOW
              r_byte[n_rbyte] = r_byte[n_rbyte] | (8'h01 << ((n_sampled - 1) % 8));
            if ((n_sampled % 8) == 0) n_rbyte = n_rbyte + 1;
          end
        end
        end
        last_bit3 = dut.dmem[3];
      end
    end
  end

  always @(ow_line) if (run && rst_n && n_edge < 256) begin
    e_cyc[n_edge] = $realtime * CLK_HZ / 1.0e9; e_lvl[n_edge] = ow_line;
    n_edge = n_edge + 1;
  end
  always @(pin_oe_bus[DATA_BIT]) if (run && rst_n && n_oe < 256) begin
    e_oe_cyc[n_oe] = $realtime * CLK_HZ / 1.0e9; e_oe[n_oe] = pin_oe_bus[DATA_BIT];
    n_oe = n_oe + 1;
  end

  initial begin
    $dumpfile("tb_pe_soc_ds18b20.vcd");
    $dumpvars(0, ow_line, pin_oe_bus, pin_in_bus, dbg_pc, sensor_low, xs);

    scratch[0] = SCRATCH_LSB;  scratch[1] = SCRATCH_MSB;  scratch[2] = 8'h4B;
    scratch[3] = 8'h46;        scratch[4] = 8'h7F;        scratch[5] = 8'hFF;
    scratch[6] = 8'h0C;        scratch[7] = 8'h10;        scratch[8] = 8'h00;

    n_edge = 0; n_oe = 0;
    reset_measurements();

    rst_n = 1'b0; run = 1'b0; host_we = 1'b0; host_imem_sel = 1'b0;
    host_addr = '0; host_wdata = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    load_firmware();
    repeat (4) @(posedge clk);
    #1;

    $display("\n=== DS18B20 1-Wire: reset, presence, 0xCC/0xBE, timed read slots ===\n");
    run = 1'b1;
    repeat (180_000) @(posedge clk);   // 3 ms: 486 us reset + 16 writes + 16 reads

    // ---- 1. the reset pulse, from the pin --------------------------------
    t_fall = -1;
    for (j = 0; j < n_edge; j = j + 1)
      if (!e_lvl[j] && t_fall < 0) t_fall = e_cyc[j];
    check(t_fall >= 0, "the host pulled the 1-Wire line low (the reset pulse)");
    if (t_fall >= 0) begin
      j = 0;
      for (j = 0; j < n_edge; j = j + 1)
        if (e_lvl[j] && e_cyc[j] > t_fall) begin
          i = e_cyc[j] - t_fall; break;   // i reused as the width, in cycles
        end
      $display("    reset pulse: line low for %.1f us (min %.0f)",
               i * CYC_US, RESET_MIN_US);
      check(i * CYC_US >= RESET_MIN_US,
            $sformatf("the reset pulse is >= %.0f us -- got %.1f us",
                      RESET_MIN_US, i * CYC_US));
    end

    // ---- 2. the presence pulse, and that the host let go for it ----------
    if (pres_lo_cyc0 >= 0 && pres_hi_cyc > pres_lo_cyc0) begin
      $display("    presence pulse: %.1f us (datasheet %.0f-%.0f us)",
               (pres_hi_cyc - pres_lo_cyc0) * CYC_US, PRES_LO_MIN_US, PRES_LO_MAX_US);
      check((pres_hi_cyc - pres_lo_cyc0) * CYC_US >= PRES_LO_MIN_US &&
            (pres_hi_cyc - pres_lo_cyc0) * CYC_US <= PRES_LO_MAX_US,
            "the presence pulse is inside the datasheet's 60-240 us");
    end else begin
      check(1'b0, "the sensor drove a presence pulse after the reset");
    end
    check(pres_oe_bad == 0,
          $sformatf("the host RELEASED the line for the whole presence pulse (%0d clocks it drove it)",
                    pres_oe_bad));

    // ---- 3. the write slots, decoded from the pads, and their widths -----
    $display("    write slots: %0d bits   1-low %.1f-%.1f us   0-low %.1f-%.1f us",
             n_wbits, w1_lo_cyc * CYC_US, w1_lo_hi * CYC_US,
             w0_lo_cyc * CYC_US, w0_lo_hi * CYC_US);
    check(n_wbits == 16,
          $sformatf("the sensor saw two bytes of write slots (%0d, want 16)", n_wbits));
    if (n_wbits == 16) begin
      $display("    command 1: %02h (want %02h SKIP ROM)   command 2: %02h (want %02h READ)",
               w_cmd1[7:0], CMD_SKIP_ROM, w_cmd2[7:0], CMD_READ);
      check(w_cmd1 == CMD_SKIP_ROM,
            $sformatf("the first command is SKIP ROM 0x%02h (got 0x%02h)", CMD_SKIP_ROM, w_cmd1));
      check(w_cmd2 == CMD_READ,
            $sformatf("the second command is READ SCRATCHPAD 0x%02h (got 0x%02h)", CMD_READ, w_cmd2));
      check(w1_lo_cyc * CYC_US >= W1_LO_MIN_US && w1_lo_hi * CYC_US <= W1_LO_MAX_US,
            $sformatf("every write-1's low pulse is inside %.0f-%.0f us -- got %.1f-%.1f us",
                      W1_LO_MIN_US, W1_LO_MAX_US, w1_lo_cyc * CYC_US, w1_lo_hi * CYC_US));
      check(w0_lo_cyc * CYC_US >= W0_LO_MIN_US && w0_lo_hi * CYC_US <= W0_LO_MAX_US,
            $sformatf("every write-0's low pulse is inside %.0f-%.0f us -- got %.1f-%.1f us",
                      W0_LO_MIN_US, W0_LO_MAX_US, w0_lo_cyc * CYC_US, w0_lo_hi * CYC_US));
    end

    // ---- 4/5. the read slots: how many, and what they said --------------
    $display("    read slots: %0d, sampled: %0d, model decoded: %02h %02h",
             r_slots, n_sampled, r_byte[0], r_byte[1]);
    $display("    firmware dmem[0..1]: %02h %02h (want %02h %02h, LSB first)",
             dut.dmem[0], dut.dmem[1], SCRATCH_LSB, SCRATCH_MSB);
    check(r_slots == 16,
          $sformatf("the host asked for exactly 16 read slots (%0d)", r_slots));
    check(n_sampled == 16,
          $sformatf("all 16 slots were sampled inside a data window (%0d)", n_sampled));
    check(dut.dmem[14] == 8'h01,
          $sformatf("the firmware finished both bytes (dmem[14] = %02h)", dut.dmem[14]));
    check(dut.dmem[0] == SCRATCH_LSB && dut.dmem[1] == SCRATCH_MSB,
          $sformatf("the two temperature bytes came back LSB first (got %02h %02h, want %02h %02h)",
                    dut.dmem[0], dut.dmem[1], SCRATCH_LSB, SCRATCH_MSB));
    // The model decodes its own drive from the pins, independently of the
    // firmware, so a disagreement is attributable rather than a shared bug.
    check(r_byte[0] == SCRATCH_LSB && r_byte[1] == SCRATCH_MSB,
          $sformatf("the model read back off the wire what it drove (%02h %02h)",
                    r_byte[0], r_byte[1]));

    // ---- 6. the read slot widths, both sides of the sample ---------------
    $display("    read initiation pulses: %.1f-%.1f us (datasheet %.0f-%.0f us)",
             rd_init_lo * CYC_US, rd_init_hi * CYC_US, RD_INIT_MIN_US, RD_INIT_MAX_US);
    $display("    sample instant inside the data window: %.1f us after the response, %.1f us before the hold ends",
             marg_open_min * CYC_US, marg_close_min * CYC_US);
    check(rd_init_lo * CYC_US >= RD_INIT_MIN_US && rd_init_hi * CYC_US <= RD_INIT_MAX_US,
          $sformatf("every read slot's initiation pulse is inside %.0f-%.0f us -- got %.1f-%.1f us",
                    RD_INIT_MIN_US, RD_INIT_MAX_US, rd_init_lo * CYC_US, rd_init_hi * CYC_US));
    check(marg_open_min * CYC_US >= SAMPLE_MARGIN_MIN_US,
          $sformatf("the sample is at least %.0f us after the sensor's latest permitted response -- got %.1f us",
                    SAMPLE_MARGIN_MIN_US, marg_open_min * CYC_US));
    check(marg_close_min * CYC_US >= SAMPLE_MARGIN_MIN_US,
          $sformatf("the sample is at least %.0f us before the sensor's hold ends -- got %.1f us",
                    SAMPLE_MARGIN_MIN_US, marg_close_min * CYC_US));

    // ---- 7. non-vacuity -------------------------------------------------
    trans = 0;
    for (i = 0; i < 7; i = i + 1)
      if ((SCRATCH_LSB >> i & 1) != (SCRATCH_LSB >> (i + 1) & 1)) trans = trans + 1;
    for (i = 0; i < 7; i = i + 1)
      if ((SCRATCH_MSB >> i & 1) != (SCRATCH_MSB >> (i + 1) & 1)) trans = trans + 1;
    $display("    payload bit-transitions: %0d of 14", trans);
    check(trans >= 5,
          $sformatf("the payload has enough transitions to catch a repeated-bit fault (%0d of 14)", trans));
    check(dut.dmem[0] != 8'h00 && dut.dmem[0] != 8'hFF && dut.dmem[1] != 8'h00,
          "the decoded bytes are neither all-zero nor all-ones (the polarity check)");

    $display("");
    if (errors == 0) $display("PASS: all checks");
    else             $display("FAIL: %0d checks failed", errors);
    $finish;
  end

  initial begin
    #4_000_000;
    $display("FAIL: watchdog -- test did not complete");
    $finish;
  end

endmodule
