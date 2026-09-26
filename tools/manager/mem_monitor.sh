#!/usr/bin/env bash
# mem_monitor.sh — manager-side RAM watchdog and runaway-process brake.
#
# Deployed by the Project Review & Pi Orchestration Manager on the user's
# orders (2026-09-25):
#   1. "deploy a memory monitor to ping you with an interrupt if ram gets
#       past ~80% usage"
#   2. "if ram gets too high, debug the problem and fix it. i keep coming
#       back to a dead wezterm and OOM message from CachyOS."
#
# WHY THIS EXISTS: two kernel OOM events (2026-09-24 14:33:40 and 18:43:28,
# journalctl -k) each killed a runaway python3 at 22-23 GB anon RSS (+5 GB
# swapped). Both lived in the wezterm systemd unit's cgroup; systemd then
# tore the unit down ("Failed with result 'oom-kill'") and the user came back
# to a dead wezterm. The 18:43 event also left a HALF-APPLIED Verilog
# mutation on disk (regress/mutate_i2c_tb.sh m1: the pe_pinmux open-drain
# gate) because the mutation harness died before its restore step.
#
# WHAT IT DOES (every INTERVAL seconds):
#   * RAM% = (MemTotal - MemAvailable) / MemTotal.
#   * >= THRESHOLD (default 80): write ALERT_FILE (/tmp/pi-mem-interrupt) with
#     the usage, free -m, the top-RSS process table with cmdlines, and the
#     suspected runaways. The manager's sleep-1 interrupt loop wakes on the
#     file and DEBUGS + FIXES (user order: not just report). A dated copy is
#     kept in SNAPDIR so post-mortems survive.
#   * Runaway brake (the fix that prevents another dead wezterm): any process
#     matching TOOL_RE (project tooling: python3 running peasm/peemu/tools/
#     host_bridge/host_gui/pytest, or vvp/iverilog/yosys/opensta) with RSS
#     over RUNAWAY_KB (default 6 GB) is snapshotted and KILLED, then alerted.
#     Nothing legitimate in this toolchain needs more than a few GB; the two
#     OOM runaways reached 22-23 GB because nothing stopped them.
#   * Hysteresis: re-alert at most every REALERT_S (default 600 s) while the
#     threshold stays crossed; re-arm when usage falls to THRESHOLD-5 or below.
#
# Usage:
#   mem_monitor.sh          run forever (use nohup/setsid to detach)
#   mem_monitor.sh --once   evaluate one cycle, print to stdout, do not write
#                           ALERT_FILE, do not kill anything (verification)
#
# Env: THRESHOLD REALERT_S INTERVAL ALERT_FILE SNAPDIR LOG RUNAWAY_KB TOOL_RE

set -u

THRESHOLD="${THRESHOLD:-80}"
REALERT_S="${REALERT_S:-600}"
INTERVAL="${INTERVAL:-2}"
ALERT_FILE="${ALERT_FILE:-/tmp/pi-mem-interrupt}"
SNAPDIR="${SNAPDIR:-/tmp/pi-mem-snapshots}"
LOG="${LOG:-/tmp/pi-mem-monitor.log}"
RUNAWAY_KB="${RUNAWAY_KB:-6291456}"   # 6 GiB
TOOL_RE="${TOOL_RE:-(python[0-9.]* .*(peasm|peemu|tools/|host_bridge|host_gui|pytest))|(vvp )|(iverilog)|(yosys)|(opensta)}"
PIDFILE="${PIDFILE:-/tmp/pi-mem-monitor.pid}"

ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

snapshot() {  # $1 = label; prints the snapshot file path
  mkdir -p "$SNAPDIR"
  local f; f="$SNAPDIR/$(date +%F_%H%M%S)_$1.txt"
  {
    echo "== $1 @ $(date '+%F %T') =="
    free -m
    echo
    echo "-- top RSS (pid ppid rss_kb cmdline) --"
    for p in $(ps -eo pid --sort=-rss | head -16 | tail -15); do
      printf '%s %s %s %s\n' "$p" "$(ps -o ppid= -p "$p" | tr -d ' ')" \
        "$(ps -o rss= -p "$p" | tr -d ' ')" \
        "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | head -c 240)"
    done
    echo
    echo "-- tooling processes over ${RUNAWAY_KB} KB --"
    ps -eo pid,rss,args --sort=-rss | grep -E "$TOOL_RE" | grep -v grep
  } >"$f" 2>&1
  echo "$f"
}

latched=0
last_alert=0

if [ "$ONCE" -eq 0 ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "mem_monitor: already running (pid $(cat "$PIDFILE"))" >&2
    exit 1
  fi
  echo $$ >"$PIDFILE"
  log "monitor start pid=$$ threshold=${THRESHOLD}% rearm=$((THRESHOLD-5))% interval=${INTERVAL}s runaway_kb=${RUNAWAY_KB} alert=${ALERT_FILE}"
fi

while :; do
  read -r total avail < <(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t, a}' /proc/meminfo)
  if [ -z "${total:-}" ] || [ -z "${avail:-}" ] || [ "$total" -eq 0 ]; then
    sleep "$INTERVAL"; continue
  fi
  used=$((total - avail))
  pct=$((used * 100 / total))
  now=$(date +%s)

  # --- /tmp capacity (2026-09-26: /tmp hit 100% and gates failed looking like logic bugs) ---
# A full tmpfs makes fixtures un-writable: self-tests report "dirty" and a
# resource fault and a logic fault produce the SAME verdict. Alert before that.
tpct=$(df -P /tmp 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
if [ -n "$tpct" ] && [ "$tpct" -ge 85 ]; then
  {
    echo "MEM-MONITOR $(date '+%F %T'): /tmp is ${tpct}% full (resource fault incoming: gates will fail like logic bugs)"
    df -h /tmp | tail -1
    du -sh /tmp/* 2>/dev/null | sort -rh | head -8
  } >>"$ALERT"
fi

# ---- runaway brake: snapshot + kill oversized project tooling ------------
  runaways=""
  while read -r pid rss rest; do
    [ -z "${pid:-}" ] && continue
    if [ "$rss" -ge "$RUNAWAY_KB" ] 2>/dev/null; then
      runaways="$runaways pid=$pid rss=${rss}KB cmd=${rest}"$'\n'
      if [ "$ONCE" -eq 0 ]; then
        snap=$(snapshot "runaway_${pid}")
        log "RUNAWAY KILL: pid=$pid rss=${rss}KB (snapshot $snap)"
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
  done < <(ps -eo pid,rss,args --sort=-rss | grep -E "$TOOL_RE" | grep -v grep)

  # ---- threshold alert ----------------------------------------------------
  if [ "$pct" -ge "$THRESHOLD" ] || [ -n "$runaways" ]; then
    if [ "$ONCE" -eq 1 ]; then
      echo "MEM ${pct}% (used ${used}kB / ${total}kB) runaways:${runaways:-none}"
      free -m
      exit 0
    fi
    if [ "$latched" -eq 0 ] || [ $((now - last_alert)) -ge "$REALERT_S" ]; then
      snap=$(snapshot "mem_${pct}pct")
      {
        echo "MEM: RAM at ${pct}% (threshold ${THRESHOLD}%) at $(date '+%F %T')"
        [ -n "$runaways" ] && echo "RUNAWAY BRAKE APPLIED:${runaways}"
        echo "Snapshot: $snap"
        echo
        free -m
        echo
        echo "-- top RSS (pid ppid rss_kb cmdline) --"
        for p in $(ps -eo pid --sort=-rss | head -16 | tail -15); do
          printf '%s %s %s %s\n' "$p" "$(ps -o ppid= -p "$p" | tr -d ' ')" \
            "$(ps -o rss= -p "$p" | tr -d ' ')" \
            "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | head -c 240)"
        done
        echo
        echo "Manager: DEBUG and FIX per the user's standing order (not just report)."
      } >"$ALERT_FILE" 2>&1
      latched=1
      last_alert=$now
      log "ALERT written: RAM ${pct}% (used ${used}kB / ${total}kB) runaways:$( [ -n "$runaways" ] && echo yes || echo no)"
    fi
  elif [ "$latched" -eq 1 ] && [ "$pct" -le $((THRESHOLD - 5)) ]; then
    latched=0
    log "re-armed: RAM back to ${pct}%"
  fi

  [ "$ONCE" -eq 1 ] && exit 0
  sleep "$INTERVAL"
done
