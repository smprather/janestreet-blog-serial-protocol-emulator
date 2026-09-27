#!/usr/bin/env bash
# tier.sh — the verification ladder. Match the gate to the change.
#
# WHY THIS EXISTS. Measured on 2026-09-27, the box spent its time like this:
# 20 completed full gates (TOTAL 47 PASS 47 FAIL 0) and roughly a dozen ABORTED
# ones - five died at 4 of 15 mutation suites, six at 13 of 15. An aborted gate
# has spent its whole budget and returned no verdict, and on a 24-core box that
# is 20 minutes the user does not get back. Meanwhile the defects actually being
# found that day were overwhelmingly PROCESS - broken wiki links, doc-index
# drift, tools that counted cases they never ran, a run-lock case that could not
# pass where it actually runs - none of which needs 47 testbenches and 16
# mutation suites to detect.
#
# So the problem was never that the checks are slow. Individual checks are cheap:
# testbenches are seconds, formal peaks under 1GB, and --fast is already
# concurrency (a Verilator swap was measured at 69.6x SLOWER, so it is not the
# lever it looks like). The problem was a UNIFORM 20-minute gate applied to a
# wildly non-uniform change stream. A wiki-link fix does not need the full gate.
#
# THE THREE TIERS
#
#   T0  seconds   Every edit, unscheduled, never needs a window. The fast
#                 self-tests and checkers. This is where the process defects
#                 live, and it is cheap enough to run without thinking.
#   T1  1-3 min   Every CODE edit. The slow self-tests, plus the affected
#                 testbench set only - verify_merge.sh already computes that
#                 mapping and run_all.sh --cases=REGEX already consumes it.
#   T2  20-30 min NAMED GATES ONLY: before a merge to main, at a closeout, or
#                 before any claim in a review. The full gate, and it REFUSES
#                 to start unless the window is actually clear.
#
# T2 refusing is the whole point. On 2026-09-27 a verify_merge gate ran in the
# main worktree at the same time as a live mutation harness holding a planted
# mutant, so it measured whatever the tree happened to contain and printed a
# verdict anyway. A warning is not enough: on a weak box a wrongly-started
# 20-minute gate is 20 minutes you do not get back. --force exists, and it says
# out loud that it was forced.
#
# HONEST COUNTING. The check list below is DECLARED and the count is verified
# against what actually ran. This repo has been bitten twice by self-tests that
# reported "N of N" for cases they never executed, so a summary line that cannot
# be wrong is part of the point, not decoration.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || { echo "tier.sh: cannot enter $REPO" >&2; exit 2; }
# The shared dirty-classification rule, so this gate and the merge gate can never
# disagree about what counts as substantive dirt. See regress/lib_dirty.sh for
# why that disagreement is the dangerous direction.
# shellcheck source=regress/lib_dirty.sh
. "$REPO/regress/lib_dirty.sh"

# ---- T0: the fast gate. Declared, not discovered, so it cannot silently shrink.
T0=(
  "regress/check_shell_syntax.sh"
  "regress/check_tree_known.sh"
  "regress/check_staged_mutants.sh"
  "regress/check_doc_index.sh"
  "regress/check_wiki_links.sh"
  "regress/check_harness_preflight.sh"
  "regress/check_run_environment.sh"
  "regress/check_mutation_lists.sh"
  "regress/test_vvp_run.sh"
  "regress/test_check_tree_known.sh"
  "tools/manager/test_agent_tag.sh"
  "tools/manager/test_pe_forbidden_sweep.sh"
)
# ---- T1: the slow self-tests. Everything that compiles something or walks the
# whole tree, so it does not belong in a gate you run on every keystroke.
T1_SELF=(
  "regress/test_run_lock.sh"
  "regress/test_dep_guard.sh"
  "regress/test_check_wiki_pages.sh"
  "regress/check_tmp_isolation.sh"
  "regress/check_r2_package.sh"
)

FORCE=0
usage() {
  cat <<EOF
usage: regress/tier.sh <tier> [--force] [--list]

  0        fast self-tests. Every edit, no window needed.        (seconds)
  1        slow self-tests + the AFFECTED testbench set only.    (1-3 min)
  2        the FULL gate. Named gates only, and it refuses
           unless the window is clear.            (20-30 min)
  --list   print the declared check list and exit
  --force  run T2 anyway, loudly, even if the window is not clear

WHY T2 REFUSES: a gate that runs while the tree is dirty, or while a mutation
harness holds a planted mutant, measures whatever the tree happens to contain and
prints a verdict anyway. On 2026-09-27 that produced a meaningless gate at 13:50
and an orphan mutant in rtl/pe_eth_mac.v by 14:00.
EOF
  exit 2
}

tier=""
for a in "$@"; do
  case "$a" in
    0|1|2) tier="$a" ;;
    --force) FORCE=1 ;;
    --list) printf 'T0 (%d checks):\n' "${#T0[@]}"; printf '  %s\n' "${T0[@]}"
            printf 'T1 self-tests (%d):\n' "${#T1_SELF[@]}"; printf '  %s\n' "${T1_SELF[@]}"
            printf 'T2: the full gate (regress/run_all.sh)\n'; exit 0 ;;
    -h|--help) usage ;;
    *) echo "tier.sh: unknown argument '$a'" >&2; usage ;;
  esac
done
[ -n "$tier" ] || usage

# ---- runner. Prints a verdict, the seconds it cost, and nothing else.
declare -a PASSED=() FAILED=() SKIPPED=()
run_one() { # path [args...]
  local p="$1"; shift
  local t0 t1 rc out
  if [ ! -x "$p" ]; then
    printf '  %-46s MISSING\n' "$(basename "$p")"
    SKIPPED+=("$p"); return 0
  fi
  t0=$(date +%s)
  out=$("$p" "$@" 2>&1); rc=$?
  t1=$(date +%s)
  if [ "$rc" -eq 0 ]; then
    printf '  %-46s ok    %3ds\n' "$(basename "$p")" "$((t1-t0))"
    PASSED+=("$p")
  else
    printf '  %-46s FAIL  %3ds\n' "$(basename "$p")" "$((t1-t0))"
    printf '%s\n' "$out" | tail -8 | sed 's/^/        /'
    FAILED+=("$p")
  fi
  return 0
}

summarise() { # label declared
  local label="$1" declared="$2" ran=$(( ${#PASSED[@]} + ${#FAILED[@]} + ${#SKIPPED[@]} ))
  echo
  if [ "$ran" -ne "$declared" ]; then
    echo "$label: FAILED - $ran of $declared declared checks actually ran."
    echo "  A check list that silently shrinks is worse than no list: a gate that"
    echo "  quietly stops checking something is a gate that lies. Investigate the"
    echo "  MISSING entries above before trusting any verdict from this run."
    return 1
  fi
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo "$label: FAILED - ${#SKIPPED[@]} check(s) MISSING, so this was not a real run."
    printf '  missing: %s\n' "${SKIPPED[@]}"
    return 1
  fi
  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "$label: FAILED - ${#FAILED[@]} of $ran checks red:"
    printf '  %s\n' "${FAILED[@]}"
    return 1
  fi
  echo "$label: OK ($ran of $ran declared checks)"
  return 0
}

case "$tier" in
0)
  echo "=== TIER 0 - fast self-tests (run this on every edit) ==="
  for c in "${T0[@]}"; do run_one "$c"; done
  summarise "tier0" "${#T0[@]}"
  ;;
1)
  echo "=== TIER 1 - slow self-tests ==="
  for c in "${T1_SELF[@]}"; do run_one "$c"; done
  summarise "tier1-self" "${#T1_SELF[@]}" || echo "tier1 self-tests are red; the affected-set run below will be noise until they are."
  echo
  echo "=== TIER 1 - the AFFECTED testbench set (not all 47) ==="
  # verify_merge already owns the mapping; run_all already knows how to consume
  # a regex. Composing the two is the whole point: a pe_eth_mac.v edit is a
  # handful of cases, not the whole gate.
  map="$(regress/verify_merge.sh --list 2>&1)"
  if [ -z "$map" ]; then
    echo "  could not compute the affected set; falling back to the full gate list"
    map='.'
  fi
  printf '  affected: %s\n' "$(printf '%s' "$map" | tr '\n' ' ' | cut -c1-200)"
  regress/run_all.sh --cases="$map"
  exit $?
  ;;
2)
  echo "=== TIER 2 - the FULL gate (named gates only) ==="
  # The window guard. Each of these is a way the 2026-09-27 gate was voided.
  blocked=""
  # SUBSTANTIVE dirt only, via the rule verify_merge.sh shares with us. The first
  # version of this guard used a bare `git status --porcelain -- regress/ rtl/ tb/`,
  # which meant it refused FOREVER: formal/results/summary.txt is rewritten by
  # every formal run and its peak_rss column is a per-run measurement, so the tree
  # is dirty after essentially every run. A guard that is always right and always
  # in the way gets --forced every time, and then it protects nothing. Both gates
  # now ask lib_dirty.sh the same question, so they cannot drift apart.
  dirty="$(substantive_dirty_paths)"
  [ -n "$dirty" ] && blocked="substantive uncommitted changes in regress/ rtl/ tb/
$(printf '%s\n' "$dirty" | head -5 | sed 's/^/    /')"
  harness="$(pgrep -af 'mutate_.*\.sh' 2>/dev/null | head -3)"
  [ -n "$harness" ] && blocked="${blocked:+$blocked; }a mutation harness is running and owns a planted mutant
$(printf '%s\n' "$harness" | sed 's/^/    /')"
  other="$(pgrep -af 'run_all\.sh|verify_merge\.sh' 2>/dev/null | grep -v 'pgrep' | head -3)"
  [ -n "$other" ] && blocked="${blocked:+$blocked; }another gate is already running
$(printf '%s\n' "$other" | sed 's/^/    /')"
  if [ -n "$blocked" ] && [ "$FORCE" -ne 1 ]; then
    echo "tier2: REFUSING to start the full gate."
    echo
    echo "  The window is not clear:"
    printf '    %s\n' "${blocked//;/$'\n    '}"
    echo
    echo "  A gate started here would measure whatever the tree happens to contain and"
    echo "  print a verdict anyway - which is exactly what happened at 13:50 on"
    echo "  2026-09-27. On a weak box a wrongly-started 20-minute gate is 20 minutes"
    echo "  you do not get back."
    echo
    echo "  Fix the window, or override deliberately with:  regress/tier.sh 2 --force"
    exit 6
  fi
  [ "$FORCE" -eq 1 ] && [ -n "$blocked" ] && echo "tier2: --FORCE, starting anyway with the window UNCLEAR:" && printf '    %s\n' "${blocked//;/$'\n    '}"
  regress/run_all.sh
  exit $?
  ;;
esac
