#!/usr/bin/env bash
# check_diagram_renders.sh — every checked-in diagram render must be the render
# of its own source, byte for byte.
#
# WHY THIS IS A SEPARATE FILE, and not a sixth rule in check_wiki_pages.sh.
# That gate checks hand-written wiki PAGES against the five rules in
# wiki/SCHEMA.md. This checks generated ARTEFACTS against their generators — the
# same job the generated-page drift checks do for wiki/reference/*, and the same
# job as tools/gen/* --check. Folding it into the page gate would put a
# java-and-plantuml dependency inside a check whose entire virtue is that it is
# a five-line, dependency-free, always-runnable rule pass. When plantuml is
# absent, the page gate must still be able to say something useful, and it must
# not have to apologise for a sibling check first.
#
# WHY IT EXISTS. Nothing gated diagrams/ at all. The directory went from 26 to
# 106 files — 22 PlantUML sources and 84 renders — and the only thing standing
# between a source and its render was somebody remembering. A stale render is
# the worst kind of documentation defect, because it is not wrong-looking: the
# picture is still a correct picture OF SOMETHING, just not of the source next
# to it, and a reader has no way to tell. The project maps already carry a
# documented history of that (a hand-drawn map that claimed a pin matrix which
# did not exist and a flop memory which had been replaced by an SRAM).
#
# MEASURED BEFORE IT WAS BUILT, because a freshness gate that is red on day one
# is worse than no gate — it gets routed around, and then it is worse than no
# gate twice over. Three things were measured rather than assumed:
#   1. Are the renders REPRODUCIBLE? Both formats compare byte-identical when
#      re-rendered from the same source with the documented command. If PlantUML
#      embedded a timestamp or a version banner in the output, this check could
#      only ever be red and the idea would have been wrong.
#   2. What does it COST? 22 sources x 2 formats render in ~4 s, which is noise
#      against a multi-minute regression.
#   3. How many are stale TODAY? None. 84 of 84 renders match, so the gate
#      ships green rather than shipping with a baseline of known failures.
# The checks are byte comparison, not mtime: a checkout that rewrites identical
# content advances every mtime in the tree, and an mtime check would report the
# whole directory stale after a clone.
#
# MULTI-PANEL SOURCES. A .puml may render to numbered siblings —
# proto-midi.puml produces proto-midi.png plus proto-midi_001.png .. _004.png —
# so this compares the WHOLE SET each source emits, in both directions: a
# checked-in render with no source-produced counterpart, and a produced render
# with no checked-in counterpart, are both failures. Comparing only
# <name>.png would have silently ignored half the directory.
#
# FAIL-CLOSED, EXCEPT WHERE IT CANNOT BE. No plantuml, or no source directory,
# is a LOUD SKIP: the check reports that it did not run and why, and exits 0,
# because a box without a diagram renderer is a normal box and a regression that
# fails for want of one trains people to ignore reds. It is never silent — the
# skip prints, so a green run always distinguishes "checked" from "not
# checked", which is the distinction this project cares most about.
#
# ONE trap only, for the same reason every harness here has one: a second EXIT
# trap REPLACES the first, silently discarding it.
#
# Usage:
#   regress/check_diagram_renders.sh          judge
#   regress/check_diagram_renders.sh --list   print every source and its renders
# Exit: 0 clean or loud skip · 1 a stale/orphaned render · 2 usage
set -u
cd "$(dirname "$0")/.." || exit 1

DIR=diagrams
LIST_ONLY=0
case "${1:-}" in
  "")        ;;
  --list)    LIST_ONLY=1 ;;
  -h|--help) sed -n '2,54p' "$0"; exit 0 ;;
  *)         echo "usage: $0 [--list]" >&2; exit 2 ;;
esac

if [ ! -d "$DIR" ]; then
  echo "diagram renders: SKIPPED — $DIR is not a directory" >&2
  exit 0
fi
n_src=$(find "$DIR" -maxdepth 1 -name '*.puml' | wc -l | tr -d ' ')
if [ "$n_src" -lt 1 ]; then
  # A directory with no sources is not "nothing to check", it is a filter that
  # stopped matching. Say so rather than reporting a clean directory.
  echo "diagram renders: HARNESS ERROR — no .puml sources under $DIR" >&2
  exit 1
fi
if ! command -v plantuml >/dev/null 2>&1; then
  echo "diagram renders: SKIPPED — plantuml is not on PATH, so freshness is UNCHECKED" >&2
  echo "  (a stale render is invisible to every other gate; this is the one that catches it)" >&2
  exit 0
fi

# The documented render invocation, from diagrams/README.md. PLANTUML_LIMIT_SIZE
# is in that command because these maps are large; dropping it produces empty or
# truncated renders, which would then compare unequal and look like staleness.
export JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192"

TMP=$(mktemp -d) || { echo "diagram renders: HARNESS ERROR — mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

echo "diagram renders: re-rendering $n_src source(s) x 2 formats from $DIR"
if ! plantuml -tsvg -o "$TMP" "$DIR"/*.puml >"$TMP/svg.log" 2>&1; then
  echo "diagram renders: HARNESS ERROR — the svg render pass failed" >&2
  tail -10 "$TMP/svg.log" >&2
  exit 1
fi
if ! plantuml -tpng -o "$TMP" "$DIR"/*.puml >"$TMP/png.log" 2>&1; then
  echo "diagram renders: HARNESS ERROR — the png render pass failed" >&2
  tail -10 "$TMP/png.log" >&2
  exit 1
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for f in "$DIR"/*.puml; do
    b=$(basename "$f" .puml)
    printf '%s\n' "$b"
    for r in "$TMP/$b".png "$TMP/$b"_[0-9][0-9][0-9].png; do
      [ -f "$r" ] && printf '    %s\n' "$(basename "$r")"
    done
  done
  exit 0
fi

# --- per source: compare the whole set it emits -------------------------------
stale=0; orphan=0; unproduced=0; compared=0
: > "$TMP/findings"
for f in "$DIR"/*.puml; do
  b=$(basename "$f" .puml)
  for ext in svg png; do
    for prod in "$TMP/$b.$ext" "$TMP/${b}"_[0-9][0-9][0-9]."$ext"; do
      [ -f "$prod" ] || continue
      rel=$(basename "$prod")
      if [ ! -f "$DIR/$rel" ]; then
        orphan=$((orphan + 1))
        printf 'ORPHANED  %s — produced by %s.puml but not checked in\n' "$rel" "$b" >> "$TMP/findings"
      elif cmp -s "$DIR/$rel" "$prod"; then
        compared=$((compared + 1))
      else
        stale=$((stale + 1))
        printf 'STALE     %s — differs from the render of %s.puml (checked in %s B, fresh %s B)\n' \
          "$rel" "$b" "$(wc -c < "$DIR/$rel" | tr -d ' ')" "$(wc -c < "$prod" | tr -d ' ')" >> "$TMP/findings"
      fi
    done
  done
done

# --- the other direction, and the BUG a self-test caught here ---------------
# This used to ask only "does a .puml exist whose base name matches this render",
# which is NOT the same question. The self-test added a checked-in
# proto-midi_009.png — a numbered panel BEYOND the ones proto-midi.puml actually
# produces — and the gate reported OK. Both directions missed it: the produced
# sweep only walks files the render produced, and the base-name sweep stripped
# the _009 and found proto-midi.puml happily. So a stale EXTRA panel, which is
# exactly what a deleted or renamed panel leaves behind, was invisible forever.
#
# The question that is actually right is set membership: is this checked-in file
# one of the files the source produced? That catches the extra panel, a
# hand-copied render, and a render whose source was deleted or renamed, in one
# test — and it cannot be satisfied by a matching base name.
: > "$TMP/produced"
for r in "$TMP"/*.png "$TMP"/*.svg; do [ -f "$r" ] && basename "$r" >> "$TMP/produced"; done
LC_ALL=C sort -u -o "$TMP/produced" "$TMP/produced"

for r in "$DIR"/*.png "$DIR"/*.svg; do
  [ -f "$r" ] || continue
  rel=$(basename "$r")
  if ! grep -qxF "$rel" "$TMP/produced"; then
    unproduced=$((unproduced + 1))
    printf 'NO-SOURCE %s — not among the files any .puml in %s renders\n' "$rel" "$DIR" >> "$TMP/findings"
  fi
done

echo "  compared: $compared render(s) byte-for-byte; $n_src source(s)"
if [ "$stale" -eq 0 ] && [ "$orphan" -eq 0 ] && [ "$unproduced" -eq 0 ]; then
  echo "diagram renders: OK — every checked-in render matches its source"
  exit 0
fi
echo "diagram renders: FAILED" >&2
[ -s "$TMP/findings" ] && cat "$TMP/findings" >&2
echo "  stale=$stale orphaned=$orphan no-source=$unproduced" >&2
echo "  fix: re-render with the command in diagrams/README.md, or delete the render." >&2
exit 1
