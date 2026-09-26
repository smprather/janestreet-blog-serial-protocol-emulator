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

# The directory the harnesses are read from. A VARIABLE, not a literal, so the
# negative control below can drive THIS SCRIPT'S OWN RULES against synthetic
# harnesses in a sandbox. A self-test that re-implements the rules proves the
# copy, not the checker -- the same reason the orphan/byte cases in
# check_diagrams.sh run the real check_dir rather than a mock.
HARNESS_DIR="${HARNESS_DIR:-regress}"

self_test() {
  local sb results=0 caught=0
  sb=$(mktemp -d /tmp/hpf_selftest.XXXXXX) || return 1
  # FILE-SCOPE cleanup path, not a function-local: an EXIT trap fires at SCRIPT
  # exit, by which time a local is gone and the trap silently removes nothing.
  _HPF_SB="$sb"
  trap 'rm -rf "${_HPF_SB:?}"' EXIT

  mk() { # file, then body on stdin
    local f="$sb/$1"; shift
    { printf '#!/usr/bin/env bash\n'; cat; } > "$f"
    chmod +x "$f"
  }

  # (a) fully wired, non-empty MUTABLE, baseline declared -> must be CLEAN
  mk mutate_a_good.sh <<'EOF'
MUTABLE="rtl/pe_x.v"
chip_take_run_lock "$(basename "$0")"
chip_dep_expect pristine $MUTABLE
cleanup() { chip_dep_check "run_$(basename "$0")" || exit 4; }
EOF
  # (b) never takes the lock -> CAUGHT
  mk mutate_b_nolock.sh <<'EOF'
MUTABLE="rtl/pe_x.v"
chip_dep_expect pristine $MUTABLE
chip_dep_check "run_$(basename "$0")"
EOF
  # (c) no chip_dep_check on its exit path -> CAUGHT (a FALSE PASS is what that
  #     absence permits, so this is the rule the whole file exists for)
  mk mutate_c_nocheck.sh <<'EOF'
MUTABLE="rtl/pe_x.v"
chip_take_run_lock "$(basename "$0")"
chip_dep_expect pristine $MUTABLE
EOF
  # (d) THE RULE ADDED FOR THE SAMPLER: MUTABLE targets but no baseline
  #     declaration. Without this case the sampler rule is unproven, and its only
  #     proof would be a worker remembering to run a control by hand.
  mk mutate_d_nobaseline.sh <<'EOF'
MUTABLE="rtl/pe_x.v rtl/pe_y.v"
chip_take_run_lock "$(basename "$0")"
chip_dep_check "run_$(basename "$0")"
EOF
  # (e) the EXEMPTION: no MUTABLE targets means nothing to watch, so no
  #     declaration is required. A rule that fired here would be wrong, and this
  #     is the case that keeps the rule honest.
  mk mutate_e_nomutable.sh <<'EOF'
MUTABLE=""
chip_take_run_lock "$(basename "$0")"
chip_dep_check "run_$(basename "$0")"
EOF
  # (f) a second clean harness, so the corpus is the right shape for the count
  mk mutate_f_good.sh <<'EOF'
MUTABLE="rtl/pe_z.v"
chip_take_run_lock "$(basename "$0")"
chip_dep_expect pristine $MUTABLE
chip_dep_check "run_$(basename "$0")"
EOF

  plant() { # name expect harness
    local name="$1" expect="$2" only="$3"
    results=$((results + 1))
    if HARNESS_DIR="$sb" bash "${BASH_SOURCE[0]}" 2>/dev/null | grep -q "FAIL mutate_${only}"; then got=dirty; else got=clean; fi
    if [ "$expect" = "$got" ]; then
      printf '  ok:   self-test — %-44s expected %-5s, checker said %s\n' "$name" "$expect" "$got"
      caught=$((caught + 1))
    else
      printf '  FAIL: self-test — %-44s expected %-5s, checker said %s\n' "$name" "$expect" "$got"
    fi
  }

  echo "check_harness_preflight self-test:"
  plant "(a) a fully wired harness is clean"        clean a_good
  plant "(b) a harness that never takes the lock"    dirty b_nolock
  plant "(c) a harness with no chip_dep_check"       dirty c_nocheck
  plant "(d) MUTABLE targets but NO baseline"        dirty d_nobaseline
  plant "(e) empty MUTABLE is exempt and clean"      clean e_nomutable
  echo "check_harness_preflight self-test: $caught/$results cases behaved correctly"
  [ "$caught" -eq "$results" ]
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
esac

bad=0; n=0
for f in "$HARNESS_DIR"/mutate_*.sh; do
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
