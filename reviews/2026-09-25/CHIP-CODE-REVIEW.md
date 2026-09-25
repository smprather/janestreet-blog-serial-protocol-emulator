# Independent code review — chip 10BASE-T TX + R2 read path (2026-09-25)

**Reviewer:** `gui-worker` (the host-controller session). **Read-only** in the
chip repo — I did not write this code, which is the point: this is a fresh pair
of eyes on the R2/TX work before it is signed off. No chip file was modified.

**Scope reviewed:** `rtl/pe_eth_tx.v`, the `pe_soc` window/owner mux and read
port, the wrapper's G6 (`uo_out[2]`) pad, `pe_cpu` debug registers, and
`pe_ctrl`'s `0x12`–`0x15` read opcodes + wait-word contract. Cross-checked
against `R2-READ-PATH-REVIEW.md` (chip) and this repo's golden package
`reviews/2026-09-25/R2-READ-VERIFICATION.json` + `r2-hex/`.

**Verdict:** the R2 read path is well-built and matches its written contract on
every point I could check statically. One **Important** contract gap (a host↔chip
divergence that the conformance suite cannot see), a couple of **Minor**
hardening items, and no Critical defects. Overall **ready to merge** once the
ceiling gap is acknowledged (it does not affect the 15 shipped vectors).

---

## Strengths (specific)

- **The read dispatch is disciplined about ordering.** Bounds are checked
  *before* any read is issued (`pe_ctrl.v` ~767-795), so a rejected read never
  touches memory, and a rejected read is `RANGE` with the sticky
  `faults <= faults | FAULT_RANGE` set in the same cycle — no read-then-fault
  window. `run` is checked first, so a running core's bounded read is a clean
  `NOT_READY` with no fault (the documented sequencing rejection).
- **Widths are ISA-native everywhere.** `OP_RDCPU` builds
  `{6'b0, dbg_pc}` (pc full 10-bit width), `{8'b0, dbg_a/x/y}` (8-bit) and
  `dbg_insn` (16-bit) — exactly the corrected widths my vectors were flipped
  to. The `A stays 8 bits` decision is honored (the old model bug is not
  reproduced).
- **The wait-word contract is documented in the RTL header, not just the
  review** (lines ~65-75): filler is `0xFFFF`, leading-only skip, a filler can
  never be a header, worst case 15 filler words, and it is transport-level so
  an R1 host sees zero wait words. That is the right place for a contract that
  both sides must honor.
- **DUMP_CORE and STATUS are structurally identical** — they share the same
  11-word header construction (status/state/run/target/pc/a/x/y/timer/faults/
  words_written), so the "dump == status while stopped" golden step is backed
  by construction, not coincidence.
- **Payload length is validated per opcode** (`OP_RDCPU/DUMPCOR` must be 0
  payload words, `OP_RDIMEM/RDMEM` exactly 2, etc.) — a wrong-length request
  is caught before dispatch.
- **R2 found and fixed three real defects** during bring-up (dropped trailing
  dmem byte, never-fired response launch, an X on the MISO pad before the first
  frame). The pad-level X finding in particular is the kind of bug that only a
  real MISO test catches.

---

## Issues

### Important

**1. The 15-word ceiling is enforced by the chip but NOT by the host model, and
no golden vector covers it — a two-sided conformance gap.**
- **File:** `tools/host_gui/fake_pe.py` `_read_imem` / `_read_dmem` (host
  repo) vs `rtl/pe_ctrl.v:240,770,792` (chip).
- **Issue:** the chip rejects `pay1 > MAX_READ_WORDS` (15) for READ_IMEM and
  `pay1 > 2*MAX_READ_WORDS` (30 bytes) for READ_DMEM with `RANGE`. The host
  `FakePE` has no ceiling check: `READ_IMEM(0,20)` returns **OK** with 20 words
  from the model, while the chip returns **RANGE**. Every shipped vector reads
  1-4 data words, so the divergence is invisible to the 15-step conformance
  suite in *both* directions (chip TB and host model agree because no vector
  triggers it).
- **Why it matters:** this is the classic "the tests agree because neither side
  ever went there" failure. A real host that chunks a large read into >15-word
  pieces would see the model OK in `--fake` and `RANGE` on silicon — the exact
  class of fake-vs-real bug this package exists to prevent. It is also the
  documented host obligation ("a count larger than one frame can carry also
  answers RANGE so the host splits"), so the model is the thing that owes the
  ceiling.
- **Fix (host side, my queue):** enforce `count <= 15` (words) / `count <= 30`
  (bytes) as `RANGE` in `FakePE._read_imem`/`_read_dmem`, and add two vectors
  (`read_imem_over_ceiling`, `read_dmem_over_ceiling`) so the gap closes in
  both directions. This does not touch chip code.
- **Severity rationale:** Important, not Critical — it does not affect any
  currently-shipped behavior or the 15 proven vectors, and the chip is the
  stricter side (it already rejects). But it is a real divergence and an
  untested assumption, and the manager explicitly asked for reverse-direction
  checking.

### Minor

**2. `pay1 == 0` (a zero-count read) is RANGE on the chip; the model agrees
only by accident.** The chip treats `count == 0` as `RANGE`
(`pay1 == 16'd0 ||` in both checks). The model returns `OK` with zero words for
`READ_IMEM(0,0)`. This is *not* currently a divergence in the vectors (none use
count 0) but the two implementations reach the same visible answer for
different reasons, and a future reader could "fix" one and break the other.
Recommend pinning it in a vector or a comment. (Same fix batch as #1.)

**3. X-propagation on the MISO pad before the first frame was found and fixed,
but the same class of risk should be re-checked at reset for the *read* path
specifically.** The fix history shows the filler reset was the right call; the
reviewer note is that the read datapath (`r_addr`, `r_left`, `r_half`,
`r_first`) is reset at line ~467 — I confirmed the reset exists and sets the
safe defaults, so this is a "verify at the next regression" item rather than a
defect. No action beyond the existing pad-level TB.

**4. Reset state of `resp_buf` beyond slot 5 is not cleared per frame.**
Slots 0-5 are defaulted in the `S_CRC` dispatch; the read ops write up to
slot 10 (STATUS/DUMP) or the dynamic read slots. Because `resp_len` bounds what
is serialized, stale higher slots are not *sent*, so this is not a correctness
bug — but a shorter response after a longer one could in principle serialize a
stale slot if `resp_len` and the serializer ever disagree. The conformance TB
compares every response byte, which is the right guard; noted for awareness
only.

### Declined to judge (with reasons)

- **TX frame-path deep correctness (pe_eth_tx, window/owner mux, G6 pad).** I
  reviewed the read path because that is where my golden vectors bind, but a
  line-by-line audit of the TX engine is a different review with a different
  oracle (its proof is `tb_pe_eth_tx` + the four TX firmwares, not my package).
  I read enough to confirm the deliverable's shape and found nothing, but I am
  not claiming a TX sign-off here.
- **Physical/timing behavior of the read mux.** The R2 read port arbitrates
  `pe_imem` between the CPU fetch and the host read; that contention is a chip-
  internal timing question, out of scope for a host reviewer and already gated
  by the chip's STA screening.

---

## Reverse-direction check (does any golden vector assume unimplemented
behavior?)

I replayed every shipped vector's request through the contract:

- **All 8 vectors' requests are implemented by the RTL** with the documented
  status: bounded reads OK/NOT_READY, past-the-end RANGE, bad-read
  FAULT_RANGE + sticky, CLEAR_FAULT clears, the 15 steps cover PING-adjacent
  header/status/dump/read/reject/clear. No vector assumes a response word, width,
  or status the chip does not produce.
- **The one assumption gap is the ceiling** (Issue #1) — the vectors stay well
  under it, so nothing assumes the *wrong* behavior, but the ceiling itself is
  an unverified cross-side assumption in both directions.

---

## Test-quality assessment (the 15 conformance steps + mutation gates)

- The suite is **behavioral, not self-confirming**: it loads the real
  `imem.hex`/`dmem.hex`, replays the session's opening 3-word LOAD as a real
  framed frame, and compares **every response byte** against the golden stream
  (skipping only leading wait words). That is the right shape — it would catch a
  word-order, width, CRC, sticky-fault, or wait-word regression, which is exactly
  the set of bugs the R2 work actually made.
- The three real defects it found (dropped dmem byte, never-fired launch, MISO
  X) are each a class the byte-compare catches — evidence the oracle has teeth.
- **The gap is coverage breadth, not oracle strength:** the vectors do not span
  the count ceiling (#1), zero-count (#2), or a mid-range split read. Adding
  those is host-side work and the highest-value next test increment.

---

## Recommendations

1. Fix the ceiling gap on the host side (Issue #1) and add the two over-ceiling
   vectors; this is the one item I'd do before the next hardware run.
2. Add a zero-count vector or an explicit comment (#2) so the two sides share
   one stated reason.
3. At the next chip regression, re-run the pad-level TB to confirm the MISO-reset
   fix (#3) still holds under the reset sequence.

---

## Assessment

**Ready to merge: Yes, with the ceiling gap acknowledged.** The R2 read path is
a careful, well-documented implementation that matches its contract on every
static check I could make, and the conformance suite has real teeth. The single
Important finding is a host-side model gap (not a chip defect) that does not
affect the 15 proven vectors but should be closed before the next hardware run
to keep fake and silicon from diverging on a large read. Nothing I found argues
against landing the R2 work.
