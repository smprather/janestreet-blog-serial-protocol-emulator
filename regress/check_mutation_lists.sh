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

if [ "$bad" -ne 0 ]; then
  echo "check_mutation_lists: $bad of $n harness(es) FAILED — a narrowed gate would skip a suite that guards a changed file"
  exit 1
fi
echo "check_mutation_lists: $n harness(es), every MUTABLE list covers every repo file that harness writes"
