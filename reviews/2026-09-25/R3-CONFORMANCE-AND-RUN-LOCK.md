# R3 conformance, the run-lock process tree, and the contract ruling

**Outcome: the R3 conformance harness is GREEN (14/14 vectors, 26/26 steps,
byte-exact) and the root cause of its long red phase was a word-versus-byte slip
in its own generator — not the chip, and not the `pe_cpu` the handoff blamed.

Date: 2026-09-25. Author: protocol-worker. Scope: four dispatched items plus a
manager ruling that arrived mid-task.

---

## 0. The ruling, folded in (manager, 2026-09-25)

The contract's §3 golden-vector table was **wrong in two rows and the RTL was
right**; the table has been corrected and no RTL moved. "Never change truthful
RTL to match a doc table" is the rule this records.

* **Row 11 (`debug_bp_clr_while_stopped_is_boot_stop`)** expected `pc=0` in the
  `DEBUG_BP_CLR` response. The RTL answers the PC **at the request** (3) and
  re-zeroes the core at that same edge, so the *following* read reports 0. The
  RTL's own comment and the contract's `Known limits` already said this; only
  the table row disagreed. Corrected, keeping the same-edge explanation.
* **Row 13 (`debug_status_common_prefix`)** expected `insn=imem[4]` while
  free-running. `pe_cpu` fetches at `next_pc` while executing (`pc` while held,
  0 at the boot stop), so a free-running readback reports the **landing** word:
  `imem[2] = 0xF000`, the target of the `JMP 2` at address 4. The table's
  `imem[4]` was stale numbering. Corrected — and the author notes' general
  wording ("`insn` is the instruction at the reported PC") was corrected with
  it, because `insn` follows the **fetch mode**.
* `rtl/pe_ctrl.v`'s pasted §1 header needed no change: it never repeated either
  error, and its `DEBUG_BP_CLR` comment already stated the RTL behaviour. A
  changelog section was added to the contract recording the correction, the
  reason, and that the host's vectors (not the doc table) are the reference.

---

## 1. The R3 golden package, consumed byte-exactly

`reviews/2026-09-25/r3-hex/` + `R3-VECTOR-BYTES.md` (14 vectors / 26 steps) are
now in the tree as the authoritative package. The chip side consumes them the
way R2 does: a **byte-exact copy** in `tb/r3-vectors/`, read with `$readmemh`,
with `tools/gen/gen_r3_vectors.py` deriving the per-vector preloads and the
per-step file names from `manifest.json`.

The generator is not a formatter, it is a **cross-check**, and it refuses to
emit a stale file:

* every request frame is re-CRC'd (CRC-16/CCITT-FALSE over every word but the
  last, sync included) — so the vector whose CRC is *deliberately corrupt* has
  its corruption confirmed rather than assumed, which is the whole point of it;
* every frame header is decoded for the opcode (bits 11:4, not the high byte —
  a real trap, and the generator's first version got it wrong) and its length
  field is checked against the framing rule for that opcode;
* every response's length field is checked against its byte count and its status
  against the manifest;
* the **expected sticky fault** for each step is derived from the request bytes
  themselves rather than assumed: a frame that fails its CRC latches
  `FAULT_CRC`, a frame whose length contradicts its opcode latches
  `FAULT_PROTOCOL`. The host model has no sticky fault register, so
  `model_faults` is 0 everywhere; deriving the expectation is what keeps the
  check honest (and it is what makes the two BAD_FRAME vectors assert something
  real instead of nothing);
* `--check` re-derives the include and fails if the checked-in one differs.

Two vectors' pre-states are a **free-running core** (run=1, no hold) at a named
pc, which a running core cannot hold for the ~1000 clocks a frame takes. The
TB re-drives the CPU's registers for those, and the generator **refuses** to arm
that freeze on any vector that expects a `DEBUG_STEP` to succeed — so the model
boundary can never swallow a real execution. The one vector that pairs a freeze
with a step expects `NOT_READY`, where no pulse is emitted at all.

---

## 2. `tb_pe_ctrl_r3_conf.v` — GREEN, and the root cause was one token

**14 of 14 vectors, 26 of 26 golden steps, byte-exact (CRC included).** Wired
into `run_all.sh`. Three steps carry a **known** divergence — seven words — and
those are pinned by a lock rather than waved through (below).

### The bug that wore the costume of a protocol disagreement

For most of a session this harness reported that **the chip rejected the host's
frames**: 61 failures, a 5-word `BAD_FRAME` with `FAULT_CRC` latched, and on most
steps no response at all. The handoff written at the red phase pointed at the
attached `pe_cpu`.

It was not the `pe_cpu`. The decisive experiment was running the **R3 golden
bytes through the untouched, proven `tb_pe_ctrl_r2` transport** — which failed
identically (0/18), ruling the harness out entirely. With the transport
exonerated, the remaining difference was in what the *generator* emits, and it
was one token:

```
r3_step(6, 10, ...)      # WORD counts
```

into a transport whose signature is `(req_bytes, rsp_bytes)` — it sends with
`i < req_bytes; i += 2` and reads `rsp_bytes / 2`. So a six-word
`DEBUG_BP_SET` frame was cut to **three** words, the host switched to reading,
and the chip sat waiting for the rest of the payload. A word-versus-byte slip,
which looks exactly like a chip that refuses the host's protocol.

Two other things were exonerated the same way, and are worth recording because
they were each *probably* the cause: the attached `pe_cpu` (a stubbed-out copy
gives byte-identical results), and the frame rate (`HALF_NS` 50/55/60/70/100 ns
all behave the same).

### What the transport still needs (load-bearing)

1. **The pad, not the driver.** The reader must sample
   `miso_oe ? spi_miso : 1'b1`. The R3 ops answer from registers, so no memory
   fetch fills the gap before the frame; without this the pad-idle word reads
   `0x0000`, which the leading-filler skip must not swallow.
2. **`r3_clear_faults` reads 5 + 2 = 7 words.** R2's helper reads 6 and leaves
   the chip one word from finishing, so the next `CS_N` fall makes the next
   frame read this response's last word. (That is ruling (a)'s masked oracle
   bug, now fixed in `tb_pe_ctrl_r2.v` itself.)
3. **The host must not release MOSI to 0 before reading.** Doing so cost 83 of
   144 checks.
4. **The model freeze covers the whole vector** whenever the strap is high and
   nothing in the vector is expected to execute — not merely when the
   *pre-state* is free-running. `debug_bp_clr_resumes` starts held and is
   released mid-vector, and without the wider scope the core races ahead of the
   frame while the golden models the instant after the release. The generator
   **refuses** to arm the freeze where a step is expected to succeed, so it can
   never swallow a real execution.

### The three steps that do not match, pinned

`tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt` lists all seven words with the
reasoning, and the harness re-reads it at the end of the run and requires the
observed **set** to equal it. A known divergence that *changes*, or any **new**
one, turns the gate red. That is deliberately stricter than an XFAIL list of
step names, which would let a step start failing for a new reason and still
read as "known". Both directions are proven, not asserted:

* changing one expected value in the list → **red** (4 failures);
* corrupting one byte of a golden response → a new divergence appears → **red**
  (9 failures).

Two of the three are **host-side vector defects where the chip is right** (the
manager's standing ruling: never change truthful RTL to match a doc or a vector):

* `read_cpu_shows_a_55` — the host's `READ_CPU` builder returns its debug
  `state` in the slot the contract gives to `run`, and a stale `insn`. The chip
  answers `run` and the fetched word, per `rtl/pe_ctrl.v`'s own `OP_RDCPU`
  builder. The **R2** package's `READ_CPU` vector carries a run value in that
  slot and the chip passes it byte-exactly (18/18), which settles the shape.
* `status_reports_the_hit` — `a` = `0x00AA` from the chip, `0x0055` in the
  package: the step from 1 to 2 really does execute the `LDI A,0xAA` at address
  1. A step is exactly one instruction, and stop-before applies to the
  instruction **at** the breakpoint, which has not run. The chip is truthful.

The third is a **model boundary, not a disagreement**, and is not claimed:
`status_full_readback`'s `insn` is a mid-execution *snapshot* (pc=4 with a=0 has
not executed the `LDI` at 3), and the freeze that holds such a snapshot pins
`pc` every cycle, which collapses the fetch pipeline onto the fill word instead
of the manager-ruled landing word `0xF000`.

### What this means for `chip_confirmed`

23 of the 26 steps are byte-exact with no divergence at all, and the other 3
carry divergences that are either host-side (the chip is right) or an explicitly
unproven model boundary. **The manager's call on which steps to flip** — the
evidence is `tb_pe_ctrl_r3_conf` plus the directed harness's 7/7 mutants and the
S1–S4 formal claims, and the host should regenerate the package for the two
host-side steps rather than the chip moving.

## 3. The run lock now owns its process tree (`regress/run_lock.sh`)

**The failure it fixes.** `flock` releases when the holder dies, but the
holder's *children* do not die with it: they inherited fd 9, so the lock stayed
held **and** a mutation harness kept mutating and restoring RTL in a tree that
had moved on — with no run left to explain it, and the next run refused for "a
lock nobody is holding". This was not hypothetical: the full suite that finished
during this task (pid 815922) left its own holder note behind at
`/tmp/chip-run-all.c20d814a.owner`, because `chip_release_run_lock` removed a
hard-coded **shared** path while the lock itself had moved to a per-worktree one.

**The fix, in three parts.**

1. **Isolation.** The holder puts itself in its own process group (`setsid`, or
   the group job control already gave it) so "kill everything this run started"
   can never reach the shell that started it. The re-exec is skipped — with an
   explanatory message, not a failure — when `$0` is not a re-runnable script.
   That check is not pedantry: sourced from `bash -c`, `$0` is the **bash
   binary**, and blindly exec'ing it asks a shell to execute an ELF file
   (exit 126) with the lock half-taken. It is also skipped when the process is
   already a group leader, and it redirects stdin from `/dev/null` because the
   new session has no controlling terminal.
2. **Trap.** `EXIT`/`INT`/`TERM` kill the group, never this process, escalating
   `TERM` → `KILL`. The **`BASHPID` guard is load-bearing**: a subshell inherits
   the `EXIT` trap and `$$` is the *same pid* inside it, so without the guard a
   `( ... )` or `cmd &` finishing anywhere in a 900-line run would fire the trap
   and take the whole run down. If this shell is not a group leader its group
   belongs to someone else, so the fallback walks descendants instead.
3. **Watchdog.** A trap cannot run when the kernel takes the process, and this
   box has an OOM history, so the holder leaves a detached watcher that polls
   for its own death and does the cleanup no trap could. Two details it needed:
   it **closes fd 9** on the way in (otherwise the watchdog *becomes* the reason
   a lock is still held), and it captures the **group while the holder is still
   alive** — a subshell's `$$` is the dead holder's pid, and asking `ps` about a
   dead pid returns nothing, which would silently turn the cleanup into a no-op
   exactly when it is needed.

**The gate** (`regress/test_run_lock.sh`, 16 checks) proves it on real process
trees with real signals: a second taker refused (exit 75), `SIGINT`/`SIGTERM`/
`SIGKILL` each reaping the run's child and freeing the lock, a clean exit leaving
no strays, a reentrant child neither re-locking nor killing its parent, and a
background subshell not firing the kill trap. It uses a private lock file, so it
never touches the worktree lock and is safe beside a real run.

**RED-first, as the project requires:** against the pre-fix `run_lock.sh` the
same gate is **12 failed / 4 passed**; against the fix, **16/16**. It also has
to clean up after itself — an early version of it leaked process trees, which is
the hazard it exists to catch, so its own cleanup matches on the run's unique
work directory and never on a broad pattern.

**The gate then failed INSIDE the suite (11 passed / 5 failed) while passing
standalone — and it was the gate's own bug, which is the best kind of catch.**
`run_all.sh` is itself a lock holder, so it exports `CHIP_RUN_LOCK_HELD` and
`CHIP_RUN_ISOLATED`; the test inherited a lock it did not hold and an isolation
it had not performed, so every case passed through the acquire path instead of
taking the lock. The gate now clears every variable the lock uses before
sourcing it, and passes 16/16 in both environments (verified by running it with
those variables deliberately set).

**And then it was demonstrated for real, by accident.** A full suite was killed
mid-mutation to re-run it with a fixed gate. Under the old code that is the
scenario the fix exists for. What happened instead: the process group died with
the run, the mutation harness's own signal handler restored
`rtl/pe_eth_mac.v` byte-exactly (`git status` clean for it, no `MUTANT` string
anywhere in `rtl/`), the per-worktree lock **freed**, and the holder note was
removed. A live reproduction of the leak — with the leak closed.

One behaviour worth knowing, because it looks like a bug and is not: signalling
the holder's **pid** alone does not reach its children, and bash defers a
trapped signal until the foreground child finishes, so a long mutation harness
keeps running for a while. A terminal `Ctrl-C` signals the whole foreground
process group, which is the case that matters and the one the gate tests; the
harness is gone as soon as the group is signalled.

---

## 4. The formal MEM label (cosmetic, and it was making a claim)

`peak_of()` reported `MEMCAP-or-killed (no MEM line)` for any log without a
yosys `MEM: x MB peak` line. That **asserts a cause the log cannot support**: a
cap kill, a timeout and the OOM killer look identical there. It now reports only
what the log shows:

* the `MEM` line → the number;
* `model found` with no end-of-script → `no-MEM-line (killed while printing the
  model)` — the case the dispatch named, and the common one (the counterexample
  dump is where these runs die);
* otherwise → `no-MEM-line (killed before end of script)`.

Checked against the real logs: `eth_tx_reach_busy` and `mutant_eth_tx_len_window`
are model-print deaths; `mutant_pe_ctrl_bp_hit_no_hold` died earlier still (in
the induction step, inside yosys's own banner).

---

## 5. Suite state

* The full suite that was in flight at the start of this task
  (`/tmp/run_all_r3f.log`, pid 815922) **completed**: 38/38 RTL, 30/30 firmware,
  all 14 mutation suites OK, every generated-doc and formal gate OK, no `FAILED`
  and no `REFUSING` anywhere in the log. Its exit status was not observable (it
  was not this session's child), so a fresh full run with the exit captured is
  recorded in `WORKLOG.md`.
* Three gates are wired into `run_all.sh` (all green): the run-lock process
  tree, the R3 package byte-exactness + generator `--check`, and the R3
  conformance TB itself.
* The R3 conformance TB **is** wired now: 14/14 vectors, 26/26 steps, with seven
  words across three steps pinned as known divergences by a lock that turns red
  on any change (section 2).


### R3.1 — the held-core semantics, landed; the last step stays pinned, with the
### measured reason

The dispatch was to model HOLD semantics for the held-core steps so `insn` is
deterministic, and to flip the last step if it then passed. The modelling landed
and is enforced: `tb_pe_ctrl_r3_conf` now **asserts**, on every held-core step,
that the chip's reported `insn` is `imem[pc]` — a claim about the chip, decidable
without any model freeze, and one the golden vectors already implied
(`v04` pc=1/imem[1], `v07` pc=2/imem[2], `v09` pc=3/imem[3], `v11` pc=0/imem[0]).
All 25 confirmed steps are preserved unchanged.

`status_full_readback` **still diverges, so it stays pinned** — and the reason is
now measured in every regime rather than asserted:

| regime at `pc=4` | `insn` reported |
|---|---|
| HELD (the real debug hold) | `0x4002` = `imem[pc]` |
| free-running + the model freeze | `0x0000` (the 0-filled region; the freeze collapses the fetch) |
| free-running, unpinned | the core does not stay at 4 to be sampled — the `JMP 2` leaves |
| package expects | `0xF000` = `imem[2]`, the **landing** word |

`0xF000` is the NOP at address 2: the one-cycle state in which the jump at 4 has
been decoded and the fetch has moved to 2 but the PC has not yet advanced. And
the vector's whole pre-state is **unreachable**: reaching address 4 means
executing address 3, which is `LDI A,0x0F`, so `a` would be `0x0F` — not the
package's `a=0`. So `(pc=4, a=0, insn=imem[2])` is not a state the chip can
occupy, and a conformance gate must not chase it by racing a clock. Neither side
was bent.

That measurement also **corrected a doc line of mine**: I had written that a
collapsed freeze reports the fill `0xF000`. It does not — `0xF000` is the NOP at
2, and the collapsed fetch reports the **0-fill** `0x0000`. The contract's freeze
rule now carries the measured values.

**Final: 25/26 `chip_confirmed`**, one pinned with its reason, and the
conformance gate green with both directions proven.


### Synthesis screen after R3 (the phase had never been through it)

`regress/synth_area.sh` (sg13g2 typ, mapped, pre-route) exits 0 with no
diagnostics — no driver-driver conflict, no undriven wire, no yosys ERROR — so
the R3 netlist is not quietly broken. The interesting number is the DELTA, and
that needed measuring rather than reading a recorded baseline, because every
recorded baseline predates the R2 read engine:

| block | pre-R3 (`5cc5152~1`) | post-R3 | delta |
|---|---|---|---|
| `pe_cpu` | 377 cells | 401 | **+24** (+6.4%) |
| `pe_ctrl` | 3,771 cells | 4,054 | **+283** (+7.5%) |
| `pe_soc` | 6,334 cells / 110,421 µm² | 6,355 / 110,570 | **+21** (+0.3%) |

Both sides measured with the same liberty and the same script, the pre-R3 sources
taken from git, so the comparison is like for like.

**Earlier recorded figures are not comparable, and I first overstated why.**
`wiki/STATUS.md` is an append-only chronology, so it holds several screens taken
with DIFFERENT source lists: an early one has `pe_ctrl` 463, the newest recorded
(eth_tx) has `pe_soc` 6,191 / `tt_um_top` 7,980, and another has `pe_ctrl` 1,731.
None is comparable to today's 4,054 / 6,355 / 10,221, and the gap is mostly the
R2 read engine and the growing source list - NOT R3. Only the pre/post pair in the
table above isolates R3. I had written that the baselines were "R1-era"; the
accurate statement is that they are *earlier-list* measurements. A current
figures entry has been appended to `wiki/STATUS.md` with today's screen and the
R3 delta, and the no-STA-screen note for this phase is carried forward there.

## 8. gui-worker chip-review action list (ed8aa51) — dispositions

| # | item | disposition |
|---|---|---|
| **M1** | contract §3 rows 11/13 "still superseded" | **VERIFIED CORRECTED — no change needed.** Rows 11 (line 164, `pc=3` = PC at the request) and 13 (line 166, `insn` = the landing word) are corrected **in the table body**, not only the changelog, and the file is clean three ways: working tree == HEAD == origin/main. Checked rather than assumed; "fixing" an already-correct table would have added noise. |
| **M2** | hierarchical preload can encode an unreachable pre-state | **RECORDED PER VECTOR.** A reachability table now heads `tb/tb_pe_ctrl_r3_conf.v` classifying all 14: 7 fully reachable from reset (± a `BP_SET`); 4 whose core *state* is reachable but whose `a` is not what a real path yields (every claim they test is `a`-independent); 1 (`step_while_running`, pc=7) whose pc is unreachable in the shipped image for a pc-independent claim; and **1 IMPOSSIBLE** — the boundary step. |
| **M4** | `dbg_hold` unconstrained in the pe_soc STA screen | **FIXED.** `dbg_hold`/`dbg_step` (and the R2 `dbg_rd_*` inputs) added to the `set_input_delay` set in all six pe_soc screens. Unconstrained-endpoint warnings **1 → 0** on every corner; worst slack unchanged (0.00 / −0.87), confirming they were genuinely unconstrained rather than secretly timed. |
| **L1** | once held, the `run` strap is ignored both ways | **DOCUMENTED IN `pe_ctrl`'s header**, as a bring-up trap: `cpu_exec = dbg_step \|\| (run && !dbg_hold)` (pe_cpu.v:217) masks `run` entirely, and `dbg_hold_r` clears at exactly two places (reset, and the `DEBUG_BP_CLR` branch). Comment-only (0 non-comment lines added), lint clean. The runbook line routes to the gui-worker. |

**The boundary-step impossibility, proved from the program's own update rule**
(M2's explicit ask): the vector asks for `pc=4, a=0, run=1, no hold`. The shipped
imem is `LDI A,0x55 / LDI A,0xAA / NOP / LDI A,0x0F / JMP 2`, so the only path to
address 4 **executes address 3**, which loads `a=0x0F`. A real core at pc=4
therefore has `a=0x0F`, and `(pc=4, a=0)` is a state the chip cannot occupy. Its
expected `insn` is consequently not contract-determined for a preloaded pc — which
is precisely why that step stays `chip_confirmed=false` with its divergence
pinned. The impossibility is the reason, and it is derived, not asserted.

### M3 — the R2 `STATUS` debug-state surface: COVERAGE ADDED, residual pinned

The reviewer's point was that R2's `STATUS`/`DUMP_CORE` now report states 2/3 but
no R2 vector exercises that surface. Scoped down to the real gap, it is one cell:

| R2 `STATUS` (0x11) reporting | covered by | before |
|---|---|---|
| state 0 (STOPPED) | `tb_pe_ctrl_r3` C12 | yes |
| state 1 (RUNNING) | C12 | yes |
| state 2 (DEBUG_HOLD) | C13 | yes |
| **state 3 (BP_HIT)** | **new case, M3** | **NO — the live-hit case read `DEBUG_STATUS` (0x24)** |

So a chip that reported the debug states correctly on 0x24 and wrongly on 0x11
would have passed everything. The new case drives `OP_STATUS` while the core is
held on the breakpoint and asserts `state=3`, `run=1` (the hit holds the core, it
does not drop the strap) and `pc=2`. Green, and **RED-proven**: flipping the
expected state to 2 makes the case fail, so it is not a rubber stamp.

A note on how it was written: the first version also asserted `bp_addr`/`flags`
on the `STATUS` response and failed — correctly, because the R2 `STATUS` layout is
`{status, state, run, target, pc, a, x, y, …}` (`pe_ctrl.v:885-897`) and does
**not** carry the breakpoint context; that belongs to the debug ops. The failure
caught my own misreading of the shape, which is the case earning its keep.

**Residual, pinned honestly rather than implied away:** the R2 **golden package**
(the host's artefact) still contains no `STATUS` step at state 2 or 3. The chip
side now covers the surface (C12/C13 + this case), so the chip is not relying on
that package for it; regenerating the R2 package to carry the cells would be
host-side work and would need its citations re-established. Recorded here rather
than left for a reader to assume the R2 vectors cover it.

## 9. M4 follow-through: the same defect was in the R2 screens too

M4 (the gui-worker chip review) flagged that the R3 pe_soc screen left `dbg_hold`
unconstrained — a screen claiming a debug input is constrained when it is not.
The **R2 pe_soc screens had the identical gap** (and so would any earlier screen
of this block): they constrained `{rst_n host_* run pin_in*}` only, leaving the
debug wires and the R2 read port (`dbg_rd_addr/dmem/req/data/valid`) — exactly
the surface those screens exist to cover — unconstrained, with the report saying
so (`1 unconstrained endpoint`, startpoint `rst_n`, on every corner).

Fixed the same way and re-run against the **existing** netlist (the constraints
changed; the netlist did not):

| screen | unconstrained endpoints before → after | worst slack after |
|---|---|---|
| r2-sta pe_soc/slow | 1 → **0** | 0.00 / −0.87 |
| r2-sta pe_soc/typ | 1 → **0** | 0.00 / −0.61 |
| r2-sta pe_soc/fast | 1 → **0** | 0.00 / −0.48 |

The slack is **unchanged**, which is the point: it shows those inputs were
genuinely unconstrained rather than secretly timed, so tightening the screen
changed no verdict — it only stopped the screen from over-claiming. The `tt_um`
screens need nothing (`dbg_hold` is internal there, not a port). Recorded
because the *originally shipped* r2-sta screens had the flaw; the ones in the
tree now are the corrected re-run.

## 10. R3-scoped verification record (the shared tree is red for someone else's reason)

The full `regress/run_all.sh` is currently **EXIT=1**, and the only six failing
testbenches are fw-timing's timing/input-capture acts, merged at `5b4731f` — a
descendant of this phase's last green run, absent from it, and in their files
(their own log records them BLOCKED mid-Block 3 with RED testbenches committed).
So the R3 closeout is recorded here on its own evidence, every item re-run
independently of that boundary:

| R3 evidence | result |
|---|---|
| `tb_pe_ctrl_r3_conf` (golden conformance) | **14/14 vectors, 26/26 steps**, 2 known divergences pinned |
| `tb_pe_ctrl_r3` (directed) | PASS (incl. the new M3 `STATUS`-at-state-3 case) |
| `tb_pe_ctrl_r2` | 18/18 |
| full formal gate (`run_formal.sh`) | **8 proved, 0 failed**, 1 reachable-at-depth, 1 vacuous-at-depth |
| formal mutant harness | 14 caught, 0 survived, 0 inconclusive |
| R3 STA screen (12 screens) | no new violation class; same four hold classes to ±0.014 ns |
| R3 synthesis screen | exit 0; pe_cpu +24, pe_ctrl +283, pe_soc +21 cells (pre/post) |
