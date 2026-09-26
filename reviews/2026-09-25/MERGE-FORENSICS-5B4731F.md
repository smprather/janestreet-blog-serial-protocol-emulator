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

---

## 6. CLOSED (2026-09-25, post-`/new` session) — the gate exists and is demonstrated

`regress/verify_merge.sh` is written, self-tested (18 checks) and demonstrated
RED and GREEN. Everything the list above asked for is done; the four items below
are what changed my mind while doing it, and each was found by the work itself.

### 6.1 The three demonstrations

| demo | how | result |
| --- | --- | --- |
| **RED on the real merge** | a scratch worktree at `5b4731f` with the gate copied in; the only difference from that commit is the gate plus `run_all.sh`'s `--cases` filter (`git diff 5b4731f HEAD -- regress/` is exactly those 22 lines) | `TOTAL: 45  PASS: 39  FAIL: 6` → **MERGE GATE: RED**, naming all six: `tb_pe_soc_ws2812 tb_pe_soc_servo tb_pe_soc_dht11 tb_pe_soc_ds18b20 tb_pe_soc_ir_nec tb_pe_soc_stepper_ramp`, with the documented signature (`dmem[14] = xx`). ~4.5 min. |
| **GREEN on a benign merge** | a scratch worktree at `6da4100` (the last green main) plus a branch that adds a **comment** to `rtl/pe_codec_mux.v` and one line to `docs/demo-walkthrough.md`, merged `--no-ff` | **14 of 39 cases selected**, no escalation, `MERGE GATE: GREEN`. The doc churn is treated as inert and does NOT widen the run — the point of the record/inert split. |
| **no-match exit code** | `./regress/run_all.sh --cases zzz_no_such_case \| tail -2` | **exit 2**, read with `${PIPESTATUS[0]}` — `$?` would have read `tail`'s 0. The wrap-state note that this was unverified is now settled. |

The RED run also produced two unplanned demonstrations, both of them real gate
behaviour rather than staged results: an **exit 137** (OOM-killed mid-loop) that
the first version of the gate reported as *"RED, the affected set failed"* with
an **empty** failure list, and a **GATE ERROR** when `run_all.sh` rejected a
filter the gate itself had built. Both are now their own outcomes.

### 6.2 FINDING: a non-zero exit with nothing named is NOT a red — it is INCONCLUSIVE

The first RED demonstration died at exit 137 and my gate printed `RED … Failing
testbenches:` followed by nothing. The suite had not said one testbench failed;
it had not finished. A gate that prints RED there is making a claim its log does
not support, in the exact shape that lets a red merge through. So the gate now
exits **4 = INCONCLUSIVE** when `run_all.sh` fails with no named failing case,
prints the causes in the order they have actually happened here (137/143 killed,
75 the single-run lock, FATAL a missing SRAM model), and says explicitly that
nothing here says the RTL is broken. Named-failure RED stays exit 1.

### 6.3 FINDING: the gate and `run_all.sh --cases` disagreed, and the disagreement was invisible

The GREEN demonstration selected 20 cases and `run_all.sh` reported
`0 selected … matched NO case`. The reason: `run_all.sh` matched with
`printf '%s\n' "$_n $_t" | grep -qE "$FILTER"` — **one** line, `"name top"` — so
the anchored regex the gate builds (`^(a|b|c)$`) could never match it. An
unanchored filter like `tb_pe_ctrl_r3$|tb_pe_cpu$` (which is what the wrap-state
test used) matched by luck, which is why the defect survived part 1.

Fixed on the filter's side (name and top are now matched as separate lines) and
**pinned on the gate's side**: `--self-test` now builds a regex the way the
driver does and matches it the way `run_all.sh` does, and requires the same
count. The bug was not in a rule but in the hand-off between two files, and a
hand-off needs a test like any other contract.

Also fixed, from the same demonstration: the mapper was being called as
`printf … | map_changed`, and a function on the right of a pipe runs in a
**subshell** — so every value it set was discarded and the gate selected nothing
while printing an empty mapping. Called with a here-string now, and the
self-test's own counter is guarded for the same reason (it counts the rules it
actually exercised, and fails if that is not the number it claims).

### 6.4 What the gate does NOT narrow, stated so nobody is surprised

`run_all.sh`'s firmware, param-guard, lint, doc, formal and **mutation** gates
are unconditional, so even a one-case merge pays for all of them; what the
mapping narrows is the RTL simulation loop, which is where the six acts failed.
Mapping each mutation suite onto the RTL it mutates is the obvious next
improvement and is **not** done here. Reported rather than assumed: the gate's
value is that it is automatic, prints the affected set with reasons, and cannot
be forgotten — not that it is fast.

`regress/verify_merge.sh --self-test` → 18/18. The mapper also flags
`tb/tb_pe_soc_freqmeter.v` as **not in `run_all.sh`'s `CASES`** — a real
same-list violation in the shared tree, found by the gate's own coverage rule.
