#!/usr/bin/env bash
# lib_dirty.sh — ONE definition of "is this dirty path just measurement noise?"
#
# WHY THIS IS SHARED AND NOT DUPLICATED. Two gates need this answer and they
# must never disagree:
#
#   verify_merge.sh  the merge gate's dirty-tree NOTE, so "the merge is green" is
#                    never claimed for a tree that is not the one being pushed
#   tier.sh          the T2 window guard, which REFUSES to start a full gate
#                    while regress/ rtl/ tb/ is dirty
#
# If they used different rules, one of two bad things happens. Either tier.sh
# refuses forever because formal/results/summary.txt is dirty after every formal
# run - so people reach for --force every time, and a guard that is always
# overridden protects nothing. Or tier.sh is looser than the merge gate, and a
# gate runs against a tree the merge gate would have called dirty. Both are the
# failure this repo keeps paying for: a gate that cries wolf, or a gate that
# lies. So the rule lives here once and both source it.
#
# THE RULE (verbatim from verify_merge.sh, which is the authority; this file is
# the extraction, not a rewrite).
#
# formal/results/summary.txt carries real verdict signal across time - it has
# held REFUTED and UNREACHABLE, and rows that appeared and vanished - so it must
# stay tracked and must NEVER be gitignored. But formal/run_formal.sh:177-179
# rewrites it every run and its peak_rss column is a per-run memory measurement,
# so the file is DIRTY after essentially every formal run even when every
# verdict is byte-identical.
#
# A NOTE that fires on measurement noise trains its reader to dismiss it, and
# this gate's whole reason for existing is that a reader who learns to ignore a
# signal has stopped getting evidence from it. So the two kinds of dirt are
# distinguished: SUBSTANTIVE (a real source change; the rule applies in full) and
# this churn (a number no gate reads - run_all.sh decides the formal verdict from
# run_formal.sh's EXIT CODE alone, and its "see summary.txt" is a human pointer,
# not a parse; repo-wide nothing else consumes the file).
#
# THE TEST IS BY CONTENT, NOT BY PATH: a diff whose changed lines all still
# match the header's 5-field shape and differ ONLY in the trailing peak_rss
# field is churn. Any other diff - a verdict flipping, a row added or removed,
# the header changing - is substantive.
#
# THE FAILURE MODE IS DELIBERATE AND TOWARD FALSE NEGATIVES: when in doubt this
# returns 1 (substantive). A missed classification costs one redundant NOTE; a
# wrong one would hide a verdict change. Callers treat 1 as "do not skip".
#
# Measured on 2026-09-27, which is what motivated the extraction: a full formal
# re-run left 9 of 10 rows changed and 0 verdict columns changed, and
# formal/results/summary.txt was the ONLY dirty path in the tree.

# dirty_is_measurement_churn <path> — 0 if the path is dirty but the change is
# only the nondeterministic measurement column, 1 if it is substantive or clean.
dirty_is_measurement_churn() {
  local f="$1" d
  [ "$f" = "formal/results/summary.txt" ] || return 1
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || return 1   # untracked => not churn
  d=$(git diff -U0 -- "$f" 2>/dev/null | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')
  [ -n "$d" ] || return 1                                            # clean file => not dirty

  # Every changed line, stripped of its +/- and of a leading peak_rss change,
  # must be identical; equivalently: no changed line may alter fields 1-4 or
  # the header. Compare field-by-field.
  printf '%s\n' "$d" | while IFS= read -r ln; do
    body=${ln:1}
    # header line?
    [ "${body%%|*}" = "name" ] && { echo BAD; continue; }
    # must be exactly 5 pipe-separated fields
    [ "$(printf '%s' "$body" | awk -F'|' '{print NF}')" = "5" ] || { echo BAD; continue; }
    # fields 1-4 (name|result|depth|shape) are the verdict-bearing ones
    echo "${body}" | cut -d'|' -f1-4
  done | sort -u | grep -qx BAD && return 1

  # The set of fields 1-4 across ALL changed lines must be unchanged when only
  # peak_rss moves. Compare sorted field tuples of the '-' lines vs '+' lines.
  local minus_pp plus_pp
  minus_pp=$(printf '%s\n' "$d" | grep '^-' | sed 's/^-//' | cut -d'|' -f1-4 | sort)
  plus_pp=$(printf '%s\n' "$d" | grep '^+' | sed 's/^+//' | cut -d'|' -f1-4 | sort)
  [ "$minus_pp" = "$plus_pp" ]
}

# substantive_dirty_paths [<pathspec...>] — the dirty paths that are NOT mere
# measurement churn, one per line. Empty output means "nothing substantive".
# Defaults to the gate sets: the same three directories the dep-guard and the
# quiet-window policy treat as gate-input, because editing those mid-run is what
# voids a run.
substantive_dirty_paths() {
  local spec=("$@")
  [ "${#spec[@]}" -eq 0 ] && spec=(regress/ rtl/ tb/)
  # The porcelain status field is deliberately discarded: this function asks
  # only "is this path substantively dirty", and the two-character code is
  # redundant with the answer. Naming it $st made shellcheck (rightly) flag an
  # unused variable, which is the cheapest possible drift signal in a gate.
  git status --porcelain -- "${spec[@]}" 2>/dev/null | while read -r _ path; do
    [ -z "${path:-}" ] && continue
    # porcelain renames put the arrow form in $path; keep the destination
    path="${path##* -> }"
    dirty_is_measurement_churn "$path" && continue
    printf '%s\n' "$path"
  done
}
