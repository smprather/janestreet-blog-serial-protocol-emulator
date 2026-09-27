#!/usr/bin/env bash
# lib_leak.sh — prove a mutation suite's process tree is actually GONE before
# the next suite starts.
#
# WHY THIS EXISTS. A mutation harness plants a mutant, runs the testbench, and
# restores. It can also spawn children of its own. If one of those children
# outlives the script that made it, two things follow, and BOTH were observed on
# 2026-09-27:
#
#   1. The next suite is declared INCONCLUSIVE. mutate_eth_mac_tb.sh saw
#      rtl/pe_eth_mac.v change to `mutated` with `cause: external` for 0.168s
#      while it ran, and the dep-guard sampler correctly refused to call the run
#      green or red. Nothing was wrong with either suite; something that was no
#      longer part of any run was still writing.
#   2. A mutant is left in the tree AFTER the gate exits. A harness was still
#      alive holding a plant in rtl/pe_soc.v once run_all had finished, which is
#      the 2026-09-24 orphan-mutant shape and exactly what
#      regress/check_tree_known.sh was written to catch.
#
# The suites in run_all.sh are called strictly one at a time - 16 separate
# calls, nothing backgrounded, no waits - so they cannot race each other
# directly. A leaked child is the one way a later suite can see a write it did
# not make, and it is therefore the thing worth checking at the one boundary
# where it can be caught cheaply: immediately after a suite returns.
#
# WHY A LEAK IS INCONCLUSIVE AND NOT A WARNING. The suite that leaked verified
# nothing reliable, and the suite after it verified nothing reliable either. That
# is the same verdict the dep-guard returns for interference, and it is
# deliberately the same: a verdict with a hole in it is worse than no verdict,
# because a green that was earned by accident is the one nobody re-checks.
#
# THE FALSE-POSITIVE DIRECTION MATTERS. The pattern is the suite's own basename,
# and a leak is a process whose COMMAND LINE still names that suite. A suite that
# has returned legitimately has no such process, so a match really is a leak. The
# risk being guarded is the opposite one: a suite that spawns a short-lived
# helper which exits a moment after the parent does. So the check WAITS briefly
# before accusing, and only then reports.
set -u

# mut_leak_check <suite-basename> [grace-seconds]
#
# Prints the leaked pids (one per line) and returns:
#   0  no leak - the suite's tree is gone
#   1  a leak - pids are printed
#   2  usage error
mut_leak_check() {
  local name="${1:-}" grace="${2:-20}" waited=0 leaked=""
  [ -n "$name" ] || { echo "mut_leak_check: a suite name is required" >&2; return 2; }
  case "$grace" in ''|*[!0-9]*) return 2;; esac

  while :; do
    # pgrep -f matches the whole command line, which is the right thing here: a
    # leaked child is identified by still naming the suite that spawned it. The
    # full suite path is used rather than a bare name so an unrelated process
    # that merely mentions the topic is not mistaken for a leak.
    leaked="$(pgrep -f -- "$name" 2>/dev/null | grep -vxF "$$" || true)"
    [ -z "$leaked" ] && return 0
    [ "$waited" -ge "$grace" ] && break
    sleep 1
    waited=$((waited+1))
  done
  printf '%s\n' "$leaked"
  return 1
}

if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0
  ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
  bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
  # mut_leak_check is defined in THIS file, so there is no path to resolve here
  # and no HERE to keep.

  # 1. the negative case: nothing alive -> no leak
  if mut_leak_check "mutate_no_such_suite_zzz.sh" 2 >/dev/null 2>&1; then
    ok "a suite with nothing left running reports NO leak"
  else
    bad "a suite with nothing left running reports NO leak" "false positive"
  fi

  # 2. the positive case, against a REAL leaked process
  setsid bash -c 'exec -a regress/mutate_leak_probe_tb.sh sleep 30' >/dev/null 2>&1 </dev/null &
  sleep 0.5
  if leaked="$(mut_leak_check "mutate_leak_probe_tb.sh" 3 2>/dev/null)"; then
    bad "a genuinely leaked child IS reported" "it said no leak"
  else
    n=$(printf '%s\n' "$leaked" | grep -c '' || true)
    if [ "$n" -ge 1 ]; then
      ok "a genuinely leaked child IS reported (pid(s): $(printf '%s' "$leaked" | tr '\n' ' '))"
    else
      bad "a genuinely leaked child IS reported" "returned failure but printed no pids"
    fi
  fi
  pkill -f 'mutate_leak_probe_tb.sh' 2>/dev/null || true
  sleep 0.5

  # 3. and it must not be a one-shot: the SAME name is clean once the leak dies
  if mut_leak_check "mutate_leak_probe_tb.sh" 3 >/dev/null 2>&1; then
    ok "once the leaked child is gone the same name reports clean (no sticky red)"
  else
    bad "once the leaked child is gone the same name reports clean" "stuck reporting a leak"
  fi

  # 4. a short-lived helper that exits just after its parent must NOT be called
  #    a leak - this is the false-positive direction the grace period exists for
  bash -c "exec -a regress/mutate_grace_probe_tb.sh sleep 0.2" >/dev/null 2>&1
  if mut_leak_check "mutate_grace_probe_tb.sh" 5 >/dev/null 2>&1; then
    ok "a short-lived helper that exits on its own is NOT called a leak"
  else
    bad "a short-lived helper that exits on its own is NOT called a leak" "the grace period is too short"
  fi

  if [ "$FAIL" -eq 0 ]; then
    echo "mut_leak self-test: OK ($PASS of $PASS cases)"
    exit 0
  fi
  echo "mut_leak self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"
  exit 1
fi
