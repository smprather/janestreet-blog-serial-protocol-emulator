# 10BASE-T line driver — evidence record (2026-09-26)

**Author:** a Claude Code session, at the user's request (not the Pi worker
and not the manager). **Branch:** `eth-tx-line-driver`, worktree
`/home/mylesp/worktrees/eth-tx-line-driver`, based on `main` at `4560432`.
**State:** committed on the branch, NOT MERGED. The design and the decisions are in
[`wiki/plans/eth-tx-line-driver.md`](../../wiki/plans/eth-tx-line-driver.md);
this file is the command-level evidence behind it.

**Why a separate worktree:** the shared `main` checkout had a live Pi
protocol-worker in it (dep_guard work). Nothing was edited there; the only
shared state touched was `.git` (this worktree plus a throwaway detached
checkout of `4560432` for the area baseline, created and removed) and the
global run lock, taken normally by every mutation-capable run below.

---

## 1. What changed

```
 info.yaml                              |  10 +-
 regress/mutate_eth_tx_loop_tb.sh       |  43 ++++
 regress/mutate_eth_tx_tb.sh            | 119 +++++++++
 regress/param_guards.sh                |  57 ++++
 rtl/pe_eth_tx.v                        | 101 +++++++-
 rtl/pe_soc.v                           |  21 +-
 rtl/tt_um_protocol_emulator.v          |  33 ++-
 tb/tb_pe_eth_tx.v                      | 458 ++++++++++++++++++++++++++++++++-
 tb/tb_pe_soc_eth_loop.v                |  20 +-
 tb/tb_pe_soc_eth_tx.v                  | 107 +++++++-
 tb/tb_tt_um_protocol_emulator.v        |  54 +++-
 tools/gen/pin_budget.py                |  50 ++--
 tools/gen/signal_glossary.py           |  12 +
 wiki/ (7 pages edited, 1 new plan)     |
 new: wiki/plans/eth-tx-line-driver.md, docs/feature-ideas.md, this file
```

- `rtl/pe_eth_tx.v` — parameter `NLP_CELLS` (default 160,000, guard `>= 2`),
  local `TPIDL_CELLS = 3`, output `line_drive` (a register), the link-pulse
  counter, the TP_IDL countdown, and the header section THE LINE DRIVER.
- `rtl/pe_soc.v` — outputs `eth_tx_n = eng_tx_wire ^ eth_line_drive` and
  `eth_tx_n_en = tx_path && eng_ov_en[7] && pin_oe[7]`.
- `rtl/tt_um_protocol_emulator.v` — `uo_out[3] = eth_tx_n_en ? eth_tx_n :
  dbg_pc[1]`, `uo_out[7:4] = dbg_pc[5:2]`, and the pin-map comments.
- `info.yaml` — `uo[2]`/`uo[3]` descriptions and the board-hardware note.

## 2. Test-first sequence

| Step | Command (from the worktree) | Result |
|---|---|---|
| Baseline, unmodified | 4 Ethernet TBs via `regress/run_one_tb.sh` | 4/4 PASS |
| Interface stubs (ports tied off) | same 4 TBs | 4/4 PASS — the stubs change no behaviour |
| RED, unit | `tb_pe_eth_tx` against the stub | **15,325 failures**: 15,281 "a frame bit went out with the pair undriven", TP_IDL missing after every frame/abort/underrun, no link pulses (period, first pulse, width, 16 ms constant all fail) |
| RED, SoC | `tb_pe_soc_eth_tx` against the SoC stub | **6 failures**: owner flag, frame complement, 3 TP_IDL cells, no pulse at the pads |
| RED, pad | `tb_tt_um_protocol_emulator` against the wrapper stub | `uo_out[3] is not eth_tx_n while the Ethernet line owns the pair` |
| GREEN, unit | `tb_pe_eth_tx` | PASS (4-5 s): `nlp: first pulse after 50 boundaries, period 50 cells, width 6 clocks`; `nlp constant: first pulse 160000 boundaries (16.000 ms) after enable, width 6 clocks` |
| GREEN, SoC | `tb_pe_soc_eth_tx` | PASS (18 s): `link pulse at the pads: 6 clocks wide, 16.000 ms after the engine went idle` |
| GREEN, pad | `tb_tt_um_protocol_emulator` | PASS (10 s) |
| GREEN, loop | `tb_pe_soc_eth_loop` | PASS: `owner: ... serdes_on_pin7=119 clk` (the owner check is non-vacuous) |

"a start beats a due pulse" (case 13b) passed against the stub, because a
design with no pulses trivially satisfies it. Its value is proven by the
`start-loses-to-nlp` mutant (section 4), not by the RED run.

### Found and fixed during the work (honest ledger)

- **A testbench timing bug (mine), in case 7b.** It read `ncells` in the same
  clock the monitor classified the aborted frame's last bit cell, so the
  decode began one cell early and reported "idle cell inside the frame at
  bit 1" on the correct RTL. Fixed by letting the classification land (3
  clocks, still inside the 18-clock TP_IDL, and the case checks that
  TP_IDL is still running so it cannot go vacuous).
- **Two redundant RTL statements, removed rather than kept untestable.** A
  mutation review showed `if (state != S_IDLE) nlp_cnt <= '0;` and the abort
  branch's `line_drive <= 1'b1;` could be deleted with no observable effect
  (equivalent mutants). Both were removed. Two defensive resets in the
  `!enable` branch (`tpidl_left`, `nlp_cell`) are equally invisible; they are
  KEPT for state hygiene and are stated here as not mutation-tested.
- **Two new cases added because the change created claims nothing reached:**
  7b (a restart inside an abort's TP_IDL must cancel the countdown) and 8b
  (the bare-preamble underrun path, which no existing case drove).
- **A vacuity guard in the loop TB:** the new `eth_tx_n_en` check counts the
  clocks where the SERDES really drives pin 7 with `tx_path` low (119) and
  fails if that count is zero.

## 3. Mutation suites (run under the global run lock)

`bash regress/mutate_eth_tx_tb.sh` — exit 0, 190 s:

```
  [nlp-never] detected                    [tpidl-omitted] detected
  [nlp-period-short] detected             [tpidl-short] detected
  [nlp-count-not-reset] detected          [tpidl-not-on-abort] detected
  [nlp-not-ended] detected                [tpidl-not-on-underrun] detected
  [nlp-period-not-restarted] detected     [tpidl-not-on-preamble-underrun] detected
  [start-loses-to-nlp] detected           [pair-kept-on-disable] detected
  [start-not-cancel-tpidl] detected       [period-kept-on-disable] detected
                                          [nlp-negative] detected
=== 33 detected, 0 survived, 0 harness errors ===   (18 existing + 15 new)
```

`bash regress/mutate_eth_tx_loop_tb.sh` — exit 0, 371 s:

```
  [pair-leg-not-inverted] detected (by tt)
  [pair-drive-inverted] detected (by tt)
  [pair-owner-ignores-tx-path] detected (by loop)
  [pair-pad-not-mapped] detected (by tt)
  [pair-pad-always-eth] detected (by tt)
=== 13 detected, 0 survived, 0 harness errors ===   (8 existing + 5 new)
```

## 4. Static and structural gates

| Gate | Result |
|---|---|
| `bash regress/param_guards.sh` | 11/11 (new: `NLP_CELLS=1` rejected, `2` and `160000` accepted) |
| `bash regress/lint.sh` | lint clean — Verilator `-Wall` on 10 tops, yosys elaboration on 13 |
| `python3 tools/gen/signal_glossary.py --check` | fresh after regeneration (3 new port notes) |
| `python3 tools/gen/pin_budget.py --check` | fresh after regeneration (10BASE-T = 3 wires; 23 = 11/5/7) |
| `bash regress/check_wiki_pages.sh` | 64 pages, 0 violations |
| `bash regress/check_wiki_links.sh` | 74 documents, 737 links, 0 dead |

## 5. Formal (existing targets, re-run on the branch)

Invoked exactly as `formal/run_formal.sh` does, through `formal/fv_run.sh`,
with logs outside the tree so the tracked `formal/results/summary.txt` is
untouched:

| Target | Branch | `main` summary |
|---|---|---|
| `eth_tx_safety` (bmc 16) | PROVED, 101.87 MB | PROVED, 101.77 MB |
| `eth_tx_reach_busy` (bmc 16, reach) | COUNTEREXAMPLE = reachable | REACHABLE |
| `eth_tx_reach_tx_done` (bmc 16, reach) | PROVED = vacuous at 16 | VACUOUS |
| `eth_tx_ifg_floor` (induct) | PROVED, 52.07 MB | PROVED, 52.94 MB |
| `pe_soc_owner_gate_depth` (bmc 16) | PROVED, 958.38 MB | PROVED, 957.89 MB |
| `pe_soc_owner_guard` (induct) | PROVED, 364.55 MB | PROVED, 372.29 MB |

No new property covers the line driver; that is a listed follow-up.

**The formal MUTANT campaign, and a regression I caused and fixed.** In the
full regression below, `formal/mutants.sh` ran 13 mutants, not 14:
`eth_tx_skip_gap` anchors on the literal text `state   <= S_IFG;`, and my
first edit had realigned that line (`state      <= S_IFG;`) while adding the
TP_IDL load beside it. The harness printed "MUTATION DID NOT APPLY -- pattern
absent (INCONCLUSIVE)" and then summarised "13 caught, 0 inconclusive", so
the gate said OK (see §9, finding B). The alignment is restored, every
formal-mutant anchor on a file this branch touches was re-checked (all match
once), and `bash formal/mutants.sh` on the final files gives **14 caught, 0
survived, 0 inconclusive**, verdict-for-verdict identical to `main`'s
`formal/results/mutants.txt`.

## 6. Area (mapped, sg13g2 typ, pre-route)

`bash regress/synth_area.sh` on a detached checkout of `4560432` and on the
branch, same host, same yosys:

| Block | `main` | branch | Δ |
|---|---|---|---|
| `pe_eth_tx` | 904 cells / 16,749.4 µm² | 1,040 / 18,888.1 | +136 / +2,138.6 |
| `pe_soc` | 6,345 / 110,582.5 | 6,447 / 112,630.5 | +102 / +2,048.0 |
| `tt_um_protocol_emulator` | 10,215 / 172,735.7 | 10,269 / 174,145.6 | +54 / +1,409.9 (+0.8%) |
| every other block | — | identical | 0 |

No yosys warning or error in the branch run.

## 7. Full regression

`./regress/run_all.sh --fast -j8` on the branch (2026-09-26 ~04:05-04:50),
read gate by gate — **not** by its exit code, which is 0 but meaningless under
`--fast` (§9, finding A):

- firmware 37/37; RTL TBs `TOTAL: 46 PASS: 46 FAIL: 0`, where
  `tb_pe_soc_sr04` is KNOWN-WIP (expected red). It fails **identically on an
  unmodified checkout of `4560432`** (same messages, same timestamp).
- lint clean; param guards; shell syntax; harness pre-flight; MUTABLE lists;
  every generated reference up to date; wiki page rules; wiki gate negative
  control; 741 document links, 0 dead; diagrams; document index; formal
  safety proofs; run-lock process tree; R2 golden package — all OK.
- all **16 mutation suites** "OK (no unexplained survivors)".
- formal mutant checks "OK" — but only 13 of 14 applied (my anchor
  regression, fixed above).
- **R3 golden package: FAILED** — `reviews/2026-09-25/r3-hex/README.md` and
  `tb/r3-vectors/README.md` differ. **Pre-existing on `main`**: the two files
  already differ at `4560432` (`b7ad4d2` updated the reviews copy at 18:10;
  the tb copy was last touched by `17d24e5` at 16:53). This branch touches
  neither.

**Re-verified on the final files** (after the alignment fix and a comment-only
wrapper edit): all 45 TB cases (44 PASS; `tb_pe_soc_sr04` the known red),
lint, param guards 11/11, the three generators `--check`, wiki pages and
links, MUTABLE lists, shell syntax, `mutate_eth_tx_tb.sh` 33/33 (185 s),
`mutate_eth_tx_loop_tb.sh` 13/13 (374 s), the six formal targets (unchanged)
and the formal mutants 14/14. No `MUTANT` marker is left in `rtl/`.

## 8. Not run, by rule or by scope

- The physical flow, DRC and LVS (standing ruling: final tapeout prep only).
- An STA screen of the new `uo_out[3]` path (recommended before adoption).
- Hardware: nothing here has been on a board.

## 9. For the manager

1. **A pinout decision is waiting:** reclaim `uo_out[3]` (`dbg_pc[1]`) as
   `eth_tx_n`. STATUS item 4 owns the `dbg_pc` pads. If adopted: update
   STATUS (pinout table, item 9's "`uo_out[2]` is the `eth_tx` pad", the
   pin-budget lines), README's status paragraph, and the maps
   (`diagrams/project-plan.puml`, `project-progress.puml` — the architecture
   authority, not touched here).
2. **Merge gate:** this branch changes `regress/`, `tools/` and `wiki/`, so
   `regress/verify_merge.sh` will escalate to the full suite. **Run it
   WITHOUT `--fast` until finding A is fixed**, or read the per-gate lines:
   under `--fast` its exit code is always 0.
3. **Conflict risk:** `regress/mutate_eth_tx_tb.sh` and
   `regress/mutate_eth_tx_loop_tb.sh` are edited here while the worker is
   editing the dep_guard wiring across all harnesses; expect a textual merge
   in those two files. `wiki/log.md` and `wiki/index.md` are append/insert
   edits.
4. **Finding A — `run_all.sh --fast` cannot fail (HIGH).** In the `--fast`
   path the EXIT trap becomes `trap 'rm -rf "$work"; _on_exit' EXIT`
   (`regress/run_all.sh` line 421). `_on_exit` starts with `local rc=$?`,
   which now reads `rm`'s status, so every `exit 1` — a failed TB at line 610,
   a stale gate at line 1334 — leaves the script as **exit 0** (only the
   dep-guard's 4 survives). Reproduction:
   `bash -c '_on_exit(){ local rc=$?; exit "$rc"; }; trap "rm -rf /nonexistent; _on_exit" EXIT; exit 1'; echo $?`
   prints 0 (with `trap "_on_exit" EXIT` it prints 1). Seen live here: the R3
   gate printed FAILED and the run exited 0. `regress/verify_merge.sh`
   forwards `--fast` and judges by that exit code, so **a `--fast` merge gate
   can report green over red cases**, and every recorded "`run_all.sh --fast
   -j8` exit 0" is not evidence on its own. Suggested one-line fix (not
   applied here — the worker is editing `run_all.sh`):
   `trap '_rc=$?; rm -rf "$work"; (exit "$_rc"); _on_exit' EXIT`, plus a
   negative control that plants a failing case under `--fast`.
5. **Finding B — `formal/mutants.sh` drops a mutant whose anchor rotted.**
   `apply_mutation` prints "INCONCLUSIVE" but does not count it, so the
   summary says "0 inconclusive" and the gate says OK with a mutant missing
   (§5). Fix: `inconclusive=$((inconclusive+1))` in `apply_mutation`'s
   failure path.
6. **Finding C — the R3 package README drift** (§7) is red on `main` today.
7. **Other findings:** (a) `tools/gen/pin_budget.py` keeps the
   pinout as hand-typed data, so its `--check` stayed green while it was wrong;
   its prose also asserted "the outputs fit" unconditionally (fixed here).
   (b) the wiki said an external PHY was a 10BASE-T option; a PHY bypasses
   `pe_manch`/`pe_dru` (corrected in two pages). (c) 802.3 numbers here come
   from secondary sources; `raw/` holds no capture of Clause 14 (a datasheet
   was not captured because it is copyrighted).
8. **Board work is now the blocker for a live Ethernet demo:** a PMOD with a
   line buffer, RJ45 magnetics and an RX comparator (details in the plan).
9. **Behaviour to know:** with the persona off, `uo_out[2]`/`uo_out[3]` carry
   `dbg_pc[0]`/`dbg_pc[1]`, which an attached Ethernet front end would put on
   the cable.
