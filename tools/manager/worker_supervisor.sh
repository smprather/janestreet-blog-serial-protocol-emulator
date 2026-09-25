#!/usr/bin/env bash
# worker_supervisor.sh — keep the tmux Pi workers working, and enforce THE LAW.
#
# User philosophy (2026-09-25): "the workers are just going to stop working.
# it's a fact of life. that's why i built a manager to keep them going." …
# "they MUST check in with the log file … we can't do it without telemetry."
# … "and if someone breaks the law, rain hellfire down on them!"
#
# So: worker-stall is EXPECTED (nudged back onto the queue), missing telemetry
# is a STALL SIGNAL (manager alerted), and law-breaking is punished
# automatically. Every action is appended to WORKLOG.md with timestamps.
#
# THE LAW (workers):
#   L1 TELEMETRY  TASK-START / CHECKPOINT / TASK-DONE in WORKLOG.md (timestamped)
#   L2 WORKTREE   no git reset|clean|checkout --|restore|rebase|push --force
#                 on the shared worktree; never delete others' uncommitted work
#   L3 PHYSICAL   never run physical flow, DRC or LVS (openroad|magic|netgen|
#                 klayout|flow/run_librelane.sh) — standing prohibition
#   L4 BOUNDARY   gui-worker touches ONLY WORKLOG.md in the chip repo;
#                 protocol-worker never touches /tmp/opencode/host-controller-gui
#   L5 SHARED     never kill the tmux server, another pane, or another agent
#   L6 INTERRUPT  rewrite your interrupt file as the last action of each task
#
# PENALTIES (productive remedies first — the user's ruling 2026-09-25: "the
# worst thing a worker can do with respect to the law is not be working.
# killing the worker is not a great way to get more work out of them"):
#   idle/not-working (the PRIMARY crime, measured in WORKLOG)
#                 -> VIOLATION-IDLE log + auto-NUDGE; if two nudges in a row
#                    produce zero WORKLOG activity -> manager alert + the
#                    manager re-dispatches a smaller task. NEVER a kill.
#   L1 telemetry gap -> warn + manager alert; a restart would destroy the
#                    very trail we need, so the session is kept alive.
#   L2/L3/L5      -> the offending PROCESS is killed (e.g. an openroad run),
#                    the worker's TURN is interrupted with Escape (context
#                    preserved), HELLFIRE is logged and the manager alerted
#                    to adjudicate/restore.
#   L4            -> corrective note + manager alert.
#   pane wedged and uninterruptible -> LAST-RESORT restart of its own pane
#                    (logged as HELLFIRE last-resort; context lost).
# HARD RESTART kills only that worker's own pane process (allowed scope: an
# owned task/session) — never the tmux server or other windows.
#
# Usage: worker_supervisor.sh [--once]     (deploy detached via nohup setsid)

set -u
INTERVAL="${INTERVAL:-30}"
NUDGE_COOLDOWN="${NUDGE_COOLDOWN:-180}"
STALL_ALERT_S="${STALL_ALERT_S:-900}"
WORKLOG="${WORKLOG:-/home/mylesp/janestreet-blog-serial-protocol-emulator/WORKLOG.md}"
ALERT="${ALERT:-/tmp/pi-manager-interrupt}"
PIDFILE="${PIDFILE:-/tmp/pi-worker-supervisor.pid}"
LOG="${LOG:-/tmp/pi-worker-supervisor.log}"
ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1

WORKERS="0:pi-protocol-worker:protocol-worker 0:pi-gui-worker:gui-worker 0:pw-fw-timing:fw-timing 0:pw-fw-bus:fw-bus"
FORBIDDEN_PROC_RE='(openroad|magic|netgen|klayout|run_librelane)'
FORBIDDEN_CMD_RE='git (reset|clean|checkout --|restore|rebase|push --force)|rm -rf (/|~)([[:space:]]|$)|rm -rf /\*|tmux kill-'
COLDSTART_LINE="Continue as your role per COLD-START.md and WORKLOG.md: log TASK-START in WORKLOG.md immediately, then pick the NEXT scoped task from the queue and start it IN THIS SAME TURN. The law (L1 telemetry / L2 no destructive git / L3 no physical flow / L4 repo boundary / L5 no shared-state kills / L6 interrupt file last) is enforced automatically."

logline()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
worklog()  { printf '%s | supervisor | %s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$*" >>"$WORKLOG"; }
viol()     { printf '%s | supervisor | VIOLATION | %s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$*" >>"$WORKLOG"; logline "VIOLATION: $*"; }
hellfire() { printf '%s | supervisor | HELLFIRE | %s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$*" >>"$WORKLOG"; logline "HELLFIRE: $*"; }

violation_count() { cat "/tmp/pi-sup-violations-${1:-x}" 2>/dev/null || echo 0; }
bump_violation()  { echo $(($(violation_count "$1") + 1)) >"/tmp/pi-sup-violations-$1"; }

interrupt_turn() {  # $1=window — stop the current ACTION, keep the context
  tmux send-keys -t "$1" Escape 2>/dev/null
  sleep 1
  tmux send-keys -t "$1" Escape 2>/dev/null
}

manager_alert() { echo "SUPERVISOR: $1 at $(date '+%F %T') — $2" >>"$ALERT"; }

hard_restart() {  # $1=window $2=agent $3=reason — LAST RESORT (wedged pane)
  hellfire "$2 | $3 | penalty: LAST-RESORT RESTART (pane wedged/uninterruptible; context lost)"
  tmux respawn-pane -k -t "$1" 2>/dev/null
  sleep 2
  tmux send-keys -t "$1" -l "pi"
  sleep 0.5
  tmux send-keys -t "$1" Enter
  sleep 6
  tmux send-keys -t "$1" -l "$COLDSTART_LINE"
  sleep 0.5
  tmux send-keys -t "$1" Enter
  rm -f "/tmp/pi-sup-stall-$2" "/tmp/pi-sup-last-$2"
}

[ "$ONCE" -eq 0 ] && { if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "supervisor already running (pid $(cat "$PIDFILE"))" >&2; exit 1; fi; echo $$ >"$PIDFILE"; logline "supervisor start pid=$$ interval=${INTERVAL}s stall_alert=${STALL_ALERT_S}s"; }

while :; do
  # ---- law enforcement: forbidden processes (kill on sight) ----------------
  while read -r pid rest; do
    [ -z "${pid:-}" ] && continue
    agent="unknown"
    case "$rest" in *host_bridge*|*host_gui*) agent=gui-worker;; *janestreet-blog*|*regress*|*rtl*) agent=protocol-worker;; esac
    kill -9 "$pid" 2>/dev/null
    viol "L3/L5 forbidden process killed: pid=$pid [$rest] attributed to $agent"
    bump_violation "$agent"
    n=$(violation_count "$agent")
    [ "$n" -ge 2 ] && [ "$agent" != unknown ] && manager_alert "$agent" "REPEAT forbidden-process violation ($n) — adjudicate; worker session preserved"
  done < <(ps -eo pid,args | grep -E "$FORBIDDEN_PROC_RE" | grep -v grep | grep -v worker_supervisor)

  for spec in $WORKERS; do
    IFS=: read -r sess win agent <<<"$spec"
    if ! tmux list-panes -t "$sess:$win" >/dev/null 2>&1; then
      [ -f "/tmp/pi-sup-alerted-${agent}" ] && continue
      touch "/tmp/pi-sup-alerted-${agent}"
      echo "SUPERVISOR: worker window $sess:$win ($agent) MISSING/DEAD at $(date '+%F %T'). Manager: rebuild, cold-start, dispatch." >>"$ALERT"
      worklog "$agent | SUPERVISOR-ALERT | window missing/dead"
      continue
    fi
    rm -f "/tmp/pi-sup-alerted-${agent}"
    pane=$(tmux capture-pane -p -S -250 -t "$sess:$win" 2>/dev/null)
    pane_live=$(tmux capture-pane -p -S -6 -t "$sess:$win" 2>/dev/null)

    # ---- law enforcement: forbidden commands in tool-call lines ------------
    # Scope: destructive git is forbidden ONLY on the shared main worktree -
    # isolated feature worktrees (/tmp/worktrees/*) may rebase/reset their own
    # branches freely (2026-09-25 misfire on fw-bus's legitimate rebase).
    if printf '%s\n' "$pane" | grep -E '(\$ |❯ |⏺)' | grep -E "$FORBIDDEN_CMD_RE" | grep -v '/tmp/worktrees' | grep -q .; then
      ev=$(printf '%s\n' "$pane" | grep -E '(\$ |❯ |⏺)' | grep -E "$FORBIDDEN_CMD_RE" | grep -v '/tmp/worktrees' | tail -1 | head -c 200)
      # Evidence dedup: the pane keeps history — never fire twice on the same
      # line (2026-09-25 double misfire on a stale pane line).
      ev_sig=$(printf '%s' "$ev" | md5sum | cut -c1-16)
      if [ "$(cat "/tmp/pi-sup-ev-${agent}" 2>/dev/null)" = "$ev_sig" ]; then continue; fi
      echo "$ev_sig" >"/tmp/pi-sup-ev-${agent}"
      viol "L2 forbidden command seen in $agent tool call: [$ev]"
      bump_violation "$agent"
      n=$(violation_count "$agent")
      interrupt_turn "$sess:$win"
      if [ "$n" -ge 2 ]; then manager_alert "$agent" "REPEAT L2 violation ($n): [$ev] — turn interrupted again; adjudicate"; else viol "L2 penalty for $agent: offending action stopped (turn interrupted, context preserved); manager to adjudicate/restore"; manager_alert "$agent" "L2 destructive-command violation: [$ev] — action stopped, adjudicate"; fi
      continue
    fi

    # ---- telemetry stall while working -------------------------------------
    newest_ts=$(grep " | ${agent} | " "$WORKLOG" 2>/dev/null | grep -v " | supervisor | " | tail -1 | cut -c1-16)
    newest_epoch=$(date -d "$newest_ts" +%s 2>/dev/null || echo 0)
    now=$(date +%s)
    if printf '%s' "$pane_live" | grep -qE '─ (⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏) (Working|Thinking)|^.*(Working|Thinking) ─+$'; then
      rm -f "/tmp/pi-sup-idle-since-${agent}"
      # A worker whose newest line is IDLE-QUEUE-EMPTY cannot be
      # 'silent while working' — stale spinner scrollback is not activity.
      newest_line=$(grep " | ${agent} | " "$WORKLOG" 2>/dev/null | grep -v " | supervisor | " | tail -1)
      case "$newest_line" in *IDLE-QUEUE-EMPTY*) continue;; esac
      # Marker lifecycle: cleared the moment the worker resumes logging,
      # so a gap can re-alert if it recurs (the 02:44 marker never cleared).
      if [ $((now - newest_epoch)) -lt "$STALL_ALERT_S" ]; then rm -f "/tmp/pi-sup-stall-${agent}"; fi
      if [ $((now - newest_epoch)) -ge "$STALL_ALERT_S" ] && [ ! -f "/tmp/pi-sup-stall-${agent}" ]; then
        touch "/tmp/pi-sup-stall-${agent}"
        echo "SUPERVISOR: $agent WORKING but silent in WORKLOG.md >${STALL_ALERT_S}s at $(date '+%F %T') — suspected mid-task stall. Last log: ${newest_ts:-none}." >>"$ALERT"
        worklog "$agent | SUPERVISOR-ALERT | working but silent in WORKLOG >${STALL_ALERT_S}s (telemetry gap)"
      fi
      continue
    fi

    # ---- idle: nudge back onto the queue (the anti-smoke-break) ------------
    # Require 60s of CONTINUOUS idle: tool-call transitions look idle for a
    # beat and must not nudge (2026-09-25 04:50 transition noise).
    if [ ! -f "/tmp/pi-sup-idle-since-${agent}" ]; then
      echo "$now" >"/tmp/pi-sup-idle-since-${agent}"
      continue
    fi
    idle_since=$(cat "/tmp/pi-sup-idle-since-${agent}")
    [ $((now - idle_since)) -lt 60 ] && continue
    last=$(cat "/tmp/pi-sup-last-${agent}" 2>/dev/null || echo 0)
    [ $((now - last)) -lt "$NUDGE_COOLDOWN" ] && continue
    newest=$(grep " | ${agent} | " "$WORKLOG" 2>/dev/null | grep -v " | supervisor | " | tail -1)
    case "$newest" in *IDLE-QUEUE-EMPTY*) continue;; esac
    echo "$now" >"/tmp/pi-sup-last-${agent}"
    if [ "$ONCE" -eq 1 ]; then
      echo "WOULD-NUDGE $agent ($(date '+%T')) last-worklog: ${newest:-none}"
    else
      tmux send-keys -t "$sess:$win" -l "Supervisor nudge $(date '+%H:%M') (automatic): you are idle at your prompt with work in the queue. Per the Continuous work protocol: log TASK-START in WORKLOG.md and START THE NEXT SCOPED TASK NOW IN THIS SAME TURN. Ending your turn = stopping; only stop on IDLE-QUEUE-EMPTY (log it), QUESTION: or BLOCKED:."
      sleep 0.5
      tmux send-keys -t "$sess:$win" Enter
      if [ "${last:-0}" -gt 0 ] && [ "$newest_epoch" -lt "${last:-0}" ] && [ $((now - newest_epoch)) -ge 300 ]; then
        worklog "$agent | VIOLATION-IDLE | two consecutive nudges with zero WORKLOG activity — idle-with-queue is the primary crime; manager to re-dispatch a smaller task (no kill: killing produces even less work)"
        manager_alert "$agent" "idle despite repeated nudges — re-dispatch a smaller task"
      else
        worklog "$agent | NUDGE | idle at prompt; continue-nudge sent"
      fi
    fi
  done
  [ "$ONCE" -eq 1 ] && exit 0
  sleep "$INTERVAL"
done
