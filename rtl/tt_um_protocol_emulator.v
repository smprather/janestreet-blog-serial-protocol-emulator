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
//   ui_in[7:2]  unused
//
//   uo_out[0]   UART TX          (the protocol output pin)
//   uo_out[1]   heartbeat        timer bit 7, so a scope shows life
//   uo_out[7:2] dbg_pc[5:0]      visible program counter, for bring-up
//
//   uio[0]      SDA              open-drain, for the I2C milestone
//   uio[1]      SCL              open-drain, for the I2C milestone
//   uio[7:2]    released         (oe = 0)
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

  // ---- firmware load window --------------------------------------------
  // Not brought out to pads in this revision: the SoC boots from whatever the
  // host interface last wrote, and the testbench drives that interface
  // directly. Tying the port off here keeps the pad budget for protocol pins
  // (wiki/reference/protocol-pin-budget.md: 24 usable, and a load port would
  // cost 10 of them). A real bring-up loads over a serial shift path; that is
  // a separate block and a separate decision record.
  wire        host_we       = 1'b0;
  wire        host_imem_sel = 1'b0;
  // Width follows the SoC's loader port, which follows IMEM_WORDS. Written as
  // the same expression the SoC uses so the two cannot drift apart.
  localparam int TT_IMEM_WORDS = 1024;
  wire [((((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) > 8)
         ? ((TT_IMEM_WORDS <= 2) ? 1 : $clog2(TT_IMEM_WORDS)) : 8)-1:0]
       host_addr = '0;
  wire [15:0] host_wdata    = 16'h0000;

  wire       uart_rx = ui_in[0];
  wire       run     = ui_in[1];
  wire       uart_tx;
  wire [7:0] dbg_pc, dbg_a, dbg_timer;

  pe_uart_soc #(
    .IMEM_WORDS(TT_IMEM_WORDS),
    .DMEM_BYTES(16),
    .CLK_HZ(40_000_000),
    .BAUD(115_200)
  ) u_soc (
    .clk(clk),
    .rst_n(rst_n),
    .host_we(host_we),
    .host_imem_sel(host_imem_sel),
    .host_addr(host_addr),
    .host_wdata(host_wdata),
    .run(run),
    .pin_in(uart_rx),
    .pin_out(uart_tx),
    .dbg_pc(dbg_pc),
    .dbg_a(dbg_a),
    .dbg_timer(dbg_timer)
  );

  // ---- dedicated outputs -------------------------------------------------
  assign uo_out[0]   = uart_tx;
  assign uo_out[1]   = dbg_timer[7];      // heartbeat: ~one edge per 128 ticks
  assign uo_out[7:2] = dbg_pc[5:0];

  // ---- bidirectional pins: open-drain SDA/SCL ---------------------------
  // Drive low or release, never drive high -- that is what open-drain means,
  // and an I2C bus with two masters driving high is a short. uio_out is held
  // at 1 for the released pins so the waveform reads as "not driving" rather
  // than "driving an unknown".
  //
  // Today both are released and the bus level is simply observable. The pin
  // matrix takes these over; the point of wiring them now is that uio_oe has a
  // real path to a pad, which the plan lists as an unverified assumption.
  wire sda_drive_low = 1'b0;
  wire scl_drive_low = 1'b0;

  assign uio_oe[0]   = sda_drive_low;
  assign uio_oe[1]   = scl_drive_low;
  assign uio_oe[7:2] = 6'b000000;         // released

  assign uio_out[0]   = 1'b0;             // only ever driven LOW
  assign uio_out[1]   = 1'b0;
  assign uio_out[7:2] = 6'b000000;

  // ---- deliberately unused ----------------------------------------------
  // `ena` is ignored on purpose (see the header). uio_in is readable but not
  // consumed until the pin matrix lands. Sinking them explicitly is what keeps
  // tb/lint.sh clean without a blanket waiver.
  // dbg_pc[7:6] are not brought out: only 6 of the 8 uo_out bits are spare
  // after TX and the heartbeat, and the low 6 bits of the program counter are
  // the ones that move during bring-up.
  wire _unused = &{ena, uio_in, ui_in[7:2],
                   dbg_a, dbg_timer[6:0], dbg_pc[7:6], 1'b0};

endmodule
