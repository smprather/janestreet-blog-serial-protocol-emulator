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
//   ui_in[3]    SPI SCLK         (pe_ctrl loader clock; ADR-007)
//   ui_in[4]    SPI MOSI         (loader data, MSB-first)
//   ui_in[5]    SPI CS_N         (active-low loader select)
//   ui_in[7:6]  unused
//
//   uo_out[0]   UART TX          (the protocol output pin)
//   uo_out[1]   heartbeat        timer bit 7, so a scope shows life
//   uo_out[7:2] dbg_pc[5:0]      visible program counter, for bring-up
//
//   uio[0]      SDA              open-drain, for the I2C milestone
//   uio[1]      SCL              open-drain, for the I2C milestone
//   uio[7:2]    released         (oe = 0)
//
// WHY SIX PADS STILL CARRY THE PROGRAM COUNTER (decision 2026-09-23, STATUS
// item 4). The pad budget is not the constraint: with UART, the loader, I2C and
// the heartbeat pinned, 14 pads are free (ui_in[7:6], uio[7:2] and these six),
// which covers the remaining protocol wires even if all nine run at once. The
// chip has NO READBACK PATH -- pe_ctrl is a passive slave with no MISO -- so
// these six pins are the only live observability on silicon: a loaded program
// walking the PC is how bring-up tells "running" from "silent". Reclaim them
// when a protocol needs the pads and the free uio/ui pins are gone, or when a
// readback path lands; the matrix can already drive any free uio pad at
// runtime, so this is a pinout choice, not a capability limit.
//
// The two uio pins are wired as a loopback-capable open-drain pair driven from
// the SoC's pin today. That is enough to prove the oe path works in silicon,
// which is the thing wiki/plans/through-i2c.md flags as unverified.

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

  // ---- firmware load window: pe_ctrl, the passive SPI slave ------------
  // The host clocks a program into instruction memory before `run` rises.
  // This was tied off until ADR-007; the loader now owns the SoC's host
  // write port. Pads: ui_in[3]=SCLK, ui_in[4]=MOSI, ui_in[5]=CS_N. The
  // protocol bits 0-3, UART/ETH RX and `run` keep their assignments.
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
  wire [15:0] ctrl_words_written;

  pe_ctrl #(.WORDS(TT_IMEM_WORDS)) u_ctrl (
    .clk(clk), .rst_n(rst_n),
    .spi_sclk(ui_in[3]), .spi_mosi(ui_in[4]), .spi_cs_n(ui_in[5]),
    .run(ui_in[1]),
    .host_we(host_we), .host_imem_sel(host_imem_sel),
    .host_addr(host_addr), .host_wdata(host_wdata),
    .load_active(ctrl_load_active), .load_error(ctrl_load_error),
    .words_written(ctrl_words_written)
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
  wire [7:0] dbg_pc, dbg_a, dbg_timer;

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
    .pin_in(pin_in_bus),
    .pin_out(pin_out_bus),
    .pin_oe(pin_oe_bus),
    .dbg_pc(dbg_pc),
    .dbg_a(dbg_a),
    .dbg_timer(dbg_timer)
  );

  // ---- dedicated outputs -------------------------------------------------
  assign uo_out[0]   = pin_out_bus[0];    // UART TX / protocol pin 0
  assign uo_out[1]   = dbg_timer[7];      // heartbeat: ~one edge per 128 ticks
  assign uo_out[7:2] = dbg_pc[5:0];

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

  assign uio_out[7:2] = 6'b000000;
  assign uio_oe[7:2]  = 6'b000000;        // released

  // The matrix samples the pad level on the port's input bits. SDA is bit 4 and
  // SCL is bit 5, so a released SDA is readable by firmware as port bit 4 --
  // that read-back IS I2C arbitration and clock-stretch detection.
  assign pin_in_bus[4] = uio_in[0];       // SDA
  assign pin_in_bus[5] = uio_in[1];       // SCL

  // ---- deliberately unused ----------------------------------------------
  // `ena` is ignored on purpose (see the header). Port bits that no current
  // firmware claims are sunk here rather than left as a silent unused-signal
  // warning: the matrix CAN drive them, but the wrapper has no pad for them.
  // Sinking them explicitly is what keeps regress/lint.sh clean without a blanket
  // waiver.
  //
  // dbg_pc[7:6] are not brought out: only 6 of the 8 uo_out bits are spare
  // after TX and the heartbeat, and the low 6 bits of the program counter are
  // the ones that move during bring-up. dbg_a is unused by the wrapper.
  //
  // uio_in[7:2] are sunk because the current pin map claims only uio[0] and
  // uio[1]; a future protocol can claim the rest without touching this line.
  wire _unused = &{ena, ui_in[7:6], uio_in[7:2],
                   pin_out_bus[7:6], pin_out_bus[3:1],
                   pin_oe_bus[7:6], pin_oe_bus[3:0],
                   dbg_a, dbg_timer[6:0], dbg_pc[7:6],
                   ctrl_load_active, ctrl_load_error, ctrl_words_written, 1'b0};

endmodule
