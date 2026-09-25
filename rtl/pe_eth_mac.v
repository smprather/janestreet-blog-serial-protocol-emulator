// pe_eth_mac.v — 10BASE-T receive path: SFD lock, byte assembly, FCS check, and
// a store-and-forward write into the frame buffer.
// Signal meanings: wiki/reference/signal-names.md#pe_eth_mac
//
// WHY THIS EXISTS RATHER THAN FIRMWARE
//
// wiki/concepts/ethernet-scope.md settles this with arithmetic. 10BASE-T's bit
// period is 100 ns; at 60 MHz the core has 48 clocks per byte and is
// single-cycle, so 48 instructions is the budget for EVERYTHING. A software
// CRC-32 costs ~240 instructions per byte, over budget by 5x. For 10BASE-T the
// firmware sequences frames and never touches bits -- the bit work is hardware.
//
// ---------------------------------------------------------------------------
// WHAT IT CONSUMES, AND WHY EVERY PIECE WAS ALREADY BUILT
//
//   pe_dru     -> bit_en strobe + rx_first/rx_second half-cell levels
//   pe_manch   -> rx_raw (decoded bit) + rx_err (invalid/absent mid-bit transition)
//   pe_crc     -> the CRC-32 engine, folded one wire bit per strobe
//   pe_fbuf    -> where the payload lands (2 KB, ADR-003)
//
// All four existed and were TB-proven before this block, and three were
// ORPHANS: built, tested in isolation, instantiated nowhere. Instantiating a
// block is how its claim stops being untested prose.
//
// ---------------------------------------------------------------------------
// THE FCS: FOLD IT AS TRANSMITTED, COMPARE AGAINST THE CATALOGUE RESIDUE
//
// IEEE 802.3 3.2.9 transmits the FCS with x^31 first. It also gives an
// equivalent formulation -- right-shifting CRC-32, octets LSB-first, FCS
// emitted LSB-first -- in the standard's own words "resulting in identical
// transmissions" (quoted in wiki/reference/crc-config.md, which is generated
// from tools/gen/crc_config.py and drift-gated against the RevEng catalogue).
// This project uses that formulation, so there is no bit reversal here.
//
// The RECEIVER has two self-consistent-looking options and only one is
// checkable against an outside value. Measured over a 42-byte ARP-shaped frame
// before this RTL was written:
//
//   fold the field EXACTLY AS TRANSMITTED -> R == catalogue residue
//                                            CRC-32/ISO-HDLC = 0xDEBB20E3
//   fold the field UN-complemented        -> R == 0, crc_zero asserts
//
// This block folds as transmitted and compares against the residue, so
// crc_field_out is held LOW: pe_crc's field mode is for EMITTING a field (a
// pure shift so the transmitter's register drains), while a receiver folds the
// field as ordinary data. The verdict is `crc_state == CRC_RESIDUE` and NEVER
// `crc_zero` -- crc_zero belongs to the other convention, so writing it here
// would reject every valid frame while looking exactly like a CRC bug. The
// residue is also an outside value, so agreeing with it is evidence rather than
// the engine marking its own homework.
//
// ---------------------------------------------------------------------------
// SFD LOCK: THE 8-BIT WINDOW ALONE. MEASURED, NOT ASSUMED.
//
// An earlier draft carried an "alternating run must exceed N bits before
// accepting 0xD5" test, on the theory that the window alone was ambiguous.
// Enumerating the 64-bit prelude (56 alternating preamble bits then the SFD
// 0xD5 LSB-first) settles it:
//
//   windows assembling LSB-first to 0xD5 : exactly one, bits 56..63 (the SFD)
//   every window before the SFD          : 0x55 or 0xAA, alternating only
//
// 0xD5 is UNREACHABLE in a well-formed preamble, so the window cannot
// false-lock. The run test was also actively harmful: a receiver that started
// listening a few bits into the preamble would see a short run and MISS the
// frame -- a silent receive failure, in the one part of the design whose whole
// justification was robustness. The run counter is gone.
//
// Because the window shifts only on VALID cells, an idle line leaves it
// untouched, and a frame that arrives mid-preamble still locks on its SFD.
//
// ---------------------------------------------------------------------------
// EVERY BIT IS HELD ONE CYCLE, AND THE PHASE IS READ FROM `state`
//
// A 10BASE-T line signals end-of-frame by going IDLE -- a constant level. The
// DRU keeps emitting cells for an idle line (its header is explicit that
// `locked` is a confidence indicator and NOT a gate), and an idle cell has
// EQUAL halves, which is exactly what pe_manch reports as rx_err. So an invalid
// cell after a frame IS the end-of-frame marker, and it is also how a truncated
// frame is caught.
//
// pe_manch's rx_err is REGISTERED: on a cell's strobe cycle rx_err still holds
// the PREVIOUS cell's verdict and only updates on the next edge. A receiver
// consuming each bit on its own strobe would take in one idle bit before it
// could see the error, fold it into the CRC, and then reject a good frame --
// with the residue mismatching, so it would look like a CRC bug.
//
// So each bit is latched and acted on one cycle later, when rx_err has caught
// up:
//
//   strobe T   : bit_en=1, rx_raw = cell T's bit   -> latch bit, raise `pend`
//   cycle T+1  : rx_err now describes cell T
//                pend && !rx_err -> the bit is real: shift, fold, count
//                pend &&  rx_err -> invalid cell: drop the bit
//
// THE PHASE OF THE DELAYED BIT IS `state`, NOT A SAVED COPY OF IT, and that is
// worth stating because the obvious alternative is wrong. In this file every
// state transition is decided on the cycle that consumes a phase's LAST bit, so
// that bit is consumed while the machine is still in that phase's state; the
// machine moves on at the same edge the next bit is latched. The invariant is
// therefore:
//
//   during cycle T+1, `state` is the phase cell T belongs to
//
// An earlier draft instead latched the state alongside the bit (a `from`
// register) and qualified the CRC fold and the write strobe with it. That
// mis-attributes the FIRST bit of every phase: the first body bit after the SFD
// is strobed on the cycle the SFD is consumed, so `from` records S_SEARCH and
// the bit would be dropped from the CRC. `state` is correct at that boundary by
// construction.
//
// ---------------------------------------------------------------------------
// TWO FRAME KINDS, BECAUSE ARP IS NOT A LENGTH FRAME
//
// The field after the MAC addresses is a LENGTH below 0x0600 and an EtherType
// at or above it. Easy to miss and decisive here: the acceptance test for this
// block is an ARP exchange, ARP is EtherType 0x0806, and reading 0x0806 as a
// length demands a 2,054-byte payload that cannot fit -- so a length-only
// receiver rejects every ARP frame while passing any hand-made length-frame
// test.
//
//   length frame (< 0x0600) : payload is that many bytes, then 32 FCS bits
//                             which are NOT written. Ends by count, and its
//                             size is known at the header, so it is
//                             bounds-checked there before any write.
//   type frame   (>= 0x0600): payload ends when the line does, and the last
//                             four bytes received before that are the FCS.
//                             Nothing can distinguish them from payload as
//                             they arrive, so they ARE written and the pointer
//                             is wound back 4 at the verdict.
//
// That asymmetry is the whole of `is_type`'s effect on storage, and it is why
// the wind-back is `is_type ? 4 : 0`: a length frame's FCS bytes were never
// written, so winding back would corrupt the ring.
//
// ---------------------------------------------------------------------------
// BUFFER OWNERSHIP: wptr IS THE PRODUCER, rptr IS THE CONSUMER
//
// The ring has one write pointer (`wptr`) and one read pointer (`rptr`).
// `room` is the free space ahead of the producer; `used = BUF_BYTES - room` is
// what is allocated. `published_used` is the subset committed as complete
// frames. The consumer moves `rptr` with `buf_consume`, naming the address it
// has read up to; only committed bytes can be released. The producer never
// touches `rptr`, and the consumer never touches `wptr`.
//
// That separation is what makes a reclaim safe while the NEXT frame is already
// arriving. The whole-ring reset (`buf_reset`) moves BOTH pointers to zero and
// is only legal when nothing is in flight, so it is a testbench/debug control:
// the SoC does not pulse it in traffic. An earlier integration did, and the
// reset rebased an in-flight frame's write pointer, so the frame was published
// with a wrapped window start and firmware read unwritten memory
// (reviews/2026-09-23/ETHERNET-SOC-REVIEW.md E1).
//
// A consume is accepted only when the named address is a FORWARD distance no
// greater than both `used` and `published_used`; an in-flight frame can later
// be rolled back or have its FCS reclaimed, so allocated bytes alone are not
// releasable. A duplicate (distance 0) is a no-op and a backward address is
// ignored, so a firmware mistake cannot over-credit `room` or release bytes
// still owned by an uncommitted frame.

// No `timescale here on purpose: all RTL in this repo is timescale-free so the
// unit is the consumer's (the testbenches set their own). pe_eth_mac was the
// only RTL file that carried one, copied from a TB template, and adding it to
// the lint gate surfaced it as a TIMESCALEMOD on every other module.

module pe_eth_mac #(
  parameter int BUF_BYTES = 2048,     // pe_fbuf's capacity
  parameter int AW        = $clog2(BUF_BYTES),
  // Idle cells required before an SFD hunt is allowed. IEEE 802.3's
  // inter-frame gap is 96 bit times, and a frame cannot begin until the line
  // has been idle -- so requiring idle before hunting is the STANDARD's rule,
  // not a heuristic. 8 is far below 96 and far above the 1-2 cells a DRU
  // glitch can produce, which is the whole reason it is small.
  parameter int IDLE_CELLS = 8
) (
  input  logic clk,
  input  logic rst_n,

  // ---- from the DRU + Manchester codec --------------------------------
  input  logic bit_en,      // one strobe per recovered wire bit cell
  input  logic rx_raw,      // the decoded bit for this strobe
  input  logic rx_err,      // registered: describes the PREVIOUS strobe's cell
  // The two half-cell samples, straight from pe_dru. They are here to derive
  // the IDLE indicator, and that is not a convenience: measured on a held line
  // (tb_idle), the DRU emits cells whose halves are EQUAL while BOTH pe_manch's
  // rx_err AND pe_dru's locked stay 0. Neither can mark idleness. The
  // equal-halves property is the one thing that does, and a Manchester cell
  // guarantees the halves DIFFER, so this is the codec's own definition of a
  // valid cell, read as a level instead of as a one-cycle pulse.
  input  logic rx_first,
  input  logic rx_second,

  // ---- buffer ownership (firmware) ------------------------------------
  input  logic          buf_reset,        // pulse: reclaim the WHOLE ring (tests/debug)
  input  logic          buf_consume,      // pulse: consumer has read up to buf_consume_addr
  input  logic [AW-1:0] buf_consume_addr, // the consumer's current position

  // ---- CRC engine (external, so the TX path can share it) -------------
  output logic        crc_bit_en,     // qualified strobe, one cycle behind bit_en
  output logic        crc_clr,        // pulse at the frame start (the SFD)
  output logic        crc_bit_in,     // the latched bit, to fold
  output logic        crc_field_out,  // held 0: a receiver folds the field as data
  input  logic [31:0] crc_state,      // the engine's register, for the verdict

  // ---- frame buffer write port (pe_fbuf) ------------------------------
  output logic          fbuf_we,
  output logic [AW-1:0] fbuf_waddr,
  output logic [7:0]    fbuf_wdata,

  // ---- status / handoff ----------------------------------------------
  output logic          frame_valid,     // pulse: complete and FCS-clean
  output logic          frame_bad,       // pulse: committed, then abandoned
  output logic [15:0]   frame_len,       // payload bytes stored (with frame_valid)
  output logic [15:0]   frame_field,     // the length/EtherType field as received
  output logic          frame_is_type,   // 1 if that field was an EtherType
  output logic [AW-1:0] frame_ptr,       // next write address = the NEXT frame's start
  output logic [2:0]    dbg_state
);

  localparam logic [7:0]  SFD_BYTE    = 8'hD5;   // assembled LSB-first, never matched as a pattern
  // RevEng catalogue residue for CRC-32/ISO-HDLC, from the generated
  // wiki/reference/crc-config.md. The outside value the verdict is checked
  // against; see the header.
  localparam logic [31:0] CRC_RESIDUE = 32'hDEBB20E3;
  localparam logic [15:0] TYPE_MIN    = 16'hFFFF;   // MUTANT: no type frames
  localparam logic [2:0]  FCS_BYTES   = 3'd4;
  // Minimum data field for a 64-byte frame: 6 dst + 6 src + 2 length + 46
  // data + 4 FCS. A length frame declaring fewer than 46 bytes is padded to 46
  // by its transmitter, and the padding is covered by the FCS, so a receiver
  // that jumps from the declared length straight to the FCS rejects every such
  // frame (measured: a length-20 frame padded to 46 failed).
  localparam logic [15:0] MIN_PAY      = 16'd46;
  // The type-frame minimum, in STORED bytes: 46 data/pad + the 4 FCS bytes,
  // which for a type frame are indistinguishable from payload. 802.3's minimum
  // frame is 64 bytes total (14 header + 46 data + 4 FCS); a receiver that only
  // checks the CRC accepts an 18-byte header+FCS frame or a 63-byte short one
  // (measured, reviews/2026-09-23/FIX-VERIFICATION.md F1).
  localparam logic [15:0] MIN_TYPE_PAY = MIN_PAY + {{13{1'b0}}, FCS_BYTES};

  typedef enum logic [2:0] {
    S_SEARCH  = 3'd0,   // preamble + SFD lock; also the reset state
    S_HEADER  = 3'd1,   // dst(6) + src(6) + field(2)
    S_PAYLOAD = 3'd2,
    S_PAD     = 3'd3,   // the 802.3 pad bytes (length frames under 46)
    S_FCS     = 3'd4,   // the 32 FCS bits (length frames)
    S_SETTLE  = 3'd5,   // let the CRC register settle, then read the verdict
    S_ERR     = 3'd6
  } state_t;

  state_t state;

  // ---- the delayed bit ------------------------------------------------
  logic pend;      // the previous cycle carried a strobe
  logic bit_d;     // that strobe's bit
  logic ok;        // and its cell was valid
  assign ok = pend && !rx_err;

  // ---- SFD search -----------------------------------------------------
  // `sr` holds the LAST 7 bits of the LSB-first window and `sr_n` is the full
  // 8-bit window including the newest bit. Keeping only 7 removes the bit that
  // would otherwise be shifted out and never read (Verilator's UNUSEDSIGNAL),
  // while the window itself is still all 8 bits: the next state is sr_n[7:1],
  // which keeps the newest 7 of those 8 -- the same shift, minus the dead bit.
  logic [6:0] sr;
  logic [7:0] sr_n;
  assign sr_n = {bit_d, sr};            // LSB-first assembly

  // ---- idle gate ------------------------------------------------------
  // A frame may only be hunted for after the line has been idle, per 802.3's
  // inter-frame gap. Without this the receiver hunts MID-FRAME after an abort,
  // and a payload containing 0xD5 locks it into a phantom frame -- measured:
  // it made one rejected frame report frame_bad twice.
  //
  // An idle cell is one whose halves are EQUAL, which is exactly what the
  // codec reports as rx_err. So `idle_run` counts consecutive invalid cells and
  // resets on any valid one.
  logic [15:0] idle_run;
  logic        may_hunt;      // latch: the line has been idle, so hunt is legal
  // A LATCH, NOT A LIVE CONDITION. The gate means "the line has been quiet since
  // the last frame ended, so the next SFD is legitimate" -- and the preamble
  // itself is 56 VALID cells, so a live `idle_run >= IDLE_CELLS` would drop to
  // false exactly when the SFD arrives and no frame would ever lock. Measured:
  // that is precisely what the live version did.
  //
  // It re-arms only after idle and clears when a frame locks, which is the
  // standard's rule read directly: an inter-frame gap precedes every frame.
  //
  // The idle indicator is the equal-halves property, sampled with the strobe.
  // See the port comment for why neither rx_err nor locked can serve.

  // ---- assembly -------------------------------------------------------
  logic [7:0]    byte_cnt;    // bytes within the header
  logic [2:0]    bit_cnt;     // bits within the current byte
  // Same construction as `sr`: `shreg` is the last 7 bits and `shreg_n` is the
  // current 8-bit byte. The dst/src MAC addresses used to be captured into 12
  // dead registers that nothing ever read -- folded into the CRC by the bit
  // path and otherwise unused, with no filter and no handoff that wants them.
  // Removed rather than suppressed (STATUS: there are no accepted lint
  // warnings).
  logic [6:0]    shreg;
  logic [7:0]    shreg_n;
  logic [15:0]   field;       // the length/EtherType field
  logic          is_type;
  logic [15:0]   pay_cnt;     // bytes written in the payload phase
  logic [15:0]   pad_cnt;     // pad bytes consumed (length frames under 46)
  logic [4:0]    fcs_cnt;     // FCS bits received
  logic [AW-1:0] wptr;
  logic [AW-1:0] frame_start;
  logic [AW-1:0] rptr;         // consumer read pointer (buffer ownership)
  logic [AW:0]   freed;        // guarded consumer credit for this cycle
  logic [AW:0]   used;         // producer allocation since rptr
  logic [AW:0]   published_used; // committed bytes available to the consumer
  logic [AW:0]   room;
  logic [AW:0]   consume_credit;
  logic [1:0]    settle;
  // Structural completeness, independent of the CRC. A residue can match on a
  // frame that never had a complete structure -- the review's 14-byte runt
  // (preamble + SFD + 10 bytes + 4 FCS, no payload at all) folded to the
  // catalogue residue and was accepted as a TYPE frame, then wound the write
  // pointer back 4 bytes that had never been stored: wptr underflowed to 2,044
  // and `room` grew to 2,052 in a 2,048-byte buffer. CRC residue proves the BITS
  // are consistent, not that a frame was there.
  logic          hdr_done;    // the 14-byte header completed for THIS frame
  logic          fcs_done;    // a length frame's 32 FCS bits completed

  assign shreg_n = {bit_d, shreg};

  assign frame_ptr     = wptr;
  assign frame_field   = field;
  assign frame_is_type = is_type;
  assign dbg_state     = state;

  // Consumer accounting: `used` is what the producer has allocated since the
  // consumer's position; `published_used` is the committed subset available
  // to firmware; `freed` is how far a consume pulse advances the consumer.
  //
  // The subtraction is AW bits wide BEFORE the zero-extension, so it measures
  // the forward distance AROUND THE RING, modulo BUF_BYTES. An AW+1-bit
  // subtraction measures modulo 2*BUF_BYTES, which adds BUF_BYTES to every
  // wrapped release (address numerically below rptr); the `freed <= used`
  // guard then rejects it and the released capacity is lost for the life of
  // the ring. A valid release must also stay within `published_used`; checking
  // only allocated bytes could release an in-flight frame that may be rolled
  // back or have its stored FCS reclaimed later.
  //
  // E1-3 (kept): a release of exactly BUF_BYTES ends on the address it started
  // from, so this address-only API cannot distinguish it from a duplicate and
  // treats it as distance 0. Current Ethernet use never releases a full ring
  // in one pulse (the largest type frame stores 2044 bytes); resolving it in
  // general needs an explicit count or wrap bit -- a scope decision.
  assign used  = BUF_BYTES[AW:0] - room;
  assign freed = {1'b0, (buf_consume_addr - rptr)};

  // The consumer may release only bytes from completed, published frames.
  // `used` also includes bytes in the current uncommitted frame, so checking
  // only freed <= used lets an over-read advance rptr into that frame; its
  // later bad-frame reclaim or TYPE FCS windback then credits the same bytes a
  // second time. Keep both bounds: published_used enforces ownership, while
  // used remains the producer's allocation bound.
  //
  // The consumer's release, already validated for this cycle. It is folded
  // into BOTH the consume branch and every producer branch that updates
  // `room`, because a consume and a producer update can land on the same
  // clock edge. The consume branch runs first in the always_ff below, so a
  // later S_PAYLOAD/S_SETTLE/S_ERR `room` assignment would otherwise win
  // (nonblocking: the last assignment for the edge takes effect) and drop the
  // freed bytes permanently -- rptr advances but the credit never returns.
  // Do NOT solve this by moving the consume after the case: that inverts the
  // bug and drops the producer's delta instead.
  assign consume_credit = (buf_consume && !buf_reset &&
                           (freed <= used) && (freed <= published_used))
                          ? freed : '0;

  assign crc_field_out = 1'b0;   // a receiver folds the field as ordinary data
  // The fold is one cycle behind the strobe and skipped for invalid cells, so
  // no idle bit ever enters the engine. `state` is the delayed bit's phase (see
  // the header); S_SEARCH is excluded, which is what keeps the preamble and the
  // SFD itself out of the CRC.
  assign crc_bit_en = ok && (state == S_HEADER || state == S_PAYLOAD ||
                             state == S_PAD || state == S_FCS);
  assign crc_bit_in = bit_d;
  // The frame boundary is the SFD, one cell before the first folded bit, and
  // pe_crc gives `clr` priority over `bit_en`, so the two never collide.
  assign crc_clr = ok && (state == S_SEARCH) && (sr_n == SFD_BYTE);

  // A byte completes on the last bit of its cell, and only from a valid one.
  assign fbuf_we    = ok && (state == S_PAYLOAD) && (bit_cnt == 3'd7) &&
                      (room != 0);
  assign fbuf_waddr = wptr;
  assign fbuf_wdata = shreg_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_SEARCH;
      pend        <= 1'b0;
      bit_d       <= 1'b0;
      sr          <= '0;
      idle_run    <= '0;
      may_hunt    <= 1'b0;
      byte_cnt    <= '0;
      bit_cnt     <= '0;
      shreg       <= '0;
      field       <= '0;
      is_type     <= 1'b0;
      hdr_done    <= 1'b0;
      fcs_done    <= 1'b0;
      pay_cnt     <= '0;
      pad_cnt     <= '0;
      fcs_cnt     <= '0;
      wptr        <= '0;
      frame_start <= '0;
      rptr        <= '0;
      published_used <= '0;
      room        <= BUF_BYTES[AW:0];
      settle      <= '0;
      frame_valid <= 1'b0;
      frame_bad   <= 1'b0;
      frame_len   <= '0;
    end else begin
      frame_valid <= 1'b0;      // both statuses are one-cycle pulses
      frame_bad   <= 1'b0;

      // Buffer ownership. `buf_reset` is the WHOLE-RING reclaim and is only
      // safe when the ring is empty and nothing is in flight, so it is a
      // testbench/debug control now: the SoC does not pulse it in traffic.
      if (buf_reset) begin
        wptr  <= '0;
        rptr  <= '0;
        published_used <= '0;
        room  <= BUF_BYTES[AW:0];
      end

      // `buf_consume` is the CONSUMER-owned reclaim. Firmware says "I have
      // read every byte up to buf_consume_addr"; only the READ pointer moves,
      // so the write pointer and an in-flight frame's start/count are
      // untouched. That is what makes the reclaim legal while the next frame
      // is arriving: it cannot rebase the frame that will be published.
      if (buf_consume && !buf_reset) begin
        if (consume_credit != '0) begin
          rptr <= buf_consume_addr;
          published_used <= published_used - consume_credit;
          // The credit is folded into every producer `room` assignment below;
          // this default covers the common idle consume. On a collision the
          // later branch carries the same `consume_credit`, so the freed bytes
          // survive. A duplicate or invalid/unpublished release has zero
          // credit and leaves all ownership state unchanged.
          room <= room + consume_credit;
        end
      end

      // ---- latch the strobe -------------------------------------------
      pend <= bit_en;
      if (bit_en) bit_d <= rx_raw;

      // ---- idle run ---------------------------------------------------
      // Counts CONSECUTIVE invalid cells. pe_manch's rx_err is registered, so
      // on the strobe cycle it still describes the previous cell -- which is
      // exactly the alignment this counter wants, since it is measuring the
      // cell that has just been judged.
      if (bit_en) begin
        if (rx_first == rx_second) idle_run <= idle_run + 16'd1;  // no transition: idle
        else                       idle_run <= '0;                // a real cell: live
      end
      // Arm on a long-enough idle; disarm the moment a frame locks, so the next
      // one needs its own inter-frame gap.
      if (idle_run >= IDLE_CELLS[15:0]) may_hunt <= 1'b1;
      if (ok && (state == S_SEARCH) && (sr_n == SFD_BYTE) && may_hunt)
        may_hunt <= 1'b0;

      case (state)

        // ---------------------------------------------------------------
        // Preamble and SFD. An invalid cell does not shift the window, so an
        // idle line leaves the search untouched and a frame arriving
        // mid-preamble still locks on its SFD.
        // ---------------------------------------------------------------
        S_SEARCH: begin
          if (ok) begin
            sr <= sr_n[7:1];
            if ((sr_n == SFD_BYTE) && may_hunt) begin
              state       <= S_HEADER;
              byte_cnt    <= '0;
              bit_cnt     <= '0;
              shreg       <= '0;
              hdr_done    <= 1'b0;
              fcs_done    <= 1'b0;
              pay_cnt     <= '0;
              pad_cnt     <= '0;
              fcs_cnt     <= '0;
              frame_start <= wptr;
            end
          end
        end

        // ---------------------------------------------------------------
        // dst + src + the length/EtherType field = 14 bytes. Only the field
        // is kept: the MAC addresses are covered by the CRC but are not used
        // by this block (no filtering, no handoff), so capturing them would be
        // dead hardware. The 14-byte count still has to be walked because the
        // field arrives last.
        // ---------------------------------------------------------------
        S_HEADER: begin
          if (ok) begin
            shreg   <= shreg_n[7:1];
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
              bit_cnt  <= '0;
              byte_cnt <= byte_cnt + 8'd1;
              case (byte_cnt)
                8'd12: field[15:8] <= shreg_n;
                8'd13: begin
                  // Byte 12 is the HIGH half, byte 13 the LOW half. The other
                  // order byte-swaps the field, and a 256-byte length then
                  // reads as 1 and runs off the end of the ring.
                  field[7:0] <= shreg_n;
                  is_type    <= ({field[15:8], shreg_n} >= TYPE_MIN);
                  hdr_done   <= 1'b1;
                  // Reject before writing anything. Only a length frame can be
                  // sized here; a type frame's bound is enforced per byte
                  // below, because its length is not known until the line
                  // goes idle.
                  //
                  // The comparison is the RAW field against `room`, with no
                  // allowance for the FCS -- correct only because a length
                  // frame does not store its FCS (see the header). Adding 4
                  // here would reject legal frames that fit exactly.
                  if ({field[15:8], shreg_n} == 16'h0000) begin
                    state <= S_ERR;                 // length 0 is not a frame
                  end else if (({field[15:8], shreg_n} < TYPE_MIN) &&
                               ({field[15:8], shreg_n} > {{4{1'b0}}, room})) begin
                    state <= S_ERR;                 // will not fit
                  end else begin
                    state   <= S_PAYLOAD;
                    pay_cnt <= '0;
                  end
                end
                default: ;   // dst/src bytes: assembled and dropped
              endcase
            end
          end
        end

        // ---------------------------------------------------------------
        // Payload. A length frame ends by count; a type frame ends when the
        // line does, which arrives as an invalid cell -- handled after the
        // case, since it is a whole-frame rule.
        // ---------------------------------------------------------------
        S_PAYLOAD: begin
          if (ok) begin
            shreg   <= shreg_n[7:1];
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
              bit_cnt <= '0;
              // A type frame has no length to bound against, so the bound is
              // enforced here instead: out of room means the frame cannot fit,
              // and it is rejected rather than wrapped over the ring. The FCS
              // transition is nested INSIDE the successful-write branch so a
              // rejected byte cannot also advance the phase -- written as two
              // sibling ifs, a length frame's last byte would let the FCS
              // assignment override the reject.
              if (room == 0) begin
                state <= S_ERR;
              end else begin
                wptr    <= wptr + 1'b1;
                room    <= room + consume_credit - 1'b1;
                pay_cnt <= pay_cnt + 16'd1;
                if (!is_type && (pay_cnt + 16'd1 >= field)) begin
                  // A length frame ends by count. If the declared length is
                  // under the 46-byte minimum, the transmitter appended pad
                  // bytes BEFORE the FCS and the FCS covers them -- so consume
                  // them next instead of mistaking them for the FCS.
                  if (field < MIN_PAY) begin
                    state   <= S_PAD;
                    pad_cnt <= '0;
                  end else begin
                    state   <= S_FCS;
                    fcs_cnt <= '0;
                  end
                end
              end
            end
          end
        end

        // ---------------------------------------------------------------
        // The 802.3 pad: 46 minus the declared length bytes, folded as data
        // (they are covered by the FCS) and NOT stored. `pay_cnt` does not
        // move, so frame_len stays the declared payload length and the buffer
        // holds exactly the bytes the client asked for.
        // ---------------------------------------------------------------
        S_PAD: begin
          if (ok) begin
            shreg   <= shreg_n[7:1];
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt == 3'd7) begin
              bit_cnt <= '0;
              pad_cnt <= pad_cnt + 16'd1;
              if (field + pad_cnt + 16'd1 >= MIN_PAY) begin
                state   <= S_FCS;
                fcs_cnt <= '0;
              end
            end
          end
        end

        // ---------------------------------------------------------------
        // The 32 FCS bits of a length frame, folded as transmitted and not
        // written (a length frame knows where its payload ends, so its FCS
        // never has to be guessed at).
        // ---------------------------------------------------------------
        S_FCS: begin
          if (ok) begin
            fcs_cnt <= fcs_cnt + 5'd1;
            if (fcs_cnt == 5'd31) begin
              state    <= S_SETTLE;
              settle   <= '0;
              fcs_done <= 1'b1;
            end
          end
        end

        // ---------------------------------------------------------------
        // The verdict, three cycles after the last fold. Free: bit cells are
        // 12 clocks apart at the 60 MHz / SPB=12 grid.
        // ---------------------------------------------------------------
        S_SETTLE: begin
          settle <= settle + 2'd1;
          if (settle == 2'd2) begin
            // The CRC residue is necessary but NOT sufficient: the frame must
            // also have a complete STRUCTURE. A header that never finished has
            // no field; a TYPE frame under 64 bytes total (46 data + 4 stored
            // FCS) is a runt; a frame that ends 1-7 bits into a byte is not a
            // frame at all; a LENGTH frame that aborted before its FCS bits
            // completed is truncated. The runt the review sent had a valid
            // residue and none of the structure.
            if ((crc_state == CRC_RESIDUE) && hdr_done && (bit_cnt == 3'd0) &&
                (is_type ? (pay_cnt >= MIN_TYPE_PAY) : fcs_done)) begin
              frame_valid <= 1'b1;
              // Wind back only what the FCS actually occupied in the buffer:
              // 4 bytes for a type frame, NOTHING for a length frame whose FCS
              // was never written.
              //
              // A plain if-else, NOT `is_type ? FCS_BYTES : '0`. The ternary
              // version silently corrupted wptr: an unsized '0 makes that arm
              // one bit wide, so the subtractor's width came from the ternary
              // instead of from wptr, and the result truncated -- measurable as
              // wptr going X after the first frame and later frames being
              // mis-classified. Explicit width on every arm, or no ternary.
              // FCS_BYTES is a 3-bit localparam, so it is zero-extended
              // EXPLICITLY rather than part-selected: `FCS_BYTES[AW:0]` is a
              // 12-bit select on a 3-bit value, which Icarus resolves to X --
              // measured, and it silently poisoned `room` from the second
              // frame on.
              if (is_type) begin
                wptr      <= wptr - AW'(FCS_BYTES);
                room      <= room + consume_credit
                             + {{(AW-2){1'b0}}, FCS_BYTES};
                published_used <= published_used + pay_cnt[AW:0]
                                   - {{(AW-2){1'b0}}, FCS_BYTES}
                                   - consume_credit;
                frame_len <= pay_cnt - 16'd4;
              end else begin
                frame_len <= pay_cnt;
                published_used <= published_used + pay_cnt[AW:0]
                                   - consume_credit;
              end
            end else begin
              frame_bad <= 1'b1;
              // A bad frame must not leave bytes that look like one: the
              // pointer rolls back to where the frame started.
              wptr  <= frame_start;
              // Reclaim EVERY byte that was charged against `room`, and the
              // width is the whole point: `pay_cnt[AW-1:0]` truncates, and a
              // full 2,048-byte frame has pay_cnt = 2048 = 11'h000, so the
              // reclaim added zero and left the receiver with room = 0
              // FOREVER (every later frame then failed its header check).
              // `pay_cnt[AW:0]` is AW+1 bits, matching `room`, and the sum
              // cannot overflow because room + pay_cnt is <= BUF_BYTES: every
              // byte in pay_cnt was subtracted from room as it was written.
              // The published-byte guard makes `consume_credit` disjoint from
              // this frame's reclaim, so room + pay_cnt + freed is also <=
              // BUF_BYTES even if a consumer over-reads during reception.
              room  <= room + consume_credit + pay_cnt[AW:0];
            end
            state <= S_SEARCH;
          end
        end

        // ---------------------------------------------------------------
        // Rejected. For a header rejection nothing was written and pay_cnt is
        // 0, so the reclaim is a no-op; for a payload rejection it reclaims
        // what landed. Either way the pointer returns to the frame's start, so
        // a rejected frame leaves no debris in the ring.
        // ---------------------------------------------------------------
        S_ERR: begin
          frame_bad <= 1'b1;
          wptr      <= frame_start;
          // Full-width reclaim; see the bad-FCS branch for why AW-1:0 was the
          // permanent-exhaustion bug.
          room      <= room + consume_credit + pay_cnt[AW:0];
          state     <= S_SEARCH;
        end

        default: state <= S_SEARCH;
      endcase

      // ---- the invalid cell, and end-of-frame -------------------------
      // One copy of a whole-frame rule instead of one per state.
      //
      // NOT applied while searching: before the SFD the line is idle and every
      // idle cell is "invalid", so a search that aborted on rx_err would never
      // survive its own preamble.
      //
      // A truncated frame needs no separate handling: its last bit was never
      // folded, so the residue will not match and the verdict lands as
      // frame_bad on its own.
      if (ok == 1'b0 && pend == 1'b1 && rx_err == 1'b1 &&
          (state == S_HEADER || state == S_PAYLOAD || state == S_PAD ||
           state == S_FCS)) begin
        state  <= S_SETTLE;
        settle <= '0;
      end
    end
  end

endmodule
