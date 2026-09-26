#!/usr/bin/env bash
# dep_guard.sh — a run must not report a verdict from scripts that changed
# underneath it. SOURCE this; do not execute it.
#
# THE FAILURE THIS EXISTS FOR (2026-09-25, and it was mine). A measurement
# campaign ran `mutate_timing_tb.sh` while I was inserting a declaration into that
# same file. Bash reads a script INCREMENTALLY, so the insertion shifted the file
# under the running shell: the harness executed fragments of comment text and
# reported FAILED. The harness was intact throughout. That direction is merely
# embarrassing — a broken run that says so.
#
# The dangerous direction is the other one, and it is the reason this file
# exists. A script edited under a running harness can just as easily make it
# report PASS: the mutation loops, the survivor counts and the exit code are all
# decided by the very text that just moved. A FALSE PASS is the worst thing a
# gate in this project can do — worse than a crash, worse than a red — because it
# is believed. So a run whose own dependencies changed may report nothing except
# INCONCLUSIVE, and "no verdict" has to be a state the caller can SEE.
#
# WHY A CONTENT HASH AND NOT AN MTIME. An mtime comparison misses the case that
# matters most: an editor or checkout that rewrites a file with identical
# content, or restores content while advancing the mtime. Both are exactly what
# a "harmless" cleanup does mid-run. The claim being made is "the bytes I am
# executing are the bytes I started with", and only a content hash makes that
# claim true. (An edit that preserves content correctly reports no change, which
# is the right answer.)
#
# THE CONTRACT.
#   chip_dep_stamp <label> [extra-dep ...]  at START. Remembers, for this
#       process, the CONTENT of this script, regress/run_lock.sh and the extras.
#       The dependency LIST is stored alongside, so the check cannot disagree
#       about what it is checking.
#   chip_dep_check <label>                  at END. Re-hashes exactly the stored
#       list. Same -> 0. Different, or a file that vanished -> prints
#       CHIP-DEP-CHANGED naming the files and returns 1. The caller must then
#       report INCONCLUSIVE, never success.
#
# THE MARKER IS THE CONTRACT WITH verify_merge.sh, which greps for
# CHIP-DEP-CHANGED and turns it into its own INCONCLUSIVE (exit 4) EVEN IF the
# run exited 0 — because a run whose scripts changed verified nothing, and an
# exit 0 is exactly what a false pass looks like from the outside.
set -u

: "${CHIP_DEP_STAMP_DIR:=${TMPDIR:-/tmp}/chip-dep-stamps}"
mkdir -p "$CHIP_DEP_STAMP_DIR" 2>/dev/null || true

# Print "hash  path" for one file, or ABSENT if it is not there. An absent file
# is a CHANGE, not an absence of evidence: a harness whose script was deleted
# mid-run is not a harness that passed.
chip_dep_one() {
  if [ ! -f "$1" ]; then
    printf 'ABSENT %s\n' "$1"
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$(sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1)" "$1"
  else
    printf 'size-mtime:%s  %s\n' "$(stat -c '%s:%Y' -- "$1" 2>/dev/null)" "$1"
  fi
}

# The dependency list, absolute, sorted, deduplicated. Always includes the
# running script and the shared lock helper, because every harness inherits that
# one's behaviour by sourcing it.
chip_dep_list() {
  {
    printf '%s\n' "$0"
    printf '%s\n' "$(dirname "${BASH_SOURCE[0]}")/run_lock.sh"
    [ $# -gt 0 ] && printf '%s\n' "$@"
  } | while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in /*) ;; *) p="$(pwd)/$p" ;; esac
      printf '%s\n' "$p"
    done | sort -u
}

chip_dep_stamp() {
  local label="$1"; shift
  local deps="$CHIP_DEP_STAMP_DIR/$label.deps"
  chip_dep_list "$@" > "$deps" 2>/dev/null
  chip_dep_list "$@" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    chip_dep_one "$f"
  done > "$CHIP_DEP_STAMP_DIR/$label.stamp" 2>/dev/null
  return 0
}

chip_dep_check() {
  local label="$1"
  local base="$CHIP_DEP_STAMP_DIR/$label"
  local cur
  if [ ! -f "$base.stamp" ] || [ ! -f "$base.deps" ]; then
    echo "CHIP-DEP-CHANGED: $label: this run recorded no dependency stamp, so its verdict cannot be trusted" >&2
    return 1
  fi
  # Rebuild the CURRENT state from the STORED list. Deliberately not
  # chip_dep_stamp: the first version of this function re-stamped, which
  # overwrote the very baseline it was about to compare against, so the check
  # compared the present against itself and could never fire — an assertion that
  # looked like coverage and was not.
  cur=$(mktemp "$CHIP_DEP_STAMP_DIR/cur.XXXXXX") || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    chip_dep_one "$f"
  done < "$base.deps" > "$cur" 2>/dev/null
  if ! cmp -s "$base.stamp" "$cur"; then
    echo "CHIP-DEP-CHANGED: $label: a script this run depends on CHANGED while it was running." >&2
    echo "  Bash executes a script incrementally, so a file edited mid-run can make a" >&2
    echo "  harness report a FALSE PASS as easily as a false failure. This run verified" >&2
    echo "  nothing and its verdict must be read as INCONCLUSIVE, not as green." >&2
    diff "$base.stamp" "$cur" 2>/dev/null | grep -E '^[<>]' | head -8 | sed 's/^/    /' >&2
    rm -f "$cur"
    return 1
  fi
  rm -f "$cur"
  return 0
}
