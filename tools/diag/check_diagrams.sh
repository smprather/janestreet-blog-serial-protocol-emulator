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
# and the suite goes green on a claim nothing is testing. The self-test plants
# each defect class in a THROWAWAY COPY and asserts the checker fails on every one
# and passes on the untouched copy, so a planted failure cannot be blamed on the
# copy. It never mutates the real diagrams/, so an interruption cannot leave the
# checkout in a planted state — a lesson this repo has already paid for once.
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
# Staleness tolerance, in seconds. See check 3: a fresh checkout writes every
# file within milliseconds of one instant.
MTIME_TOL=1

FAILURES=0
fail() { printf '  FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
ok()   { printf '  ok:   %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

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
    for st in $(expected_stems "$src" "$n"); do
      [ -f "${st}.png" ] || { miss=1; [ "$quiet" = "1" ] || fail "$base: no ${st##*/}.png for one of its $n block(s)"; }
      [ -f "${st}.svg" ] || { miss=1; [ "$quiet" = "1" ] || fail "$base: no ${st##*/}.svg for one of its $n block(s)"; }
    done
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
  rm -f "$claimed"

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
    for st in $(expected_stems "$src" "$n"); do
      for ext in png svg; do
        local committed="${st}.${ext}" rendered="$fresh/$(basename "$st").${ext}"
        [ -f "$committed" ] || continue
        local stale=0
        older_than "$committed" "$src" "$MTIME_TOL" && stale=1
        if [ ! -f "$rendered" ]; then
          bad=1; [ "$quiet" = "1" ] || fail "$(basename "$committed") is not produced by the current source at all"
        elif ! cmp -s "$committed" "$rendered"; then
          bad=1
          if [ "$stale" -eq 1 ]; then
            [ "$quiet" = "1" ] || fail "$(basename "$committed") differs from a fresh render AND is older than its source — re-render it"
          else
            [ "$quiet" = "1" ] || fail "$(basename "$committed") differs from a fresh render of the current source"
          fi
        elif [ "$stale" -eq 1 ]; then
          [ "$quiet" = "1" ] || printf '  note: %s is older than its source but byte-identical to a fresh render — up to date\n' "$(basename "$committed")"
        fi
      done
    done
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

  rm -rf "$work"
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
  fresh_case() { rm -rf "$sandbox/$1"; cp -r "$sandbox/f" "$sandbox/$1"; }

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

  printf '  -- self-test: %d of %d cases behaved correctly\n' "$caught" "$results"
  rm -rf "$sandbox"
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
    check_dir "$REPO/diagrams" "diagrams/"
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
