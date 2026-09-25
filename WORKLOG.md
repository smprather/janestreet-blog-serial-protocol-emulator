# WORKLOG — shared time-stamped state log (append-only)

Standing user order (2026-09-25): **everybody** — manager, `pi-protocol-worker`
and `pi-gui-worker` — appends every state change here. This log is the
**manager's debugging paper trail** (user's correction: "not so the user can
backtrace — so *you* can backtrace. we can't debug without a paper trail"):when work stops, the manager back-traces it from these lines, names the root
cause (lost dispatch, stall, OOM, dead session, empty queue), and fixes the
process — role description, loop, or dispatch channel — not just the symptom.

**Line format (one line per event, newest at the BOTTOM):**

```
YYYY-MM-DD HH:MM TZ | actor | EVENT | detail
```

- `actor`: `manager`, `protocol-worker`, `gui-worker`, `user`, `kernel`
- `EVENT`: `START`, `STOP`, `DISPATCH`, `TASK-START`, `TASK-DONE`, `CHAIN`,
  `QUESTION`, `BLOCKED`, `RULING`, `VERIFY`, `VERIFY-RED`, `LIVENESS`,
  `STALL` (+ reason), `REDISPATCH`, `MEM-ALERT`, `OOM`, `DEPLOY`, `COMMIT`,
  `PUSH`, `CONTEXT-NEW`
- Append-only: never rewrite or delete another actor's lines. If you must
  correct one, append a new line that says what was wrong.

## Log

2026-09-24 14:33 CDT | kernel | OOM | runaway python3 (22.0 GB anon + 5.0 GB swap) OOM-killed in the wezterm cgroup; wezterm unit failed ('oom-kill'); the worker session mid-R1 died with it
2026-09-24 18:21 CDT | protocol-worker | TASK-START | Manager Task 11 = eth-tx plan Tasks 4-5 (wrapper uo_out[2] mux, pad decode, wire loopback, probe firmwares)
2026-09-24 18:33 CDT | protocol-worker | TASK-DONE | plan Task 4 evidence: run_all 32/32 + ten mutation suites green (/tmp/run_all_t11_task4.log)
2026-09-24 18:43 CDT | kernel | OOM | runaway python3 (23.0 GB anon + 5.5 GB swap) OOM-killed in the wezterm cgroup; wezterm unit failed; ALL sessions (protocol-worker, gui-worker, manager) died mid-task; regress/mutate_i2c_tb.sh m1 mutant left UNRESTORED in rtl/pe_pinmux.v (harness SIGKILLed before its restore step)
2026-09-25 01:13 CDT | manager | START | manager restarted (user: "you are the manager"); found Task-11 work unrecorded in the tree
2026-09-25 01:15 CDT | manager | VERIFY-RED | run_all 3/33 FAIL (tb_pe_pinmux, tb_pe_soc_i2c, tb_pe_soc_i2c_xfer) -> forensically attributed to the unrestored m1 mutant (assign pad_oe = reg_oe; is m1's exact patch)
2026-09-25 01:25 CDT | manager | DISPATCH | protocol-worker: restore OD gate (byte-exact from /tmp/tmp.oxt87I4CGc snapshot), verify, close out the Task-11 record
2026-09-25 01:30 CDT | manager | DISPATCH | gui-worker: resume/finish/record the tools/host_bridge/ phase (plan Task 2)
2026-09-25 01:43 CDT | manager | DEPLOY | tools/manager/mem_monitor.sh RAM watchdog live (pid 4043668): 80% -> /tmp/pi-mem-interrupt, 6 GB runaway brake with snapshot+kill
2026-09-25 01:45 CDT | protocol-worker | TASK-DONE | pe_pinmux.v restored byte-identical (c1fa0cec...), run_all 33/33 + 26/26 + ten suites green, synth refreshed, Task-11 recorded (STATUS/HANDOFF/ledger)
2026-09-25 01:49 CDT | gui-worker | TASK-DONE | host_bridge Task 2 verified (55/55) and recorded (reviews/2026-09-25/HOST-GUI-PHASE2-BRIDGE.md)
2026-09-25 01:52 CDT | manager | DISPATCH | gui-worker: plan Task 7 (acceptance --fake dry run)
2026-09-25 01:56 CDT | gui-worker | TASK-DONE | acceptance --fake PASS (16 PASS / 0 FAIL / 1 SKIP), recorded (HOST-GUI-PHASE3-ACCEPTANCE.md); OOM-watch: bounded runs, peak child RSS 24.3 MiB
2026-09-25 01:57 CDT | manager | DISPATCH | gui-worker: plan Task 8 (final verification + deferred record items)
2026-09-25 02:00 CDT | gui-worker | TASK-DONE | Task 8 done (154/154 + 63/63 + 34/34), host queue EMPTY - remaining plan Tasks 3-5 are chip-side
2026-09-25 02:05 CDT | manager | STALL | diagram-refresh dispatch to protocol-worker LOST: typed into the busy TUI input box mid-turn and eaten; NOT retried promptly (manager occupied in user conversation)
2026-09-25 02:05-02:45 CDT | protocol-worker | STALL | idle at prompt ~40 min: no task assigned (the lost diagram dispatch + no chaining protocol yet). gui-worker idle too (empty queue). Root cause: dispatch channel is the TUI input box only, and the manager dispatches serially while conversing; interrupts alone never wake the loop for an idle-with-queue worker
2026-09-25 02:45 CDT | manager | RULING | anti-stall architecture adopted (user orders: always in the sleep-1 loop; 10-min liveness breakout; constantly tune role descriptions; this shared WORKLOG): workers CHAIN the next scoped queue task themselves after each interrupt; manager dispatches next task BEFORE bookkeeping; verified-prompt sends only; dispatch loss is logged as STALL + reason
2026-09-25 02:20 CDT | manager | DISPATCH | protocol-worker: diagram refresh (commit-gated) then chain plan Task 6 -> Task 7; logging duty adopted
2026-09-25 02:20 CDT | manager | DISPATCH | gui-worker: role-doc update + host-side R2 read-path prep (FakePE/acceptance), logging duty adopted
2026-09-25 02:20 CDT | protocol-worker | TASK-START | Manager dispatch 02:55: diagram refresh (project-plan.puml + project-progress.puml + PNG/SVG renders) to the verified post-Task-5 eth-tx state, commit-gated
2026-09-25 02:20 CDT | gui-worker | TASK-START | standing orders: (1) WORKLOG.md logging duty adopted (this file is the ONLY chip-repo file I touch), (2) role-doc/continuity update in this branch HANDOFF.md, (3) chain host-side R2 read-path prep: FakePE read ops + acceptance expectations for the read path the chip will implement (plan Tasks 3-5), not-chip-confirmed
2026-09-25 02:20 CDT | gui-worker | VERIFY | chip repo confirmed free of host work: no tools/host_gui or tools/host_bridge present; the 99 modified files are protocol-worker/manager RTL work, not mine. My host branch host-controller-gui remains the only place host_* lives.
2026-09-25 02:20 CDT | gui-worker | TASK-DONE | role-doc/continuity section added to HANDOFF.md (session role gui-worker, hard chip boundary, WORKLOG logging duty, continuous-work/chaining protocol, cold-resume procedure)
2026-09-25 02:20 CDT | gui-worker | COMMIT | c1fc916 role-doc/continuity section in HANDOFF.md (gui-worker role, chip boundary, WORKLOG duty, chaining protocol)
2026-09-25 02:20 CDT | gui-worker | CHAIN | role docs done -> next: host-side R2 read-path prep (plan Tasks 3-5): extend FakePE read ops (READ_IMEM/READ_DMEM/DUMP_CORE/READ_CPU incl. target-1 readback, bounds) + acceptance expectations, all labelled not-chip-confirmed, TDD; no chip-side changes
2026-09-25 02:20 CDT | gui-worker | TASK-START | host-side R2 read-path prep (plan Tasks 3-5): FakePE read-path fidelity (bounded READ_CPU, DMEM unpacked-word range semantics, DUMP_CORE == STATUS header, target-1 read paths, load-only-range fault accounting) + acceptance R2 coverage, all labelled not-chip-confirmed; TDD; no chip-side changes
2026-09-25 02:23 CDT | gui-worker | QUESTION | R2 read contract, for chip side to settle: (1) does an out-of-range READ (READ_IMEM/READ_DMEM past 1024w/16B) latch a sticky fault or answer RANGE with no fault? plan line 334 says RANGE + no-wrap but is silent on the sticky bit; model exposes both via FakePE(read_fault_policy=latch|status-only), default latch. (2) exact READ_CPU/READ_DMEM payload word order is asserted in tools/host_gui/r2_reads.py (READ_CPU: status,pc,a,x,y,insn,state; READ_DMEM: status then big-endian packed bytes) - confirm against the R2 RTL when it lands.
2026-09-25 02:24 CDT | protocol-worker | TASK-DONE | diagram refresh: both maps updated to post-Task-5 state (pe_eth_tx + 32-entry window + owner mux + G6 uo_out[2] + loopback acceptance green; Tasks 6-7 red/open); re-rendered PNG+SVG; plan 3385x2706 (1.25:1), progress 3947x2477 (1.59:1); structural audit: 0 lost packages/components/notes
2026-09-25 02:24 CDT | protocol-worker | CHAIN | commit gate: waiting for /tmp/pi-commit-done (poll 5 s, max 15 min) before any RTL mutation
2026-09-25 02:25 CDT | gui-worker | TASK-DONE | R2 read-path prep: tools/host_gui/r2_reads.py (7 obligations, chip_confirmed=False) + FakePE(read_fault_policy) + 5 end-to-end acceptance R2 checks (acceptance --fake now PASS 21/0/1, each tagged not-chip-confirmed). TDD red->green. Suites: host_gui 167, bridge 65, r2 13, ruff+compileall clean. Commit 77de465 on host-controller-gui. No chip-side file touched. Two contract questions sent to chip side as WORKLOG QUESTION.
2026-09-25 02:25 CDT | gui-worker | COMMIT | 77de465 feat: prepare host-side R2 read-path contract and acceptance gate (10 files)
2026-09-25 02:25 CDT | gui-worker | CHAIN | R2 prep done -> next scoped host task: add a session-level read_cpu() (and a read_dmem/read_imem parity check) so the acceptance exercises the host state machine rather than the raw transport, closing the R2-PREP limit; TDD; then a session-level read_cpu in the server API if it fits. No chip-side changes.
