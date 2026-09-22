// tb_pe_dru.v — self-checking testbench for pe_dru.
//
// WHAT IS BEING CHECKED
//
// The DRU's job is to turn an oversampled asynchronous pin into one strobe per
// Manchester bit cell, with the two half-cell samples pe_manch wants. Three
// things can go wrong and each is checked here separately:
//
//   1. THE SAMPLING GRID. Every half-cell must be captured, at its centre, for
//      EVERY Manchester transition pattern. A grid that is right for 0101 and
//      wrong for 0011 is a real failure mode, and the four 2-bit patterns
//      (00, 01, 10, 11) are the exhaustive case: they are the only things a
//      half-cell boundary can look like.
//   2. THE BIT FRAMING. The captured halves must be paired into the right bit
//      cells with the right first/second labels and the right values, for
//      arbitrary data — not just for a preamble.
//   3. THE EDGE CASES. An idle line must produce only illegal cells and must
//      never lock; the input filter must swallow a single-sample glitch.
//
// The reference is NOT a copy of the DUT. It is a Manchester ENCODER built from
// the ground-truth definition (bit 1 = L then H, bit 0 = H then L; SPB samples
// per bit) and the test asserts that the DUT recovers exactly the bits that were
// encoded — from the other end of that, with no knowledge of the pattern.
//
// The DRU samples the pin on BOTH edges of the 60 MHz core clock (ADR-002's
// DDR front end), so this TB drives REAL 10BASE-T timing: a 60 MHz clock and a
// 100 ns bit period, i.e. 3 clocks / 6 samples per 50 ns half-cell. The first
// version of this TB collapsed the DDR front end into "one sample per clock"
// and ran at 100 MHz with 120 ns bits, which passed while a real 100 ns/bit
// stimulus was missed entirely -- the review finding this TB closes.
//
// A `drive_half` holds a level for exactly HALF samples by walking the sample
// edges explicitly, and sets the level just after an edge so it can never race
// the sample's capture.
//
// ICARUS NOTE: task ports cannot be unpacked arrays, so the vectors below are
// module-scope. `nvec` says how many entries of the ACTIVE vector are in use.

`timescale 1ns / 1ps

module tb_pe_dru;

  localparam int SPB  = 12;      // samples per bit period (60 MHz / ADR-005)
  localparam int HALF = SPB / 2; // samples per half-cell (6)
  localparam int CLK_HZ = 60_000_000;
  localparam real CLK_NS = 1e9 / CLK_HZ;   // 16.667 ns; real, not rounded
  localparam int MAXB = 2048;    // bit cells in the longest vector here

  logic       clk = 0, rst_n;
  logic       rx_pin, cfg_filter_en;
  logic [7:0] cfg_lock_bits;
  logic       bit_en, rx_first, rx_second, rx_wire, locked;
  logic [3:0] dbg_phase;

  pe_dru #(.SPB(SPB)) dut (.*);
  always #(CLK_NS/2) clk = ~clk;

  // ---- the integration that matters: DRU -> pe_manch ----
  // The DRU's contract is defined by what the codec wants, so the only test that
  // proves the contract is feeding the DRU's rx_first/rx_second straight into a
  // pe_manch and reading its decoded bit and its error flag. A DRU whose halves
  // were swapped would pass every level check above and still be useless.
  //
  // bit_en is shared: pe_manch samples the two halves and commits on the same
  // strobe, and its rx_raw is combinational so it is valid BEFORE it.
  logic man_tx_unused, man_rx_bit, man_rx_err;
  pe_manch u_manch (
    .clk(clk), .rst_n(rst_n), .bit_en(bit_en), .bypass(1'b0), .clr(1'b0),
    .half_phase(1'b0),
    .tx_raw(1'b0), .tx_wire(man_tx_unused),
    .rx_wire(rx_wire), .rx_first(rx_first), .rx_second(rx_second),
    .rx_raw(man_rx_bit), .rx_err(man_rx_err)
  );

  logic man_bits [0:MAXB-1];     // decoded raw bits, one per bit_en
  logic man_errs [0:MAXB-1];
  int   nman;

  always @(posedge clk) begin
    if (rst_n && bit_en) begin
      if (nman < MAXB) begin
        man_bits[nman] = man_rx_bit;
        man_errs[nman] = man_rx_err;
      end
      nman = nman + 1;
    end
  end

  integer errors = 0;
  int     seed = 20260920;

  // The bit vector under test, and the captured stream.
  logic vec    [0:MAXB-1];
  logic cap_f  [0:MAXB-1];
  logic cap_s  [0:MAXB-1];
  logic cap_lk [0:MAXB-1];      // `locked` AS OF each emitted cell
  logic filt_f [0:MAXB-1];      // filtered-run captures, for the A/B below
  logic filt_s [0:MAXB-1];
  int   filt_n;
  int   nvec, nbits;

  // `locked` is a level that clears on the first malformed cell, and the line
  // goes idle after every test vector — which correctly clears it. So the lock
  // state during a frame has to be captured PER CELL rather than sampled once at
  // the end, or the assertion reads the post-frame value and always fails.
  // (STATUS gotcha 6: a single-cycle event behind trailing timing needs a sticky
  // record. This is the same lesson in the other direction.)
  always @(posedge clk) begin
    if (rst_n && bit_en) begin
      if (nbits < MAXB) begin
        cap_f[nbits]  = rx_first;
        cap_s[nbits]  = rx_second;
        cap_lk[nbits] = locked;      // pre-update value: the verdict for THIS cell
      end
      nbits = nbits + 1;
    end
  end

  task automatic check(input bit c, input string m);
    if (!c) begin $display("FAIL dru: %s @%0t", m, $time); errors++; end
  endtask

  function automatic logic lvl_of(input bit b, input bit first_half);
    return first_half ? ~b : b;      // bit 1 -> L then H ; bit 0 -> H then L
  endfunction

  // One sample per edge, with the edge parity tracked GLOBALLY. The first
  // draft derived the edge from a per-loop k parity, which assumes every task
  // returns with the same parity it started with -- true for drive_half but
  // not something to rely on when a glitch loop interleaves with it. A wrong
  // parity silently injects TWO-sample glitches, which is exactly what a
  // filtered-glitch check then reads as a corrupt cell.
  bit next_pos = 1'b1;             // does the NEXT sample edge rise?

  task automatic drive_sample(input logic lvl);
    rx_pin = lvl;
    if (next_pos) @(posedge clk); else @(negedge clk);
    next_pos = ~next_pos;
  endtask

  // One half-cell: HALF consecutive samples at one level. The assignment
  // happens just after the previous edge (or at t=0), and the sample edge is
  // awaited after it, so the stimulus can never race the DUT's capture.
  task automatic drive_half(input logic lvl);
    for (int k = 0; k < HALF; k++) drive_sample(lvl);
  endtask

  task automatic drive_cell(input bit b);
    drive_half(lvl_of(b, 1'b1));
    drive_half(lvl_of(b, 1'b0));
  endtask

  // Assert the DUT's capture stream contains `vec[0..nvec-1]` somewhere, with
  // every matched cell's halves complementary.
  //
  // The search is a SUBSTRING match on purpose. Before the vector starts the
  // line is idle, so the DRU is already emitting cells (equal halves) — that is
  // correct, not noise to be suppressed. The claim under test is that the driven
  // bits appear in order, which a substring match states exactly.
  task automatic check_stream(input string tag);
    int matched, i;
    matched = -1;
    for (int off = 0; off + nvec <= nbits; off++) begin
      bit ok; ok = 1'b1;
      for (i = 0; i < nvec; i++)
        if (cap_s[off+i] !== vec[i]) ok = 1'b0;
      if (ok) begin matched = off; break; end
    end
    check(matched >= 0,
          $sformatf("%s: %0d bits not recovered (stream had %0d)",
                    tag, nvec, nbits));
    if (matched >= 0)
      for (i = 0; i < nvec; i++)
        check(cap_f[matched+i] !== cap_s[matched+i],
              $sformatf("%s: bit %0d halves must differ", tag, i));
  endtask

  // Drive the vector, then continue alternating for two more cells so the final
  // driven cells complete. A cell finishes when its second half is captured, a
  // half-cell after the vector's last sample — stopping dead would leave the last
  // cell or two mid-flight, which is an artifact of the stimulus, not a property
  // of the DRU.
  //
  // THE LEAD-IN IS NOT A FUDGE. The F/S parity of the first captured cell cannot
  // be known until a transition establishes a phase reference, so the first cell
  // after acquisition may be mislabelled — and that is true of every real
  // Manchester receiver, which is precisely WHY Ethernet has a 56-bit preamble
  // and why the preamble is defined as the part that gets consumed during
  // acquisition. Driving three alternating cells first is the honest model of a
  // frame boundary; a test that started mid-frame and demanded the very first
  // cell be correctly labelled would be testing something no protocol promises.
  task automatic run_vec(input string tag);
    int n;
    nbits = 0;
    nman  = 0;
    // lead-in: three alternating cells (the "preamble"), consumed on acquisition
    drive_cell(1'b1); drive_cell(1'b0); drive_cell(1'b1);
    nbits = 0;                       // count only from the payload
    nman  = 0;
    for (int i = 0; i < nvec; i++) drive_cell(vec[i]);
    // tail: continue alternating, which is always a legal Manchester sequence
    n = vec[nvec-1];
    drive_cell(~n);
    drive_cell(n);
    drive_cell(~n);
    repeat (SPB) @(posedge clk);
    check_stream(tag);
    check_dru_to_manch(tag);
  endtask

  // The integration check: pe_manch, fed by the DRU, must decode exactly the
  // driven bits and must not raise rx_err on any of them. The error flag being
  // quiet is the strong half — it means every cell had a mid-bit transition, so
  // the halves were not merely "some value" but a legal Manchester symbol.
  task automatic check_dru_to_manch(input string tag);
    int matched, i, nerr;
    matched = -1;
    for (int off = 0; off + nvec <= nman; off++) begin
      bit ok; ok = 1'b1;
      for (i = 0; i < nvec; i++)
        if (man_bits[off+i] !== vec[i]) ok = 1'b0;
      if (ok) begin matched = off; break; end
    end
    check(matched >= 0,
          $sformatf("%s: pe_manch did not decode the bits (had %0d)", tag, nman));
    if (matched >= 0) begin
      nerr = 0;
      for (i = 0; i < nvec; i++)
        if (man_errs[matched+i] === 1'b1) nerr++;
      check(nerr == 0,
            $sformatf("%s: pe_manch raised rx_err on %0d legal cells", tag, nerr));
    end
  endtask

  task automatic reset_dut();
    rst_n = 0; repeat (4) @(posedge clk); #1; rst_n = 1; @(posedge clk); #1;
  endtask

  initial begin
    $dumpfile("tb_pe_dru.vcd");
    $dumpvars(0, tb_pe_dru);
    rst_n = 0; rx_pin = 1; cfg_filter_en = 0; cfg_lock_bits = 8'd4;
    nbits = 0; nvec = 0;
    repeat (4) @(posedge clk); #1; rst_n = 1; @(posedge clk); #1;

    // ================= exhaustive 2-bit patterns =================
    // These four are the whole of Manchester as far as the grid is concerned:
    // 00 and 11 put a transition on the half-cell boundary, 01 and 10 do not.
    vec[0] = 0; vec[1] = 0; nvec = 2; run_vec("pattern 00");
    vec[0] = 0; vec[1] = 1; nvec = 2; run_vec("pattern 01");
    vec[0] = 1; vec[1] = 0; nvec = 2; run_vec("pattern 10");
    vec[0] = 1; vec[1] = 1; nvec = 2; run_vec("pattern 11");

    // ================= longer fixed vectors =================
    nvec = 32;
    for (int i = 0; i < 32; i++) vec[i] = 1'b1;
    run_vec("32 ones");
    for (int i = 0; i < 32; i++) vec[i] = 1'b0;
    run_vec("32 zeros");
    for (int i = 0; i < 32; i++) vec[i] = i % 2;
    run_vec("32 alternating");
    for (int i = 0; i < 32; i++) vec[i] = (i / 2) % 2;
    run_vec("32 in pairs");

    // ================= Ethernet framing =================
    // 56 alternating preamble bits, SFD 1,1, then arbitrary payload. This is
    // the framing 10BASE-T actually uses, so the preamble cannot be optional.
    nvec = 118;
    for (int i = 0; i < 56; i++) vec[i] = (i % 2 == 0) ? 1'b1 : 1'b0;
    vec[56] = 1'b1; vec[57] = 1'b1;
    for (int i = 0; i < 60; i++) vec[58+i] = $unsigned($random(seed)) & 1'b1;
    run_vec("preamble + SFD + data");

    // ================= random soak =================
    for (int t = 0; t < 24; t++) begin
      nvec = 8 + ($unsigned($random(seed)) % 96);
      for (int i = 0; i < nvec; i++)
        vec[i] = $unsigned($random(seed)) & 1'b1;
      run_vec($sformatf("random %0d", t));
    end

    // ================= lock behaviour =================
    // `locked` is checked from the PER-CELL record, because the idle line after
    // the vector legitimately clears it (see the cap_lk comment above).
    reset_dut();
    nvec = 16;
    for (int i = 0; i < 16; i++) vec[i] = (i % 2 == 0) ? 1'b1 : 1'b0;
    cfg_lock_bits = 8'd4;
    check(locked === 1'b0, "starts unlocked");
    nbits = 0;
    for (int i = 0; i < 16; i++) drive_cell(vec[i]);
    repeat (SPB) @(posedge clk);
    check(cap_lk[5] === 1'b1, "locks one cell after the 4-cell threshold");
    check(cap_lk[15] === 1'b1, "still locked at the end of the frame");
    check(nbits > 8, "emitted bits while locking (locked is not a gate)");

    // An 8-bit threshold must be honoured, not rounded to a constant.
    reset_dut();
    cfg_lock_bits = 8'd8;
    nbits = 0;
    for (int i = 0; i < 16; i++) drive_cell(vec[i]);
    repeat (SPB) @(posedge clk);
    check(cap_lk[5] === 1'b0, "not locked at the 6th cell with an 8-bit threshold");
    check(cap_lk[7] === 1'b0, "not locked at the 8th cell either");
    check(cap_lk[9] === 1'b1, "locks one cell after the 8-cell threshold");
    cfg_lock_bits = 8'd4;

    // ================= a line with no transitions =================
    // A held level is not Manchester. The free-running counter still emits, but
    // every cell's halves are EQUAL — which pe_manch flags as a code violation —
    // and `locked` must never assert. That combination IS what "idle" looks like
    // to this block.
    reset_dut();
    nbits = 0;
    rx_pin = 1'b1;
    repeat (SPB * 12) @(posedge clk);
    check(locked === 1'b0, "a held line never locks");
    begin
      bit all_equal; all_equal = 1'b1;
      for (int i = 0; i < nbits; i++)
        if (cap_f[i] !== cap_s[i]) all_equal = 1'b0;
      check(all_equal, "a held line produces only illegal (equal-half) cells");
    end

    // ================= the input filter =================
    reset_dut();
    cfg_filter_en = 1'b1;
    nvec = 24;
    for (int i = 0; i < 24; i++) vec[i] = (i % 3) ? 1'b1 : 1'b0;
    run_vec("filtered data");
    cfg_filter_en = 1'b0;

    // ================= a single-sample glitch =================
    // The 3-tap majority's actual job, stated so the test can fail: an isolated
    // spike on a HELD line (no transition anywhere near it) must be outvoted,
    // so the line still looks idle -- every cell has equal halves and `locked`
    // never asserts. The same spike with the filter OFF is a legal-looking
    // edge pair and produces well-formed cells, which is what makes the claim
    // falsifiable rather than a tautology.
    //
    // WHAT THIS DOES NOT CLAIM: a glitch inside the 3-tap window of a real
    // transition can move the filtered edge by a sample, because a majority
    // cannot distinguish an early edge from a spike next to one. Measured
    // during the DDR rewrite; the end-to-end Ethernet TB (real frames, real
    // FCS) is the coverage for traffic, and one bad cell is what a framing
    // check rejects anyway.
    reset_dut();
    cfg_filter_en = 1'b1;
    rx_pin = 1'b0;
    repeat (SPB) @(posedge clk);        // settle onto the held level
    nbits = 0;
    // One FALLING-edge sample spikes high. The latch is transparent through the
    // high phase and takes the spike at the falling edge; the restore happens
    // in the low phase, so the next rising sample is clean. A falling-edge
    // spike touches the latch only -- a rising-edge one would be re-taken by
    // the latch at the next falling edge (two samples).
    @(posedge clk);
    rx_pin = 1'b1;
    @(negedge clk);
    #(CLK_NS/4) rx_pin = 1'b0;
    repeat (SPB * 4) @(posedge clk);
    begin
      bit all_equal; all_equal = 1'b1;
      for (int i = 0; i < nbits; i++)
        if (cap_f[i] !== cap_s[i]) all_equal = 1'b0;
      check(all_equal, "filtered: a held line with one spike stays idle");
    end
    check(locked === 1'b0, "filtered: a spike on an idle line cannot lock");
    // Keep the filtered capture stream for the A/B below.
    filt_n = nbits;
    for (int i = 0; i < nbits; i++) begin filt_f[i] = cap_f[i]; filt_s[i] = cap_s[i]; end

    // The same spike, filter OFF. The claim that must be falsifiable is that the
    // filter CHANGED something: if the two streams are identical the filter is
    // a no-op and the check above proves nothing. (Stream equality is the right
    // comparison here; "the unfiltered run must show an unequal cell" is not --
    // whether the spike lands on a capture instant depends on the free-running
    // phase, and measured, it sometimes does not.)
    reset_dut();
    cfg_filter_en = 1'b0;
    rx_pin = 1'b0;
    repeat (SPB) @(posedge clk);
    nbits = 0;
    @(posedge clk);
    rx_pin = 1'b1;
    @(negedge clk);
    #(CLK_NS/4) rx_pin = 1'b0;
    repeat (SPB * 4) @(posedge clk);
    begin
      bit differs; differs = (nbits != filt_n);
      for (int i = 0; i < nbits && i < filt_n; i++)
        if (cap_f[i] !== filt_f[i] || cap_s[i] !== filt_s[i]) differs = 1'b1;
      check(differs, "unfiltered: the same spike must change the capture stream");
    end
    cfg_filter_en = 1'b0;

    if (errors == 0) $display("PASS: tb_pe_dru");
    else $display("FAILURES dru: %0d", errors);
    $finish;
  end

  initial begin
    #10_000_000;
    $display("FAIL: watchdog");
    $finish;
  end
endmodule
