#!/usr/bin/env bash
# pe_scope_exec.sh — the inner half of pe_run.sh. systemd-run invokes THIS FILE,
# never a `bash -c` string.
#
# WHY THIS IS A FILE AND NOT A `bash -c` STRING (found 2026-09-27, the bug that
# would have repeated the manager's own death). systemd-run builds a transient
# unit and systemd expands `$` in the command per its OWN unit-file rules, where
# `$$` is the escape for a literal dollar sign. So passing
#
#     bash -c 'export PE_ROOT_PID=$$; exec pi'
#
# through systemd-run does not reach bash with `$$`: systemd collapses it to a
# single `$` first, and the agent ends up with the literal string
# PE_ROOT_PID=$ . That is worse than no tag at all, because the one check that
# makes an agent untouchable -- "is this pid the agent's own root?" -- compares
# the pid against PE_ROOT_PID, never matches, and the manager's own killer
# returns "kill" for the manager. Verified: PE_ROOT_PID=$ gave
# `pe_kill_decision -> rc=0 kill raw-probe`.
#
# Putting the logic in a file means no `$` is ever an argument to systemd, so
# nothing rewrites it, and `$$` is an ordinary bash pid as intended.
#
# Contract (called only by pe_run.sh):
#   $1 = agent name
#   $2.. = the command to exec
# Exits by exec'ing, so the pid never changes and PE_ROOT_PID stays true.
set -u

if [ $# -lt 2 ]; then
  echo "pe_scope_exec.sh: internal error - needs <agent-name> <command...>" >&2
  exit 2
fi

export PE_TEAM="protocol-emulator"
export PE_AGENT_NAME="$1"
shift

# $$ is this shell's pid, and the exec below REPLACES this shell without
# changing the pid - so PE_ROOT_PID names exactly the process that becomes the
# agent. That is what makes it the untouchable root.
export PE_ROOT_PID=$$

exec "$@"
