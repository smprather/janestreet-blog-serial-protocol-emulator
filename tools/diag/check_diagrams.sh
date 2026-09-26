#!/usr/bin/env bash
# check_diagrams.sh — the gate for diagrams/, which until now had NO gate at all.
#
# WHY THIS EXISTS. The project's other artifact classes are all gated: RTL, the
# firmware images, the mutation harnesses, the formal mutants, the wiki pages. The
# diagrams were not, which is a gap rather than a decision — a directory whose
# whole value is that it is correct pictures of the code, and nothing in the suite
# that would have noticed one of them going stale or breaking.
#
# WHAT IT CHECKS, and why each check is here rather than because it was easy:
#
#   1. SYNTAX      every .puml parses under `plantuml --check-syntax`.
#                  A .puml with a syntax error still renders: PlantUML emits an
#                  ERROR IMAGE — a picture of a parser complaint — and returns
#                  non-zero. A committed error image is indistinguishable from a
#                  diagram to anything that only looks at the file, which is
#                  exactly the class of artifact that should never be committed.
#
#   2. COLOCATION  a .puml with N blocks must have exactly N .png and N .svg
#                  beside it, with the stems PlantUML actually produces, and
#                  NOTHING in the directory may be unclaimed. This is the
#                  MULTI-BLOCK CONVENTION, stated here because it is otherwise
#                  only knowable by reading filenames: block 1 is <stem>, blocks
#                  2..N are <stem>_001..<stem>_(N-1). Without it written down a
#                  second person reasonably assumes one source means one picture
#                  and deletes two thirds of a figure set as duplicates. Both
#                  directions fail: a missing render is an unviewable figure, and
#                  an unclaimed render is a picture of code that no longer exists.
#
#                  The orphan test is GLOBAL over the directory, not per source,
#                  and that is not a detail. The timing family uses stems that
#                  are prefixes of each other — proto-ws2812.puml,
#                  proto-ws2812-frame.puml, proto-ws2812-timing.puml — so a
#                  per-source glob for `proto-ws2812*` finds its siblings'
#                  renders and reports four orphans on a perfectly good tree. The
#                  first version of this script did exactly that. An orphan is
#                  defined here as a render in the directory that NO source in
#                  the directory claims, which is both the correct rule and the
#                  one that survives a shared stem prefix.
#
#   3. FRESHNESS   every render must not be OLDER than its source, and must be
#      AND         byte-identical to a fresh render of that source. The mtime
#      CONSISTENCY test catches "edited the source, forgot the picture". The
#                  byte test catches everything mtime cannot: a hand-edited
#                  render, a render made by a DIFFERENT PlantUML version, and the
#                  `data-source-line` drift class — where an earlier block in a
#                  multi-block source grows, every later block's line references
#                  shift, and the render differs while the visible picture is
#                  byte-for-byte the same picture. That case was found by hand
#                  once already; this is the check that makes it automatic.
#
#                  BOTH rest on a fact this script TESTS rather than assumes:
#                  PlantUML output is byte-deterministic for a fixed source and
#                  version. If that stops being true, the byte test reports every
#                  file as inconsistent, loudly, instead of passing quietly.
#
#                  THE MTIME IS A HINT AND CANNOT FAIL ON ITS OWN, which is a
#                  correction rather than a fudge. Two separate reasons, both
#                  learned by getting it wrong first:
#                    * A fresh `git checkout` writes every file within a few
#                      milliseconds of one instant, in an order that is not
#                      source-before-render, so "render is newer than source"
#                      flags EVERY render in a clean clone.
#                    * Restoring, `cp`-ing or checking out a .puml updates its
#                      mtime without changing one byte of its output.
#                  The first version of this script failed on the mtime alone and
#                  reported 64 failures on a tree where every figure was
#                  byte-identical to a fresh render of the current source. So the
#                  byte comparison is authoritative: a render that is older than
#                  its source but byte-identical to a fresh render IS up to date
#                  and is reported as a note, not a failure. The mtime keeps two
#                  jobs — explaining a real mismatch, and being free.
#
#   4. ASPECT      a PNG's width and height live in the IHDR chunk, so the ratio
#                  is checkable with no image library and no decoder. The band
#                  is wide because legitimate figures span a lot: the committed
#                  set runs from about 0.36 (a tall state machine) to about 10 (a
#                  break/mark timeline). The band catches the SHAPE OF A LAYOUT
#                  ACCIDENT — a figure a few hundred pixels wide and 8000 tall,
#                  or 8000 wide and 300 high, which reads as a smear rather than a
#                  picture. Extremes print every run, so drift inside the band is
#                  still visible to whoever reads the log.
#
# USAGE
#   tools/diag/check_diagrams.sh              check the real diagrams/
#   tools/diag/check_diagrams.sh --self-test  prove the checker still fails
#   tools/diag/check_diagrams.sh DIR          check some other directory
#
# WHY THE SELF-TEST IS PART OF THE GATE rather than something run once. A checker
# that stops detecting is worse than no checker: it reports OK on a broken tree
# and the suite goes green on a claim nothing is testing. So the self-test is in
# the suite, not merely available on request, and it plants seven defect classes
# in a THROWAWAY SYNTHETIC fixture — a stale render, a hand-edited render, a
# broken .puml, a committed error image, an unclaimed render, a missing block
# render, and a source name containing spaces (that last one is a PASS case: it
# fails if the checker gets NOISIER, not if it gets laxer). It requires the
# checker to fail on every planted case and to pass an untouched copy, so a
# planted failure cannot be blamed on the fixture, and it verifies each planting
# actually CHANGED something — or a no-op planting reports itself as a broken
# checker, which is how two of the three bugs in this file's own history were
# found in the first place.
#
# It never mutates the real diagrams/, so an interruption cannot leave the
# checkout in a planted state — a lesson this repo has already paid for once. The
# only destructive line in the file guards BOTH halves of its path with ${var:?}.
#
# EXIT: 0 all checks passed, 1 otherwise. The self-test exits 0 only if every
# planted defect was caught AND the clean copy passed.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Per-worktree /tmp scoping, the convention regress/mutate_fwbus_tb.sh adopted
# after the parallel-worker collision: 14 gate logs sharing /tmp paths is a known
# open defect here and this harness must not become the fifteenth.
_wt=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null | md5sum | cut -c1-8)
[ -n "$_wt" ] || _wt=shared

# The flags diagrams/README.md specifies. PLANTUML_LIMIT_SIZE matters: the
# project maps are large and the default limit truncates rather than failing.
export JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192"

# The aspect band. See check 4. Deliberately generous: this is a smoke alarm for
# a layout accident, not a style rule, and a gate that cries wolf gets disabled.
ASPECT_MIN=0.25
ASPECT_MAX=15.0

# ---- the toolchain pin, and why the byte comparison depends on it -----------
#
# The byte comparison below is the strongest staleness check there is, and it is
# only meaningful on a host whose renderer produces the same bytes as the host
# that made the committed renders. Nothing pinned that, so a contributor with a
# different PlantUML, Graphviz or JDK got a red gate on figures they had never
# touched: a red that NO DIAGRAM CHANGE CAN CLEAR. That is worse than no gate --
# it teaches people to ignore the gate, and the usual "fix" is to re-render, which
# destroys the very staleness the gate exists to catch. A sibling worker reported
# exactly this, with the signature "the two largest maps failed, thirty smaller
# figures passed".
#
# The mechanism was then measured rather than assumed, and it is not the obvious
# one. FONTS ARE NOT IT: PlantUML emits font-family="monospace" and
# font-family="sans-serif" as GENERIC references and bakes its own textLength
# estimates, so substituting the resolved font (verified with fc-match) leaves the
# committed bytes identical. The LAYOUT ENGINE is it: dot produces the geometry
# for every package/component figure, and forcing PlantUML's own engine moves the
# coordinates and the viewBox. The largest dot figures have the most coordinates
# to move, which is why the failure looked selective rather than uniform. See
# diagrams/TOOLCHAIN.md for the measurement and the reasoning.
#
# So: read the pin, compare it with the host, and make the byte comparison
# CONDITIONAL on them agreeing. When they disagree, say so loudly and treat
# byte-differences as inconclusive instead of failures -- the environment-
# independent checks (parses, both formats present, nothing unclaimed, aspect
# sane) still run and still fail, because none of them depends on which renderer
# produced the bytes. A missing pin is a FAILURE, not a fallback: without it the
# byte comparison is unenforceable and silently skipping it would be fail-open.
PIN_NAME=TOOLCHAIN.md

# The version the host actually has, one per pin key.
#
# FILTER BEFORE `head`, NEVER AFTER. `plantuml` and `java` are JVMs, and a JVM
# prints "Picked up JAVA_TOOL_OPTIONS: ..." to STDERR **whenever that variable is
# set** — and this script exports it, because diagrams/README.md requires it for
# the headless render. So `plantuml -version 2>&1 | head -1` captured the BANNER
# rather than the version, the anchored sed matched nothing, and the gate reported
# "plantuml(not detected on this host)" on every run. Two things make that
# especially bad: it is invisible until you trace it, and it is a toolchain
# MISMATCH report — the very thing this feature exists to make actionable.
# `dot` and `fc-match` are not JVMs, which is exactly why only these two keys
# failed and why the fault looked like a parsing bug rather than a banner.
detect_toolchain() {
  local v
  v=$(plantuml -version 2>&1 | sed -n 's/^PlantUML version \([^ /]*\).*/\1/p' | head -1); echo "plantuml=${v:-unknown}"
  v=$(dot -V 2>&1 | sed -n 's/^dot - graphviz version \([^ ]*\).*/\1/p' | head -1);       echo "graphviz=${v:-unknown}"
  v=$(java -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -1);            echo "java=${v:-unknown}"
  # fc-match prints:  NotoSansMono-Regular.ttf: "Noto Sans Mono" "Regular"
  # The FAMILY is the FIRST quoted string. Anchoring on the colon after the
  # filename is what makes this non-greedy: an earlier `s/.*"\(...\)".*/\1/p`
  # was, and captured "Regular" -- the STYLE -- for every family.
  v=$(fc-match monospace  2>/dev/null | sed -n 's/^[^:]*:[[:space:]]*"\([^"]*\)".*/\1/p'); echo "monospace=${v:-unknown}"
  v=$(fc-match sans-serif 2>/dev/null | sed -n 's/^[^:]*:[[:space:]]*"\([^"]*\)".*/\1/p'); echo "sans-serif=${v:-unknown}"
}

# The pinned versions, from the machine-readable block in the pin file.
#
# PARSED BY KEY, NOT BY A SPACE-DELIMITED REGEX. A value like "Noto Sans Mono"
# contains spaces, and a `\\([^[:space:]]*\\)` value pattern truncates it to
# "Noto" -- which would compare "Noto" against "Noto Sans Mono" and report a
# mismatch on a host that is in fact correct. That is the worst possible failure
# for this feature: a toolchain check that cries wolf on the right host.
pinned_toolchain() {
  local pin="$1" key line value
  [ -f "$pin" ] || return 0
  for key in plantuml graphviz java monospace sans-serif; do
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$pin" 2>/dev/null | head -1)
    [ -n "$line" ] || continue
    value=${line#*=}
    # trim leading and trailing whitespace without word-splitting the value
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [ -n "$value" ] && printf '%s=%s\n' "$key" "$value"
  done
}

# 0 = every pinned line matches this host, 1 = at least one differs, 2 = no pin.
compare_toolchain() {  # pin_file -> mismatches on stdout
  local pin="$1"
  [ -f "$pin" ] || return 2
  local line key want got missing=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*}
    want=${line#*=}
    got=$(detect_toolchain | grep "^${key}=" | cut -d= -f2-)
    if [ -z "$got" ] || [ "$got" = "unknown" ]; then
      missing="${missing} ${key}(not detected on this host)"
    elif [ "$got" != "$want" ]; then
      missing="${missing} ${key}: pinned ${want}, host ${got}"
    fi
  done <<EOF
$(pinned_toolchain "$pin")
EOF
  if [ -n "$missing" ]; then
    printf '%s\n' "$missing"
    return 1
  fi
  return 0
}
# Staleness tolerance, in seconds. See check 3: a fresh checkout writes every
# file within milliseconds of one instant.
MTIME_TOL=1

FAILURES=0
fail() { printf '  FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
ok()   { printf '  ok:   %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- the PINNED BASELINE -----------------------------------------------------
# A pin records that a rule is currently not met, so a gate written today can be
# green against a corpus carrying defects OWNED BY OTHER PEOPLE. It is only safe
# because it is enforced BOTH ways: a stale render not listed is NEW and red, and
# a listed render that is no longer stale is STALE-PIN and red. Without the second
# half a pin outlives its defect and the log and the tree disagree with nothing to
# say which is true. It earned that in the wild: it caught four of its own
# author's pins within one merge, written against a branch behind main.
#
# Both lists carry a LEADING newline on purpose - the membership test matches
# "<nl>item<nl>", so without it the first element could never match itself.
PINFILE="$REPO/wiki/.known-stale-diagrams.txt"
PIN_DECLARED=$'\n'
PIN_HITS=$'\n'
load_pins() {
  [ -f "$PINFILE" ] || {
    printf 'check_diagrams: HARNESS ERROR - %s is missing, so a known-stale render cannot be told from a new one\n' "$PINFILE"
    exit 1
  }
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086  # word splitting is the point: $1=file, $2..=reason
    set -- $line
    if [ "$#" -lt 2 ]; then
      printf 'check_diagrams: HARNESS ERROR - malformed line in %s:\n  %s\n  expected: <render-file> <reason>\n' "$PINFILE" "$line"
      exit 1
    fi
    PIN_DECLARED="${PIN_DECLARED}$1
"
  done < "$PINFILE"
}
_in_list() {
  case "$1" in *"
$2
"*) return 0 ;; *) return 1 ;; esac
}
# A stale render whose name is pinned: reported, recorded as FIRED, not counted.
pin_note() {
  _in_list "$PIN_DECLARED" "$1" || return 1
  PIN_HITS="${PIN_HITS}$1
"
  printf '  note: %s is STALE but PINNED (known-stale, awaiting its owner-s re-render)\n' "$1"
  return 0
}
# After the checks: EVERY declared pin must have fired. The two ways one can fail
# to are told apart because the remedies differ - the render was fixed (collect
# the pin) versus the render is gone (which is its own news).
pin_audit() {
  local rel why
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _in_list "$PIN_HITS" "$rel" && continue
    why=$(awk -v k="$rel" '$1==k { $1=""; sub(/^ /,""); print; exit }' "$PINFILE" 2>/dev/null)
    if [ ! -e "$REPO/diagrams/$rel" ]; then
      fail "STALE-PIN-ABSENT $rel - pinned as known-stale but the render is not in diagrams/ at all: collect the pin AND check the render was not lost (pinned reason: ${why:-none})"
    else
      fail "STALE-PIN $rel - pinned as known-stale but is no longer stale, so the pin has outlived its defect: DELETE this line from $PINFILE (pinned reason: ${why:-none})"
    fi
  done <<PINLIST
$PIN_DECLARED
PINLIST
}

# ---- the stems PlantUML produces for an N-block source ---------------------
block_count() { grep -c '^[[:space:]]*@startuml' "$1" 2>/dev/null || echo 0; }

expected_stems() {  # source n
  local src="$1" n="$2" stem k
  stem="${src%.puml}"
  printf '%s\n' "$stem"
  k=2
  while [ "$k" -le "$n" ]; do
    printf '%s\n' "$(printf '%s_%03d' "$stem" $((k - 1)))"
    k=$((k + 1))
  done
}

# Stale by more than the tolerance. `-nt` is not usable here: it is false for
# EQUAL timestamps, which is exactly the fresh-checkout case.
older_than() {  # file ref tolerance_seconds
  local a b
  a=$(stat -c %Y "$1" 2>/dev/null) || return 1
  b=$(stat -c %Y "$2" 2>/dev/null) || return 1
  [ $((b - a)) -gt "$3" ]
}

# PNG width/height from the IHDR chunk: bytes 16..24 of any PNG are the
# big-endian width and height, which is why this needs no image library.
png_aspect() {
  python3 - "$1" <<'PY' 2>/dev/null || echo nan
import struct, sys
try:
    d = open(sys.argv[1], 'rb').read(26)
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        print('nan'); raise SystemExit
    w, h = struct.unpack('>II', d[16:24])
    print('%.4f' % (w / h) if h else 'nan')
except Exception:
    print('nan')
PY
}

# ---- one directory's worth of checks ---------------------------------------
# 0 = clean, 1 = at least one failure. `quiet` suppresses the per-file narration
# so the self-test's own output is readable.
check_dir() {
  local dir="$1" label="${2:-$1}" quiet="${3:-0}"
  local n_puml=0 n_png=0 n_svg=0 n_orphan=0 bad_total=0
  [ "$quiet" = "1" ] || printf '\n== %s ==\n' "$label"

  # bad_total, NOT the global FAILURES, accumulates inside this function and is
  # published once at the end. The first version incremented a global directly
  # and used the `A && B || C` shape to decide, which can skip a count entirely
  # when B fails -- a gate whose failure tally can under-count is a gate that can
  # pass on a broken tree, which is the whole defect this gate exists to catch.
  if [ ! -d "$dir" ]; then
    # `return 1` EXPLICITLY. An earlier version fell off the end of this branch,
    # which returned the status of the arithmetic assignment above — always 0 —
    # so a gate pointed at a directory that does not exist reported PASS. The CLI
    # entry point happened to mask it by re-testing FAILURES afterwards; the
    # self-test does not, and neither should any future caller.
    [ "$quiet" = "1" ] || fail "$dir is not a directory"
    FAILURES=1
    return 1
  fi

  local work src base n st
  work=$(mktemp -d "/tmp/diag_gate.${_wt}.XXXXXX") || { FAILURES=$((FAILURES + 1)); return; }

  # ---- 1. syntax ---------------------------------------------------------
  # TWO STAGES, because the per-file form costs 11.7 s of the gate's time and
  # the batched form costs 0.5 s but does not name the offending file. So: ask
  # once for the whole directory, and only if something is broken pay for the
  # per-file loop purely to attribute it. On a healthy tree the fast path is the
  # whole of this check; on a broken one the same 11.7 s buys a filename, which
  # is exactly when it is worth paying.
  local any_puml=0
  for src in "$dir"/*.puml; do
    [ -e "$src" ] || { [ "$quiet" = "1" ] || fail "no .puml files in $dir"; bad_total=$((bad_total + 1)); break; }
    n_puml=$((n_puml + 1)); any_puml=1
  done
  if [ $any_puml -eq 1 ] && ! plantuml --check-syntax "$dir"/*.puml >/dev/null 2>&1; then
    for src in "$dir"/*.puml; do
      [ -e "$src" ] || continue
      if ! plantuml --check-syntax "$src" >/dev/null 2>&1; then
        local syn; syn=$(plantuml --check-syntax "$src" 2>&1 | head -2 | tr '\n' ' ')
        [ "$quiet" = "1" ] || fail "$(basename "$src") does not parse: $syn"
        bad_total=$((bad_total + 1))
      fi
    done
  fi

  # ---- 2a. every block has BOTH formats, colocated ------------------------
  for src in "$dir"/*.puml; do
    [ -e "$src" ] || continue
    base=$(basename "$src")
    n=$(block_count "$src")
    local miss=0
    # Read the stems a LINE AT A TIME, never as `for st in $(...)`. The stems are
    # filenames, and unquoted command substitution word-splits them, so a source
    # called "my figure.puml" was reported as needing my.png, my.svg,
    # figure.png AND figure.svg — four false failures, immediately followed by
    # "every render is fresh and byte-consistent" for a file the loop had never
    # visited. No diagram in this repo has a space in its name today, so this was
    # latent rather than active; but a gate that is only correct while nobody
    # names a file the obvious way is correct by luck, and the day it fires the
    # red gets ignored or the gate gets disabled.
    while IFS= read -r st; do
      [ -n "$st" ] || continue
      [ -f "${st}.png" ] || { miss=1; [ "$quiet" = "1" ] || fail "$base: no ${st##*/}.png for one of its $n block(s)"; }
      [ -f "${st}.svg" ] || { miss=1; [ "$quiet" = "1" ] || fail "$base: no ${st##*/}.svg for one of its $n block(s)"; }
    done < <(expected_stems "$src" "$n")
    if [ $miss -ne 0 ]; then
      bad_total=$((bad_total + 1))
    else
      ok "$base: $n block(s), both formats colocated"
    fi
  done

  # ---- 2b. GLOBALLY: no render in the directory is unclaimed --------------
  # Built from every source's expected stems, so a stem that is a prefix of
  # another source's stem does not read as an orphan.
  local claimed; claimed=$(mktemp "/tmp/diag_claimed.${_wt}.XXXXXX")
  for src in "$dir"/*.puml; do
    [ -e "$src" ] || continue
    expected_stems "$src" "$(block_count "$src")" >> "$claimed"
  done
  for st in "$dir"/*.png "$dir"/*.svg; do
    [ -e "$st" ] || continue
    local key="${st%.*}"
    if ! grep -qxF "$key" "$claimed"; then
      n_orphan=$((n_orphan + 1))
      [ "$quiet" = "1" ] || fail "ORPHANED render $(basename "$st") — no .puml in $dir produces it"
    fi
  done
  if [ $n_orphan -ne 0 ]; then bad_total=$((bad_total + n_orphan)); fi
  rm -f "${claimed:?}"

  # ---- 3. freshness + consistency, BATCHED --------------------------------
  # One plantuml invocation per format for the whole directory, not two per
  # source: 22 sources x 2 formats was 44 JVM starts and 40 seconds, which is
  # too slow for a suite step. Batched it is two starts.
  local fresh="$work/fresh"; mkdir -p "$fresh"
  plantuml -tpng "$dir"/*.puml -o "$fresh" >/dev/null 2>&1
  plantuml -tsvg "$dir"/*.puml -o "$fresh" >/dev/null 2>&1

  for src in "$dir"/*.puml; do
    [ -e "$src" ] || continue
    base=$(basename "$src")
    n=$(block_count "$src")
    # ---- 0. the toolchain pin, which the byte comparison depends on --------
  local pin="$dir/$PIN_NAME" tc_rc=0
  compare_toolchain "$pin" > "$work/tc.txt" 2>/dev/null || tc_rc=$?
  if [ "$tc_rc" -eq 2 ]; then
    [ "$quiet" = "1" ] || fail "no toolchain pin at $pin -- the byte comparison would be unenforceable, so it is NOT silently skipped"
    bad_total=$((bad_total + 1))
    tc_rc=1
  elif [ "$tc_rc" -eq 1 ]; then
    while IFS= read -r mm; do [ -n "$mm" ] && printf '  TOOLCHAIN MISMATCH: %s\n' "$mm"; done < "$work/tc.txt"
    printf '  note: byte-differences below are INCONCLUSIVE while the toolchain\n'
    printf '        differs; see %s. Re-render, or pin what this host has.\n' "$pin"
  fi

  # THE BYTE COMPARISON IS THE TRUTH AND THE MTIME IS ONLY A HINT. An earlier
    # version failed on the mtime alone, and reported 64 failures on a tree where
    # every single figure was byte-identical to a fresh render — because
    # restoring, checking out or `cp`-ing a .puml updates its mtime without
    # changing one byte of its output, and a gate that goes red on that is a gate
    # that cries wolf and then gets disabled. So: a render that is older than its
    # source but byte-identical to a fresh render of it IS up to date, and is
    # reported as such. The mtime still earns its place by explaining a real
    # mismatch ("edited at T, rendered before T") and by being free.
    local bad=0
    while IFS= read -r st; do
      [ -n "$st" ] || continue
      for ext in png svg; do
        local committed rendered
        committed="${st}.${ext}"
        rendered="$fresh/$(basename "$st").${ext}"
        [ -f "$committed" ] || continue
        local stale=0
        older_than "$committed" "$src" "$MTIME_TOL" && stale=1
        if [ ! -f "$rendered" ]; then
          bad=1; [ "$quiet" = "1" ] || fail "$(basename "$committed") is not produced by the current source at all"
        elif ! cmp -s "$committed" "$rendered"; then
          # Inconclusive while the toolchain differs: the bytes may simply be
          # another renderer's. A hard failure here is the red that no diagram
          # change can clear, which is the defect being fixed.
          # A PINNED stale render is reported and NOT counted, and it is
          # consulted BEFORE bad=1 is set: suppressing only the message left the
          # stem counted as a failing directory, so the gate printed no FAIL line
          # and still exited 1 - a red that names nothing.
          if pin_note "$(basename "$committed")"; then
            :
          elif [ "$tc_rc" -ne 0 ]; then
            [ "$quiet" = "1" ] || printf '  inconclusive: %s differs from a fresh render, but the toolchain differs\n' "$(basename "$committed")"
          else
            bad=1
            if [ "$stale" -eq 1 ]; then
              [ "$quiet" = "1" ] || fail "$(basename "$committed") differs from a fresh render AND is older than its source — re-render it"
            else
              [ "$quiet" = "1" ] || fail "$(basename "$committed") differs from a fresh render of the current source"
            fi
          fi
        elif [ "$stale" -eq 1 ]; then
          [ "$quiet" = "1" ] || printf '  note: %s is older than its source but byte-identical to a fresh render — up to date\n' "$(basename "$committed")"
        fi
      done
    done < <(expected_stems "$src" "$n")
    if [ $bad -ne 0 ]; then
      bad_total=$((bad_total + 1))
    else
      ok "$base: every render is fresh and byte-consistent"
    fi
  done

  # ---- 4. aspect ---------------------------------------------------------
  # ONE python process for the whole directory: 42 separate interpreter starts
  # cost more than the render comparison did, and a per-file loop that shells
  # out 42 times to read 8 bytes of a header is the kind of cost nobody
  # notices until a gate is 7 seconds instead of 5.
  local aspects
  aspects=$(find "$dir" -maxdepth 1 -name '*.png' | sort | python3 -c '
import struct, sys
for path in (l.strip() for l in sys.stdin if l.strip()):
    try:
        d = open(path, "rb").read(26)
        if d[:8] != b"\x89PNG\r\n\x1a\n":
            print("%s\tnan" % path); continue
        w, h = struct.unpack(">II", d[16:24])
        print("%s\t%.4f" % (path, (w / h) if h else float("nan")))
    except Exception:
        print("%s\tnan" % path)
' 2>/dev/null)
  local lo=99999 lo_f="" hi=0 hi_f=""
  local path a
  while IFS="$(printf '\t')" read -r path a; do
    [ -n "${path:-}" ] || continue
    case "$a" in
      nan|'')
        [ "$quiet" = "1" ] || fail "$(basename "$path") is not a readable PNG"
        bad_total=$((bad_total + 1)) ;;
      *)
        if awk -v v="$a" -v lo="$ASPECT_MIN" -v hi="$ASPECT_MAX" 'BEGIN{exit !(v<lo || v>hi)}'; then
          [ "$quiet" = "1" ] || fail "$(basename "$path") aspect $a is outside [$ASPECT_MIN, $ASPECT_MAX] — a layout accident"
          bad_total=$((bad_total + 1))
        fi
        awk -v v="$a" -v c="$lo" 'BEGIN{exit !(v<c)}' && { lo=$a; lo_f=$(basename "$path"); }
        awk -v v="$a" -v c="$hi" 'BEGIN{exit !(v>c)}' && { hi=$a; hi_f=$(basename "$path"); }
        ;;
    esac
  done <<EOF
$aspects
EOF
  if [ -n "$lo_f" ]; then
    ok "aspects within band (tallest $lo_f $lo, widest $hi_f $hi)"
  fi

  n_png=$(find "$dir" -maxdepth 1 -name '*.png' | wc -l)
  n_svg=$(find "$dir" -maxdepth 1 -name '*.svg' | wc -l)
  [ "$quiet" = "1" ] || printf '  -- %d .puml, %d .png, %d .svg in %s\n' "$n_puml" "$n_png" "$n_svg" "$dir"

  rm -rf "${work:?}"
  FAILURES=$bad_total
  [ "$bad_total" -eq 0 ]
}

# ---- the self-test ----------------------------------------------------------
# A SYNTHETIC FIXTURE, not a copy of the real diagrams/. Two reasons, and the
# second is the important one:
#
#   1. Speed. The first version copied all 42 renders and ran the whole check
#      seven times: 56 seconds, which is far too slow to wire into a suite step
#      on every run. The fixture is two small sources, so the self-test is ~2 s.
#   2. Independence. A self-test that copies the real tree can only test the
#      defect classes the real tree happens to contain. It cannot prove the
#      checker fires on, say, a stale render if no render in diagrams/ is stale.
#      A synthetic fixture is built to contain exactly the cases under test, so
#      every case is exercised whether or not the tree needs fixing today.
#
# The fixture is: one 2-block source (which exercises the multi-block stem
# convention) and one 1-block source, each with both formats rendered.
build_fixture() {  # dest
  local d="$1"
  mkdir -p "$d"
  cat > "$d/fixture-multi.puml" <<'PUML'
@startuml
title fixture block one
state "A" as A
state "B" as B
A --> B
@enduml
@startuml
title fixture block two
state "C" as C
C --> C : self
@enduml
PUML
  cat > "$d/fixture-single.puml" <<'PUML'
@startuml
title fixture single block
state "D" as D
D --> [*]
@enduml
PUML
  plantuml -tpng "$d"/*.puml -o "$d" >/dev/null 2>&1
  plantuml -tsvg "$d"/*.puml -o "$d" >/dev/null 2>&1
  # A pin MATCHING this host, so the byte comparison is authoritative in the
  # fixture and the planted cases below test the byte comparison rather than the
  # toolchain check. Without it every byte case would be inconclusive and the
  # self-test would pass for the wrong reason.
  detect_toolchain > "$d/$PIN_NAME"
}

# A pin that deliberately disagrees with this host, for the environmental case.
write_mismatched_pin() {  # dest
  printf 'plantuml    = 0.0.0-not-a-real-release\ngraphviz    = 0.0.0\njava        = 0.0.0\n' > "$1/$PIN_NAME"
}

self_test() {
  have plantuml || { printf 'self-test: plantuml not found\n'; return 1; }
  local sandbox results=0 caught=0
  sandbox=$(mktemp -d "/tmp/diag_selftest.${_wt}.XXXXXX") || return 1
  build_fixture "$sandbox/f"

  # A helper so every case is judged identically, and the verdict is always the
  # one question that matters: did the checker NOTICE?
  plant() {  # name expect case_name
    local name="$1" expect="$2" got dir="$sandbox/$3"
    results=$((results + 1))
    if check_dir "$dir" "$dir" 1; then got=clean; else got=dirty; fi
    if [ "$expect" = "clean" ] && [ "$got" = "clean" ]; then
      printf '  ok:   self-test — %-42s untouched: PASSES\n' "$name"; caught=$((caught + 1))
    elif [ "$expect" = "dirty" ] && [ "$got" = "dirty" ]; then
      printf '  ok:   self-test — %-42s planted:  CAUGHT\n' "$name"; caught=$((caught + 1))
    else
      printf '  FAIL: self-test — %-42s expected %s, checker said %s\n' "$name" "$expect" "$got"
    fi
  }
  # Each case gets its own pristine copy of the fixture.
  # ${var:?} on BOTH halves: this is the only destructive line in the file, and
  # an empty parent would otherwise turn into a path like "/c0" rather than a
  # hard error. Cheap insurance in a tool whose promise is that it never touches
  # the real tree.
  fresh_case() { rm -rf "${sandbox:?}/${1:?}"; cp -r "$sandbox/f" "$sandbox/$1"; }

  # did_change FILE_BEFORE FILE_AFTER — a planting that silently did nothing must
  # be reported as a PLANTING failure, not as a checker failure. The first
  # version of case (c) hit exactly this: `sed` without /g replaced only the
  # FIRST data-source-line attribute, whose value was already 1, so the file came
  # out byte-identical, the checker correctly said "clean", and the self-test
  # concluded the checker was broken. Verifying the planting is what separates the
  # two, and it is the difference between a self-test that diagnoses and one that
  # misleads.
  planting_check() {  # name before after
    if cmp -s "$2" "$3"; then
      printf '  FAIL: self-test — %s: the PLANTING changed nothing, so this\n' "$1"
      printf '        case cannot say anything about the checker\n'
      return 1
    fi
    return 0
  }

  # (0) baseline. Must PASS, or every case below proves nothing — which is
  # exactly the mistake a planted failure is otherwise indistinguishable from.
  fresh_case c0; plant "baseline" clean c0

  # (a) STALE RENDER. The source is changed in a way that VISIBLY alters the
  #     picture, and the renders are then aged so the source is unambiguously
  #     newer. Both halves matter and the first version of this case got both
  #     wrong: it appended a trailing COMMENT, which does not move any
  #     data-source-line reference, so the render bytes were legitimately
  #     identical and the checker correctly said "clean"; and it aged the SOURCE
  #     rather than the renders, which made the mtime test see a fresh picture.
  #     A checker that had been wrong there would have looked right.
  fresh_case c1
  cp "$sandbox/c1/fixture-multi.svg" "$sandbox/c1-before.svg"
  sed -i 's/^title fixture block one$/title PLANTED STALE/' "$sandbox/c1/fixture-multi.puml"
  plantuml -tsvg "$sandbox/c1/fixture-multi.puml" -o "$sandbox/c1-ref" >/dev/null 2>&1
  if ! planting_check "a stale render" "$sandbox/c1-before.svg" "$sandbox/c1-ref/fixture-multi.svg"; then
    results=$((results + 1))
  else
    for r in "$sandbox/c1"/fixture-multi*.png "$sandbox/c1"/fixture-multi*.svg; do
      touch -d '10 seconds ago' "$r"
    done
    plant "a stale render" dirty c1
  fi

  # (b) BROKEN .puml. Plantuml renders an ERROR IMAGE for this and still exits
  #     non-zero, so the committed artifact would be a picture of a parser
  #     complaint — indistinguishable from a diagram to anything that only looks
  #     at the file.
  fresh_case c2
  printf '@startuml\ntitle planted\nstate "A" as A\nA --> \n' > "$sandbox/c2/fixture-broken.puml"
  plant "b a broken .puml" dirty c2

  # (c) HAND-EDITED RENDER, with a NEWER mtime than its source. This is the
  #     data-source-line drift class and the case an mtime-only test cannot
  #     see, which is the whole reason the byte comparison is here.
  fresh_case c3
  cp "$sandbox/c3/fixture-single.svg" "$sandbox/c3-before.svg"
  # /g is not cosmetic: without it sed replaces only the first match, and a
  # hand-edit that happens to write back the value already there is a no-op.
  sed -i 's/data-source-line="[0-9]*"/data-source-line="1"/g' "$sandbox/c3/fixture-single.svg" 2>/dev/null
  if ! planting_check "c a hand-edited render" "$sandbox/c3-before.svg" "$sandbox/c3/fixture-single.svg"; then
    # The drift class is unavailable in this SVG (no such attribute); fall back
    # to a byte-level hand edit, which the byte comparison must still catch.
    printf '<!-- hand edit -->\n' >> "$sandbox/c3/fixture-single.svg"
    planting_check "c a hand-edited render (fallback)" "$sandbox/c3-before.svg" "$sandbox/c3/fixture-single.svg" \
      && { touch "$sandbox/c3/fixture-single.svg"; plant "c a hand-edited render" dirty c3; }
    results=$((results + 1))
  else
    touch "$sandbox/c3/fixture-single.svg"
    plant "c a hand-edited render" dirty c3
  fi

  # (d) UNCLAIMED RENDER: a picture of code that no longer exists.
  fresh_case c4
  [ -f "$sandbox/c4/fixture-single.png" ] || { printf '  FAIL: self-test — d: nothing to unclaim\n'; results=$((results + 1)); }
  if [ -f "$sandbox/c4/fixture-single.png" ]; then
    mv "$sandbox/c4/fixture-single.png" "$sandbox/c4/zz-unclaimed.png"
    plant "d an unclaimed render" dirty c4
  fi

  # (e) A BLOCK'S RENDER REMOVED: an unviewable figure.
  fresh_case c5
  if [ -f "$sandbox/c5/fixture-multi_001.svg" ]; then
    rm -f "$sandbox/c5/fixture-multi_001.svg"
    plant "e a missing block render" dirty c5
  else
    printf '  FAIL: self-test — e: the fixture has no second block, so the\n'
    printf '        multi-block convention is not being exercised at all\n'
    results=$((results + 1))
  fi

  # (f) AN ERROR IMAGE COMMITTED AS A RENDER. The planted source really does
  #     produce a valid PNG, so a size/format/"is it a PNG" check could not
  #     catch it — only the syntax check can.
  fresh_case c6
  printf '@startuml\ntitle planted\nstate "A" as A\nnote over A : multi\n  line note\n@enduml\n' \
    > "$sandbox/c6/fixture-err.puml"
  plantuml -tpng "$sandbox/c6/fixture-err.puml" -o "$sandbox/c6" >/dev/null 2>&1
  plantuml -tsvg "$sandbox/c6/fixture-err.puml" -o "$sandbox/c6" >/dev/null 2>&1
  if [ -f "$sandbox/c6/fixture-err.png" ]; then
    printf '       (the planted source DID produce a %s-byte PNG, so a\n' "$(stat -c %s "$sandbox/c6/fixture-err.png")"
    printf '        "is it a valid PNG" check could not have caught this)\n'
  fi
  plant "f an error image committed as a render" dirty c6

  # (g) A SOURCE WHOSE NAME CONTAINS A SPACE. This is the word-splitting class,
  #     and it is here because the fix without this case would rot silently: the
  #     checker read `for st in $(expected_stems ...)`, so "my figure.puml" was
  #     reported as needing my.png, my.svg, figure.png AND figure.svg — four
  #     false failures immediately followed by "every render is fresh and
  #     byte-consistent" for a file the loop had never visited. No diagram in
  #     this repo has a space in its name, so the class was latent; a checker that
  #     is only correct while nobody names a file the obvious way is correct by
  #     luck. The planted tree here is a CORRECT tree, so the expectation is
  #     PASS: this case fails if the checker gets noisier, not if it gets laxer.
  fresh_case c7
  if [ -f "$sandbox/c7/fixture-single.puml" ]; then
    cp "$sandbox/c7/fixture-single.puml" "$sandbox/c7/a figure with spaces.puml"
    cp "$sandbox/c7/fixture-single.png"  "$sandbox/c7/a figure with spaces.png"
    cp "$sandbox/c7/fixture-single.svg"  "$sandbox/c7/a figure with spaces.svg"
    plantuml -tpng "$sandbox/c7/a figure with spaces.puml" -o "$sandbox/c7" >/dev/null 2>&1
    plantuml -tsvg "$sandbox/c7/a figure with spaces.puml" -o "$sandbox/c7" >/dev/null 2>&1
    # The copy above is only a stand-in if PlantUML refused the spaced name, so
    # assert the real renders exist rather than trusting the cp.
    if [ -f "$sandbox/c7/a figure with spaces.png" ] && [ -f "$sandbox/c7/a figure with spaces.svg" ]; then
      plant "g a source name containing spaces" clean c7
    else
      printf '  FAIL: self-test — g: PlantUML did not render the spaced name, so\n'
      printf '        the word-splitting class cannot be exercised\n'
      results=$((results + 1))
    fi
  else
    printf '  FAIL: self-test — g: no single-block fixture to rename\n'
    results=$((results + 1))
  fi

  # (h) THE ENVIRONMENTAL CASE: the renders are byte-INCONSISTENT with a fresh
  #     render, but the pin disagrees with this host, so the difference cannot be
  #     attributed to the figures. The gate must report a TOOLCHAIN MISMATCH and
  #     treat the byte difference as inconclusive -- NOT as a stale render.
  #
  #     This is the case that was missing, and its absence is why the first
  #     version of this gate shipped a red that no diagram change could clear: a
  #     sibling worker hit exactly that on the two largest maps while thirty
  #     smaller figures passed. Note the planted tree really is byte-inconsistent
  #     (the render is genuinely different from a fresh render), so a gate that
  #     ignores the pin would catch it -- and would be WRONG to, because on a host
  #     with a different dot version the same red would be a false positive.
  fresh_case c8
  sed -i 's/^title fixture block one$/title PLANTED ENVIRONMENTAL/' "$sandbox/c8/fixture-multi.puml"
  write_mismatched_pin "$sandbox/c8"
  # Assert the tree really is byte-inconsistent, or the case proves nothing.
  plantuml -tsvg "$sandbox/c8/fixture-multi.puml" -o "$sandbox/c8-ref" >/dev/null 2>&1
  if ! cmp -s "$sandbox/c8/fixture-multi.svg" "$sandbox/c8-ref/fixture-multi.svg"; then
    results=$((results + 1))
    out=$(check_dir "$sandbox/c8" "$sandbox/c8" 1 2>&1)
    if printf '%s' "$out" | grep -q 'TOOLCHAIN MISMATCH'; then
      if printf '%s' "$out" | grep -q 'stale render\|differs from a fresh render of the current'; then
        printf '  FAIL: self-test — h: reported a toolchain mismatch AND blamed the\n'
        printf '        render, which is the false positive this case exists to stop\n'
      else
        printf '  ok:   self-test — %-42s planted:  CAUGHT\n' "h a byte difference under a differing toolchain"
        caught=$((caught + 1))
      fi
    else
      printf '  FAIL: self-test — h: no TOOLCHAIN MISMATCH reported, so a byte\n'
      printf '        difference would be blamed on the figures\n'
    fi
  else
    printf '  FAIL: self-test — h: the planted tree is not byte-inconsistent, so\n'
    printf '        the case cannot exercise the toolchain path\n'
  fi

  # (i) A MISSING PIN must be a failure, not a silent skip: without a pin the
  #     byte comparison is unenforceable, and skipping it would be fail-open.
  fresh_case c9
  rm -f "$sandbox/c9/$PIN_NAME"
  plant "i a missing toolchain pin" dirty c9

  printf '  -- self-test: %d of %d cases behaved correctly\n' "$caught" "$results"
  rm -rf "${sandbox:?}"
  [ "$caught" -eq "$results" ]
}

# ---- entry ------------------------------------------------------------------
case "${1:-}" in
  --self-test)
    printf '=== diagrams self-test: the checker must still FAIL on planted defects ===\n'
    # if/then rather than `A && B || C`: as a gate entry point it must not be
    # able to report FAILED just because printing the success line went wrong.
    if self_test; then
      printf 'self-test: OK\n'
    else
      printf 'self-test: FAILED\n'
      exit 1
    fi
    ;;
  --help|-h)
    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
    ;;
  "")
    for dep in plantuml python3 cmp; do
      have "$dep" || { printf 'check_diagrams: %s not found — cannot check diagrams/\n' "$dep"; exit 1; }
    done
    printf '=== diagrams: syntax, colocation, freshness, consistency, aspect ===\n'
    printf '    multi-block convention: block 1 is <stem>, blocks 2..N are\n'
    printf '    <stem>_001..<stem>_(N-1), in BOTH .png and .svg, beside the source\n'
    FAILURES=0
    load_pins
    check_dir "$REPO/diagrams" "diagrams/"
    # the anti-staleness half, judged only once we know which pins actually fired
    pin_audit
    if [ "$FAILURES" -eq 0 ]; then
      printf '\ndiagrams: OK\n'; exit 0
    fi
    printf '\ndiagrams: %d FAILURE(S)\n' "$FAILURES"; exit 1
    ;;
  *)
    FAILURES=0
    check_dir "$1" "$1"
    [ "$FAILURES" -eq 0 ] || exit 1
    ;;
esac
