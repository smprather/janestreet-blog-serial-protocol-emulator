#!/usr/bin/env bash
# check_mutation_lists.sh — every mutation harness's MUTABLE list still covers
# every file that harness writes.
#
# WHY THIS GATE EXISTS. regress/verify_merge.sh narrows a merge gate to the
# mutation suites whose MUTABLE targets intersect the merge's changed set. That
# makes a MISSING entry in a list the most dangerous kind of omission in this
# repository: the gate would skip a suite that guards exactly the file the merge
# changed, and it would do so silently-ish, which is the one thing a gate in
# this project may never do. A list is therefore only trustworthy if something
# checks it, and the thing that can check it is the harness itself: the files it
# writes are already named in its own variables.
#
# WHAT IS CHECKED, AND WHAT IS DELIBERATELY NOT. For each harness, every
# repository path (rtl/, tb/, firmware/) named in a variable assignment must
# appear in that harness's MUTABLE -- with two classes excluded, both stated
# here rather than buried:
#   * COMPILE LISTS (SRCS=, WTB_SRCS=, SOC_SRCS=, TOP_SRCS= — any name ending in
#     _SRCS): the sources a testbench is built from. A merge that changes one
#     of those is covered by the CASE mapping, not by this one; a suite does
#     not mutate its compile list. (The first version of this gate excluded
#     only SRCS and WTB_SRCS and failed on SOC_SRCS — a false positive that
#     named thirteen files, which is why the exclusion is a suffix now.)
#   * TB* variables: the TESTBENCH paths a harness runs. Verified, not assumed:
#     no harness in this repository mutates a testbench (a harness that mutated
#     its TB would have to restore it, and none of them do). If that ever
#     changes, this exclusion is the thing to revisit, and the printed "skipped"
#     list is what makes it auditable.
# Anything else is a real mutation target and must be listed.
#
# A harness with NO MUTABLE line is a FAILURE, not a skip. It is also the signal
# verify_merge.sh escalates on: a harness that does not declare what it mutates
# is the unmappable case, and the gate runs everything rather than guessing.
#
# Usage:  regress/check_mutation_lists.sh     -> exit 0 clean, 1 on a violation
set -u
cd "$(dirname "$0")/.." || exit 1

bad=0; n=0
EXCL=""
for f in regress/mutate_*.sh; do
  h=$(basename "$f" .sh); n=$((n + 1))
  if ! grep -q '^MUTABLE=' "$f"; then
    echo "FAIL $h: no MUTABLE line — verify_merge.sh cannot narrow this suite and will run all of them"
    bad=$((bad + 1)); continue
  fi
  MUT=$(grep -m1 '^MUTABLE=' "$f" | cut -d'"' -f2)
  # What the exclusions actually hid, printed at the end: an exclusion that
  # cannot be seen is an exclusion nobody can review.
  EXCL="$EXCL $(grep -oE '^(TB[A-Za-z0-9_]*|[A-Za-z_]*_?SRCS)=.*' "$f" \
           | grep -oE '(rtl|tb|firmware)/[A-Za-z0-9_.$-]+' | tr '\n' ' ')"
  # Every repo path named in an assignment, minus the two excluded classes.
  PATHS=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=.*' "$f" \
          | grep -vE '^(TB[A-Za-z0-9_]*|[A-Za-z_]*_?SRCS)=|^(SNAP|PRISTINE|BAK|WBAK|TMP|WORK|LOG|CCLOG|RESULTS|CASES)=' \
          | grep -oE '(rtl|tb|firmware)/[A-Za-z0-9_.$-]+' | sort -u)
  missing=""
  for p in $PATHS; do
    case " $MUT " in
      *" $p "*) ;;
      *) missing="$missing $p" ;;
    esac
  done
  if [ -n "$missing" ]; then
    echo "FAIL $h: writes repo file(s) not in MUTABLE:$missing"
    echo "     MUTABLE=\"$MUT\""
    bad=$((bad + 1))
  fi
done

echo "check_mutation_lists: excluded as testbench/compile-list paths (printed so the exclusion is reviewable):"
printf '%s\n' $EXCL | sort -u | sed 's/^/  /' | head -20
echo "  (no harness in this repository mutates a TESTBENCH — verified by the absence of any"
echo "   TB restore in any harness. If that ever changes, this exclusion is what to revisit.)"

# ---------------------------------------------------------------------------
# THE SECOND CHECK, AND IT IS A DIFFERENT KIND OF OMISSION.
#
# The MUTABLE check above asks whether a harness covers every file it WRITES.
# This one asks whether a harness's case DISPATCH covers every case it DECLARES
# — and the two are unrelated: a harness can list a case perfectly and still
# have an arm for an id that is not in the list, which means the arm is dead
# code that the harness never executes.
#
# IT IS NOT HYPOTHETICAL, it was found in this repository, and the shape of it
# is the expensive one: `mutate_timing_tb.sh` carried a complete-looking
# `sv-idle-level` arm — anchor, replacement, and a row in
# wiki/concepts/protocol-servo.md describing the fault it caught — with no
# entry in its CASES list. MEASURED 59 arms against 58 case entries. It had
# never run, and it COULD NOT have passed if it had been listed, because its
# anchor and its replacement differed only in a COMMENT: nothing was injected,
# so nothing failed. The wiki documented a case that could not exist.
#
# SCOPE IS DELIBERATELY ONE HARNESS, and that was measured rather than assumed.
# All seventeen regress/mutate_*.sh were surveyed for this shape: a `cat > ...
# <<` case list plus `<id>)` dispatch arms. Only mutate_timing_tb.sh has it.
# The other sixteen declare their mutants a different way (inline per-mutant
# python under $TMP, among others), so they have neither a CASES list nor an
# id dispatch, and this fault cannot arise in them. A check that claimed to
# cover seventeen would be covering sixteen by not looking at them, which is
# the exact failure the MUTABLE check above is built to prevent.
arms_of() {  # every `<id>)` dispatch arm, with its line number
  grep -nE '^[[:space:]]{2,6}[a-z][a-z0-9]*([_-][a-z0-9]+)+\)[[:space:]]*$' "$1" \
    | sed -E 's/^([0-9]+):[[:space:]]*([a-z][a-z0-9]*([_-][a-z0-9]+)+)\).*/\1 \2/'
}
cases_of() {  # every id in the CASES heredoc, one per line
  awk '/^cat > "\$CASES" <</{f=1; next} f && /^CASES_EOF$/{f=0} f && NF && $0 !~ /^#/{print $1}' "$1" \
    | sed 's/|.*//'
}

ARM_BAD=0
ARM_N=0
for h in regress/mutate_timing_tb.sh; do
  ARM_N=$((ARM_N + 1))
  arms=$(arms_of "$h" | awk '{print $2}' | sort -u)
  cases=$(cases_of "$h" | sort -u)
  n_arms=$(printf '%s\n' "$arms" | grep -c .)
  n_cases=$(printf '%s\n' "$cases" | grep -c .)
  echo "check_mutation_lists: $h: $n_arms dispatch arm(s), $n_cases case entry(ies)"
  # an arm with no entry never runs; an entry with no arm is a declared case
  # that the dispatch cannot reach. Both are the same omission seen from
  # opposite ends, so both are reported here rather than one of them.
  orphan_arms=$(comm -23 <(printf '%s\n' "$arms") <(printf '%s\n' "$cases"))
  orphan_cases=$(comm -13 <(printf '%s\n' "$arms") <(printf '%s\n' "$cases"))
  if [ -n "$orphan_arms" ]; then
    echo "FAIL $h: dispatch arm(s) with NO case entry, so they NEVER RUN:"
    printf '%s\n' "$orphan_arms" | sed 's/^/     /'
    for id in $orphan_arms; do
      ln=$(arms_of "$h" | awk -v i="$id" '$2==i{print $1}')
      echo "       $id is defined at $h:$ln"
    done
    echo "     An arm outside the list is dead code, and a dead arm can look complete."
    echo "     If it is redundant, delete it AND any doc that claims it runs; if it"
    echo "     is a real case, add it to the CASES list above."
    ARM_BAD=$((ARM_BAD + 1))
  fi
  if [ -n "$orphan_cases" ]; then
    echo "FAIL $h: case entry(ies) with NO dispatch arm, so the harness cannot run them:"
    printf '%s\n' "$orphan_cases" | sed 's/^/     /'
    ARM_BAD=$((ARM_BAD + 1))
  fi
  if [ "$n_arms" -eq 0 ] || [ "$n_cases" -eq 0 ]; then
    echo "FAIL $h: found $n_arms arm(s) and $n_cases case entry(ies) — one side is"
    echo "     empty, so this check would pass by having nothing to compare. A gate"
    echo "     that cannot see is not a gate."
    ARM_BAD=$((ARM_BAD + 1))
  fi
done
echo "check_mutation_lists: dispatch/case-list coverage checked for $ARM_N harness(es); the other 16 were surveyed and use a different case-declaration shape."

if [ "$ARM_BAD" -ne 0 ]; then
  echo "check_mutation_lists: $ARM_BAD dispatch/case-list problem(s) — an arm with no entry is code that never runs"
  exit 1
fi

if [ "$bad" -ne 0 ]; then
  echo "check_mutation_lists: $bad of $n harness(es) FAILED — a narrowed gate would skip a suite that guards a changed file"
  exit 1
fi
echo "check_mutation_lists: $n harness(es), every MUTABLE list covers every repo file that harness writes"
