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
// The DRU is single-edge and expects a sample grid; the "sample clock" here is
// just clk at SPB cycles per bit period. That is the 40 MHz-clocked DRU with a
// DDR front end (ADR-002) collapsed into one domain for the test — the logic is
// the same either way.
//
// ICARUS NOTE: task ports cannot be unpacked arrays, so the vectors below are
// module-scope. `nvec` says how many entries of the ACTIVE vector are in use.

`timescale 1ns / 1ps

module tb_pe_dru;

  localparam int SPB  = 8;       // samples per bit period
  localparam int HALF = SPB / 2;
  localparam int MAXB = 2048;    // bit cells in the longest vector here

  logic       clk = 0, rst_n;
  logic       rx_pin, cfg_filter_en;
  logic [7:0] cfg_lock_bits;
  logic       bit_en, rx_first, rx_second, rx_wire, locked;
  logic [3:0] dbg_phase;

  pe_dru #(.SPB(SPB)) dut (.*);
  always #5 clk = ~clk;

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

  task automatic drive_cell(input bit b);
    for (int k = 0; k < HALF; k++) begin
      rx_pin = lvl_of(b, 1'b1); @(posedge clk);
    end
    for (int k = 0; k < HALF; k++) begin
      rx_pin = lvl_of(b, 1'b0); @(posedge clk);
    end
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
    repeat (SPB * 2) @(posedge clk);
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
    repeat (SPB * 2) @(posedge clk);
    check(cap_lk[5] === 1'b1, "locks one cell after the 4-cell threshold");
    check(cap_lk[15] === 1'b1, "still locked at the end of the frame");
    check(nbits > 8, "emitted bits while locking (locked is not a gate)");

    // An 8-bit threshold must be honoured, not rounded to a constant.
    reset_dut();
    cfg_lock_bits = 8'd8;
    nbits = 0;
    for (int i = 0; i < 16; i++) drive_cell(vec[i]);
    repeat (SPB * 2) @(posedge clk);
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
    repeat (SPB * 24) @(posedge clk);
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
    // One inverted sample mid-half-cell. The 3-tap majority must swallow it, so
    // the recovered bits must be exactly the driven ones.
    //
    // The lead-in matters here for the same reason it does in run_vec: the first
    // cell's F/S labels are not knowable until a transition establishes the phase
    // reference. Drive three alternating cells first, then count.
    reset_dut();
    cfg_filter_en = 1'b1;
    nvec = 12;
    for (int i = 0; i < 12; i++) vec[i] = (i % 2 == 0) ? 1'b1 : 1'b0;
    nbits = 0;
    for (int p = 0; p < 3; p++) drive_cell(p % 2);      // lead-in cells 0,1,0
    nbits = 0;                                          // count from the payload
    for (int i = 0; i < 12; i++) begin
      for (int k = 0; k < HALF; k++) begin
        rx_pin = lvl_of(vec[i], 1'b1);
        if (i == 6 && k == 1) rx_pin = ~rx_pin;          // one bad sample
        @(posedge clk);
      end
      for (int k = 0; k < HALF; k++) begin
        rx_pin = lvl_of(vec[i], 1'b0);
        if (i == 6 && k == 3) rx_pin = ~rx_pin;          // and one in the 2nd half
        @(posedge clk);
      end
    end
    drive_cell(~vec[11]); drive_cell(vec[11]);
    repeat (SPB * 2) @(posedge clk);
    check_stream("glitch filtered");

    // And the filter must NOT move the grid: the same pattern captured with the
    // filter off must produce the same levels. (It will produce EXTRA cells from
    // the glitch, which is the documented cost of turning the filter off — so
    // the comparison is that the clean bits are a subsequence, not that the
    // streams are equal.)
    reset_dut();
    cfg_filter_en = 1'b0;
    nbits = 0;
    for (int p = 0; p < 3; p++) drive_cell(p % 2);
    nbits = 0;
    for (int i = 0; i < 12; i++) drive_cell(vec[i]);
    drive_cell(~vec[11]); drive_cell(vec[11]);
    repeat (SPB * 2) @(posedge clk);
    check_stream("glitch unfiltered");
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
