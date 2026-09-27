#!/usr/bin/env bash
# union_log.sh — reconcile two divergent APPEND-ONLY logs without losing an entry
# from either side, and without repeating the shared history between them.
#
# WHY THIS EXISTS, AND WHY IT IS NARROW. MANAGER-COLD-START.md's
# conflict-resolution scope says: "the timestamp-union script is ONLY for
# WORKLOG.md and wiki/log.md. Every other conflict - code, docs, configs - is
# HAND-MERGED hunk by hunk." That rule cites a script which did not exist in the
# repo, so this is it, scoped exactly as written.
#
# THE RULE HAS A HISTORY AND IT IS NOT SUBTLE. A union script was once run over
# acceptance.py and scrambled prose into code; the note says the damage is that
# the errors are SILENT. So this script refuses to be general. It understands one
# line shape:
#
#     YYYY-MM-DD HH:MM TZ | actor | EVENT | detail...
#
# and treats a line that does not start with a timestamp as a continuation of the
# entry above it. Anything it cannot classify makes it REFUSE rather than guess,
# because a log that silently loses an audit entry is worse than a merge that
# stops and asks for a human.
#
# WHY UNION IS THE APPEND-ONLY-CORRECT RESOLUTION, not a violation of it. Both
# sides appended; nothing was rewritten. The union is the only resolution that
# preserves every entry from both streams. Taking one side wholesale would
# DISCARD the other side's audit trail, and that is the real append-only
# violation. A read-only guard that flags any write to an append-only log is right
# to be suspicious and wrong about this file - so the proof is mechanical rather
# than asserted: no-entry-lost is verified and the script exits non-zero if it
# cannot be shown.
#
# THE ENCODING IS LOAD-BEARING, and it is the subtle part. An entry is made a
# SINGLE PHYSICAL LINE before any sorting happens, with its internal newlines
# encoded as \x1f. The first version left real newlines in the block and piped it
# through sort - and sort works on physical LINES, so a multi-line entry split:
# its first line sorted as one record, its continuation as another, and the two
# drifted apart. The self-test caught it on a two-line entry. Real WORKLOG
# entries run to several hundred characters, so that would have scrambled the
# audit log this script exists to repair.
set -u

TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [A-Z][A-Z][A-Z]'

# One line per entry: "sortkey<TAB>block-with-\x1f-for-newlines", preceded by a
# single PREAMBLE record holding everything before the first timestamped line.
#
# THE PREAMBLE IS A REAL STRUCTURE, NOT GARBAGE. WORKLOG.md opens with a
# markdown header carrying the rotation policy, the concision rule and the line
# format - about fifteen lines before its first entry. The first version of this
# script treated those as UNCLASSIFIED and refused, which was wrong: a log with a
# header is the normal case, and the refusal then cascaded, because a failed emit
# produced an empty intermediate and the no-loss verifier correctly reported that
# every entry had vanished. The verifier was right and the parser was wrong.
#
# So the model is: everything before the FIRST timestamped line is a preamble and
# is preserved verbatim; after that, a timestamped line starts an entry and any
# other line is its continuation. A file with NO timestamped line at all is not a
# log, and that is the case that still refuses.
emit_entries() {
  awk -v tsre="$TS_RE" -v US=$'\x1f' '
    BEGIN { key=""; blk=""; n=0; pre=""; inpre=1 }
    {
      if ($0 ~ tsre) {
        inpre=0
        if (n>0) printf "%s\t%s\n", key, blk
        key = substr($0, 1, 16); blk = $0; n++
      } else if (inpre) {
        pre = pre $0 US
      } else {
        blk = blk US $0
      }
    }
    END {
      if (n==0) { print "NO ENTRIES" > "/dev/stderr"; exit 3 }
      if (n>0) printf "%s\t%s\n", key, blk
    }
  ' "$1"
  # Emit the preamble separately, on stderr-safe fd 1, only when there is one.
  # Done by a second pass so the entry stream stays pure.
}

# Stable sort on the timestamp key only. LC_ALL=C so ordering does not depend on
# the caller locale: a log reordered by locale is a log whose newest entry is no
# longer at the bottom.
sort_entries() { LC_ALL=C sort -t$'\t' -k1,1 -s; }

# Drop DUPLICATE entries, then decode back to real newlines.
#
# The dedup is CORRECTNESS, not tidiness. Two branches that diverged share their
# history - our WORKLOG.md and the branch's have ~1876 identical leading lines -
# so a plain union of two append streams emits that shared history TWICE and the
# log repeats itself for three days. The self-test caught this on its first run
# with a two-entry fixture.
#
# Dedup is on the WHOLE encoded block, so two entries that begin alike but differ
# in a continuation line are both kept: they are different events that happen to
# share a first line. Doing dedup and decode in one pass is what makes that
# distinction possible at all.
finalize_entries() {
  awk -F'\t' -v US=$'\x1f' '
    !seen[$2]++ { gsub(US, "\n", $2); printf "%s\n", $2 }
  '
}

# Prove every entry from BOTH sides survives, comparing in the ENCODED domain
# where an entry is exactly one line. An exact line match is then both correct and
# total. A verifier that cries wolf is worse than none, because the obvious
# response to a false alarm is to stop running it.
verify_no_loss() {
  local ours="$1" theirs="$2" sorted="$3" lost=0 e
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    grep -Fqx -- "$e" "$sorted" || { printf 'union_log.sh: LOST from ours: %s\n' "${e%%$'\t'*}" >&2; lost=$((lost+1)); }
  done < <(emit_entries "$ours")
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    grep -Fqx -- "$e" "$sorted" || { printf 'union_log.sh: LOST from theirs: %s\n' "${e%%$'\t'*}" >&2; lost=$((lost+1)); }
  done < <(emit_entries "$theirs")
  return "$lost"
}

selftest() {
  local T; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  local PASS=0 FAIL=0
  ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
  bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }

  printf '2026-09-26 10:00 CDT | a | E | base\n2026-09-26 12:00 CDT | a | E | ours-1\n' >"$T/ours"
  printf '2026-09-26 10:00 CDT | a | E | base\n2026-09-26 11:00 CDT | b | E | theirs-1\n' >"$T/theirs"
  { emit_entries "$T/ours"; emit_entries "$T/theirs"; } | sort_entries >"$T/sorted"
  finalize_entries <"$T/sorted" >"$T/merged"

  if verify_no_loss "$T/ours" "$T/theirs" "$T/sorted" >/dev/null 2>&1; then
    ok "no entry is lost when both sides are unioned"
  else
    bad "no entry is lost when both sides are unioned" "$(verify_no_loss "$T/ours" "$T/theirs" "$T/sorted" 2>&1 | head -2)"
  fi
  # THE DEDUP CASE - the assertion that failed on the script's first run. Both
  # sides carry the same base entry, exactly as two diverged branches do.
  if [ "$(grep -c 'base' "$T/merged")" -eq 1 ]; then
    ok "the SHARED base entry appears ONCE, not twice"
  else
    bad "the shared base entry appears once" "found $(grep -c 'base' "$T/merged") copies"
  fi
  if [ "$(sed -n 2p "$T/merged")" = "2026-09-26 11:00 CDT | b | E | theirs-1" ]; then
    ok "entries come out in TIMESTAMP order, not side order"
  else
    bad "entries come out in timestamp order" "$(sed -n 2p "$T/merged")"
  fi

  # a near-duplicate must NOT be collapsed
  printf '2026-09-26 14:00 CDT | a | E | twin\n  detail one\n' >"$T/t1"
  printf '2026-09-26 14:00 CDT | a | E | twin\n  detail two\n' >"$T/t2"
  { emit_entries "$T/t1"; emit_entries "$T/t2"; } | sort_entries | finalize_entries >"$T/tm"
  if [ "$(wc -l <"$T/tm")" -eq 4 ]; then
    ok "entries sharing a first line but differing below are BOTH kept"
  else
    bad "near-duplicate entries are both kept" "got $(wc -l <"$T/tm") lines"
  fi

  # a multi-line entry must stay ONE entry: the defect sort would have caused
  printf '2026-09-26 15:00 CDT | a | E | starts here\n  continues here\n  and here\n' >"$T/multi"
  emit_entries "$T/multi" | sort_entries | finalize_entries >"$T/multimerge"
  if [ "$(wc -l <"$T/multimerge")" -eq 3 ] && [ "$(head -1 "$T/multimerge")" = "2026-09-26 15:00 CDT | a | E | starts here" ]; then
    ok "a multi-line entry survives intact and unsplit"
  else
    bad "a multi-line entry survives intact" "$(head -2 "$T/multimerge" | tr '\n' '/')"
  fi

  # the refusal case: a file with no entries at all is not a log
  printf '# A heading\n\nProse that is not a log entry.\n' >"$T/notalog"
  if emit_entries "$T/notalog" >/dev/null 2>&1; then
    bad "a file with no timestamped entries is REFUSED" "it parsed happily"
  else
    ok "a file with no timestamped entries is REFUSED"
  fi

  # the PREAMBLE case: a real log opens with a markdown header, and the first
  # version of this script refused it - then cascaded into a false "every entry
  # lost" report, because a failed emit leaves an empty intermediate.
  printf '# WORKLOG - header\n\nRotation policy blah.\n\n2026-09-26 10:00 CDT | a | E | one\n' >"$T/pre"
  if emit_entries "$T/pre" >/dev/null 2>&1; then
    ok "a log WITH a markdown preamble parses (it did not before)"
  else
    bad "a log with a markdown preamble parses" "refused a normal WORKLOG"
  fi
  { emit_entries "$T/pre"; emit_entries "$T/pre"; } | sort_entries | finalize_entries >"$T/prem"
  if [ "$(grep -c 'one' "$T/prem")" -eq 1 ] && [ "$(wc -l <"$T/prem")" -eq 1 ]; then
    ok "and its entries still union correctly alongside a preamble"
  else
    bad "entries union correctly with a preamble" "$(cat "$T/prem")"
  fi

  # and the verifier must actually be able to FAIL, or it proves nothing
  printf '2026-09-26 16:00 CDT | a | E | only-in-ours\n' >"$T/lo"
  : >"$T/empty"
  if verify_no_loss "$T/lo" "$T/empty" "$T/empty" >/dev/null 2>&1; then
    bad "the verifier DETECTS a lost entry (it is not vacuous)" "it passed an empty comparison"
  else
    ok "the verifier DETECTS a lost entry (it is not vacuous)"
  fi

  if [ "$FAIL" -eq 0 ]; then
    echo "union_log self-test: OK ($PASS of $PASS cases proved the union is lossless)"
    return 0
  fi
  echo "union_log self-test: FAILED ($FAIL of $((PASS+FAIL)) cases failed)"
  return 1
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

FILE="${1:-}"
[ -n "$FILE" ] || { echo "usage: $(basename "$0") <conflicted-file> | --selftest" >&2; exit 2; }
[ -f "$FILE" ] || { echo "union_log.sh: no such file: $FILE" >&2; exit 2; }

# The two sides of a conflicted file live in the git index stages.
git show :2:"$FILE" >"${FILE}.ours"  2>/dev/null || { echo "union_log.sh: no :2 stage for $FILE" >&2; exit 2; }
git show :3:"$FILE" >"${FILE}.theirs" 2>/dev/null || { echo "union_log.sh: no :3 stage for $FILE" >&2; exit 2; }
cleanup(){ rm -f "${FILE}.ours" "${FILE}.theirs" "${FILE}.sorted" "${FILE}.union"; }
trap cleanup EXIT

n_ours=$(emit_entries "${FILE}.ours"   | grep -c '' || true)
n_theirs=$(emit_entries "${FILE}.theirs" | grep -c '' || true)
echo "union_log: $FILE -- ours $n_ours entries, theirs $n_theirs entries"

# The preamble, as one encoded record, or nothing if the log opens with an entry.
emit_preamble() {
  awk -v tsre="$TS_RE" -v US=$'\x1f' '
    BEGIN { pre=""; inpre=1 }
    {
      if ($0 ~ tsre) { inpre=0; next }
      if (inpre) pre = pre $0 US
    }
    END { if (pre != "") printf "%s", pre }
  ' "$1"
}

# Count ENTRIES, not physical lines. An entry is usually several lines, and the
# first version of this message reported the line count while calling it an entry
# count - 2094 "entries" for a file with 1945 of them. A tool that miscounts in
# its own summary teaches its reader to distrust the summary.
count_entries() { emit_entries "$1" | grep -c '' || true; }

# Sorted intermediate, kept so the no-loss proof compares ENCODED entries (one
# per line) rather than decoded text, which grep cannot match multi-line.
if ! { emit_entries "${FILE}.ours" && emit_entries "${FILE}.theirs"; } | sort_entries >"${FILE}.sorted"; then
  echo "union_log.sh: REFUSING - one of the sides is not a log at all." >&2
  echo "  This script only understands a log of 'YYYY-MM-DD HH:MM TZ | actor | EVENT' lines" >&2
  echo "  with an optional markdown preamble. Hand-merge this file instead of letting a" >&2
  echo "  script guess at it." >&2
  exit 3
fi

if ! verify_no_loss "${FILE}.ours" "${FILE}.theirs" "${FILE}.sorted"; then
  echo "union_log.sh: REFUSING - the union would lose entries. Hand-merge." >&2
  exit 4
fi

n_lines=$(grep -c '' <"${FILE}.sorted" || true)
{
  # Preamble first, from ours; the two sides share it verbatim in practice, and
  # ours is the branch under merge so it is the one whose wording should win.
  pre="$(emit_preamble "${FILE}.ours")"
  [ -n "$pre" ] && printf '%s' "$pre" | tr '\x1f' '\n'
  finalize_entries <"${FILE}.sorted"
} >"${FILE}.union"
mv "${FILE}.union" "$FILE"
echo "union_log: wrote $FILE -- $(count_entries "$FILE") entries, $n_lines physical lines;"
echo "union_log: every entry from BOTH sides verified present (ours $n_ours, theirs $n_theirs, shared history deduped)"
exit 0
