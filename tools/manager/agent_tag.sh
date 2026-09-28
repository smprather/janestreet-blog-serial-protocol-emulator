#!/usr/bin/env bash
# agent_tag.sh — THE env contract for "which team agent launched this process,
# and may the manager touch it?" SOURCE this; do not execute it.
#
# THE FAILURE THIS EXISTS FOR (2026-09-27 13:27:39). The manager wrote
# tools/manager/runaway_watch.sh to catch a check script that looped for 27h36m
# and burned a core for a day and a half. Its very first scan saw a `pi` process
# at 40056s of CPU — the manager's OWN 60-hour-old session, where 11.1h of CPU
# is just what being the manager costs — and `kill -9`'d it. The watchdog had no
# concept of ownership: it killed on a CPU threshold alone, so a healthy
# long-lived agent was indistinguishable from the runaway it was built to catch.
# The manager died from its own fix, seconds after arming it.
#
# THE USER'S RULING (2026-09-27 13:44): every harness instance working on this
# project gets a NAME; the name is tagged into every child process it spawns
# (readable at /proc/<pid>/environ); and the manager may only kill processes
# launched by a protocol-emulator team member.
#
# THE CONTRACT — three env vars, set once at launch by tools/manager/launch_agent.sh
# and inherited by every descendant through ordinary environment inheritance:
#
#   PE_TEAM=protocol-emulator   MEMBERSHIP + AUTHORIZATION. Present iff the
#                               process descends from a project agent. This is
#                               the token the manager's killers gate on. A
#                               process without it is NOT ours and is NEVER
#                               touched. Fail-safe direction: unknown -> skip.
#   PE_AGENT_NAME=<name>       WHICH agent ("manager", "steward",
#                               "protocol-worker", "fw-timing", ...). Pure
#                               attribution: every kill/skip alert names the
#                               owner, so "whose runaway?" has an answer.
#   PE_ROOT_PID=<pid>          the harness process ITSELF. launch_agent.sh sets
#                               it to the pid it is about to exec into, so the
#                               tag's origin is identifiable and is NEVER a kill
#                               target: a runaway is by definition a DESCENDANT
#                               of a harness, never the harness.
#
# Because the kernel copies the environment into every child, any process can be
# attributed by reading /proc/<pid>/environ — no pidfile, no registry, nothing
# to drift out of sync with reality. That is the whole point: ownership is a
# property of the running process, not a bookkeeping entry someone must maintain.
#
# Consumers: runaway_watch.sh (CPU runaway killer), mem_monitor.sh (RSS runaway
# brake). Both call pe_kill_decision before every kill -9. There is no other
# kill path in the manager tooling.
#
# Usage:  . "$(dirname "$0")/agent_tag.sh"   # from a script in tools/manager/

# The single team token. Override only for tests (PE_TEAM_TOKEN).
PE_TEAM_TOKEN="${PE_TEAM_TOKEN:-protocol-emulator}"

# Harness / service binaries: never kill, even when team-tagged. These are what
# an agent session needs to keep working; killing one (e.g. a context-mode node
# server) breaks the session in a way that looks like a tool bug, not a kill.
PE_HARNESS_COMM_RE='^(pi|claude|codex|gemini|opencode|node)$'

# Manager's own tooling, matched on the command line because a bash script's
# /proc/<pid>/comm is just "bash" (the name is in argv, not comm).
PE_TOOL_ARGS_RE='(runaway_watch|mem_monitor|worker_supervisor|launch_agent|agent_tag)'

# pe_environ_var <pid> <var>  -> value, or empty if the var is absent or /proc
# is unreadable (another user's process, or a non-descendant under yama
# ptrace_scope). An unreadable env is NOT team.
#
# WHY THIS IS WRITTEN AS A GROUP WITH ITS OWN STDERR REDIRECT, and why the
# obvious `test -r` guard does NOT work. Two separate leaks, both found by
# running test_agent_tag.sh rather than by reading the code:
#   1. `tr ... < /proc/$pid/environ 2>/dev/null` does not suppress the SHELL's
#      redirect failure - the shell emits that diagnostic before tr ever runs -
#      so every unreadable /proc printed "Permission denied" on every scan.
#   2. Guarding with `[ -r ... ]` silences nothing, because -r is a STAT check
#      and the kernel gates the OPEN on ptrace_may_access(PTRACE_MODE_READ
#      _FSCREDS): under yama ptrace_scope=1 a process may read only a DESCENDANT's
#      environ. So `test -r /proc/989/environ` is TRUE (mylesp owns it, mode
#      0400) and the open still fails EACCES. A permission-bit check is the
#      wrong instrument for a ptrace-gated file.
# Redirecting the enclosing GROUP's stderr is what actually works: the shell's
# diagnostic goes to the group's /dev/null, and a readable environ still reads
# (both directions are asserted by the self-test, so this cannot silently
# degrade into "suppress everything" and pass).
pe_environ_var() {
  { tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null || true; } 2>/dev/null |
    sed -n "s/^$2=//p" | head -1
}

# pe_comm <pid> -> /proc/<pid>/comm (basename of the executable).
pe_comm() { cat "/proc/$1/comm" 2>/dev/null; }

# pe_agent_of <pid> -> the PE_AGENT_NAME of the owning agent, or "unnamed".
pe_agent_of() { local n; n=$(pe_environ_var "$1" PE_AGENT_NAME); printf '%s' "${n:-unnamed}"; }

# pe_is_team <pid> -> 0 iff the process carries the exact team token.
pe_is_team() { [ "$(pe_environ_var "$1" PE_TEAM)" = "$PE_TEAM_TOKEN" ]; }

# pe_kill_decision <pid> <args...> -> prints a verdict and returns 0 to kill, 1
# to skip. Verdicts:
#   kill <agent>              tagged, a work process, above threshold -> KILL
#   skip not-team             no/foreign PE_TEAM -> never touch (fail-safe)
#   skip agent-root <agent>   this pid IS the harness that owns the tag -> never
#   skip harness <agent>      a pi/claude/node session or its MCP server
#   skip manager-tool <agent> one of the manager's own watchdog/monitor scripts
# Ordering matters: team first (cheapest gate, and the whole ruling), then the
# two "even though it's ours, don't" classes, then the manager's own tools.
pe_kill_decision() {
  local pid="$1"; shift
  local args="$*"
  local team agent root comm
  [ -d "/proc/$pid" ] || { echo "skip gone"; return 1; }
  team=$(pe_environ_var "$pid" PE_TEAM)
  if [ "$team" != "$PE_TEAM_TOKEN" ]; then
    # Log the actual team value when present so a process carrying the WRONG
    # token is visible rather than silently lumped in with "not ours".
    echo "skip not-team${team:+ [PE_TEAM=$team]}"
    return 1
  fi
  agent=$(pe_agent_of "$pid")
  root=$(pe_environ_var "$pid" PE_ROOT_PID)
  if [ -n "$root" ] && [ "$root" = "$pid" ]; then echo "skip agent-root $agent"; return 1; fi
  comm=$(pe_comm "$pid")
  if printf '%s' "$comm" | grep -qE "$PE_HARNESS_COMM_RE"; then echo "skip harness $agent"; return 1; fi
  if printf '%s' "$args" | grep -qE "$PE_TOOL_ARGS_RE"; then echo "skip manager-tool $agent"; return 1; fi
  echo "kill $agent"
  return 0
}
