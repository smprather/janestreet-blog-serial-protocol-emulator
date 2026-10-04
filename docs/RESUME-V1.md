# RESUME HERE — v1.0 closeout

**Written 2026-09-29 immediately before a context flush.** Everything needed to
resume is here or in `WORKLOG.md` (which is complete and authoritative). If you
read only one file after the flush, read this one.

## 2026-10-04 update: read this before anything below

- **The live work is a plan with its own progress checkpoint:**
  `docs/superpowers/plans/2026-10-03-host-bridge-review-fixes.md`. Read its
  "Progress checkpoint" table first; it says which tasks are done (with commit
  hashes), which is in flight, and what is left. A pi worker in tmux pane
  `0:5.4` was executing it. Check that pane, `git log` and `git status` before
  redoing anything.
- **REAL CHIP DEFECT FOUND (2026-10-04):** every host IMEM read
  (R2 `READ_IMEM`) returns the PREVIOUS address's word. The cause is
  `rtl/pe_soc.v:391-394`, which captures the registered `imem_rdata` one edge
  early. It was found by the new `+script` replay lane and verified
  independently. **This puts a hole in "Chip side is DONE and GREEN" below:** no
  earlier test read IMEM through the real SoC and memory. The user chose to
  finish the harness work first, with the defect pinned by
  `test_known_defect_*` tests, and to fix the RTL separately. That fix needs a
  stronger agent and the user's sign-off (plan Amendment A2). Open question for
  the user: was the design already submitted to a shuttle?
- **Open user decision:** plan Task 5, the TTAdapter read budget (#1), lands as
  its own revertable commit, flagged.
- **Discipline:** checkpoint progress into these .md files (the plan's table,
  WORKLOG) at every step. Sessions here end on rate limits without warning.

## Start here, in this order

1. `WORKLOG.md` — the full record. The last ~12 entries cover everything below.
2. `docs/design/VVPT-ADAPTER-DESIGN.md` — the design of the v1.0 simulation
   path, written before the code so it survives a lost session.
3. `reviews/2026-09-28/V1.0-GATE.log` — the reference gate verdict.

## Where v1.0 stands

**Chip side is DONE and GREEN.** Full gate at `dca7033`: `TOTAL 50 PASS 50
FAIL 0`, 16/16 mutation suites with no unexplained survivors, formal safety
proofs and formal mutant checks OK, 77 documents / 792 links / 0 dead, 69
diagram checks, document index 54/54.

**Open item 11 (real Pico/USB acceptance run) is the ONLY thing between here and
v1.0, and it is HARDWARE-GATED** — it needs the Tiny Tapeout demo board and a
real RP2040 on USB. Nothing on the design or software side blocks it. Do not
report it as anything else.

**Zero unmerged branches.** All real work is on `main`.

## The single in-flight piece

A simulation path that SHRINKS what item 11 must trust, from the whole stack to
four hardware-only things (USB enumeration, SPI timing/setup, board power and
clock, MicroPython). It does **not** close item 11.

Landed and independently verified:
- `tb/tb_pe_soc_extspi.v` — externally-paced SPI testbench. Re-ran from clean:
  COMPILE OK, vvp exit 0. Its PING frame `a55a1010000700007dfe` **exactly
  matches** `tools/host_bridge/tests/golden_vectors.json` (verified by calling
  the project's own `pe_frame.encode_frame`).
- `tools/host_bridge/vvp_adapter.py` — `VvpTTAdapter`, the 6-method
  `TTAdapter` HAL backed by a vvp process running the real
  `tt_um_protocol_emulator` (where `pe_ctrl`, the SPI slave, lives).
- `tools/host_bridge/tests/test_vvp_integration.py` — the payoff lane.

**Just fixed, at `7de9775`:** two real defects a worker found in the adapter and
reported rather than patched (I gate that file). The testbench path lacked `../`
for the `regress` cwd, and the adapter passed `+read_words=` while the TB reads
`+nresp=`. Both fixed; `_start()` now compiles, where it previously failed with
"No such file or directory". **Re-run the integration lane now that the blocker
is cleared** — that is the first thing to do.

## The lane, when you relaunch it

The fleet was killed mid-bite (all pe scopes gone). Relaunch with
`tools/manager/pe_run.sh <name>` — **no `pi` argument**, or the model stamp is
skipped (a bare `pi` came up with empty panes twice). Names: `protocol-worker`,
`wiki-features`, `diag-proto`.

Only one thing is unfinished: `test_vvp_integration.py` has an uncommitted
post-commit edit in the worktree (18 insertions). It is already in `main` at
`3412e14`; the diff is work-in-progress on top. Check it before overwriting.

## The number that is the deliverable

**How many of the 6 recorded golden frames the real RTL reproduces
byte-exactly, through the real bridge.** It is currently **BLOCKED, not zero** —
the worker refused to report a count because no vector had reached the chip. With
the adapter fixed, run it and report the real number, including which ones do not
match and why. A partial count reported precisely beats a green that hides it.

## Discipline that has repeatedly mattered

- **Verify worker claims independently before merging.** This session's workers
  found a wrong pin map I had written, and two real bugs in my own adapter. Both
  were only caught by re-running the check myself.
- **`git add -A` does not report files it skipped.** `.gitignore`'s `*.log` had
  silently swallowed three v1.0 evidence logs that I had "committed".
- **Anything uncommitted in a `/tmp` worktree is one clear from gone.** Two
  real bodies of work were sitting that way; both are now committed and pushed.
- **A gate that cries wolf gets ignored.** Two workers caught their own
  instruments lying mid-audit.
- **Use `regress/tier.sh <tier>`.** T0 is ~25 s and 14 checks; T2 is 20–30 min
  and for named gates only. Never pipe T2 to `head` — it starts a real gate.
- **Never upgrade a simulation claim to a hardware claim.** This is the failure
  the whole repo is built against, and item 11 depends on it staying honest.

## Resource state

24 cores, 31 GB. Team budget `pe-agents.slice`: MemoryHigh=14G, MemoryMax=20G;
per agent 7G/9G. **RAM is the scarce resource, CPUs are free** (user ruling).
Measured: a full gate peaks at 4.7 G for one agent, so the old 4G high was
*below* the observed peak and throttled every gate for nothing.
