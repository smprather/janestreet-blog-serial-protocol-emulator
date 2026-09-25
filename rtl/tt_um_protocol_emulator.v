// tt_um_protocol_emulator.v — the Tiny Tapeout top level.
//
// Everything else in rtl/ is a block with its own testbench. This is the only
// module that is a DELIVERABLE: Tiny Tapeout instantiates `tt_um_*` by name and
// nothing else in this repo is submittable. Until it existed, the pin analysis
// in wiki/reference/protocol-pin-budget.md described a pad interface that no
// RTL here implemented.
//
// ---------------------------------------------------------------------------
// THE TT PAD CONTRACT (wiki/entities/tiny-tapeout.md)
//
//   ui_in   [7:0]  dedicated inputs
//   uo_out  [7:0]  dedicated outputs
//   uio_in  [7:0]  bidirectional, value driven INTO the chip
//   uio_out [7:0]  bidirectional, value driven OUT of the chip
//   uio_oe  [7:0]  1 = drive uio_out, 0 = release (input / high-Z)
//   ena            1 when this design is selected by the mux. NOT a reset.
//   clk, rst_n     clock and ACTIVE-LOW reset
//
// Two rules that are easy to get wrong and expensive to get wrong at tapeout:
//
//   1. `ena` must not gate logic. The harness holds it low for unselected
//      designs and the mux is not glitch-free; gating a clock or a reset with
//      it is how a design comes back dead. It is ignored here, deliberately,
//      and sunk explicitly so the lint gate does not flag it.
//   2. Every output must be driven in every state. An undriven uo_out bit is
//      a floating pad.
//
// ---------------------------------------------------------------------------
// OPEN DRAIN, WHICH IS WHAT THE I2C MILESTONE NEEDS
//
// `uio_oe` is per-pin, so open-drain is native to the pad: drive low by
// asserting oe with uio_out=0, and release by deasserting oe. The value in
// uio_out while oe is low cannot reach the pad, so the release ordering that
// wiki/plans/through-i2c.md worries about is a non-issue at this level -- but
// uio_out is still driven to 1 on release, so that the intent is readable in a
// waveform and so a reviewer does not have to prove the oe gating themselves.
//
// This wrapper does NOT yet contain the pin matrix. It wires the software-UART
// SoC to real pads so the deliverable exists and is testable end to end; the
// matrix replaces the fixed mapping below at step 4 of the plan.
//
// ---------------------------------------------------------------------------
// PIN MAP
//
//   ui_in[0]    UART RX          (the protocol input pin)
//   ui_in[1]    run              1 = execute firmware, 0 = hold at PC 0
//   ui_in[2]    10BASE-T RX      (Manchester line input; port bit 7)
//   ui_in[7:3]  free             (R1: the old loader pads moved to uio[4:7])
//
//   uo_out[0]   UART TX / SPI SCLK  shared port bit 0, one persona at a time
//   uo_out[1]   IRQ_N            host fault, active low (R1; sticky)
//   uo_out[2]   eth_tx           10BASE-T TX (reclaims dbg_pc[0]: port bit 7)
//   uo_out[7:3] dbg_pc[5:1]      visible program counter, for bring-up
//
//   uio[0]      SDA              open-drain, for the I2C milestone
//   uio[1]      SCL              open-drain, for the I2C milestone
//   uio[2]      SPI MOSI         push-pull, port bit 1
//   uio[3]      SPI CS_N         push-pull, port bit 2
//   uio[4]      host CS_N        framed host bus, lower PMOD SPI row (R1)
//   uio[5]      host MOSI        framed host bus (R1)
//   uio[6]      host MISO        framed response, released when idle (R1)
//   uio[7]      host SCK         framed host bus (R1)
//
// SCLK (port bit 0) and MISO (port bit 3) are NOT remapped: SCLK already has
// its pad on uo_out[0] and MISO on ui_in[0], shared with UART TX/RX because the
// two protocols share the SoC's port bits and only one firmware image runs at
// a time. Only the two output bits with no pad -- MOSI and CS_N -- are added.
// A second SCLK pad would duplicate uo_out[0]; there is no input mux for a
// dedicated MISO. See wiki/plans/spi-pads.md.
//
// WHY FIVE PADS STILL CARRY THE PROGRAM COUNTER (decision 2026-09-23, STATUS
// item 4; amended by the eth-tx plan G6 adoption 2026-09-24). Not because pads
// are free: the committed pinout uses 19 of 24 usable pads, and a literal "all
// nine protocols at once" needs 22 disjoint wires (10 out, 5 in, 7 bidir). It
// does NOT fit even if these five were reclaimed -- the direction-aware
// arithmetic is generated from this wrapper and info.yaml into
// wiki/reference/protocol-pin-budget.md. What the budget does not threaten is
// every realistic case: the baseline (UART/SPI/I2C) and any single- or
// two-protocol persona. Under R1 (2026-09-24) the framed host bus owns
// uio[4:7] (CS_N/MOSI/MISO/SCK) and IRQ_N is uo_out[1], so no uio is free and
// ui_in[3:7] are the free pads; the A1 uio[4] echo is retired (its
// commit-latched semantics live in the framed LOAD response), so STATUS item
// 4's revisit trigger fired and the manager adopted G6: uo_out[2] (dbg_pc[0])
// is reclaimed as the 10BASE-T `eth_tx` pad behind a bit-identical reset mux
// (`pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0]`; see the outputs below). The
// remaining five debug pins stay dbg_pc[5:1] until a later protocol needs
// them; the free-uio alternative was voided by the R1 pad map (no uio is
// free). The matrix can already drive the committed uio pads at runtime, so
// this is a pinout choice, not a capability limit.
//
// The two I2C uio pins are wired as a loopback-capable open-drain pair driven
// from the SoC's pin today. That is enough to prove the oe path works in
// silicon, which is the thing wiki/plans/through-i2c.md flags as unverified.
// uio[0:3] are the firmware protocol row (SDA/SCL, SPI MOSI/CS_N);
// uio[4:7] are the framed host bus CS_N/MOSI/MISO/SCK (R1), and uo_out[1] is
// IRQ_N. The old heartbeat on uo_out[1] moved into the STATUS response.

module tt_um_protocol_emulator (
  input  wire [7:0] ui_in,      // dedicated inputs
  output wire [7:0] uo_out,     // dedicated outputs
  input  wire [7:0] uio_in,     // bidirectional: input path
  output wire [7:0] uio_out,    // bidirectional: output path
  output wire [7:0] uio_oe,     // bidirectional: 1 = drive, 0 = release
  input  wire       ena,        // design selected. NOT a reset. Do not use.
  input  wire       clk,
  input  wire       rst_n
);

  // ---- firmware load window: pe_ctrl, the framed host bus --------------
  // The host (a Pico bridge) owns the lower PMOD SPI row:
  //   uio[4]=CS_N, uio[5]=MOSI, uio[6]=MISO, uio[7]=SCK
  // and uo_out[1] is IRQ_N (active low; the old heartbeat moved into the
  // STATUS response, phase R2). The old ui_in[3:5] loader pads are freed.
  // Plan: wiki/plans/host-controller-gui.md "PE host protocol", R1; the
  // A1 raw echo on uio[4] is superseded (its commit-latched semantics live
  // in the framed LOAD response). The protocol bits 0-3, UART/ETH RX and
  // `run` keep their assignments.
  //
  // Width follows the SoC's loader port, which follows IMEM_WORDS. Written as
  // the same expression the SoC uses so the two cannot drift apart.
  localparam int TT_IMEM_WORDS = 1024;

  wire        host_we;
  wire        host_imem_sel;
  wire [((((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) > 8)
         ? ((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) : 8)-1:0]
       host_addr;
  wire [15:0] host_wdata;
  wire        ctrl_load_active, ctrl_load_error;
  wire [15:0] ctrl_words_written, ctrl_faults;
  wire        ctrl_spi_miso, ctrl_miso_oe, ctrl_irq_n;
  // R2: pe_ctrl drives the bounded reads and receives the architectural state.
  wire        dbg_rd_req, dbg_rd_dmem, dbg_rd_valid;
  wire [15:0] dbg_rd_addr, dbg_rd_data;

  // R2: the debug bus is FULL WIDTH at the SoC (dbg_pc is PCW bits, i.e. 10
  // in a 1,024-word machine). Declared before BOTH instances below (Icarus
  // binds declaration before use). The pads still expose only dbg_pc[5:1] — a
  // pad can carry 6 bits, and that limit is a pin budget fact, not a register
  // truncation. The host read path sees the whole register.
  wire [9:0] dbg_pc;
  wire [7:0] dbg_a, dbg_x, dbg_y, dbg_timer;
  wire [15:0] dbg_insn;

  pe_ctrl #(.WORDS(TT_IMEM_WORDS)) u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(uio_in[7]), .spi_mosi(uio_in[5]), .spi_cs_n(uio_in[4]),
    .spi_miso(ctrl_spi_miso), .miso_oe(ctrl_miso_oe), .irq_n(ctrl_irq_n),
    .run(ui_in[1]),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(ctrl_load_active), .load_error(ctrl_load_error),
    .words_written(ctrl_words_written), .faults(ctrl_faults),
    .dbg_rd_req(dbg_rd_req), .dbg_rd_dmem(dbg_rd_dmem),
    .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
    .dbg_rd_valid(dbg_rd_valid),
    .dbg_pc(dbg_pc), .dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y),
    .dbg_insn(dbg_insn), .dbg_timer(dbg_timer)
  );

  wire       uart_rx = ui_in[0];
  wire       run     = ui_in[1];

  // The SoC's pin port carries PROTOCOL pins only -- `run` is a separate
  // control input, not a pin. Under the SoC's "outputs low, inputs high" rule
  // (see the header of rtl/pe_soc.v) the three baseline protocols share:
  //   bit 0 = TX / SCLK, bit 1 = (spare) / MOSI, bit 2 = (spare) / CS_N,
  //   bit 3 = RX / MISO, bit 4 = I2C SDA, bit 5 = I2C SCL
  // which is why PIN_IN_MASK there is 8'hF8. Bits 0 and 3 are the UART pair on
  // dedicated pads; I2C lives on `uio` and is attached below.
  wire [7:0] pin_in_bus;
  wire [7:0] pin_out_bus;
  wire [7:0] pin_oe_bus;

  // UART RX (bit 3) is a dedicated input pad. Bits 4/5 (SDA/SCL) come from
  // `uio_in` and are attached after the pads are declared -- see below.
  assign pin_in_bus[3]   = uart_rx;
  assign pin_in_bus[2:0] = 3'b000;
  assign pin_in_bus[7]   = ui_in[2];   // 10BASE-T RX -> the DRU's raw pin
  assign pin_in_bus[6]   = 1'b0;

  pe_soc #(
    .IMEM_WORDS(TT_IMEM_WORDS),
    .DMEM_BYTES(16),
    .BAUD(115_200)
  ) u_soc (
    .clk(clk),
    .rst_n(rst_n),
    .host_we(host_we),
    .host_imem_sel(host_imem_sel),
    .host_addr(host_addr),
    .host_wdata(host_wdata),
    .run(run),
    .dbg_rd_req(dbg_rd_req),
    .dbg_rd_dmem(dbg_rd_dmem),
    .dbg_rd_addr(dbg_rd_addr),
    .dbg_rd_data(dbg_rd_data),
    .dbg_rd_valid(dbg_rd_valid),
    .pin_in(pin_in_bus),
    .pin_out(pin_out_bus),
    .pin_oe(pin_oe_bus),
    .dbg_pc(dbg_pc),
    .dbg_a(dbg_a),
    .dbg_x(dbg_x),
    .dbg_y(dbg_y),
    .dbg_insn(dbg_insn),
    .dbg_timer(dbg_timer)
  );

  // ---- dedicated outputs -------------------------------------------------
  // uo_out[2] is the reclaimed 10BASE-T eth_tx pad (G6, Task 4): while the
  // matrix drives port bit 7 (firmware's PINOE plus the engine overlay) the
  // pad carries that bit; otherwise uo_out[7:2] is dbg_pc[5:0] EXACTLY as
  // before, which is the reset-bit-identical rule. The mux has no glitch to
  // worry about: both sources are levels and the select is a matrix register.
  assign uo_out[0]   = pin_out_bus[0];    // UART TX / SPI SCLK, port bit 0
  assign uo_out[1]   = ctrl_irq_n;        // IRQ_N: active low, sticky faults
  assign uo_out[2]   = pin_oe_bus[7] ? pin_out_bus[7] : dbg_pc[0];
  assign uo_out[7:3] = dbg_pc[5:1];

  // ---- bidirectional pins: driven by the pin matrix ----------------------
  // Port bits 4 and 5 are I2C SDA and SCL, and the matrix's per-pin enable
  // drives the pad's own output-enable. That is open-drain, natively: assert oe
  // to drive LOW, deassert to release to the board's pull-up. The pad can never
  // drive high on these pins unless firmware explicitly asks for push-pull by
  // clearing that pin's OD bit -- which is a firmware decision, made visible in
  // the waveform, and checked by tb_tt_um_protocol_emulator.
  //
  // The pad does exactly what the matrix says: level from pad_out, enable from
  // pad_oe. That is the whole point of instantiating the matrix rather than
  // hardwiring these two pins.
  //
  // This was first written as `uio_out = 0` on the reasoning that a released
  // pin should not present a level. That is wrong twice over: uio_out cannot
  // reach the pad while uio_oe is low, and forcing it to 0 silently breaks
  // PUSH-PULL mode -- the matrix can clear a pin's OD bit, in which case
  // pad_oe=1 and pad_out=1 and the pad must drive HIGH. Hardwiring 0 would have
  // driven it low instead, and the open-drain check in
  // tb_tt_um_protocol_emulator would have passed anyway, because uio_oe would
  // still be set by pad_oe. A check on the wrong signal is how that class of bug
  // survives.
  assign uio_out[0]   = pin_out_bus[4];   // SDA level
  assign uio_out[1]   = pin_out_bus[5];   // SCL level
  assign uio_oe[0]    = pin_oe_bus[4];    // SDA drive enable (open-drain gate)
  assign uio_oe[1]    = pin_oe_bus[5];    // SCL drive enable

  // SPI MOSI and CS_N are push-pull outputs: the matrix's per-pin enable gates
  // the pad, so releasing bits 1/2 releases the pads (the default UART/I2C
  // images leave them driven low per the SoC's outputs-low rule).
  assign uio_out[2]   = pin_out_bus[1];   // SPI MOSI level
  assign uio_oe[2]    = pin_oe_bus[1];    // SPI MOSI drive enable
  assign uio_out[3]   = pin_out_bus[2];   // SPI CS_N level
  assign uio_oe[3]    = pin_oe_bus[2];    // SPI CS_N drive enable

  // uio[4:7] are the framed host bus (R1): CS_N, MOSI, MISO, SCK. MISO is
  // driven only while a response frame is shifting (`miso_oe`), so the pad
  // is released when idle or when CS_N is high; the other three are inputs
  // to the chip and stay released. uio[0:3] remain the firmware matrix row.
  assign uio_out[4]   = 1'b0;
  assign uio_oe[4]    = 1'b0;            // CS_N input
  assign uio_out[5]   = 1'b0;
  assign uio_oe[5]    = 1'b0;            // MOSI input
  assign uio_out[6]   = ctrl_spi_miso;   // framed response MISO
  assign uio_oe[6]    = ctrl_miso_oe;    // driven only while a response shifts
  assign uio_out[7]   = 1'b0;
  assign uio_oe[7]    = 1'b0;            // SCK input

  // The matrix samples the pad level on the port's input bits. SDA is bit 4 and
  // SCL is bit 5, so a released SDA is readable by firmware as port bit 4 --
  // that read-back IS I2C arbitration and clock-stretch detection.
  assign pin_in_bus[4] = uio_in[0];       // SDA
  assign pin_in_bus[5] = uio_in[1];       // SCL

  // ---- deliberately unused ----------------------------------------------
  // `ena` is ignored on purpose (see the header). Port bits that no current
  // firmware claims are sunk here rather than left as a silent unused-signal
  // warning: the matrix CAN drive them, but the wrapper has no pad for them.
  // Sinking them explicitly is what keeps regress/lint.sh clean without a
  // blanket waiver.
  //
  // dbg_pc[7:6] are not brought out: only 6 of the 8 uo_out bits are spare
  // after TX and IRQ_N, and the low 6 bits of the program counter are the
  // ones that move during bring-up. dbg_a is unused by the wrapper, and the
  // heartbeat `dbg_timer[7]` now lives only in the phase-R2 STATUS payload.
  //
  // ui_in[7:3] are free since the host bus moved to uio[4:7]; uio_in[6] is
  // the chip's own MISO output pin (its input path is unused) and
  // uio_in[3:2] belong to firmware outputs.
  wire _unused = &{ena, ui_in[7:3], uio_in[6], uio_in[3:2],
                   pin_out_bus[6], pin_out_bus[3],
                   pin_oe_bus[6], pin_oe_bus[3], pin_oe_bus[0],
                   dbg_timer,
                   ctrl_load_active, ctrl_load_error, ctrl_words_written,
                   ctrl_faults, 1'b0};

endmodule
