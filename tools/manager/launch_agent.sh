#!/usr/bin/env bash
# launch_agent.sh — start a NAMED harness instance for the protocol emulator team.
#
# THE USER'S RULING (2026-09-27 13:44): "each pi (or any other harness we happen
# to be using) instance working on this project needs to have a name. that name
# should be tagged into any child process spawned via env var (/proc/$$/environ)
# the manager can only kill processes launched by one of the protocol emulator
# team."
#
# This is the whole mechanism, and it is deliberately three lines of environment
# because the kernel does the rest: a child inherits its parent's environment,
# so exporting the tag HERE means every process this harness ever spawns - bash
# tool calls, vvp, yosys, python, a runaway that spins for a day - carries the
# name in its /proc/<pid>/environ. Attribution is then a property of the running
# process rather than a bookkeeping entry someone has to keep updating, and the
# manager's killers can ask "is this ours, and whose?" before acting. See
# agent_tag.sh for the contract and the consumers.
#
# Usage:
#   launch_agent.sh <agent-name> <command> [args...]
#   launch_agent.sh steward pi
#   launch_agent.sh manager-tools ./tools/manager/runaway_watch.sh
#
# The name is REQUIRED and must not be empty: an unnamed instance is exactly the
# gap this closes, so the launcher refuses to start one rather than quietly
# producing an untagged process that the manager can then never touch.
#
# Harness-agnostic on purpose: it execs whatever command it is given, so the same
# launcher names pi, claude, or anything else the team ends up using. PE_ROOT_PID
# is $$ (this shell's pid) because the exec below REPLACES this shell - the pid
# does not change, so $$ is the pid the harness will run as, which is what marks
# the tag's origin as "never a kill target".
set -u

usage() {
  echo "usage: $(basename "$0") <agent-name> <command> [args...]" >&2
  echo "  names the instance, tags every child via env, then execs the command" >&2
}

name="${1:-}"
[ $# -ge 1 ] && shift
if [ -z "$name" ] || [ $# -eq 0 ]; then
  echo "launch_agent.sh: an agent NAME and a command are both required" >&2
  usage
  exit 2
fi
# A name with whitespace or a newline would break the "PE_AGENT_NAME=<name>" line
# contract in /proc/<pid>/environ and every grep of it downstream. Fail here.
case "$name" in
  *[[:space:]]*) echo "launch_agent.sh: agent name must not contain whitespace: '$name'" >&2; exit 2;;
esac

export PE_TEAM="${PE_TEAM:-protocol-emulator}"
export PE_AGENT_NAME="$name"
export PE_ROOT_PID=$$

exec "$@"
