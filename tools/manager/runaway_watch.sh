#!/usr/bin/env bash
# runaway_watch.sh — catch processes burning CPU for hours, the way mem_monitor
# catches RAM. Added 2026-09-27 after a verification script looped for 27h36m
# on a full core and was found by the USER, not the manager.
#
# WHY THIS EXISTS. Every other alarm the manager has covers a resource (RAM,
# tmpfs) or an agent (a frozen session). Nothing watched the CPU line: a
# non-terminating check script looks exactly like a healthy long run from the
# outside - it prints nothing, it just never exits, and nothing in the fleet
# notices for a day and a half.
#
# WHAT COUNTS. CPU TIME (utime+stime), not wall time: a legitimate suite is
# wall-heavy and CPU-light per child. On this project the longest legitimate
# single process is a mutation suite at roughly 5-7 minutes of CPU; a full gate
# is spread across dozens of children. A single process past ALERT_CPU is
# anomalous; past KILL_CPU it is a runaway, and a runaway that is not stopped is
# indistinguishable from wasting a core forever.
#
# WHO IT MAY KILL (user ruling 2026-09-27 13:44) - and why this section exists
# at all. The first version of this script had no notion of ownership: it killed
# on CPU time alone, so on its first scan it `kill -9`'d the manager's OWN pi
# session (40056s of CPU over 60 hours - the cost of being the manager, not a
# runaway). The manager died from its own fix. Every harness instance is now
# launched NAMED via tools/manager/launch_agent.sh, which exports PE_TEAM +
# PE_AGENT_NAME + PE_ROOT_PID into every descendant; those land in
# /proc/<pid>/environ. So before killing anything this script asks
# pe_kill_decision (tools/manager/agent_tag.sh): it acts only on a process whose
# environment carries THIS project's team token, and never on the harness that
# owns the tag or a peer pi/node session. A process it does not positively
# recognize as ours is SKIPPED and logged, never killed - the fail-safe
# direction is "leave it alone", because the cost of a missed runaway is a busy
# core, and the cost of a wrong kill is a dead session.
set -u

# shellcheck source=tools/manager/agent_tag.sh
. "$(dirname "$0")/agent_tag.sh"

ALERT_CPU="${ALERT_CPU:-5400}"    # 90 minutes of CPU -> alert for adjudication
KILL_CPU="${KILL_CPU:-14400}"     # 4 hours of CPU   -> brake, with a record
ALERT="${ALERT:-/tmp/pi-mem-interrupt}"
SELF=$$
ONCE="${PE_WATCH_ONCE:-0}"       # 1 = one scan then exit (verification/tests)
SLEEP_S="${PE_WATCH_SLEEP:-60}"   # poll interval between scans

alert() { echo "RUNAWAY-WATCH $(date '+%F %T'): $*" >>"$ALERT"; }

# cpu_seconds <ps-time-field> -> seconds. Handles [[dd-]hh:]mm:ss.
cpu_seconds() {
  local t=${1# } secs=0 days=0
  case "$t" in *-*) days=${t%%-*}; t=${t#*-};; esac   # ps renders >24h as dd-hh:mm:ss
  local IFS=:
  read -ra parts <<<"$t"
  case ${#parts[@]} in
    3) secs=$((10#${parts[0]}*3600 + 10#${parts[1]}*60 + 10#${parts[2]}));;
    2) secs=$((10#${parts[0]}*60 + 10#${parts[1]}));;
    1) secs=$((10#${parts[0]}));;
  esac
  printf '%s' $((secs + days*86400))
}

# One full scan. Every candidate at/over KILL_CPU is passed to pe_kill_decision;
# only a "kill" verdict results in kill -9. "skip" verdicts are alerted (so a
# skipped high-CPU process is visible to the manager) but never acted on.
scan_once() {
  ps -eo pid=,stat=,time=,args= 2>/dev/null | while read -r pid stat cput args; do
    [ -z "${pid:-}" ] && continue
    [ "$pid" = "$SELF" ] && continue
    secs=$(cpu_seconds "$cput")
    [ "$secs" -ge "$ALERT_CPU" ] || continue
    local verdict rc=1
    verdict=$(pe_kill_decision "$pid" "$args"); rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$secs" -ge "$KILL_CPU" ]; then
        alert "KILL: pid $pid used ${secs}s CPU (stat $stat) agent=${verdict#kill }: $args"
        kill -9 "$pid" 2>/dev/null
      else
        alert "ALERT: pid $pid used ${secs}s CPU (stat $stat) agent=${verdict#kill }: $args"
      fi
    else
      alert "SKIP (${verdict#skip }): pid $pid used ${secs}s CPU (stat $stat): $args"
    fi
  done
}

if [ "$ONCE" = "1" ]; then
  scan_once
  exit 0
fi

while :; do
  scan_once
  sleep "$SLEEP_S"
done
