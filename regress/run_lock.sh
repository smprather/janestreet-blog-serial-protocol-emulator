#!/usr/bin/env bash
# run_lock.sh — the single-run lock for this worktree. SOURCE this, do not
# execute it.
#
# WHY (the 2026-09-25 incident). This worktree is SHARED. The manager's
# run_all_merge and the worker's run_all were invoked CONCURRENTLY, so two
# mutation harnesses were mutating and restoring the same RTL at the same time.
# The per-case cmp-verified restores held, so nothing was corrupted — but a
# run can transiently read a file another run has mutated, which is exactly the
# "nonsense result" failure mode every mutation harness exists to detect. The
# per-case restore is a correctness net, NOT a concurrency guard: it restores
# to the snapshot the run started from, and two runs starting from different
# states will fight over the file.
#
# THE CONTRACT. One mutation-capable run per worktree at a time. The lock is
# advisory and process-based (flock): if the holder dies, the kernel releases
# it, so there is no stale lock to clean up by hand.
#
# FAIL FAST, do not queue. A queued run would sit waiting with a snapshot of
# the tree taken at queue time and then start mutating against a tree that
# moved on underneath it. Refusing is louder and safer, and the message says
# what to do instead.
#
# REENTRANCY. run_all.sh invokes the mutation harnesses, so the harnesses must
# NOT try to take a lock their own parent already holds. run_all.sh exports
# CHIP_RUN_LOCK_HELD; a child that sees it skips the lock and runs.
#
# THE LOCK HOLDER OWNS ITS PROCESS TREE (2026-09-25, second incident). flock
# releases when the HOLDER dies, but the holder's CHILDREN do not die with it:
# they are separate processes that inherited fd 9, so the lock stays held, and a
# mutation harness that outlives its run_all keeps MUTATING and restoring RTL in
# a tree that has moved on — the exact hazard above, with no run left to explain
# it. A trap cannot fix the SIGKILL case (the OOM killer is real on this box), so
# there are two mechanisms:
#
#   1. ISOLATION + TRAP. The holder puts itself in its own process group
#      (setsid, or the group job control already gave it) and kills that group
#      on EXIT/INT/TERM. Anything the run started dies with the run.
#   2. A WATCHDOG, a detached child that polls `kill -0 <holder>` and cleans up
#      the group when the holder is gone WHATEVER killed it.
# Both are scoped to the run's own process group: if this shell is not a group
# leader the group is not ours to kill, and the fallback walks DESCENDANTS
# instead, so a run can never take down the shell (or the manager) that started
# it. regress/test_run_lock.sh proves all of it, including the SIGKILL case.
#
# Usage:
#   . "$(dirname "$0")/run_lock.sh"        # from a script in regress/
#   chip_take_run_lock "run_all.sh"        # or the absolute path
# Exits non-zero (75) with a message when another run holds the lock.

# Sourcing captures the caller's identity, because a function cannot see the
# script's own positional parameters -- and the isolation re-exec below needs
# both to restart the caller verbatim.
CHIP_RUN_SCRIPT="$0"
if [ "${CHIP_RUN_SCRIPT%/*}" = "$CHIP_RUN_SCRIPT" ]; then
  case "$CHIP_RUN_SCRIPT" in
    */*) CHIP_RUN_SCRIPT="./$CHIP_RUN_SCRIPT" ;;
    *)   CHIP_RUN_SCRIPT="$(command -v "$CHIP_RUN_SCRIPT" 2>/dev/null || printf './%s' "$CHIP_RUN_SCRIPT")" ;;
  esac
fi
CHIP_RUN_SCRIPT_ARGS=("$@")

# PER-WORKTREE by default (2026-09-25, parallel workers): concurrent runs in
# DIFFERENT worktrees are safe (disjoint files); the hazard is concurrent runs
# in the SAME worktree, which is what this lock exists for.
_wt=$(git rev-parse --show-toplevel 2>/dev/null | md5sum | cut -c1-8)
CHIP_RUN_LOCK_FILE="${CHIP_RUN_LOCK_FILE:-/tmp/chip-run-all.${_wt:-shared}.lock}"
CHIP_RUN_OWNER_FILE="${CHIP_RUN_OWNER_FILE:-/tmp/chip-run-all.${_wt:-shared}.owner}"

# The pids this run owns, and nothing else.
#
# Group-first: the holder puts itself in its own group, and every child inherits
# it, so one list covers the whole tree INCLUDING children that were reparented
# to init after an intermediate process died (they keep their process group,
# which is why the group and not the parent chain is the right thing to kill).
#
# Descendant fallback: if this shell is NOT a group leader then its group also
# contains whoever started it -- the manager's shell, a tmux pane, a CI job --
# and killing that group would be a disaster. So in that case walk the child
# chain instead. It misses reparented orphans, which is why isolation is worth
# having; it is the safe degradation, not the good path.
chip_run_pgid() {
  ps -o pgid= -p "${BASHPID:-$$}" 2>/dev/null | tr -d ' '
}

chip_run_tree_pids() {
  local pgid me
  me="${BASHPID:-$$}"
  pgid=$(chip_run_pgid)
  if [ -n "$pgid" ] && [ "$pgid" = "$me" ]; then
    ps -eo pid=,pgid= 2>/dev/null | awk -v g="$pgid" '$2==g {print $1}'
  else
    _chip_descendants "$me"
  fi
}

_chip_descendants() {
  local parent="$1" kid
  for kid in $(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$parent" '$2==p {print $1}'); do
    printf '%s\n' "$kid"
    _chip_descendants "$kid"
  done
}

# Signal everything the run owns, never this process, and escalate to KILL for
# whatever ignores the polite signal (a wedged iverilog does).
chip_signal_run_tree() {
  local sig="$1" p me left waited
  me="${BASHPID:-$$}"
  for p in $(chip_run_tree_pids); do
    [ "$p" = "$me" ] && continue
    kill "-$sig" "$p" 2>/dev/null
  done
  [ "$sig" = "KILL" ] && return 0
  for waited in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    left=0
    for p in $(chip_run_tree_pids); do
      [ "$p" = "$me" ] && continue
      left=1
    done
    [ "$left" -eq 0 ] && return 0
    sleep 0.1
  done
  chip_signal_run_tree KILL
}

# The cleanup the lock holder runs on EXIT/INT/TERM.
#
# The BASHPID guard is load-bearing, not decoration: a subshell inherits the
# EXIT trap, and $$ is the SAME pid inside a subshell, so without this a
# `( ... )` or a `cmd &` finishing anywhere in a 900-line run would fire the
# trap and kill the entire run's process group out from under it.
chip_kill_run_tree() {
  [ "${CHIP_RUN_LOCK_OWNER_BASHPID:-}" = "${BASHPID:-}" ] || return 0
  [ -n "${CHIP_RUN_LOCK_HELD:-}" ] || return 0
  CHIP_RUN_LOCK_HELD=
  chip_signal_run_tree TERM
  rm -f "$CHIP_RUN_OWNER_FILE" 2>/dev/null || true
}

_chip_lock_on_signal() {
  local sig="$1" rc=143
  [ "$sig" = "INT" ] && rc=130
  chip_kill_run_tree
  rm -f "$CHIP_RUN_OWNER_FILE" 2>/dev/null || true
  trap - INT TERM EXIT
  exit "$rc"
}

# The SIGKILL cover. A trap cannot run when the kernel takes the process, and
# this box has an OOM history, so the holder leaves behind a watcher that polls
# for its own death and does the cleanup the trap could not. It closes the lock
# descriptor on the way in, so it never becomes the reason a lock is still held.
chip_start_lock_watchdog() {
  [ "${CHIP_RUN_WATCHDOG:-1}" = "1" ] || return 0
  local holder="$$"
  (
    trap '' EXIT INT TERM HUP
    # Drop the lock descriptor BEFORE anything else. The watchdog exists to
    # outlive the holder, and fd 9 is inherited, so keeping it would mean the
    # LOCK stays held for as long as the watchdog lives -- the exact "refused
    # for a lock nobody is holding" symptom, just with a cause. Only the run's
    # real processes should hold it.
    exec 9>&-
    # Capture the geometry NOW, while the holder is still alive to ask about.
    # Afterwards there is nothing left to ask: a dead pid is just a number, and
    # a subshell's $$ is the dead HOLDER's pid, so the group has to be recorded
    # up front or the cleanup below degrades into a silent no-op.
    local group
    group=$(ps -o pgid= -p "$holder" 2>/dev/null | tr -d ' ')
    while kill -0 "$holder" 2>/dev/null; do sleep 0.25; done
    if [ -z "$group" ] || [ "$group" != "$holder" ]; then
      # The holder was not a group leader, so its group also belongs to whoever
      # started it (a manager's shell, a CI job). Not ours to kill.
      exit 0
    fi
    # The holder is gone by every route. Kill its group, minus ourselves.
    local p me
    me="${BASHPID:-$$}"
    for p in $(ps -eo pid=,pgid= 2>/dev/null | awk -v g="$group" '$2==g {print $1}'); do
      [ "$p" = "$me" ] && continue
      kill -TERM "$p" 2>/dev/null
    done
    sleep 0.2
    for p in $(ps -eo pid=,pgid= 2>/dev/null | awk -v g="$group" '$2==g {print $1}'); do
      [ "$p" = "$me" ] && continue
      kill -KILL "$p" 2>/dev/null
    done
    rm -f "$CHIP_RUN_OWNER_FILE" 2>/dev/null || true
  ) &
  CHIP_RUN_WATCHDOG_PID=$!
}

# Put the run in its own process group so "kill everything this run started"
# cannot reach the shell that started it. Idempotent, and a no-op when job
# control already made this process a group leader (the interactive-shell case,
# where the group is provably ours alone).
chip_isolate_run_group() {
  [ -n "${CHIP_RUN_ISOLATED:-}" ] && return 0
  CHIP_RUN_ISOLATED=1
  export CHIP_RUN_ISOLATED

  local pgid
  pgid=$(chip_run_pgid)
  if [ -n "$pgid" ] && [ "$pgid" = "${BASHPID:-$$}" ]; then
    return 0
  fi
  # The re-exec needs a SCRIPT to re-run. `$0` is not always one: sourced from
  # `bash -c` it is the bash BINARY, and blindly execing that asks a shell to
  # execute an ELF file (exit 126, and the caller has lost its lock-holding
  # process mid-run). A shebang is the test that tells them apart.
  if [ ! -r "$CHIP_RUN_SCRIPT" ] || \
     [ "$(head -c 2 "$CHIP_RUN_SCRIPT" 2>/dev/null)" != "#!" ]; then
    echo "run_lock: \$0 ($CHIP_RUN_SCRIPT) is not a re-runnable script;" \
         "skipping process-group isolation" >&2
    return 0
  fi
  if ! command -v setsid >/dev/null 2>&1; then
    echo "run_lock: no setsid; process-group cleanup falls back to the child" \
         "chain (a reparented mutator would survive a SIGKILL)" >&2
    return 0
  fi
  # exec, not a subshell: the run must BECOME the isolated process, so signals
  # aimed at the pid the caller knows keep working and the exit status is the
  # script's own. stdin from /dev/null because the new session has no
  # controlling terminal, and a read would be SIGTTIN (a stop, i.e. a hang).
  exec setsid bash "$CHIP_RUN_SCRIPT" \
    ${CHIP_RUN_SCRIPT_ARGS[@]+"${CHIP_RUN_SCRIPT_ARGS[@]}"} < /dev/null
}

chip_take_run_lock() {
  local who="${1:-$(basename "$0")}"

  # Already inside a run that holds the lock (run_all -> mutate_*.sh): pass
  # through. The lock FD is inherited, so the kernel view stays consistent, and
  # the child must NOT install a second watchdog or a second kill trap -- it
  # would take the whole run down with it.
  if [ -n "${CHIP_RUN_LOCK_HELD:-}" ]; then
    return 0
  fi

  # Before the lock, so the isolation re-exec cannot leave a half-taken lock.
  chip_isolate_run_group

  # fd 9 is inherited by children, which is what makes the check above honest.
  eval "exec 9>\"\$CHIP_RUN_LOCK_FILE\"" || {
    echo "$who: FATAL: cannot open the run lock $CHIP_RUN_LOCK_FILE" >&2
    exit 75
  }

  if ! flock -n 9; then
    echo "$who: REFUSING TO START — another run already holds $CHIP_RUN_LOCK_FILE." >&2
    echo "  This worktree is shared, and concurrent runs would mutate and" >&2
    echo "  restore the same RTL at once. Wait for the other run to finish" >&2
    echo "  (the lock releases by itself if that run dies), then start." >&2
    if [ -r "$CHIP_RUN_OWNER_FILE" ]; then
      echo "  current holder: $(cat "$CHIP_RUN_OWNER_FILE" 2>/dev/null)" >&2
    fi
    exit 75
  fi

  # Record who holds it, purely for the refusal message above. The file is
  # a NOTE, not the lock: correctness comes from flock on the descriptor. It
  # is removed on release, and because a killed run cannot run its own trap,
  # chip_take_run_lock overwrites any stale note on acquire.
  printf '%s pid=%s started=%s\n' "$who" "$$" "$(date '+%F %T %Z')" \
    > "$CHIP_RUN_OWNER_FILE" 2>/dev/null || true

  CHIP_RUN_LOCK_HELD=1
  export CHIP_RUN_LOCK_HELD
  CHIP_RUN_LOCK_OWNER_BASHPID="$BASHPID"
  export CHIP_RUN_LOCK_OWNER_BASHPID

  chip_start_lock_watchdog
  # A caller that installs its own EXIT trap afterwards (most of them do, to
  # restore mutated sources) overrides this one; that is fine, because
  # chip_release_run_lock -- which run_all.sh's trap calls -- does the same
  # cleanup, and the watchdog covers the cases no trap can.
  trap 'chip_kill_run_tree' EXIT
  trap '_chip_lock_on_signal INT' INT
  trap '_chip_lock_on_signal TERM' TERM
  return 0
}

# Release: take the run's tree down first, so nothing it started can still be
# mutating RTL, then drop the note and let the fd close with the process. The
# trap in each caller restores sources; this kills what is still running.
chip_release_run_lock() {
  chip_kill_run_tree
  rm -f "$CHIP_RUN_OWNER_FILE" 2>/dev/null || true
}
