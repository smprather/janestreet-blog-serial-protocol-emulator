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
#   chip_dep_sample_start <label> <tgt>...  at START of a MUTATING run. Launches
#       the background poller described below.
#   chip_dep_expect pristine|mutated <f>...  by the HARNESS, immediately AFTER it
#       has established that state. Says what the targets are now, so the poller
#       can catch something else changing them.
#   chip_dep_sample_stop <label>            at END. Non-zero if the poller saw a
#       target contradict a declaration, or if it never got to watch.
#
# THE MARKER IS THE CONTRACT WITH verify_merge.sh, which greps for
# CHIP-DEP-CHANGED and turns it into its own INCONCLUSIVE (exit 4) EVEN IF the
# run exited 0 — because a run whose scripts changed verified nothing, and an
# exit 0 is exactly what a false pass looks like from the outside.
set -u

: "${CHIP_DEP_STAMP_DIR:=${TMPDIR:-/tmp}/chip-dep-stamps}"
mkdir -p "$CHIP_DEP_STAMP_DIR" 2>/dev/null || true

# THE REPO ROOT, RESOLVED ONCE, HERE, AND NEVER AGAIN.
#
# This has to be eager, and the reason is a bug this very change shipped and
# then caught on the first real harness run. The harnesses source this file
# through run_lock.sh by a RELATIVE path ("./regress/run_lock.sh"), and several
# of them then do a BARE `cd "$ROOT/sim"` in their main body. So resolving
# ${BASH_SOURCE[0]} lazily -- at the moment a declaration is made -- asks "where
# is ./regress/dep_guard.sh relative to the CURRENT directory", and by then the
# answer is nothing at all. The first version did exactly that: every
# declaration from mutate_serdes_tb.sh carried the path "/rtl/pe_serdes.v",
# which matches no watch-list entry, so the sampler correctly reported all
# fourteen of its own declarations as covering nothing.
#
# Resolved at source time the cwd is still the directory the harness started in,
# so the answer is stable for the life of the process. A path lookup that depends
# on when it happens is a bug waiting for a cd.
: "${CHIP_DEP_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"

# THE SAMPLER, AND WHY IT IS A DECLARATION PROTOCOL RATHER THAN A PATTERN.
#
# Everything above compares a target's content at the START of a run with its
# content at the END. An external actor who RESTORES a target to its starting
# content mid-run leaves it exactly as that comparison expects to find it — and
# that is not hypothetical: on 2026-09-25 rtl/pe_eth_mac.v was restored from
# outside a live mutate_eth_mac_tb.sh, and the run could have reported a false
# survivor behind a perfectly clean-looking end state. The end-state check cannot
# see the one shape that actually happened, so this watches DURING the run.
#
# The obvious design is to watch for the shape of the interference: "seen
# MUTATED, then seen ORIGINAL again, while the run is live". IT WAS BUILT, IT
# WAS MEASURED, AND IT IS WRONG. Every harness restores PER CASE inside its
# mutation loop, so a clean run's own content sequence is M O M O M O — the
# signal is the dominant pattern of normal operation, not an anomaly. At a 50ms
# poll it reported INTERFERENCE about 120 times on one clean mutate_i2c_tb.sh run
# (its pristine windows are 60-62ms, longer than the poll) and fired on
# mutate_serdes_tb.sh only depending on SAMPLING PHASE. Shipping it would return
# exit 4 from every suite and make the merge gate permanently INCONCLUSIVE,
# which is worse than the gap: an INCONCLUSIVE that always fires is one people
# learn to ignore. The measurement is in reviews/2026-09-26/DEP-GUARD-SAMPLER-DESIGN.md
# sections 6-7 and the rejected discriminator is still executable as case 4 of
# regress/test_dep_guard.sh.
#
# The harness's own restore and an external restore are THE SAME CONTENT
# TRANSITION — both write the bytes the run started with. So the information is
# not in the file; it is in who wrote it. The fix is to stop inferring and start
# asking: the harness already knows what it just did, and it is already in scope
# here, because every harness sources this file through run_lock.sh. So it
# DECLARES, and the poller's only job is to compare what it sees against what
# was declared.
#
# WHY THAT IS STRICTLY BETTER THAN WATCHING FOR A PATTERN. A declaration is valid
# for an INTERVAL, not for an instant. So a poller that is too slow, or that
# samples inside a write, can only ever MISS a transition — it can never invent
# one. A missed detection is the status quo this file already documents; an
# invented one is a false INCONCLUSIVE on a clean run, which is the failure mode
# that just got a whole design thrown out.
#
# WHY A CONTRADICTION MUST PERSIST. Every real mutation is applied by python's
# write_text, which truncates and rewrites: between the truncate and the write
# the file is briefly neither the old content nor the new. A poller that fired on
# the first contradicting sample would fire on its own harnesses. So a
# contradiction has to hold for CHIP_DEP_SAMPLE_PERSIST (0.15s) before it counts —
# two orders of magnitude longer than a sub-millisecond truncate, and two orders
# of magnitude shorter than the 976-6207ms an external restore persists for
# (measured on mutate_i2c_tb.sh).
#
# THE RESIDUAL EDGE, stated rather than hidden: an external restore that lasts
# less than the persistence window, or one that lands and is re-mutated inside it,
# is still missed. That is the safe direction to be wrong in.

# The label a harness's own dep-guard calls already use, derived the same way
# they derive it, so no harness has to be told its own name and the sampler and
# the harness cannot disagree about which run they are talking about.
chip_dep_label() { printf 'run_%s\n' "$(basename "$0")"; }


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

# ---------------------------------------------------------------------------
# THE SAMPLER. Three entry points, and the contract is in the header above.
# ---------------------------------------------------------------------------

# Resolve a relative path against the REPO ROOT AS SEEN FROM THIS FILE, not
# against the caller's cwd. That is not fastidiousness: several harnesses do a
# BARE `cd "$ROOT/sim"` in their main body (mutate_serdes_tb.sh:49,
# mutate_codec_tb.sh:86, mutate_ctrl_tb.sh:58 and others), so by the time a late
# case declares its state the harness's cwd is sim/ and a relative
# `rtl/pe_soc.v` would name a file that does not exist. Two of the harnesses also
# call the root $REPO rather than $ROOT, so depending on a harness variable would
# need sixteen spellings. The guard knows where it lives, so it answers from
# that and every harness can declare with the same relative MUTABLE entries it
# already publishes. CHIP_DEP_ROOT is fixed at source time -- see the note there.
chip_dep_abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "${CHIP_DEP_ROOT:-}" "$1" ;;
  esac
}

chip_dep_sample_start() {
  local label="$1"; shift
  local base="$CHIP_DEP_STAMP_DIR/$label"
  local f
  rm -f "$base.sample.hit" "$base.sample.done" "$base.sample.truncated" \
        "$base.sample.pid" "$base.sample.log" "$base.sampling" \
        "$base.uncovered" "$base.nosample" "$base.decl" "$base.targets" \
        "$base.orig" 2>/dev/null
  : > "$base.targets"
  for f in "$@"; do
    [ -n "$f" ] || continue
    chip_dep_abspath "$f" >> "$base.targets"
  done
  if [ ! -s "$base.targets" ]; then
    # A suite that publishes no MUTABLE targets has nothing to watch. That is a
    # real case, not a hypothetical — one of the sixteen publishes MUTABLE="" —
    # so it is recorded explicitly rather than left to look like a sampler that
    # ran and saw nothing.
    : > "$base.nosample"
    return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    chip_dep_one "$f"
  done < "$base.targets" > "$base.orig" 2>/dev/null
  : > "$base.sampling"
  # $$ is the shell that will also call sample_stop, so the poller can notice
  # that shell died and stop rather than spinning in /tmp forever.
  ( chip_dep_sample_poll "$label" "$$" ) > "$base.sample.log" 2>&1 &
  printf '%s\n' "$!" > "$base.sample.pid"
  return 0
}

# The harness's side of the protocol. Called immediately AFTER the state is
# established, never before: a declaration made before the write would be a
# claim the harness had not yet earned, and a slow one would contradict it.
# Rewritten whole and moved into place, so the poller never reads half a
# declaration, and last line wins for a path declared twice.
chip_dep_expect() {
  local state="$1"; shift
  case "$state" in
    pristine|mutated) ;;
    *) echo "chip_dep_expect: state must be 'pristine' or 'mutated', got '$state'" >&2; return 1 ;;
  esac
  local base f tmp
  base="$CHIP_DEP_STAMP_DIR/$(chip_dep_label)"
  tmp="$base.decl.$$"
  : > "$tmp"
  [ -f "$base.decl" ] && cat "$base.decl" >> "$tmp" 2>/dev/null
  for f in "$@"; do
    [ -n "$f" ] || continue
    printf '%s\t%s\n' "$state" "$(chip_dep_abspath "$f")" >> "$tmp"
  done
  mv -f "$tmp" "$base.decl" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

chip_dep_sample_poll() {
  local label="$1" parent="${2:-}"
  local base="$CHIP_DEP_STAMP_DIR/$label"
  local interval="${CHIP_DEP_SAMPLE_INTERVAL:-0.05}"
  local persist="${CHIP_DEP_SAMPLE_PERSIST:-0.15}"
  local maxsecs="${CHIP_DEP_SAMPLE_MAXSECS:-7200}"
  local f i cur cls want now elapsed
  local -a _t=() _o=() _since=() _covered=()
  local start=$SECONDS hit=0
  declare -A want_by=()

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _t+=("$f"); _o+=(""); _since+=(""); _covered+=(0)
  done < "$base.targets"
  i=0
  while [ "$i" -lt "${#_t[@]}" ]; do
    _o[i]="$(chip_dep_one "${_t[i]}")"
    i=$((i + 1))
  done

  while [ -f "$base.sampling" ]; do
    want_by=()
    if [ -f "$base.decl" ]; then
      while IFS=$'\t' read -r want f; do
        [ -n "$f" ] && want_by["$f"]="$want"
      done < "$base.decl"
    fi
    i=0
    while [ "$i" -lt "${#_t[@]}" ]; do
      want="${want_by[${_t[i]}]:-}"
      if [ -z "$want" ]; then
        # No declaration means nothing to check, and it is NOT silently treated
        # as covered: _covered stays 0 and sample_stop reports it. An unchecked
        # target is the 2026-09-25 incident with the detector switched off.
        i=$((i + 1)); continue
      fi
      _covered[i]=1
      cur="$(chip_dep_one "${_t[i]}")"
      if [ "$cur" = "${_o[i]}" ]; then cls=pristine; else cls=mutated; fi
      if [ "$cls" = "$want" ]; then
        _since[i]=""
      else
        now="${EPOCHREALTIME/,/.}"
        if [ -z "${_since[i]}" ]; then
          _since[i]="$now"
        else
          elapsed=$(awk -v a="$now" -v b="${_since[i]}" 'BEGIN{printf "%.3f", a-b}')
          if awk -v e="$elapsed" -v p="$persist" 'BEGIN{exit !(e >= p)}'; then
            printf '%s\n  declared: %s   observed: %s   held for %ss while the run was live\n' \
              "${_t[i]}" "$want" "$cls" "$elapsed" >> "$base.sample.hit"
            printf '  the harness said this file was %s, and something else made it %s.\n' \
              "$want" "$cls" >> "$base.sample.hit"
            hit=1
            break
          fi
        fi
      fi
      i=$((i + 1))
    done
    [ "$hit" = 1 ] && break
    sleep "$interval"
    if [ -n "$parent" ] && ! kill -0 "$parent" 2>/dev/null; then
      : > "$base.sample.truncated"; break
    fi
    if [ $(( SECONDS - start )) -ge "$maxsecs" ]; then
      : > "$base.sample.truncated"; break
    fi
  done

  if [ "$hit" = 0 ] && [ ! -f "$base.sample.truncated" ]; then
    : > "$base.uncovered"
    i=0
    while [ "$i" -lt "${#_t[@]}" ]; do
      [ "${_covered[i]}" = 0 ] && printf '%s\n' "${_t[i]}" >> "$base.uncovered"
      i=$((i + 1))
    done
    : > "$base.sample.done"
  fi
  return 0
}

chip_dep_sample_stop() {
  local label="$1"
  local base="$CHIP_DEP_STAMP_DIR/$label"
  local pid
  if [ -f "$base.nosample" ]; then
    return 0
  fi
  if [ ! -f "$base.sampling" ] || [ ! -f "$base.sample.pid" ]; then
    echo "CHIP-DEP-CHANGED: $label: no sampler was running for this run, so a mid-run" >&2
    echo "  restore could not have been seen. This run verified less than it appears to." >&2
    return 1
  fi
  rm -f "$base.sampling"
  pid=$(cat "$base.sample.pid" 2>/dev/null)
  [ -n "$pid" ] && { wait "$pid" 2>/dev/null || true; }
  if [ -s "$base.sample.hit" ]; then
    echo "CHIP-DEP-CHANGED: $label: a MUTABLE target did not hold the state the harness" >&2
    echo "  DECLARED it was in, so something outside this run wrote to it mid-run. That is" >&2
    echo "  the 2026-09-25 shape, and a run in that state verified nothing:" >&2
    sed 's/^/    /' "$base.sample.hit" >&2
    return 1
  fi
  if [ ! -f "$base.sample.done" ]; then
    echo "CHIP-DEP-CHANGED: $label: the sampler did not run to completion, so its silence" >&2
    echo "  is not evidence. Refusing rather than reporting a verdict it cannot support." >&2
    return 1
  fi
  if [ -s "$base.uncovered" ]; then
    echo "CHIP-DEP-CHANGED: $label: these MUTABLE targets were never DECLARED by the" >&2
    echo "  harness, so nothing checked them. Unchecked is not the same as clean:" >&2
    sed 's/^/    /' "$base.uncovered" >&2
    return 1
  fi
  return 0
}
