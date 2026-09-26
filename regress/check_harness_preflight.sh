#!/usr/bin/env bash
# check_harness_preflight.sh — every mutation harness must be covered by the
# harness-edit pre-flight, and the coverage must be ASSERTED rather than
# remembered.
#
# WHY THIS EXISTS. regress/dep_guard.sh stops a run reporting a verdict from
# scripts that changed underneath it: bash reads a script INCREMENTALLY, so a
# harness edited mid-run can report a FALSE PASS as easily as a false failure,
# and a false pass is believed — the worst thing a gate in this project can do.
# The guard was wired into all sixteen mutation harnesses on 2026-09-25.
#
# Nothing asserted that. The wiring was correct on the day it was written, which
# is not a property: the next person to add a seventeenth harness gets one that
# takes the run lock, is therefore stamped, and is never checked — so a mid-run
# edit to it yields a verdict nobody can trust, with nothing anywhere saying so.
# That is the same drift regress/check_mutation_lists.sh exists to stop for the
# MUTABLE lists, where a missing entry made the merge gate SKIP a suite guarding a
# changed file. This file is the same guard for the pre-flight's own coverage.
#
# WHAT IS REQUIRED OF A HARNESS, and why both halves:
#   * it CALLS chip_take_run_lock — that is where the STAMP is taken, so a harness
#     that does not take the lock is never stamped and can never be checked;
#   * it CARRIES a chip_dep_check on its own exit path — the check cannot live in
#     run_lock.sh, because every harness sets its own `trap cleanup EXIT` after
#     sourcing that file and a second EXIT trap REPLACES the first, which would
#     discard it silently.
# And of the shared helper itself: run_lock.sh must source dep_guard.sh, and
# chip_take_run_lock must stamp. A harness can be perfectly wired and still
# unprotected if either of those is removed.
set -u
cd "$(dirname "$0")/.." || exit 1

bad=0; n=0
for f in regress/mutate_*.sh; do
  n=$((n + 1))
  h=$(basename "$f")
  if ! grep -q 'chip_take_run_lock' "$f"; then
    echo "FAIL $h: never calls chip_take_run_lock, so it is never STAMPED"
    bad=$((bad + 1))
  fi
  if ! grep -q 'chip_dep_check' "$f"; then
    echo "FAIL $h: carries no chip_dep_check, so a mid-run edit to it could report a FALSE PASS"
    echo "     add it to the harness's own exit path (its cleanup(), or a chained EXIT trap)"
    bad=$((bad + 1))
  fi
  # THE DECLARATION PROTOCOL. chip_dep_check compares a target's content at the
  # START of a run with its content at the END, so it cannot see an external
  # actor who RESTORES a target mid-run -- the 2026-09-25 incident. The sampler
  # closes that, and the sampler works by COMPARING what it sees against what
  # the harness DECLARED. A harness that never declares anything is therefore not
  # "unprotected but fine", it is a harness whose targets are watched by nothing
  # while the guard reports coverage it does not have: sample_stop names every
  # undeclared target, so the omission is loud rather than silent, but the whole
  # point of a pre-flight is to catch it BEFORE a run does.
  #
  # Only the BASELINE declaration is required here, and requiring nothing more is
  # deliberate. A static rule that tried to prove each harness declares "mutated"
  # at every write would have to guess which files a case touches, and a rule
  # that guesses is how mutate_i2c_tb.sh briefly declared all five MUTABLE
  # targets mutated when each of its cases changes exactly one. The baseline is
  # checkable from the text; the rest is checkable only by RUNNING the harness,
  # which is what the self-test in regress/test_dep_guard.sh and a real suite
  # run do. A harness with no MUTABLE targets has nothing to watch, so the rule
  # does not apply to it -- mutate_macro_flow_config.sh publishes MUTABLE="".
  _mut=$(grep -m1 '^MUTABLE=' "$f" | cut -d'"' -f2)
  if [ -n "$_mut" ]; then
    if ! grep -q 'chip_dep_expect pristine' "$f"; then
      echo "FAIL $h: has MUTABLE targets but never declares their baseline state"
      echo "     add 'chip_dep_expect pristine \$MUTABLE' where the pristine snapshot is taken."
      echo "     Without it the sampler watches files nobody has claimed, and sample_stop"
      echo "     will report this harness's targets as never DECLARED."
      bad=$((bad + 1))
    fi
  fi
done

# The shared end of the chain. Without these, every harness above is protected by
# nothing no matter how correctly it is wired.
if ! grep -q 'dep_guard\.sh' regress/run_lock.sh; then
  echo "FAIL run_lock.sh: does not source dep_guard.sh, so no harness gets the functions"
  bad=$((bad + 1))
fi
if ! awk '/^chip_take_run_lock\(\)/,/^\}/' regress/run_lock.sh | grep -q 'chip_dep_stamp'; then
  echo "FAIL run_lock.sh: chip_take_run_lock does not STAMP, so every harness is unstamped"
  bad=$((bad + 1))
fi

# The count is printed for the same reason check_shell_syntax.sh prints it: a
# check that silently covered nothing looks exactly like one that passed.
if [ "$n" -lt 5 ]; then
  echo "check_harness_preflight: only $n harness(es) found — expected the whole regress/ set" >&2
  exit 1
fi
if [ "$bad" -ne 0 ]; then
  echo "check_harness_preflight: $bad problem(s) across $n harnesses — an unprotected harness is a false pass waiting to happen"
  exit 1
fi
echo "check_harness_preflight: $n harnesses, every one stamped by the lock and checked on its own exit path"
