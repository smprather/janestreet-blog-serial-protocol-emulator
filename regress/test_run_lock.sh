#!/usr/bin/env bash
# test_run_lock.sh — proves the run lock's process-tree contract, the failure
# mode that motivated it, and the paths that could break it.
#
# THE HAZARD THIS EXISTS FOR. flock releases when the holder dies, but the
# holder's children do not: they inherited fd 9, so the lock stays held AND a
# mutation harness keeps mutating and restoring RTL in a worktree that has
# moved on. Nothing in the tree is left to explain it, and the next run is
# refused for a lock nobody appears to be holding.
#
# The cases below are the ones that matter, and each is a real signal to a real
# process tree -- no mocking of kill, no simulated trap:
#   A  a second taker is REFUSED (exit 75) while a run holds the lock
#   B  SIGINT to the holder: its child dies, the lock frees, the note goes
#   C  SIGTERM to the holder: same
#   D  SIGKILL to the holder (no trap can run): the WATCHDOG cleans up
#   E  a normal exit leaves no strays and no note
#   F  a reentrant child (CHIP_RUN_LOCK_HELD) does not re-lock, and does not
#      kill its parent -- the mistake a naive trap would make
#   G  a background subshell inside a run does not fire the kill trap (the
#      BASHPID guard), so a run cannot shoot itself in the foot
#
# Every case runs against a private lock file, so this never touches the real
# per-worktree lock and can run while a real run is in flight.

set -u
# THIS GATE RUNS INSIDE run_all.sh, WHICH IS ITSELF A LOCK HOLDER. run_all.sh
# exports CHIP_RUN_LOCK_HELD and CHIP_RUN_ISOLATED, so a test that inherits
# them inherits a lock it does not hold and an isolation it has not done: every
# case then passes through the acquire path, never takes the lock, and its
# "children survive" failures are the test's own leaked environment rather than
# a defect in the lock. (It did exactly that the first time this gate ran from
# the suite: 11 passed, 5 failed, all five explained by the inheritance.) Clear
# every variable the lock uses, so the cases exercise the real acquire path.
unset CHIP_RUN_LOCK_HELD CHIP_RUN_ISOLATED CHIP_RUN_WATCHDOG \
      CHIP_RUN_LOCK_OWNER_BASHPID CHIP_RUN_WATCHDOG_PID

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/run_lock.sh"

WORK="$(mktemp -d /tmp/run-lock-test.XXXXXX)"
RUNNER_PID=""
RUNNER_LOG=""
cleanup() {
  [ -n "$RUNNER_PID" ] && kill -KILL "$RUNNER_PID" 2>/dev/null
  # Nothing this test starts may outlive it -- the very rule it is testing. Match
  # on this run's own work directory, never a broad pattern: a stray kill aimed
  # at "anything that looks like a runner" is how a test harness takes down the
  # box it is running on.
  local p
  for p in $(ps -eo pid=,args= 2>/dev/null | grep -F "$WORK/" | grep -v grep | awk '{print $1}'); do
    kill -KILL "$p" 2>/dev/null
  done
  if [ "${RUN_LOCK_TEST_KEEP:-0}" = "1" ]; then
    echo "  (work dir kept: $WORK)"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# Every failure shows the runner's own output. A lock test that fails without
# saying what the locked process printed is a lock test you cannot debug.
show_log() {
  [ -s "$RUNNER_LOG" ] || return 0
  printf '      --- %s ---\n' "$(basename "$RUNNER_LOG")"
  sed 's/^/      /' "$RUNNER_LOG" | tail -8
}

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

CASE=""

# A stand-in for run_all.sh: takes the lock, starts a child that would happily
# keep "mutating" forever, then does whatever the case tells it to.
write_runner() {
  # @WORK@ in a case body becomes this run's work directory. The body is
  # inserted verbatim, so $WORK inside it would arrive UNEXPANDED and die on
  # `set -u` in the runner -- which is exactly what happened the first time.
  local body="${1//@WORK@/$WORK}"
  cat > "$WORK/runner.sh" <<EOF
#!/usr/bin/env bash
set -u
export CHIP_RUN_LOCK_FILE="$WORK/$CASE.lock"
export CHIP_RUN_OWNER_FILE="$WORK/$CASE.owner"
export CHIP_RUN_WATCHDOG=1
. "$HERE/run_lock.sh"
chip_take_run_lock "test:$CASE"
# The mutating child: a heartbeat that must stop when the run does. \$BASHPID,
# not \$\$: inside a subshell \$\$ is still the PARENT's pid, which would name the
# heartbeat after the runner and make every liveness check meaningless.
( trap '' TERM INT HUP
  while :; do echo x >> "$WORK/heartbeat.\$BASHPID"; sleep 0.05; done
) &
echo \$! > "$WORK/child.$CASE"
$body
EOF
  chmod +x "$WORK/runner.sh"
}

# Alive == the heartbeat is still GROWING. A missing heartbeat is NOT "alive"
# and NOT "dead": it means the child never started, so the case is vacuous and
# has to fail rather than pass quietly.
heartbeat_state() {   # -> growing | still | silent
  local f="$WORK/heartbeat.$1" a b
  if [ ! -e "$f" ]; then echo silent; return; fi
  a=$(wc -c < "$f")
  sleep 0.7
  b=$(wc -c < "$f")
  if [ "$b" -gt "$a" ]; then echo growing; else echo still; fi
}

lock_free() {
  CHIP_RUN_LOCK_FILE="$WORK/$CASE.lock" \
  CHIP_RUN_OWNER_FILE="$WORK/$CASE.probe.owner" \
  CHIP_RUN_WATCHDOG=0 \
  bash -c ". '$HERE/run_lock.sh'; chip_take_run_lock probe" 2>/dev/null
}

# The contract is "the lock frees when the holder dies", not "instantly", so
# allow a bounded settle before calling it a leak.
lock_frees_within() {   # seconds
  local limit="${1:-3}" waited=0
  while [ "$waited" -lt $((limit * 10)) ]; do
    lock_free && return 0
    sleep 0.1; waited=$((waited + 1))
  done
  return 1
}

start_case() {
  CASE="$1"; shift
  rm -f "$WORK/heartbeat."* "$WORK/child."* "$WORK/$CASE.lock" \
        "$WORK/$CASE.owner"
  write_runner "$*"
  RUNNER_LOG="$WORK/$CASE.log"
  setsid bash "$WORK/runner.sh" > "$RUNNER_LOG" 2>&1 &
  RUNNER_PID=$!
  local waited=0
  while [ ! -s "$WORK/child.$CASE" ] && [ "$waited" -lt 60 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  if [ ! -s "$WORK/child.$CASE" ]; then
    bad "$CASE: the runner never started its child"
    show_log
    return 1
  fi
  # Give the heartbeat one write so "still" means "was alive".
  sleep 0.2
  return 0
}

stop_case() {
  [ -n "$RUNNER_PID" ] && kill -KILL "$RUNNER_PID" 2>/dev/null
  wait "$RUNNER_PID" 2>/dev/null
  RUNNER_PID=""
}

echo "run_lock process-tree contract"

# ---- A: a second taker is refused while a run holds the lock --------------
if start_case refuse 'sleep 30'; then
  if CHIP_RUN_LOCK_FILE="$WORK/refuse.lock" \
     CHIP_RUN_OWNER_FILE="$WORK/refuse.probe.owner" \
     CHIP_RUN_WATCHDOG=0 \
     bash -c ". '$HERE/run_lock.sh'; chip_take_run_lock second" \
       > "$WORK/refuse.second.log" 2>&1; then
    bad "A: a second run was allowed to start while the lock was held"
  else
    rc=$?
    if [ "$rc" -eq 75 ] && grep -q "REFUSING TO START" "$WORK/refuse.second.log"; then
      ok "A: second taker refused (exit 75, names the holder)"
    else
      bad "A: refused with exit $rc, wanted 75"
    fi
  fi
  stop_case
  sleep 0.5
fi

# ---- B/C/D: a signal to the holder must take its child with it ------------
for sig in INT TERM KILL; do
  if start_case "sig$sig" 'sleep 30'; then
    child=$(cat "$WORK/child.sig$sig")
    kill "-$sig" "$RUNNER_PID" 2>/dev/null
    wait "$RUNNER_PID" 2>/dev/null
    RUNNER_PID=""
    sleep 0.6
    case "$(heartbeat_state "$child")" in
      growing) bad "$sig: the run's child SURVIVED the holder (the leak)" ;;
      silent)  bad "$sig: the child never ran, so the case proves nothing" ;;
      still)   ok "$sig: holder's child died with it" ;;
    esac
    if lock_frees_within 3; then ok "$sig: the lock is free again"
    else bad "$sig: the lock is STILL held after the holder died"; fi
    if [ -e "$WORK/sig$sig.owner" ]; then
      bad "$sig: the holder note survived"
    else
      ok "$sig: the holder note is gone"
    fi
  fi
done

# ---- E: a normal exit leaves nothing behind -------------------------------
if start_case normal 'exit 0'; then
  child=$(cat "$WORK/child.normal")
  wait "$RUNNER_PID" 2>/dev/null
  RUNNER_PID=""
  sleep 0.4
  case "$(heartbeat_state "$child")" in
    growing) bad "E: a cleanly finished run left its child running" ;;
    silent)  bad "E: the child never ran, so the case proves nothing" ;;
    still)   ok "E: a clean exit leaves no strays" ;;
  esac
  if lock_frees_within 3; then ok "E: the lock is free after a clean exit"
  else bad "E: the lock is still held after a clean exit"; fi
  if [ -e "$WORK/normal.owner" ]; then
    bad "E: the holder note survived a clean exit"
  else
    ok "E: no holder note after a clean exit"
  fi
fi

# ---- F: a reentrant child neither re-locks nor kills its parent -----------
if start_case reentrant 'sleep 0.5; kill -0 $$ && touch @WORK@/reentrant.ok; sleep 0.3'; then
  wait "$RUNNER_PID" 2>/dev/null
  RUNNER_PID=""
  if grep -q "REFUSING" "$RUNNER_LOG" 2>/dev/null; then
    bad "F: a reentrant child tried to take the lock its parent holds"
    show_log
  else
    ok "F: a reentrant child passes through the lock"
  fi
  if [ -e "$WORK/reentrant.ok" ]; then
    ok "F: the reentrant child's cleanup left its parent running"
  else
    bad "F: the reentrant child's cleanup killed its parent"
    show_log
  fi
fi

# ---- G: a background subshell must not fire the kill trap -----------------
# A naive implementation installs this trap: a subshell inherits EXIT, $$ is
# the same pid inside it, and finishing it would kill the whole run.
# `wait` with no arguments waits for EVERY background job -- including the
# heartbeat child, which never ends. Wait for the three subshells by pid.
if start_case subshell 'pids=""; for i in 1 2 3; do ( true ) & pids="$pids $!"; done; wait $pids; sleep 0.3; touch @WORK@/subshell.ok; sleep 0.3'; then
  wait "$RUNNER_PID" 2>/dev/null
  RUNNER_PID=""
  if [ -e "$WORK/subshell.ok" ]; then
    ok "G: background subshells do not fire the run's kill trap"
  else
    bad "G: a background subshell fired the kill trap and took the run down"
    show_log
  fi
fi

printf 'run_lock: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
