# Merge forensics: why the six timing acts went red at `5b4731f`

Date: 2026-09-25. Author: protocol-worker. Scope: the audit the manager asked
for — which of the `5b4731f` union resolutions could have broken the six acts'
dependency chain (peasm.py hunks, run_all/run_firmware_tests wiring, firmware
hex regen order), and the precise mechanism, so fw-timing's repair is exact and
the record is honest.

**The repair is fw-timing's, and their worktree is the ground truth. This
document does not duplicate it — it establishes the mechanism and the evidence,
including two candidate causes I ruled out by measurement rather than by
argument.** Short answer: the merge resolutions were all *sound*; the six acts went
red because a real RTL-interface change crossed a branch boundary, and the merge
is merely where the two states met.

---

## 1. What the manager suspected, and what the evidence says

| hypothesis | verdict | evidence |
|---|---|---|
| a `peasm.py` union hunk broke the acts | **RULED OUT** | the merged `tools/fw/peasm.py` is **byte-identical to fw-timing's side** (`5b4731f` vs `301ccc3`: no diff) and differs from main by +207 lines — it came in clean from their side, it was never union-resolved |
| the hex regen order is stale | **RULED OUT** | re-assembled all six `.pe` with the merged assembler: **6/6 `.hex` match a fresh assemble byte-for-byte** (`ws2812, servo_sweep, dht11_read, ds18b20, nec_ir, stepper_ramp`). No stale image. |
| the `run_all.sh` union dropped the acts' wiring | **RULED OUT** | the merge touched exactly **four** files by union (WORKLOG, demo-walkthrough, run_all.sh, STATUS); the `run_all.sh` delta vs fw's side is **purely additive** (my R3 TB entries + the run-lock and R3-package gates). The six acts' `CASES` entries (lines 150-197) are intact. |
| a merge-RESOLUTION defect | **NO** | every resolution is sound; see above. The breakage is a real RTL-interface change crossing the branch boundary. |

## 2. The actual mechanism

R3 (landed on main at `5cc5152`, after the branch point `dcdf63d`) added **two
module inputs, `dbg_hold` and `dbg_step`, to `pe_cpu`** (routed out of `pe_soc`,
which is why `rtl/pe_soc.v` lists them as inputs). The fw-timing branch was based
on `dcdf63d` and had **never seen** those ports — its `pe_cpu`/`pe_soc` have zero
`dbg_hold` references, and neither do the six acts' testbenches.

A testbench that predates a new module input leaves the port **unconnected** →
it arrives as **Z**. `pe_cpu`'s execute gate was
`cpu_exec = dbg_step || (run && !dbg_hold)`; with `dbg_hold = Z`, `!dbg_hold` is
**X**, so `cpu_exec` is X, the core **never executes one instruction**, and the
whole system sits at reset values: every `dmem` read is `x`, the pin never
moves, zero edges are counted, and the watchdog fires. That is exactly the
observed signature (`dmem = xx`, `0 rising edges`, `position index = x`, "the
firmware never drove bit 6") — and it appears in **six unrelated firmware
programs at once**, which is precisely what made it read as a merge/assembler
problem rather than one new port.

**So the merge is the TRIGGER, not the cause.** The trigger is the merge (it is
where main's R3 ports and fw's pre-R3 testbenches first coexist); the cause is
the new unconnected interface. fw-timing's own `3657847` names it: *"fix(R3
fallout): a debug input with no driver held the core at reset — the six timing
acts could not run."*

## 3. The exact repair (fw-timing's `3657847`, ground truth — not duplicated here)

Their fix is **two-layered, and both layers are load-bearing**:

1. **RTL, at the point of consumption** (`rtl/pe_cpu.v`):
   `wire cpu_exec = (dbg_step === 1'b1) || (run && !(dbg_hold === 1'b1));`
   Case equality, so anything that is not a **hard 1** reads as "not held" / "no
   step" — an undriven debug interface is inactive by default. Identical in
   synthesis (x/z do not exist in hardware), so the netlist is unchanged; the
   convention is enforced where the input is consumed, which is the one place a
   new call site cannot forget it.
2. **Each act TB, explicitly** (`.dbg_hold(1'b0), .dbg_step(1'b0)` on the
   `pe_soc` instance), so the act does not **depend** on layer 1 and the two
   repairs cannot mask each other.

One forensic note in their favour: I tried **layer 2 alone** (tied
`.dbg_hold(1'b0), .dbg_step(1'b0)` in a scratch copy of the servo act) and it
**did not** turn the act green in this tree. So a bare testbench tie-off is not
independently sufficient here; the two-layer repair is the exact one, and it is
theirs to land.

## 4. Why this was not caught before the merge (the process gap)

The R3 block's own review recorded the identical failure mode when it landed —
"unconnected debug inputs float to X … the full suite caught it immediately
(`tb_pe_soc_tick`'s first three failures). All 13 TBs now tie the debug inputs
low" — and the 13 **pre-existing** testbenches were fixed. What no gate could
catch is a **new module port** breaking testbenches that live on **another
branch**, because until the merge those two states never coexist. That is the
process gap this exposed, and the fix is `regress/verify_merge.sh`: given a merge
commit, run the TB set affected by the merge diff and fail loudly, so a merge can
never be pushed red again. (See §"merge gate" in that script and in
`docs/demo-walkthrough.md`.)

---

## 5. WRAP STATE (2026-09-25, hard wrap at 85.9%) — what is DONE and what remains

### DONE — forensics conclusion (evidence in §1-§3 above)

* The `5b4731f` union resolutions were **sound**: `peasm.py` came in clean from
  fw's side (byte-identical to `301ccc3`); the `run_all.sh` union was purely
  additive (my R3 entries); the six `.hex` all match a fresh assemble (6/6).
* **Mechanism**: R3 (`5cc5152`, after the branch point `dcdf63d`) added two
  module inputs, `dbg_hold`/`dbg_step`, to `pe_cpu` (routed out of `pe_soc`).
  The fw branch never saw them and its six act testbenches leave them
  unconnected -> Z -> `!dbg_hold` is X -> `cpu_exec` is X -> the core never
  executes -> `dmem = xx`, zero edges, watchdog, in six unrelated programs at
  once. The merge is the TRIGGER (where the two states met), not the cause.
* **Repair is fw-timing's `3657847`** ("fix(R3 fallout): a debug input with no
  driver held the core at reset"), two-layered: case-equality consumption in
  `pe_cpu.v` AND an explicit tie-off in each act TB so neither repair masks the
  other. NOT duplicated here, per the dispatch.
* Honest negative result: a bare TB tie-off (layer 2 alone) did **not** turn the
  servo act green in this tree, which supports their two-layer conclusion.

### DONE — merge gate, part 1: the opt-in case filter in `regress/run_all.sh`

`--cases REGEX` (also `--cases=REGEX`), **off by default** so the ordinary full
gate is unchanged. When used it prints selected/skipped counts and refuses to
run a filter that matches nothing.

*Functionally tested*: `--cases 'tb_pe_ctrl_r3$|tb_pe_cpu$'` selected exactly 2
of 47 (45 skipped); a non-matching filter printed
`(--cases zzz_no_such_case: 0 selected, 45 skipped)` +
`matched NO case`.

### REMAINS — for the post-`/new` session

1. **`regress/verify_merge.sh` is NOT yet written.** Design settled: given a merge
   commit (or HEAD, or a range), compute the changed set via
   `git diff --name-only <merge>^1..<merge>`, map changed files to affected cases
   by parsing run_all.sh's own `CASES` array (each entry is
   `name|<rtl list>|top`, so `../rtl/pe_cpu.v` -> `rtl/pe_cpu.v` selects every
   case listing that file — which is exactly what would have caught the six acts,
   since their cases list `pe_cpu.v`/`pe_soc.v`); add any case whose own
   `tb/<name>.v` changed; treat `firmware/*` or `tools/fw/peasm.py` changes as
   selecting every CPU/firmware-driven case; **fall back to the FULL suite**
   whenever a "global" file changes (`regress/`, `tools/`, `flow/`, `formal/`,
   the pre-commit hook) or the mapping is empty/ambiguous; then drive
   `run_all.sh --cases ...` (or the full suite) and **fail loudly**.
2. **Demonstrate the gate on `5b4731f`**: it must select the six acts and go RED.
   That is the proof the gate catches the class that actually bit us.
3. **Demonstrate it benign**: a merge touching only non-RTL files must select a
   small set (or fall back), and go GREEN.
4. Verify the `matched NO case` path returns **non-zero** through the pipe (my
   in-test `$?` read `tail`'s status, so the real exit code is still unverified).
5. Wire the gate into the docs as the manager process (COLD-START.md checkpoint
   and/or `docs/demo-walkthrough.md`), then commit + push.
