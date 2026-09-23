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
// TWO SAMPLES PER CORE CLOCK (DDR), WHICH IS WHAT MAKES 60 MHz ENOUGH
//
// 10BASE-T's bit period is 100 ns. A 12-sample-per-bit grid therefore samples
// every 8.33 ns -- 120 MHz -- and the core is 60 MHz. The grid comes from the
// CLOCK'S TWO EDGES, not from a faster clock: the pin is captured at every
// rising edge and every falling edge, and the 60 MHz state machine consumes
// both samples per cycle. ADR-002 chose the latch-pair form of this capture
// (all flops in sg13g2 are rising-edge only); this file is that front end.
//
// MEASURED, and the reason this rewrite exists: the first implementation sampled
// rising edges only. Its testbenches drove the wire at half the real bit rate
// (one sample per clock), so they passed while a real 100 ns/bit stimulus was
// missed entirely at 60 MHz. A grid claim that its test cannot reach is a claim
// that has not been tested.
//
// ---------------------------------------------------------------------------
// THE SAMPLING GRID: PHASE SPB/4 AND 3*SPB/4, OF A COUNTER THAT RESETS ON EVERY EDGE
//
// SPB = samples per bit period (12 by default: an 8.33 ns grid on a 100 ns bit,
// the ADR-001/ADR-005 design point at the 60 MHz core clock, from an edge every
// 16.67 ns). A half-cell is SPB/2 samples. The phase counter
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
// INPUT PATH: TWO STREAMS, ALIGNED BY THE TAP COUNTS
//
// The rising-edge path keeps the 2-flop synchronizer (the pin is asynchronous
// and this is the block that would sample metastability). The falling-edge
// sample is captured by a LATCH TRANSPARENT WHILE clk IS HIGH: it closes at the
// falling edge, holds through the low phase, and a rising-edge flop takes it
// with half a cycle of settling — the latch-pair timing ADR-002 specifies.
//
// The two streams reach the state machine with DIFFERENT raw latency (the
// rising path has one more flop than the falling one), so the falling path
// carries one extra history tap. The pair presented at each rising edge is
// therefore (rising sample, falling sample) OF THE SAME BIT PERIOD, in time
// order, and the machine processes them in that order.
//
// cfg_filter_en adds a 3-tap majority vote per stream, for a noisy cable. The
// filter is applied AFTER synchronization and BEFORE the edge detector. Its
// output is resampled once so it cannot move an edge — see the trap note below.
// The filter is off by default because on a clean line it only shifts the
// detected edge noise floor; it is not a substitute for the synchronizer.

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
  localparam logic [3:0] SPB_M1 = 4'(SPB - 1);

  // ---------------- DDR input path ----------------
  logic rx_s0, rx_s1;              // rising-edge sample, 2-flop synchronizer
  logic rx_nl, rx_nl2;             // falling-edge sample: latch pair
  logic rx_nq;                     // ...captured by the rising-edge flop

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_s0 <= 1'b1; rx_s1 <= 1'b1; end
    else        begin rx_s0 <= rx_pin; rx_s1 <= rx_s0; end
  end

  // TWO latches, not one. The first is transparent while the clock is HIGH,
  // so it closes on the FALLING edge and holds through the low phase. The
  // second is transparent while the clock is LOW and holds through the high
  // phase. The rising-edge flop takes the SECOND one, which is closed at that
  // edge -- and that is the whole point.
  //
  // With a single latch the capture was a simulation race: at the rising edge
  // the first latch re-opens and its blocking assignment competes with the
  // flop's read of it in the active region, so the flop could take the NEW pin
  // level (the rising-edge sample) instead of the value held since the falling
  // edge. Measured: a frame whose half-cells are slightly faster than the DUT
  // clock (49.995 ns) lost 10,786 of 12,144 folds and was rejected; 34 of 102
  // phase/duration/filter trials failed, all faster-wire. The slave latch is
  // closed at the rising edge, so there is nothing to race. This is also what
  // ADR-002's two-phase latch-pair DET means; sg13g2 has no negedge flops.
  always_latch
    if (clk) rx_nl = rx_pin;

  always_latch
    if (!clk) rx_nl2 = rx_nl;

  // Post-reset priming. The latches are not resettable, so for the first edge
  // after reset release they can still hold a pre-reset sample; the flop would
  // inject that stale bit into the falling stream and the first cell could pair
  // it with a reset level (measured: the held-line test saw one unequal-half
  // cell, and the 8-bit lock test counted that cell). Hold the falling path at
  // idle until the latch pair has seen two edges. The rising path needs no
  // equivalent: all of its flops reset to 1.
  logic [1:0] rst_prime;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_prime <= 2'b00;
    else        rst_prime <= {rst_prime[0], 1'b1};
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         rx_nq <= 1'b1;
    else if (!rst_prime[1]) rx_nq <= 1'b1;   // prime: keep the pair idle
    else                rx_nq <= rx_nl2;
  end

  // 3-tap majority over the INTERLEAVED sample stream, which is the stream the
  // original single-edge design filtered: at 12 samples/bit a half-cell has 6
  // samples, so a single bad sample is outvoted with room to spare. (The first
  // DDR draft filtered each edge stream separately; each half then has only 3
  // samples, the majority window always spans the half's transition, and a
  // mid-half glitch walks the filtered edge -- measured by tb_pe_dru's
  // filtered-glitch check.)
  //
  // The trap from the original design still applies and is why the machine
  // input is NOT simply the majority of the newest three samples: a majority is
  // not a transparent delay. At a level change its output moves one sample
  // later than the centre tap, so feeding it straight into the edge detector
  // shifts every edge by a sample and the captures move with it. The fix is to
  // give the UNFILTERED path the same latency: the machine takes x[i-2], and
  // the filtered path takes the majority of x[i-1], x[i-2], x[i-3]. Both then
  // flip on the same machine sample, so cfg_filter_en cannot move the grid --
  // including for a glitch next to a real edge, where both paths take the bad
  // edge together (a majority cannot invent information; it only outvotes
  // isolated samples on a stable level).
  //
  // h0..h2 are x[i-1]..x[i-3]; x[i] is rx_s1 and x[i+1] is rx_nq at the edge.
  logic h0, h1, h2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      h0 <= 1'b1; h1 <= 1'b1; h2 <= 1'b1;
    end else begin
      h0 <= rx_nq;      // x[i+1]
      h1 <= rx_s1;      // x[i]
      h2 <= h0;         // x[i-1]
    end
  end

  wire rx_maj_p = (h0 & h1) | (h1 & h2) | (h0 & h2);
  wire rx_maj_n = (rx_s1 & h0) | (h0 & h1) | (rx_s1 & h1);
  wire rx_p_in  = cfg_filter_en ? rx_maj_p : h1;
  wire rx_n_in  = cfg_filter_en ? rx_maj_n : h0;

  // ---------------- phase counter + capture, two samples per clock --------
  // The per-sample step is a TASK called twice per clock -- once for the
  // rising-edge sample and once for the falling-edge one. `phase` counts
  // SAMPLES (not clocks), so both calls advance it by one and the captures
  // land on the same phases the single-edge design used. It is a task with
  // OUTPUT ARGUMENTS, not a function returning a struct: Yosys 0.68 (the
  // repo's synthesis/lint tool) rejects a function whose return type is a named
  // packed struct with a bare syntax error, and it has no `ref` ports. The
  // first draft used structs and passed iverilog and verilator while yosys
  // could not parse the file at all -- which is also why regress/lint.sh now fails
  // on ANY yosys ERROR, not just the three diagnostics it used to grep for.
  task automatic grid_step(input  logic [3:0] g_phase,
                           input  logic       g_prev_lvl,
                           input  logic       g_expect_second,
                           input  logic       g_held_first,
                           input  logic       lvl,
                           output logic [3:0] n_phase,
                           output logic       n_prev_lvl,
                           output logic       n_expect_second,
                           output logic       n_held_first,
                           output logic       bit_now,
                           output logic       first_now,
                           output logic       second_now);
    logic is_edge;

    n_phase = g_phase; n_prev_lvl = g_prev_lvl;
    n_expect_second = g_expect_second; n_held_first = g_held_first;
    is_edge = (lvl != g_prev_lvl);
    n_prev_lvl = lvl;

    bit_now = 1'b0; first_now = 1'b0; second_now = 1'b0;

    if (g_phase == PH_FIRST[3:0]) begin
      // The counter reached here with no edge at phase 0, so the half-cell
      // that started SPB/2 ago had no transition — it is a first half.
      n_held_first    = lvl;
      n_expect_second = 1'b1;
    end else if (g_phase == PH_SAMP[3:0]) begin
      if (g_expect_second) begin
        // Both halves of this cell are now known: emit the bit.
        bit_now         = 1'b1;
        first_now       = g_held_first;
        second_now      = lvl;
        n_expect_second = 1'b0;
      end else begin
        // No second half was pending, so this is a first half itself.
        n_held_first    = lvl;
        n_expect_second = 1'b1;
      end
    end

    if (is_edge)                n_phase = '0;
    else if (g_phase == SPB_M1) n_phase = '0;
    else                        n_phase = g_phase + 4'd1;
  endtask

  logic [3:0] grid_phase;
  logic       grid_prev_lvl, grid_expect_second, grid_held_first;
  // The two steps per clock are COMBINATIONAL here and registered below. The
  // first draft used blocking assignments to shared temporaries inside the
  // sequential block, which trips the BLKSEQ lint warning; an always_comb makes
  // the temporaries explicit combinational nodes with no register between the
  // two samples.
  logic [3:0] p1_phase, p2_phase;
  logic       p1_prev, p2_prev, p1_expect, p2_expect, p1_held, p2_held;
  logic       b1, f1, s1, b2, f2, s2;

  always_comb begin
    grid_step(grid_phase, grid_prev_lvl, grid_expect_second, grid_held_first,
              rx_p_in, p1_phase, p1_prev, p1_expect, p1_held, b1, f1, s1);
    grid_step(p1_phase, p1_prev, p1_expect, p1_held,
              rx_n_in, p2_phase, p2_prev, p2_expect, p2_held, b2, f2, s2);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      grid_phase         <= 4'd0;
      grid_prev_lvl      <= 1'b1;
      grid_expect_second <= 1'b0;
      grid_held_first    <= 1'b0;
      bit_en          <= 1'b0;
      rx_first        <= 1'b0;
      rx_second       <= 1'b0;
      rx_wire         <= 1'b1;
    end else begin
      bit_en <= 1'b0;
      // Rising-edge sample first, then falling-edge: within one bit period the
      // rising edge comes first in time, and the phase counter's edge reset is
      // order-dependent, so the order is not interchangeable. The pair is
      // computed combinationally above from this cycle's state.
      grid_phase         <= p2_phase;
      grid_prev_lvl      <= p2_prev;
      grid_expect_second <= p2_expect;
      grid_held_first    <= p2_held;

      // At most one bit per clock: captures are SPB/2 samples apart and there
      // are two samples per clock, so SPB=8 (the smallest legal grid) still
      // spaces them by two clocks. The priority if-else is belt and braces,
      // with the earlier sample winning.
      if (b1) begin
        bit_en    <= 1'b1;
        rx_first  <= f1;
        rx_second <= s1;
      end else if (b2) begin
        bit_en    <= 1'b1;
        rx_first  <= f2;
        rx_second <= s2;
      end
      rx_wire <= rx_n_in;      // the later of the two samples this clock
    end
  end

  assign dbg_phase = grid_phase;

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
  //
  // The lock update reads the REGISTERED bit_en and halves, exactly as the
  // original single-edge design did, so `locked` keeps its one-cycle-behind-
  // the-capture relationship to bit_en.
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
