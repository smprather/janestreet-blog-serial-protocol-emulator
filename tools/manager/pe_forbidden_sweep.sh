#!/usr/bin/env bash
# pe_forbidden_sweep.sh — enforce L3 (no physical flow) and L5 (no shared-state
# kills) against OUR OWN processes, and nothing else.
#
# WHY THIS IS A SEPARATE SCRIPT (2026-09-27). worker_supervisor.sh used to do
# this inline:
#
#     ps -eo pid,args | grep -E "$FORBIDDEN_PROC_RE" | ... kill -9 "$pid"
#
# That is a BOX-GLOBAL scan with no ownership filter whatsoever, and its own
# `agent="unknown"` fallback was the admission that it could not tell whose
# processes those were. The consequence was concrete and ongoing: the protocol
# emulator's project rule ("never run physical flow, DRC or LVS") was being
# enforced against the USER'S OTHER PROJECTS. WORKLOG lines 1811-1818 and the
# 13:47/13:51 VIOLATION entries record it kill -9ing
# /home/mylesp/engineering-loadout's `loadout install librelane yosys openroad
# klayout` runs and two openroad-cts invocations - work in a live tmux window,
# in a different repository, that this project has no jurisdiction over.
#
# THE USER'S RULING: "you are only allowed to manage pe work." So the rule is
# unchanged in what it forbids, and changed in what it may touch: a process is
# only ever a candidate if it carries PE_TEAM=protocol-emulator in its
# /proc/<pid>/environ, which means this team's launcher started it. Everything
# else is logged as a SKIP and left completely alone.
#
# The fail-safe direction is deliberate and is the same one the user chose for
# runaway_watch: the cost of a missed violation is one forbidden run we did not
# stop, and the cost of a wrong kill is another project's work destroyed. The
# second one is not recoverable; the first one is visible in a log line.
#
# This is a separate file so it can be TESTED directly. The rule it enforces can
# delete processes; a rule that can delete processes has no business being an
# untestable block inside a 200-line supervision loop.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# tmp-isolation: box-global singleton, EXEMPT on purpose. This sweep is not a
# per-worktree script - it is the ENFORCEMENT HALF of the box-global supervisor,
# invoked once per tick from tools/manager/worker_supervisor.sh, and it has to
# see every process in every worktree or it cannot enforce the rule at all. Its
# ALERT and LOG are therefore the supervisor's own fleet-wide state, and they
# default to the same paths the supervisor uses. Namespacing them per worktree
# would give each worktree its own enforcement half, blind to the others, which
# is the exact regression that let a pe rule reach into another project's work.
#
# The exemption is DELIBERATE and it is the same one worker_supervisor.sh and
# mem_monitor.sh carry, because all three are one box-global singleton each. The
# baseline gate caught this file on 2026-09-27 (check_tmp_isolation, "a script
# shares a global /tmp name with every other worktree") and it was RIGHT: a new
# file wearing a fleet-wide path with no marker saying so is indistinguishable
# from a per-worktree script that happens to collide. Both LOG and ALERT remain
# overridable, which is how tools/manager/test_pe_forbidden_sweep.sh runs the
# whole rule against a private log without touching the real one.
# shellcheck source=tools/manager/agent_tag.sh
. "$HERE/agent_tag.sh"

ALERT="${ALERT:-/tmp/pi-manager-interrupt}"
LOG="${LOG:-/tmp/pi-worker-supervisor.log}"
# Physical-flow tools, plus anything that manages shared tmux state. L3 + L5.
#
# The grouping matters and I got it wrong the first time: this was written as
# `(openroad|magic|netgen|klayout|run_librelane|sta[ -])(([0-9])|$)`, which
# requires EVERY tool name to be followed by a digit or end-of-string. Real argv
# is `/path/openroad 120` - a SPACE, not a digit - so the sweep matched nothing
# at all and reported "0 killed, 0 skipped" forever. The suite's own self-test
# caught it, because a guard that finds nothing looks exactly like a guard that
# works. The suffix belongs to the sta alternative alone.
FORBIDDEN_PROC_RE="${FORBIDDEN_PROC_RE:-(openroad|magic|netgen|klayout|run_librelane|sta[ -])}"
# The same pattern this script's own name would match, and the box's other
# project's, are never candidates: we only ever act on the team's own processes.
SELF=$$

killed=0; skipped=0

logline() { printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true; }
viol()    { printf '%s\n' "$*" >>"$ALERT" 2>/dev/null || true; }

while read -r pid args; do
  [ -z "${pid:-}" ] && continue
  [ "$pid" = "$SELF" ] && continue
  [ "$pid" = "$$" ] && continue

  verdict=$(pe_kill_decision "$pid" "$args"); rc=$?
  if [ "$rc" -eq 0 ]; then
    owner="${verdict#kill }"
    if kill -9 "$pid" 2>/dev/null; then
      killed=$((killed+1))
      msg="L3/L5 forbidden process KILLED: pid=$pid agent=$owner [$args]"
    else
      skipped=$((skipped+1))
      msg="L3/L5 forbidden process kill FAILED: pid=$pid agent=$owner [$args]"
    fi
    logline "$(date '+%F %T') $msg"
    viol "$(date '+%F %T') $msg"
  else
    # Not ours. Recorded loudly, acted on never.
    skipped=$((skipped+1))
    msg="L3/L5 SKIP (${verdict#skip }): pid=$pid left untouched [$args]"
    logline "$(date '+%F %T') $msg"
  fi
done < <(ps -eo pid=,args= 2>/dev/null | grep -E "$FORBIDDEN_PROC_RE" | grep -v grep | grep -v pe_forbidden_sweep)

printf 'pe forbidden sweep: %s killed, %s skipped (skipped = not ours, never touched)\n' "$killed" "$skipped"
exit 0
