// pe_dru.v — the digital data-recovery unit: oversampled receive for
//            10BASE-T Manchester and PS/2.
// Signal meanings: wiki/reference/signal-names.md#pe_dru
// Spec: wiki/concepts/cdr-oversampling.md · ADR: decisions/adr-001-8x-oversampling.md
//
// This is the block the wiki calls the hardest one in the project, and the
// reason is the grid and the bit framing, not the gates. So the explanation is
// long and the RTL is short.
//
// ---------------------------------------------------------------------------
// THE SAMPLING GRID: PHASE SPB/4 AND 3*SPB/4, OF A COUNTER THAT RESETS ON EVERY EDGE
//
// SPB = samples per bit period (12 by default: an 8.33 ns grid on a 100 ns bit,
// the ADR-001/ADR-005 design point at the 60 MHz core clock). A half-cell is
// SPB/2 samples. The phase counter
//
//     phase <= edge ? 0 : phase + 1        (mod SPB)
//
// so `phase` is a sample's DISTANCE FROM THE LAST TRANSITION — the edge sample
// itself is phase 0, the next sample phase 1, and so on. Two captures per bit
// period, at phase SPB/4 and phase 3*SPB/4 — 2 and 6 at SPB=8, 3 and 9 at
// SPB=12. Those instants are exactly the half-cell centres:
//
//   * A half-cell begins at a transition (phase 0) or at a half-cell boundary
//     with no transition (phase 0 of the free-running counter, i.e. SPB/2 after
//     the last edge). Its centre is SPB/4 samples later — phase SPB/4 for one
//     case and phase 3*SPB/4 for the other. Either way exactly one capture lands
//     on it, which is why "sample at SPB/4 and 3*SPB/4" covers both with no
//     boundary-edge-exception logic. This is verified in tb_pe_dru against every
//     Manchester transition pattern (00, 01, 10, 11) and a random 4 KiB payload,
//     and it is the single most important thing in the file.
//
// ---------------------------------------------------------------------------
// THE BIT FRAMING, AND WHY PHASE 6 IS THE WHOLE TRICK
//
// A Manchester bit cell ALWAYS contains a mid-bit transition (that is the code:
// H->L is a 0, L->H is a 1) and MAY contain a boundary one:
//
//     0 -> 0 : boundary edge present      1 -> 1 : boundary edge present
//     0 -> 1 : no boundary edge           1 -> 0 : no boundary edge
//
// The two halves of a cell always DIFFER — by definition. So an absent
// transition at a half-cell boundary can only mean that boundary is a BIT
// boundary, and therefore:
//
//     a phase-3*SPB/4 capture is ALWAYS the first half of a bit cell
//
// That single fact is the framing. The counter reached phase 3*SPB/4 without an
// edge at phase 0, so the half-cell starting SPB/2 ago had no transition — so it
// is a first half. No edge classification, no spacing measurement, no preamble
// needed to know it.
//
// A phase-SPB/4 capture is then resolved by expectation: it is the second half
// if one is pending, otherwise it is itself a first half. Either way the
// expectation flips, because a first half is always followed by its own second
// half one half-cell later. That is the entire state machine — one bit.
//
// The stream therefore produces ONE bit per cell, emitted as `bit_en` with
// `rx_first`/`rx_second` for pe_manch, which does not care how they were found.
//
// ---------------------------------------------------------------------------
// LOCK
//
// `locked` is a CONFIDENCE INDICATOR, NOT A GATE. It counts well-formed cells
// (ones where a mid-bit transition was seen) and clears on a malformed one. The
// DRU emits bit_en whether or not locked: a consumer that gates on `locked`
// drops the first bits of every frame, and every protocol here has a preamble
// whose whole purpose is to be the part that gets dropped. Firmware decides what
// to do with the flag; nothing in this repo gates on it.
//
// A mid-bit transition being always present is also why the lock test is simply
// "was there a transition inside this cell" — a cell with none is not a
// Manchester cell, it is noise or an idle line.
//
// ---------------------------------------------------------------------------
// INPUT PATH
//
// The 2-flop synchronizer is NOT optional: the pin is asynchronous to the sample
// clock and this is the block that would sample metastability. cfg_filter_en
// adds a 3-tap majority vote after it, for a noisy cable; it is off by default
// because on a clean line it only shifts the detected edge position by a sample.
// The filter is applied to the SYNCHRONIZED signal, never before it — voting
// three metastable samples would be worse than not filtering.

module pe_dru #(
  parameter int SPB = 12           // samples per bit period; must be even, >= 8
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        rx_pin,          // the raw asynchronous pin
  input  logic        cfg_filter_en,   // 3-tap majority on the synchronized pin
  input  logic [7:0]  cfg_lock_bits,   // bits required before `locked` (0 = 4)

  output logic        bit_en,          // one strobe per decoded bit cell
  output logic        rx_first,        // first half-cell level of this bit
  output logic        rx_second,       // second half-cell level = the bit value
  output logic        rx_wire,         // latest half-cell sample (non-Manchester use)
  output logic        locked,          // confidence: cfg_lock_bits well-formed cells
  output logic [3:0]  dbg_phase        // the phase counter, for bring-up
);

  // Elaboration guards. Two separate constraints, and only checking the first
  // is a trap that cost real debugging time:
  //
  //   1. SPB % 4 == 0, so the capture phases land on half-cell centres.
  //   2. SPB <= 16, because `phase` is 4 bits and the wrap constant is
  //      `4'(SPB - 1)`, which SILENTLY TRUNCATES above 16. At SPB=20 the
  //      counter wraps at phase 3 instead of 19, never reaches PH_SAMP=5 or
  //      PH_FIRST=15, and the block emits NOTHING AT ALL -- a dead DRU, no
  //      error, no output. Measured: SPB 8/12/16 pass the TB, SPB 20+ do not.
  //
  // The failure is silent, which is why it is an elaboration error here rather
  // than a comment. Widen `phase` and `SPB_M1` together if a larger SPB is ever
  // needed; SPB=12 (the 60 MHz default grid) is well inside the limit.
  //
  // NOTE: Icarus supports only a SINGLE STRING argument to $error at
  // elaboration, so these messages carry no %0d formatting -- passing an
  // argument makes the tool emit "sorry: Elaboration tasks currently only
  // support a single string argument" INSTEAD of the intended text. Keep them
  // plain strings; the parameter value is visible in the build command anyway.
  if ((SPB % 4) != 0) begin : g_spb_guard
    $error("pe_dru: SPB must be a multiple of 4, so the capture phases land on half-cell centres.");
  end
  if (SPB > 16) begin : g_spb_width_guard
    $error("pe_dru: SPB must be <= 16: phase is 4 bits and 4'(SPB-1) truncates above it, which silently kills all capture.");
  end

  localparam int PH_SAMP  = SPB / 4;          // 2  -> a second half, usually
  localparam int PH_FIRST = 3 * SPB / 4;      // 6  -> always a first half

  // ---------------- input path ----------------
  logic rx_s0, rx_s1;
  logic rx_v0, rx_v1, rx_v2;
  logic rx_maj;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_s0 <= 1'b1; rx_s1 <= 1'b1; end
    else        begin rx_s0 <= rx_pin; rx_s1 <= rx_s0; end
  end

  // 3-tap majority over the synchronizer output.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_v0 <= 1'b1; rx_v1 <= 1'b1; rx_v2 <= 1'b1; end
    else        begin rx_v0 <= rx_s1; rx_v1 <= rx_v0; rx_v2 <= rx_v1; end
  end

  assign rx_maj = (rx_v0 & rx_v1) | (rx_v1 & rx_v2) | (rx_v0 & rx_v2);

  // WHY THE FILTER OUTPUT IS RESAMPLED BEFORE IT DRIVES THE PHASE COUNTER.
  //
  // A majority vote over three taps is not a transparent delay: at a level
  // change its output moves ONE SAMPLE LATER than the centre tap does, because
  // it takes two agreeing taps to flip. Feeding that straight into the edge
  // detector SHIFTS EVERY EDGE BY A SAMPLE -- and since the phase counter resets
  // on the detected edge, every capture moves with it. At SPB=8 a one-sample
  // shift puts the phase-3*SPB/4 capture 3 samples past a half-cell boundary
  // instead of 2, i.e. inside the NEXT half-cell, and the levels come out wrong.
  //
  // So `rx_eff` is the majority output SAMPLED ONCE (one flop, one sample of
  // delay, no logic). Measured against the unfiltered path the grid is then
  // identical -- the filter only removes glitches, it does not move edges.
  // tb_pe_dru compares filtered and unfiltered captures of the same pattern to
  // hold that property, and it is the reason cfg_filter_en does not need its own
  // re-qualification.
  logic rx_eff;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) rx_eff <= 1'b1; else rx_eff <= cfg_filter_en ? rx_maj : rx_v1;

  // ---------------- phase counter + edge detect ----------------
  localparam logic [3:0] SPB_M1 = 4'(SPB - 1);

  logic [3:0]  phase;
  logic        prev_lvl, is_edge;

  assign is_edge = (rx_eff != prev_lvl);
  assign dbg_phase = phase;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase <= '0; prev_lvl <= 1'b1;
    end else begin
      prev_lvl <= rx_eff;
      // Increment first, reset on an edge: `phase` is the sample's distance
      // from the last transition. Wrapping at SPB keeps the counter free-running
      // on an idle line, which is what lets a frame be acquired without any
      // explicit start.
      if (is_edge)          phase <= '0;
      else if (phase == SPB_M1) phase <= '0;
      else                  phase <= phase + 4'd1;
    end
  end

  // ---------------- capture + bit framing ----------------
  logic expect_second;      // is the next phase-SPB/4 capture a second half?
  logic held_first;         // the first half waiting for its partner

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      expect_second <= 1'b0;
      held_first    <= 1'b0;
      bit_en        <= 1'b0;
      rx_first      <= 1'b0;
      rx_second     <= 1'b0;
      rx_wire       <= 1'b1;
    end else begin
      bit_en <= 1'b0;

      if (phase == PH_FIRST[3:0]) begin
        // The counter reached here with no edge at phase 0, so the half-cell
        // that started SPB/2 ago had no transition — it is a first half.
        held_first    <= rx_eff;
        expect_second <= 1'b1;
        rx_wire       <= rx_eff;
      end else if (phase == PH_SAMP[3:0]) begin
        if (expect_second) begin
          // Both halves of this cell are now known: emit the bit.
          rx_first      <= held_first;
          rx_second     <= rx_eff;
          rx_wire       <= rx_eff;
          bit_en        <= 1'b1;
          expect_second <= 1'b0;
        end else begin
          // No second half was pending, so this is a first half itself.
          held_first    <= rx_eff;
          expect_second <= 1'b1;
          rx_wire       <= rx_eff;
        end
      end
    end
  end

  // ---------------- lock ----------------
  // A well-formed Manchester cell has two DIFFERENT halves — that is the code,
  // and it is the whole reason the framing above works. An idle line, by
  // contrast, completes cells with equal halves, so one comparator distinguishes
  // "data" from "nothing". No edge history, no extra flops.
  //
  // This is exactly the property pe_manch tests to produce rx_err, and the two
  // derive it INDEPENDENTLY from the same two inputs rather than sharing state:
  // the codec already has rx_first/rx_second and needs no help, and a lock
  // indicator that depended on the codec's error flag would be circular.
  logic well_formed;
  assign well_formed = (rx_first != rx_second);

  logic [7:0] lock_cnt, lock_target;
  assign lock_target = (cfg_lock_bits == 8'd0) ? 8'd4 : cfg_lock_bits;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lock_cnt <= '0; locked <= 1'b0;
    end else if (bit_en) begin
      if (well_formed) begin
        if (lock_cnt < lock_target) lock_cnt <= lock_cnt + 8'd1;
        else                        locked  <= 1'b1;
      end else begin
        lock_cnt <= '0;
        locked   <= 1'b0;
      end
    end
  end

endmodule
