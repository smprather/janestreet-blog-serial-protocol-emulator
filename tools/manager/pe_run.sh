#!/usr/bin/env bash
# pe_run.sh — THE wrapper. Start any protocol-emulator agent: NAMED, TAGGED, and
# BOUNDED BY THE KERNEL.
#
# This is the one command you should need to start work on this project.
#
#   ./tools/manager/pe_run.sh manager              # the manager, resuming the last session
#   ./tools/manager/pe_run.sh manager --fresh      # the manager, a new session
#   ./tools/manager/pe_run.sh steward              # a worker, resuming its last session
#   ./tools/manager/pe_run.sh fw-bus ./regress/run_all.sh --fast -j8
#
# WHY IT EXISTS (2026-09-27). Three separate incidents in one afternoon all had
# the same shape: the thing that was supposed to protect the machine was itself
# the thing that broke it.
#
#   1. runaway_watch.sh kill -9'd the manager's own pi session - 40056s of CPU
#      against a 4h threshold. "Whoopsie, I killed myself."
#   2. mem_monitor.sh, the RAM brake, was dead for 35 hours, so the box ran with
#      no limit at all until a fleet run drove user-1000.slice into its pids
#      limit (TasksMax=84178). The desktop could no longer fork a thread and the
#      graphical session died to a login screen. ~10 minutes of vvp at 100% on
#      every core, from testbenches that never reached $finish and were bounded
#      by nothing.
#   3. worker_supervisor.sh killed the USER'S OTHER PROJECT - it enforced this
#      project's "no physical flow" rule box-globally, kill -9ing
#      engineering-loadout's openroad runs, because it had no idea whose
#      processes those were.
#
# The common defect: enforcement was living in a userspace script that died with
# the session, could not tell one process from another, and had to be awake.
#
# THIS FIXES IT IN THE LAYER THAT CANNOT FAIL:
#
#   TAG    PE_TEAM / PE_AGENT_NAME / PE_ROOT_PID are exported into the
#          environment, so they land in /proc/<pid>/environ of the agent AND
#          every descendant it ever spawns - vvp, yosys, python, a runaway.
#          Attribution becomes a property of the running process rather than a
#          bookkeeping entry. PE_ROOT_PID marks the agent's own root, which the
#          killers refuse to touch: the manager can never kill itself.
#
#   BOUND  The agent runs inside a systemd user scope with TasksMax, MemoryMax
#          and CPUQuota. The KERNEL enforces these whether or not any script is
#          alive. Measured, not asserted: with TasksMax=64, a probe that would
#          otherwise hold 300 concurrent processes was refused by the kernel at
#          "fork: Resource temporarily unavailable" and the box was untouched.
#          That is the same EAGAIN that killed the session on 2026-09-27,
#          except it now lands on the agent instead of on your desktop.
#
#   SCOPE  This project may only manage THIS project. If PE_TEAM is already set
#          to a different team, this refuses to run, so a pe wrapper can never
#          be used to tag work as ours that is not.
#
# The limits are deliberately conservative and are meant to be tuned from a
# measured full-gate run, not from arithmetic. Until that measurement lands,
# they are set to be obviously safe rather than tight.
#
# --fresh / --resume: agents resume their last session BY DEFAULT, because a
# killed session's findings live in that session and in WORKLOG.md, and
# re-deriving them is pure cost. --fresh opts out.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# ---- the TEAM budget, and the per-agent share of it. -----------------------
# PER-AGENT CAPS ALONE DO NOT ADD UP, and on this box the arithmetic was fatal:
# 4 agents x 8G = 32G on a 31G machine that also runs the desktop, Chrome and
# five other projects. Every agent individually well-behaved, collectively dead.
# So the real ceiling is a systemd slice that all pe scopes nest inside, and the
# per-agent numbers are a share OF that ceiling rather than the ceiling itself.
#
#   pe-agents.slice   MemoryHigh=14G  throttle + reclaim here (this is the knob
#                                  that swaps work to disk rather than killing it)
#                     MemoryMax=20G   hard wall; the desktop keeps >=11G even
#                                  when the fleet is at its ceiling
#                     TasksMax=2048   4 agents x 512
#                     CPUQuota=1600%  16 of 24 cores, so the fleet cannot pin
#                                  the machine and starve the desktop
#   pe-<agent>.scope  MemoryHigh=4G   one agent's working set; above this the
#                                  kernel reclaims from THIS agent first
#                     MemoryMax=6G
#                     TasksMax=512    a --fast -j8 gate peaks in the low
#                                  hundreds; ~1/160 of the 84178 that killed
#                                  the session
#                     CPUQuota=1600%
#
# MEASURED, not guessed: with the team's MemoryHigh dropped to 64M, a 200MB
# allocation in a nested scope was reclaimed to 70MB and the process stayed
# ALIVE. That is the difference between degrading and dying, and it is why
# MemoryHigh (throttle) sits below MemoryMax (kill) - reclaim is tried first and
# the hard wall only fires if reclaim genuinely failed.
TASKS_MAX="${PE_TASKS_MAX:-512}"
MEMORY_HIGH="${PE_MEMORY_HIGH:-4G}"
MEMORY_MAX="${PE_MEMORY_MAX:-6G}"
SLICE="${PE_SLICE:-pe-agents.slice}"
CPU_QUOTA="${PE_CPU_QUOTA:-1600%}"
SESSION_FLAG="--continue"

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <agent-name> [--fresh] [command [args...]]

  manager            launch the manager (pi ${SESSION_FLAG}) in the repo
  <name>             launch any named agent, resuming its last session
  <name> --fresh     same, but start a new session
  <name> <cmd> ...   run an arbitrary command as a named, bounded agent

limits: agent MemoryHigh=$MEMORY_HIGH MemoryMax=$MEMORY_MAX TasksMax=$TASKS_MAX CPUQuota=$CPU_QUOTA
        team  $SLICE (the aggregate ceiling - see tools/manager/pe-agents.slice)
override with PE_MEMORY_HIGH / PE_MEMORY_MAX / PE_TASKS_MAX / PE_CPU_QUOTA / PE_SLICE
EOF
  exit 2
}

[ $# -ge 1 ] || usage
name="$1"; shift

case "$name" in
  -h|--help) usage;;
  *[[:space:]]*) echo "pe_run.sh: agent name must not contain whitespace: '$name'" >&2; exit 2;;
esac

# --fresh / --resume apply to the default (pi) launch only.
if [ "${1:-}" = "--fresh" ]; then SESSION_FLAG=""; shift
elif [ "${1:-}" = "--resume" ]; then SESSION_FLAG="--continue"; shift
fi

# The manager is the one agent that is not optional to name, and it is the one
# that must run in the repo. Everything else gets the repo as cwd too, because
# every pe agent's tools resolve the repo from their own location.
cd "$REPO" || { echo "pe_run.sh: cannot enter repo at $REPO" >&2; exit 1; }

# The user ruling: pe may only manage pe work. Refuse to run inside another
# team's tag rather than quietly re-tagging it as ours.
if [ -n "${PE_TEAM:-}" ] && [ "$PE_TEAM" != "protocol-emulator" ]; then
  echo "pe_run.sh: refusing to run - already tagged PE_TEAM=$PE_TEAM." >&2
  echo "  The protocol emulator may only manage its own work (user ruling," >&2
  echo "  2026-09-27). Launch that project through its own tooling." >&2
  exit 3
fi

# The name is REQUIRED, for the same reason agent_tag.sh requires it: an
# unnamed instance is exactly the gap the tagging exists to close, and an
# untagged process can never be managed or attributed.
if [ -z "$name" ]; then echo "pe_run.sh: an agent name is required" >&2; exit 2; fi

# Default command: the agent harness, resuming, in the repo. Harness-agnostic in
# spirit but pi is what this project runs.
if [ $# -eq 0 ]; then
  set -- pi
  [ -n "$SESSION_FLAG" ] && set -- "$@" "$SESSION_FLAG"
fi

unit="pe-${name}"
# systemd-run refuses a unit name that is already active, which is the correct
# behaviour (one manager, not two) but the error is opaque, so name it.
if systemctl --user is-active --quiet "$unit.scope" 2>/dev/null; then
  echo "pe_run.sh: $unit.scope is ALREADY RUNNING. Refusing to start a second $name." >&2
  echo "  (one editor per file, one root per agent - see MANAGER-COLD-START.md)" >&2
  exit 4
fi

# The TEAM slice must exist before any scope can nest in it, and if it cannot be
# established the agent must NOT start unbounded. Failing loudly is the point: a
# silently-missing ceiling is the exact condition that would let 4 agents each ask
# for 6G on a 31G box. Idempotent, and the unit is versioned in the repo rather
# than hand-written, so the budget is reviewable in a diff.
SLICE_SRC="$HERE/pe-agents.slice"
# Only the repo's own slice is auto-installed. Honouring PE_SLICE for the
# INSTALL path meant `PE_SLICE=anything` silently created a bogus unit named
# `anything.slice` out of the pe-agents.slice body - a budget under a name
# nobody chose, which is worse than no budget because it looks deliberate.
if [ "$SLICE" = "pe-agents.slice" ] && [ -f "$SLICE_SRC" ]; then
  # The unit FILE is named after the slice, and the slice name already ends in
  # ".slice" - so appending another one installs `pe-agents.slice.slice`, which
  # systemd loads as a unit by that literal name and which nothing ever joins.
  # That bug was invisible for a test run only because a correct file from an
  # earlier session was still lying around doing the real work.
  case "$SLICE" in *.slice) SLICE_FILE="$SLICE";; *) SLICE_FILE="${SLICE}.slice";; esac
  SLICE_DST="$HOME/.config/systemd/user/$SLICE_FILE"
  mkdir -p "$(dirname "$SLICE_DST")"
  if ! cmp -s "$SLICE_SRC" "$SLICE_DST" 2>/dev/null; then
    cp "$SLICE_SRC" "$SLICE_DST" || { echo "pe_run.sh: cannot install the team budget" >&2; exit 5; }
    systemctl --user daemon-reload >/dev/null 2>&1
    echo "pe_run.sh: installed the team budget $SLICE from the repo copy" >&2
  fi
fi

# Load the slice so its properties are actually applied, then read them back.
# Reading is not optional: an unloaded unit is perfectly readable and reports
# MemoryMax=infinity, so a check on the EXIT CODE of `systemctl show` passes on a
# slice that has no ceiling at all. That is the bug this guards against - the
# first version of this guard tested the exit code, printed
# "TEAM MemoryMax=infinity", and started the agent anyway.
systemctl --user start "$SLICE" >/dev/null 2>&1 || true
TEAM_HIGH="$(systemctl --user show "$SLICE" -p MemoryHigh --value 2>/dev/null)"
TEAM_MAX="$(systemctl --user show "$SLICE" -p MemoryMax --value 2>/dev/null)"
TEAM_TASKS="$(systemctl --user show "$SLICE" -p TasksMax --value 2>/dev/null)"

case "$TEAM_MAX" in
  ''|infinity)
    echo "pe_run.sh: REFUSING to start $name." >&2
    echo "  $SLICE reports MemoryMax=${TEAM_MAX:-<none>}, so the fleet has NO aggregate" >&2
    echo "  ceiling. Per-agent caps alone do not add up: 4 x $MEMORY_MAX is 24G on a" >&2
    echo "  31G machine, and that is the arithmetic that killed the session on 2026-09-27." >&2
    echo "  Fix: install tools/manager/pe-agents.slice to ~/.config/systemd/user/ and run" >&2
    echo "       'systemctl --user daemon-reload', or pass PE_SLICE=pe-agents.slice." >&2
    exit 5
    ;;
esac

echo "pe_run.sh: $name -> $unit.scope, nested in $SLICE" >&2
echo "pe_run.sh:   agent  MemoryHigh=$MEMORY_HIGH MemoryMax=$MEMORY_MAX TasksMax=$TASKS_MAX CPUQuota=$CPU_QUOTA" >&2
echo "pe_run.sh:   TEAM   MemoryHigh=$TEAM_HIGH MemoryMax=$TEAM_MAX TasksMax=$TEAM_TASKS   <- the ceiling that adds up" >&2
echo "pe_run.sh: repo=$REPO  cmd=$*" >&2

# The tag is set by a HELPER FILE, not by a `bash -c` string. systemd expands
# `$` in the command per its own unit-file rules before bash ever sees it, which
# turned PE_ROOT_PID=$$ into the literal PE_ROOT_PID=$ and left the agent
# killable - the exact defect that killed the manager on 2026-09-27. Passing a
# file means no `$` is an argument to systemd at all. See pe_scope_exec.sh.
#
# stdin/stdout/stderr are inherited, which is what makes a TUI work inside a
# scope: this is a --scope, not a service, so the terminal comes with it.
exec systemd-run --user --scope \
  --unit="$unit" \
  --slice="$SLICE" \
  -p "MemoryHigh=$MEMORY_HIGH" \
  -p "MemoryMax=$MEMORY_MAX" \
  -p "TasksMax=$TASKS_MAX" \
  -p "CPUQuota=$CPU_QUOTA" \
  -- "$HERE/pe_scope_exec.sh" "$name" "$@"
