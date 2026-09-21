// pe_crc.v — the shared CRC / LFSR engine (CRC-15 CAN, CRC-5/16 USB,
//            CRC-32 Ethernet FCS, CRC-8 SMBus).
// Signal meanings: wiki/reference/signal-names.md#pe_crc
// Constants to load: wiki/reference/crc-config.md (generated, checked).
//
// Firmware cannot do this. At 10BASE-T's 100 ns bit period the core has 4
// clocks per bit and a software CRC-32 costs ~30 instructions per bit — over
// budget by 7.5x (wiki/concepts/ethernet-scope.md). So CRC is one of the few
// things that has to be hardware, and this is that block.
//
// ---------------------------------------------------------------------------
// ONE SHIFT-RIGHT DATAPATH, NOT TWO
//
// The obvious implementation is two datapaths selected by a config bit: a
// left-shift register for the MSB-first CRCs (CAN, SMBus) and a right-shift
// register for the LSB-first ones (Ethernet FCS, USB). This block has one,
// because the two are the same computation read differently:
//
//     fb = bit_in ^ R[0]
//     R  = (R >> 1) ^ (fb ? cfg_poly_r : 0)      cfg_poly_r = REVERSED polynomial
//
//   * wire bits arriving LSB-first (Ethernet, USB):  R IS the CRC.
//   * wire bits arriving MSB-first (CAN, SMBus):  R is the bit-reversal of the
//     CRC the standard names.
//
// Both families take the feedback from the SAME end (bit 0) and enter it
// through the SAME mask. What differs is the constant the caller loads and how
// it reads the result, and both of those are caller-side — so the shift datapath
// needs no mode bit at all. (The one thing that is NOT caller-side is the final
// complement, because it sits inside the feedback path when a field is being
// emitted; that is what cfg_out_inv is for, below.)
//
// Every constant this project needs was checked against the RevEng catalogue's
// published check value; tools/gen_crc_config.py re-derives and re-checks them
// and tb/run_all.sh drift-checks the generated page:
//
//     CRC-32/ISO-HDLC   0xCBF43926      CRC-15/CAN       0x059E
//     CRC-16/USB        0xB4C8          CRC-16/ARC       0xBB3D
//     CRC-5/USB         0x19            CRC-8/SMBUS      0xF4
//
// ---------------------------------------------------------------------------
// WHY THERE IS NO WIDTH PORT EITHER
//
// cfg_poly_r and cfg_seed are loaded low-justified: rev(poly, Wcrc) and the
// seed are both < 2^Wcrc. Every operation below is a right shift plus an XOR
// with a mask that has no bit above Wcrc-1, so
//
//     R < 2^Wcrc     is an INVARIANT of the datapath
//
// and the high bits of a 32-bit register stay zero for the 5-, 8-, 15- and
// 16-bit polynomials. `crc_zero` can therefore be a full-register compare with
// no width input, and one register width serves every target. tb_pe_crc asserts
// the invariant on every strobe, so it is a checked property and not a hope.
//
// ---------------------------------------------------------------------------
// cfg_out_inv: THE FINAL COMPLEMENT
//
// Ethernet's FCS, USB's CRCs and the post-XOR form are `crc ^ xorout`, and for
// every target in this project xorout is all-ones or all-zeros. So one bit
// expresses it, and it applies to the WIRE OUTPUT ONLY.
//
// That separation is the whole subtlety. While a field is being emitted the
// register must keep doing a PURE SHIFT, so that it drains to zero and the
// transmitter and a receiver that folds the same bits agree. So:
//
//     wire bit   = R[0] ^ cfg_out_inv        (what the standard says to send)
//     feedback   = R[0]                      (pure shift: fb = R[0] ^ R[0] = 0)
//
// Putting the complement inside the feedback instead would make fb == 1 on
// every field strobe, applying the mask Wcrc times to a register that is
// supposed to be emptying — and the register would end up somewhere that means
// nothing. That is the bug this comment exists to prevent; it is easy to write
// the "obvious" version and have every transmit-side check still pass, because
// the emitted bits are identical either way. Only the register's final state
// differs, which is what the receiver depends on.
//
// The receiver needs no special handling in the block: a caller folding the
// complemented field un-complements it (XOR cfg_out_inv) before feeding it, and
// then this same pure-shift property drains the register. A caller that folds
// the field exactly as transmitted lands on the catalogue residue instead --
// which is a useful cross-check, and tb_pe_crc asserts both.
//
// ---------------------------------------------------------------------------
// crc_zero IS A STATUS, NOT AN EVENT
//
// It latches and holds until `clr` starts the next frame. That is deliberately
// different from the codecs' rx_err, which is a one-cycle pulse
// (rtl/pe_line_codec.v header): a pulse is right for an error a consumer is
// already sampling every cycle, but a frame-valid indication that vanished
// after one cycle would force a sticky flag into every consumer — the bug class
// wiki/STATUS.md gotcha 6 is about. A level needs no flag.
//
// The verdict is valid AFTER the final field strobe and BEFORE the next `clr`:
//
//     tx, after the field:  R == 0 and crc_zero == 1
//     rx, clean frame:      fold field_bit ^ cfg_out_inv -> R == 0, crc_zero == 1
//
// Both directions agree because the receiver folds what the transmitter MEANT
// (the un-complemented field), and the register's pure shift does the rest.
// That is what lets tb_pe_crc check a transmitted field with a loopback and no
// model of its own.

module pe_crc #(
  parameter int W = 32
) (
  input  logic          clk,
  input  logic          rst_n,

  input  logic          bit_en,      // one strobe per wire bit, transmission order
  input  logic          clr,         // frame boundary: R <= cfg_seed
  input  logic          crc_field,   // level: these strobes carry the CRC field
  input  logic          bit_in,      // wire bit in (ignored while crc_field)

  input  logic [W-1:0]  cfg_poly_r,  // REVERSED polynomial, low-justified
  input  logic [W-1:0]  cfg_seed,    // R-orientation seed, low-justified
  input  logic          cfg_out_inv, // 1: complement the WIRE BITS (Ethernet, USB)

  output logic          crc_bit,     // field bit to put on the wire
  output logic          crc_zero,    // status: R == 0 after the last strobe
  output logic [W-1:0]  crc_state    // observability / firmware readback
);

  logic [W-1:0] R, R_next;
  logic         fb;

  assign crc_state = R;

  // The wire bit for this strobe: R[0], complemented when the algorithm's final
  // XOR is. On the receive side the caller un-complements before feeding it.
  assign crc_bit = R[0] ^ cfg_out_inv;

  // Feedback is taken from the register's OWN low bit in BOTH modes. That is
  // the whole reason crc_bit's complement is allowed to exist at all: in field
  // mode crc_bit is R[0]^cfg_out_inv, so feeding crc_bit back would make
  // fb == cfg_out_inv on every field strobe -- applying the mask Wcrc times to
  // a register that is supposed to be emptying, and leaving a final state that
  // means nothing. Feeding R[0] back makes fb == 0 exactly, the register does a
  // pure shift, and it drains to zero. The complement stays on the wire, which
  // is the only place the standard asks for it.
  assign fb = (crc_field ? R[0] : bit_in) ^ R[0];

  assign R_next = (R >> 1) ^ (fb ? cfg_poly_r : {W{1'b0}});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      R        <= '0;
      crc_zero <= 1'b0;
    end else if (clr) begin
      // clr wins over bit_en, like every other stage in this repo: a frame
      // boundary is not a strobe, and letting a strobe land on the boundary
      // would fold one bit of the previous frame into the next one's register.
      R        <= cfg_seed;
      crc_zero <= 1'b0;
    end else if (bit_en) begin
      R        <= R_next;
      crc_zero <= (R_next == {W{1'b0}});
    end
  end

endmodule
