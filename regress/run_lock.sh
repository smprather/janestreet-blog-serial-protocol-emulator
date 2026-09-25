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
# Usage:
#   . "$(dirname "$0")/run_lock.sh"        # from a script in regress/
#   chip_take_run_lock "run_all.sh"        # or the absolute path
# Exits non-zero (75) with a message when another run holds the lock.

CHIP_RUN_LOCK_FILE="${CHIP_RUN_LOCK_FILE:-/tmp/chip-run-all.lock}"

chip_take_run_lock() {
  local who="${1:-$(basename "$0")}"

  # Already inside a run that holds the lock (run_all -> mutate_*.sh): pass
  # through. The lock FD is inherited, so the kernel view stays consistent.
  if [ -n "${CHIP_RUN_LOCK_HELD:-}" ]; then
    return 0
  fi

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
    if [ -r /tmp/chip-run-all.owner ]; then
      echo "  current holder: $(cat /tmp/chip-run-all.owner 2>/dev/null)" >&2
    fi
    exit 75
  fi

  # Record who holds it, purely for the refusal message above. The file is
  # a NOTE, not the lock: correctness comes from flock on the descriptor. It
  # is removed on release, and because a killed run cannot run its own trap,
  # chip_take_run_lock overwrites any stale note on acquire.
  printf '%s pid=%s started=%s\n' "$who" "$$" "$(date '+%F %T %Z')" \
    > /tmp/chip-run-all.owner 2>/dev/null || true

  CHIP_RUN_LOCK_HELD=1
  export CHIP_RUN_LOCK_HELD
  return 0
}

# Release: drop the marker file and let the fd close with the process. The
# trap in each caller restores sources; this only cleans up the note.
chip_release_run_lock() {
  if [ -n "${CHIP_RUN_LOCK_HELD:-}" ]; then
    rm -f /tmp/chip-run-all.owner 2>/dev/null || true
  fi
}
