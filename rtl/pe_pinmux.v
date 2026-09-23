// pe_pinmux.v — per-pin direction, open-drain, and read-back: the I2C gate.
//
// WHY THIS EXISTS. Everything before it assumed pin direction was a BUILD-TIME
// decision. That was true and it was cheap: UART and SPI are both push-pull, so
// every pin is an input or an output for the whole design and the SoC's
// PIN_IN_MASK constant says which. I2C breaks that assumption, and it is the
// only baseline protocol that does. SDA is driven low, RELEASED (allowed to
// float up to the external pull-up), and READ BACK -- often within a single bit
// cell, because arbitration means the master must compare the level it drove
// against the level the bus actually has.
//
// So this block is not "more GPIO". It makes the direction of a pin a RUNTIME
// property, and it adds the read-back that makes a shared bus observable.
//
// THE REGISTER FILE -- four registers, and every one of them is used.
//
//   addr 0  OUT   what to drive when driving
//   addr 1  OE    1 = this pin may drive, 0 = released (high-Z)
//   addr 2  IN    the pad level, whether or not we are driving   (read-only)
//   addr 3  OD    open-drain mode: drive low, release on 1
//
// `OD` is the part worth explaining, because it is not in every GPIO and it is
// what makes this block safe on a multi-master bus.
//
// In open-drain mode the pad can NEVER drive high:
//
//   pad_oe[i] = reg_oe[i] && (!reg_od[i] || !reg_out[i])
//
// od=0 (push-pull): pad_oe = reg_oe -- a normal tri-state output.
// od=1, out=0:      pad_oe = reg_oe -- driving low, which is what open-drain does.
// od=1, out=1:      pad_oe = 0      -- RELEASED. The pull-up owns the line.
//
// Without that bit, open-drain is a firmware CONVENTION: the program must
// remember to release (oe=0) when it wants to send a 1, and if it forgets it
// writes {oe=1, out=1} and drives the bus high. On an I2C bus with a slave
// pulling SDA low in the same cell that is a direct short from our pad to the
// slave's pull-down transistor -- a real, destructive contention bug, and the
// kind that only appears with two devices on the wire. With the bit, the
// hazardous state is unreachable: the gates cannot express it.
//
// And the payoff is larger than the safety. Note what firmware does in each
// mode to send a 1 and a 0:
//
//   push-pull:   out=1, oe=1   |  out=0, oe=1
//   open-drain:  out=1, oe=1   |  out=0, oe=1     <-- identical
//
// In od mode, writing out=1 releases and out=0 pulls low, so TOGGLING `out`
// sends bits in both modes with the SAME code. That is the whole thesis of the
// project expressed in one gate: "swap the program and it speaks I2C, with the
// gates unchanged" only holds if the firmware idiom survives the swap, and
// without the od bit it does not -- open-drain firmware has to toggle `oe`
// instead of `out`, which is different code in every bit-banging loop.
//
// `oe` remains authoritative in both modes: od=1 with oe=0 is still released,
// so od selects the DRIVE STYLE and oe selects WHETHER this pin participates at
// all. A pin nobody configured (oe=0, od=0) is inert, which is the right
// default for eight pins that a UART will use two of.
//
// WHY NOT "A MUX OF 8 PROTOCOL WIRE SETS". wiki/plans/through-i2c.md sketches
// `cfg_prot[i]` selecting one of eight protocol wire sets. That is strictly
// worse here: it needs the same per-pin state PLUS a selector, and the selector
// would have to hold a constant per protocol -- a build-time map wearing a
// runtime hat. Per-pin {out, oe, od} with firmware composing the assignment is
// smaller, cannot be inconsistent with the registers, and lets a protocol use
// pins no protocol table would have allocated to it. The cost is that firmware
// must know its own pin map, which it must anyway, since it writes the values.
// See wiki/concepts/pin-matrix.md.
//
// RELATION TO THE SOC'S PORT. pe_soc has a fixed PIN_IN_MASK and a masked
// write; this generalises exactly that (the SoC's port is the degenerate case,
// oe = ~PIN_IN_MASK constant, od = 0). They stay separate on purpose: the SoC's
// is what tb_pe_soc_uart and tb_pe_soc_tick sign off, and swapping the
// mechanism underneath a verified path to serve a protocol that path does not
// implement is how a green regression stops meaning anything.
//
// The reset value is RELEASE + idle-high on every pin, which is safe on every
// bus in wiki/reference/protocol-pin-budget.md. It is deliberately NOT the
// right value for a UART TX line (a low line reads to a peer as a start bit) --
// that is the SoC port's own reset value to choose, because it is the SoC that
// knows a UART is resident. This block does not guess a protocol from its pins.

module pe_pinmux #(
  parameter int          PINS    = 8,
  // Reset state, per pin: everything released and idle-high.
  parameter logic [PINS-1:0] RST_OE  = '0,
  parameter logic [PINS-1:0] RST_OUT = '1,
  parameter logic [PINS-1:0] RST_OD  = '0
) (
  input  logic              clk,
  input  logic              rst_n,

  // Register-file access: one write port, one read port.
  input  logic              we,
  input  logic [1:0]        addr,
  input  logic [PINS-1:0]   wdata,
  output logic [PINS-1:0]   rdata,

  // The pads.
  input  logic [PINS-1:0]   pad_in,     // the level on the pin, driven or not
  output logic [PINS-1:0]   pad_out,    // level to drive
  output logic [PINS-1:0]   pad_oe      // 1 = drive, 0 = release (high-Z)
);

  // Elaboration guards. PINS is bounded because the register file is addressed
  // by 2 bits and the vectors go to [-1:0] at PINS=0, which iverilog accepts as
  // a reversed range without complaint. A guard that never fires is
  // indistinguishable from a guard that passes, so regress/param_guards.sh compiles
  // this module at PINS=0 and at PINS=9 and requires a hard failure.
  //
  // NOTE: Icarus supports only a SINGLE STRING argument to $error at
  // elaboration, so these messages carry no %0d formatting -- passing an
  // argument makes the tool emit "sorry: Elaboration tasks currently only
  // support a single string argument" INSTEAD of the intended text, and the
  // guard still fires but the message a reader needs is replaced by a parser
  // complaint about the guard itself. Same trap as pe_dru.v:117.
  if (PINS < 1) begin : g_pins_lo_guard
    $error("pe_pinmux: PINS must be >= 1: the register file is addressed by 2 bits and PINS=0 gives reversed vector ranges.");
  end
  if (PINS > 8) begin : g_pins_hi_guard
    $error("pe_pinmux: PINS must be <= 8: the register file is 2 bits and the port is one byte wide.");
  end

  localparam logic [1:0] A_OUT = 2'd0,
                         A_OE  = 2'd1,
                         A_IN  = 2'd2,
                         A_OD  = 2'd3;

  logic [PINS-1:0] reg_out;
  logic [PINS-1:0] reg_oe;
  logic [PINS-1:0] reg_od;

  // The register file. `in` is NOT stored: it is the pad level, sampled
  // combinationally, because a stored copy adds a cycle of latency to the
  // arbitration comparison. The master must know the bus level during the same
  // bit cell it drove; a registered input reports the PREVIOUS cell, which is
  // exactly the bug that makes arbitration look like it passed while the bus
  // was being fought.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_out <= RST_OUT;
      reg_oe  <= RST_OE;
      reg_od  <= RST_OD;
    end else if (we) begin
      case (addr)
        A_OUT:   reg_out <= wdata;
        A_OE:    reg_oe  <= wdata;
        A_OD:    reg_od  <= wdata;
        // A_IN is read-only. A write here is a no-op rather than an error: the
        // CPU's OUT instruction takes a port number and a value, so "out to a
        // read-only port" is a firmware typo, and silently ignoring it keeps
        // the write port total -- which is what the SoC's IO decode assumes.
        default: ;
      endcase
    end
  end

  // The open-drain gate. This single expression is the safety property:
  // in od mode a pin holding a 1 is released rather than driven high.
  assign pad_oe  = reg_oe & ~(reg_od & reg_out);
  assign pad_out = reg_out;

  // Read port. OUT, OE and OD are readable so firmware can do read-modify-write
  // without a dmem shadow (the ISA has OR and AND, so composing a new value
  // from a read is two instructions); IN is the pad.
  always_comb begin
    case (addr)
      A_OUT:   rdata = reg_out;
      A_OE:    rdata = reg_oe;
      A_IN:    rdata = pad_in;
      A_OD:    rdata = reg_od;
      default: rdata = {PINS{1'b0}};
    endcase
  end

endmodule
