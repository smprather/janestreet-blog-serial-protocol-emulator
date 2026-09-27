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

# ---- the budget. Conservative on purpose; tune from measurement. -----------
#   TasksMax   512 - a --fast -j8 gate peaks in the low hundreds. This is ~1/6
#                      of the per-process pids limit that worked fine, and
#                      ~1/160 of the 84178 that killed the session.
#   MemoryMax  8G   - above anything this toolchain legitimately needs, below
#                      the 26.8G user-slice peak that did this.
#   CPUQuota   1600% - 16 of 24 cores, so a single agent cannot pin the machine
#                      and leave your desktop starved.
TASKS_MAX="${PE_TASKS_MAX:-512}"
MEMORY_MAX="${PE_MEMORY_MAX:-8G}"
CPU_QUOTA="${PE_CPU_QUOTA:-1600%}"
SESSION_FLAG="--continue"

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <agent-name> [--fresh] [command [args...]]

  manager            launch the manager (pi ${SESSION_FLAG}) in the repo
  <name>             launch any named agent, resuming its last session
  <name> --fresh     same, but start a new session
  <name> <cmd> ...   run an arbitrary command as a named, bounded agent

limits: TasksMax=$TASKS_MAX MemoryMax=$MEMORY_MAX CPUQuota=$CPU_QUOTA
override with PE_TASKS_MAX / PE_MEMORY_MAX / PE_CPU_QUOTA
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

echo "pe_run.sh: $name -> $unit.scope  TasksMax=$TASKS_MAX MemoryMax=$MEMORY_MAX CPUQuota=$CPU_QUOTA" >&2
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
  -p "TasksMax=$TASKS_MAX" \
  -p "MemoryMax=$MEMORY_MAX" \
  -p "CPUQuota=$CPU_QUOTA" \
  -- "$HERE/pe_scope_exec.sh" "$name" "$@"
