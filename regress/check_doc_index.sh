#!/usr/bin/env bash
# check_doc_index.sh — the document INDEX must be COMPLETE, not merely valid.
#
# WHY THIS EXISTS, and it is a different defect from the one that already has a
# gate. regress/check_wiki_links.sh proves every link in the live document
# surface POINTS AT SOMETHING. That is the "listed -> exists" direction. It says
# nothing about the other one: a figure can exist, be perfectly valid, and be
# MISSING from the index, and every existing gate will call the tree clean.
#
# That is not hypothetical here. reviews/2026-09-26/DOCS-ACCURACY-REVIEW-PASS11.md
# finding F3 recorded exactly that state: the README figure table listed 47 of
# 54 PNG renders, with four whole act figure sets absent. The rows were then
# regenerated exhaustively (32a7c18), which closed the omission — and closed
# ONLY that. Measured at report time, the completeness direction was still
# covered by nothing, so the index was exhaustive BY HAND with no gate keeping
# it that way, and it drifts again the first time someone adds a figure and does
# not update the index.
#
# It is the same species as this file's sibling in check_diagrams.sh: an ORPHAN
# render is a picture that no source produces, and an UNLISTED render is a
# picture the index does not mention. The directory is the authority; the index
# is a hand-maintained list derived from it, and a derived list that nothing
# compares against the thing it derives from is a list that will drift.
#
#   regress/check_doc_index.sh              check the real index
#   regress/check_doc_index.sh --self-test  prove this checker can still FAIL
#
# WHY THE SELF-TEST IS IN THE GATE. A checker that stops detecting is worse than
# no checker: it reports OK on a broken tree and the suite goes green on a claim
# nothing is testing. So this file plants each defect class and requires the
# checker to fail on every one, while passing on an untouched fixture — and
# verifies each PLANTING actually changed something, because a no-op planting
# reports itself as a broken checker.
set -u
cd "$(dirname "$0")/.." || exit 1

DIAGRAMS_DIR="diagrams"
INDEX_FILE="README.md"

# ---- the check --------------------------------------------------------------
# $1 = diagrams dir, $2 = index file. Both parameters so the self-test can run
# the SAME code against a synthetic fixture rather than a copy of the real tree.
check_index() { # dir index -> 0 clean, 1 dirty
  local dir="$1" index="$2"
  local bad=0 f base n_png=0 n_listed=0
  [ -d "$dir" ] || { echo "  HARNESS ERROR: no such directory: $dir" >&2; return 1; }
  [ -f "$index" ] || { echo "  HARNESS ERROR: no such index: $index" >&2; return 1; }

  # EVERY RENDER MUST BE LISTED. PNG is the format the index links, so PNG is
  # the format that must be accounted for; the SVG twin of a listed PNG is not
  # an omission, it is the same figure in a second format.
  for f in "$dir"/*.png; do
    [ -e "$f" ] || continue
    n_png=$((n_png + 1))
    base=$(basename "$f")
    # Match the BARE FILENAME anywhere in the index. Deliberately not a
    # markdown-link pattern: the point is that the figure is MENTIONED, and a
    # stricter pattern would let a render hide behind a link format nobody
    # noticed. A number search is not a number's identity, and neither is a
    # filename.
    if ! grep -qF "$base" "$index"; then
      bad=$((bad + 1))
      fail_msg "UNLISTED render $base — it exists in $dir but $index never mentions it"
    else
      n_listed=$((n_listed + 1))
    fi
  done

  # AND EVERY LISTED RENDER MUST EXIST, so the two directions are one assertion
  # rather than two halves that can drift apart. Read line by line rather than
  # iterating a command substitution: `for x in $(grep ...)` word-splits on IFS,
  # so a filename containing a space would be checked as two nonexistent files
  # and the count would be quietly wrong.
  local ref refs
  refs=$(mktemp "/tmp/doc_index_refs.${_wt:-shared}.XXXXXX") || return 1
  grep -oE '[A-Za-z0-9._-]+\.(png|svg)' "$index" 2>/dev/null | LC_ALL=C sort -u > "$refs"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      *diagram.png|*diagram.svg) continue ;;   # a bare word, not a figure
    esac
    if [ ! -f "$dir/$ref" ]; then
      bad=$((bad + 1))
      fail_msg "LISTED-BUT-ABSENT $ref — $index points at it and $dir has no such render"
    fi
  done < "$refs"
  rm -f "${refs:?}"

  echo "  $n_listed/$n_png render(s) listed in $(basename "$index")"
  return $((bad > 0 ? 1 : 0))
}

fail_msg() { echo "$1" >&2; }

# ---- the negative control ---------------------------------------------------
# THE SANDBOX PATH IS FILE-SCOPE, NOT local, and that is load-bearing. The
# EXIT trap runs at SCRIPT exit — after self_test has already returned — so a
# function-local `sb` is gone by then, ${_SB:?} fails, and the trap removes
# nothing. The first version of this file had exactly that, and it is the worst
# combination available: the self-test printed a bash error, still exited 0, and
# LEAKED its sandbox on every run. A check that reports OK while quietly leaking
# is the class this whole session has been about, found in the new gate by the
# final sweep rather than by the self-test itself.
_SB=""
self_test() {
  local results=0 caught=0
  _SB=$(mktemp -d /tmp/doc_index_selftest.XXXXXX) || return 1
  trap 'rm -rf "${_SB:?}"' EXIT

  build_fixture() { # a two-figure corpus whose index lists exactly one
    local d="$1"
    mkdir -p "$d"
    printf '@startuml\ntitle a\n@enduml\n' > "$d/alpha.puml"
    printf '@startuml\ntitle b\n@enduml\n' > "$d/beta.puml"
    # Two renders. The index mentions ONE of them: the other is unlisted, and
    # the whole point of case (a) is that a valid, source-backed render can be
    # absent from the index and still look like a clean tree.
    printf 'PNG-alpha\n' > "$d/alpha.png"
    printf 'PNG-beta\n'  > "$d/beta.png"
    printf 'PNG-alpha\n' > "$d/alpha.svg"
    printf 'PNG-beta\n'  > "$d/beta.svg"
    printf 'see [alpha](diagrams/alpha.png)\n' > "$d/INDEX.md"
  }

  plant() { # name expect case
    local name="$1" expect="$2" case="$3"
    results=$((results + 1))
    rm -rf "${_SB:?}/${case:?}"; mkdir -p "$_SB/$case"
    build_fixture "$_SB/$case/d"
    case "$case" in
      a_unlisted_render) : ;;                    # beta.png unlisted from the start
      b_listed_but_absent)
        printf 'see [gamma](diagrams/gamma.png)\n' >> "$_SB/$case/d/INDEX.md" ;;
      c_everything_listed)
        printf 'see [beta](diagrams/beta.png)\n' >> "$_SB/$case/d/INDEX.md" ;;
    esac
    if check_index "$_SB/$case/d" "$_SB/$case/d/INDEX.md" >/dev/null 2>&1; then got=clean; else got=dirty; fi
    if [ "$expect" = "$got" ]; then
      printf '  ok:   self-test — %-38s expected %-5s, checker said %s\n' "$name" "$expect" "$got"
      caught=$((caught + 1))
    else
      printf '  FAIL: self-test — %-38s expected %-5s, checker said %s\n' "$name" "$expect" "$got"
    fi
  }

  echo "check_doc_index self-test:"
  # (0) baseline: the fixture is DELIBERATELY incomplete, so a checker that
  #     cannot see the omission would pass this and every case below proves
  #     nothing.
  plant "(a) an UNLISTED render is caught"      dirty a_unlisted_render
  plant "(b) a listed-but-absent render is caught" dirty b_listed_but_absent
  # (c) the negative control in the other direction: complete corpus, and the
  #     checker must be SILENT. Without this, a checker that always fails would
  #     satisfy (a) and (b) and be worthless.
  plant "(c) a COMPLETE index stays silent"     clean c_everything_listed

  echo "check_doc_index self-test: $caught/$results cases behaved correctly"
  [ "$caught" -eq "$results" ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *)           if check_index "$DIAGRAMS_DIR" "$INDEX_FILE"; then
                 echo "document index: OK"
                 exit 0
               else
                 echo "document index: FAILED — a render exists that the index does not list,"
                 echo "  or the index names a render that is not there. An index that is not"
                 echo "  complete is the defect check_wiki_links.sh cannot see: it proves"
                 echo "  links RESOLVE, not that every figure is LISTED."
                 exit 1
               fi ;;
esac
