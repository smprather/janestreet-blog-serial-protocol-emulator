#!/usr/bin/env bash
# check_wiki_pages.sh — the five wiki/SCHEMA.md rules, enforced, with a PINNED
# baseline for the violations that predate this gate.
#
# WHY THIS EXISTS. wiki/SCHEMA.md has always stated five rules for hand-written
# pages: frontmatter present, `type` inside the enum, every tag inside the tag
# taxonomy, at least two outbound wikilinks, and the page listed in index.md.
# Until 2026-09-25 NOTHING checked any of them. Every documentation gate in
# regress/run_all.sh is a GENERATED-page drift check — it compares
# wiki/reference/* against tools/gen/* — so a hand-written page could break all
# five and no gate would notice. A rule nothing checks is a wish, and this
# project has been bitten by that shape repeatedly: a port table that went
# stale, a MUTABLE list that made the mapper skip a suite, an index page count
# that was two behind. This is the gate for the rules that were only ever prose.
#
# THE FIVE RULES:
#   no-frontmatter       no YAML frontmatter block at all
#   no-type / bad-type   frontmatter has no `type:`, or it is not in the enum.
#                        Only checked on a page that HAS frontmatter: without
#                        that guard, no-type and no-frontmatter are one defect
#                        reported twice, and the baseline would need two lines
#                        to pin one problem.
#   off-taxonomy-tag     a `tags:` entry is not in the schema's taxonomy
#   zero-outbound-links  fewer than two DISTINCT [[wikilink]] targets in the body
#   not-in-index         index.md does not link to the page
#
# THE PINNED BASELINE, and the half that is easy to get wrong. A gate written
# today would be red on 12 violations across 8 pages, and landing a red gate on
# someone else's suite is not this task's call. So the known violations live in
# wiki/.known-rule-violations.txt, one line each with a reason, and the checker
# enforces the pin in BOTH directions:
#     violation not listed                     -> NEW   -> red
#     listed entry that no longer fails        -> STALE -> red
# The STALE half is the half that matters. Without it the baseline is a ratchet
# that silently becomes wrong: someone fixes a page, the entry stays, and the
# gate keeps reporting a violation it can no longer see, so the log and the tree
# disagree and nothing says which is true. This is the same shape as
# tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt, where a divergence that CHANGES is
# red — deliberately stricter than an XFAIL list of names, because a check that
# starts failing for a NEW reason must not read as "known".
#
# THE TAXONOMY IS READ FROM wiki/SCHEMA.md, NOT HARDCODED. Two implementations of
# one list is two lists, and the drift is invisible until the gate rejects a tag
# the schema has been extended to allow. The parse is scoped to the
# `## Tag Taxonomy` section and to bullet lines, because an unscoped parse of
# that file picks up prose: three words of a parenthetical ("as", "distinct",
# "surface") were read as tags the first time this was written, which is exactly
# the silent-parse failure this project keeps paying for.
#
# PORTABILITY, and the bug this file nearly shipped with. The first draft ended
# each page with awk's `ENDFILE` block. mawk — the default awk on this kind of
# box — has no ENDFILE and treats it as a rule it cannot parse, so the rule pass
# would have emitted NOTHING, the violation count would have been zero, and the
# gate would have reported a perfectly clean wiki. A silent false green in the
# one gate whose whole job is to not lie. So the per-page reporting is done with
# FNR==1/END, which every awk has, and independently of that: the checker counts
# the pages the rule pass actually reported on and REFUSES to pass unless that
# equals the number of pages it was given. A check that quietly covered nothing
# must never look like one that passed.
#
# SCOPE: hand-written pages only. `wiki/raw/` is immutable verbatim source and is
# excluded. The four meta pages (index, log, SCHEMA, STATUS) are excluded
# because they are the wiki's own machinery rather than content: index.md is the
# thing being checked against, log.md and STATUS.md are append-only records, and
# SCHEMA.md is the rule source. The seven GENERATED reference pages are IN
# scope: they are checked in and they carry frontmatter, so a generator that
# emits a bad page is caught here as well as by its own --check.
#
# NOT STAMPED WITH chip_dep_stamp, deliberately. run_all.sh stamps and checks
# every MUTATION suite, because those are long-running loops where a mid-run
# edit can flip the verdict. This is a read-only scan that finishes in
# milliseconds and mutates nothing, so the incremental-read window is
# negligible; and the alternative would force it into the `stale` accumulator,
# which cannot express INCONCLUSIVE and would report "red" where the honest
# answer is "no verdict". Not stamping is a decision, not an oversight.
#
# Usage:
#   regress/check_wiki_pages.sh          judge: NEW violations red, STALE red
#   regress/check_wiki_pages.sh --list   print the actual violation set, judge
#                                        nothing (diagnose without a copy)
#
# Exit: 0 clean · 1 NEW or STALE violation, or a harness error · 2 usage
set -u
cd "$(dirname "$0")/.." || exit 1

WIKI=wiki
SCHEMA="$WIKI/SCHEMA.md"
INDEX="$WIKI/index.md"
BASELINE="$WIKI/.known-rule-violations.txt"

LIST_ONLY=0
case "${1:-}" in
  "")        ;;
  --list)    LIST_ONLY=1 ;;
  -h|--help) sed -n '2,58p' "$0"; exit 0 ;;
  *)         echo "usage: $0 [--list]" >&2; exit 2 ;;
esac

# ---- fail-closed on the checker itself --------------------------------------
# An absent file is not evidence of anything. If the schema, the index or the
# baseline is missing, this script cannot check the rules and must not report a
# pass: a missing baseline would make every violation NEW and drown the real
# signal, and a missing schema would empty the taxonomy and reject every tag in
# the wiki.
for f in "$SCHEMA" "$INDEX" "$BASELINE"; do
  if [ ! -f "$f" ]; then
    echo "check_wiki_pages: HARNESS ERROR — $f is missing, so no rule can be checked" >&2
    exit 1
  fi
done
[ -d "$WIKI" ] || { echo "check_wiki_pages: HARNESS ERROR — $WIKI is not a directory" >&2; exit 1; }

TMP=$(mktemp -d) || { echo "check_wiki_pages: HARNESS ERROR — mktemp failed" >&2; exit 1; }
# ONE trap and it is the only one. A second EXIT trap REPLACES the first — the
# trap-replacement trap this repo has already been bitten by (see
# regress/mutate_timing_tb.sh's header) — so cleanup is this single line, which
# preserves the script's exit status because the trap does not call exit itself.
trap 'rm -rf "$TMP"' EXIT

# ---- the taxonomy, read from the schema -------------------------------------
# Section-scoped: from the `## Tag Taxonomy` heading to the next `## ` heading.
# Bullet lines only, because that is the format the schema documents for the
# list and prose inside a bullet is not a tag.
awk '
  /^## Tag Taxonomy[ \t]*$/ { inside=1; next }
  inside && /^## / { inside=0 }
  inside && /^- / {
    line=$0; sub(/^- /, "", line)
    n=split(line, toks, ",")
    for (i=1; i<=n; i++) {
      t=toks[i]; gsub(/^[ \t]+|[ \t]+$/, "", t); gsub(/[*`]/, "", t)
      if (t ~ /^[a-z][a-z-]*$/) print t
    }
  }
' "$SCHEMA" | LC_ALL=C sort -u > "$TMP/taxonomy"

n_tax=$(wc -l < "$TMP/taxonomy" | tr -d ' ')
# The schema shipped 20 and carries 43 today. The floor is 15: it catches a
# parse that collapsed to a couple of lines, while staying far enough below 43
# that a legitimate future trim does not trip it.
if [ "$n_tax" -lt 15 ]; then
  echo "check_wiki_pages: HARNESS ERROR — parsed only $n_tax tags from $SCHEMA" >&2
  echo "  the parse is scoped to that file's '## Tag Taxonomy' section, so a" >&2
  echo "  rename of the heading or a reformat of its bullets breaks it." >&2
  echo "  Not reporting a pass." >&2
  exit 1
fi

# ---- the page list ----------------------------------------------------------
# find, not a glob: the wiki is nested, and a glob that stops matching reports
# zero pages and looks exactly like a clean wiki.
find "$WIKI" -type f -name '*.md' -not -path "$WIKI/raw/*" -print \
  | sed "s|^$WIKI/||" \
  | grep -vE '^(index|log|SCHEMA|STATUS)\.md$' \
  | LC_ALL=C sort > "$TMP/pages"

n_pages=$(wc -l < "$TMP/pages" | tr -d ' ')
if [ "$n_pages" -lt 20 ]; then
  echo "check_wiki_pages: HARNESS ERROR — only $n_pages hand-written page(s) found" >&2
  echo "  (43 on 2026-09-25). The find or the meta-page filter is broken;" >&2
  echo "  reporting a pass here would be a false green." >&2
  exit 1
fi

# ---- the rules --------------------------------------------------------------
# ONE awk INVOCATION PER PAGE, and that is deliberate.
#
# The first draft handed awk the page LIST as its single input file, so awk read
# one file — the list — and the rule pass reported on exactly one "page". The
# violation set came out empty, the count came out zero, and the gate would have
# reported a perfectly clean wiki. What caught it was not reading the output
# carefully; it was the coverage assertion below, which compared the number of
# pages the pass actually processed against the number it was handed and
# refused. The awk here is gawk and would have accepted ENDFILE happily, so the
# portability argument alone did not save this either.
#
# So: one file per invocation, which is the same discipline
# regress/check_shell_syntax.sh uses for `bash -n` and for the same reason — a
# single awk given many files has no way to tell you it processed fewer of them
# than it was handed. It also avoids `awk $(cat list)`, whose word splitting
# would silently break on a path containing a space.
: > "$TMP/awkin"
n_covered=0
n_pages_failed=0
while IFS= read -r page; do
  [ -n "$page" ] || continue
  if ! awk -v taxfile="$TMP/taxonomy" -v idxfile="$INDEX" '
    function init() {
      delete seen
      infm=0; havefm=0; nlinks=0; ntypes=0; badtype=""; offtag=""
    }
    function report(   p) {
      if (!havefm)   print rel, "no-frontmatter",       "no YAML frontmatter block"
      if (havefm && ntypes==0) print rel, "no-type",   "frontmatter has no type: field"
      else if (badtype != "") print rel, "bad-type",  "type=" badtype " is not in the schema enum"
      if (offtag != "") print rel, "off-taxonomy-tag", offtag
      if (nlinks < 2) print rel, "zero-outbound-links", nlinks " distinct outbound wikilink(s)"
      p=rel; sub(/\.md$/, "", p)
      # index(), NOT a regex. Three earlier versions of this line were wrong in
      # ways worth recording, because each one failed in a direction that looks
      # like success. A bare substring (p in idx) is satisfied by the TEXT of
      # plans/pe-ctrl-readback, so plans/pe-ctrl would count as listed without
      # being listed. Moving to a dynamic regex then meant escaping the brackets
      # and covering the `[[p|alias]]` form, and two attempts at that matched
      # neither form: the rule fired on all 43 pages, every one of them wrongly.
      # index() is a literal substring search, so there is nothing to escape and
      # no alternation to get wrong, and the precision comes free — `[[p]]` and
      # `[[p|` both END the path, so a longer path sharing the prefix cannot
      # satisfy either. Verified against all four cases before being adopted.
      if (index(idx, "[[" p "]]") == 0 && index(idx, "[[" p "|") == 0)
        print rel, "not-in-index", "index.md has no link to " p
      print "@COVERED@", rel
    }
    function link(t) {
      sub(/\|.*$/, "", t)
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "" || (t in seen)) return 0
      seen[t]=1; return 1
    }
    BEGIN {
      while ((getline t < taxfile) > 0) if (t != "") ok[t]=1
      close(taxfile)
      idx=""
      while ((getline l < idxfile) > 0) idx = idx "\n" l
      close(idxfile)
      # ARGV[1], NOT FILENAME: in a BEGIN block awk has not opened an input file
      # yet, so FILENAME is the empty string and every violation printed with an
      # empty page field. The first draft of this pass did exactly that, and the
      # visible symptom was 12 correct-looking STALE reports and 4 nameless NEW
      # ones — a gate that fires on the right rule for the wrong reason is still
      # a gate nobody can read. ARGV[1] is available immediately, and unlike a
      # FILENAME read on FNR==1 it also survives a zero-byte page.
      rel=ARGV[1]; sub(/^wiki\//, "", rel)
      init()
    }
    {
      line=$0
      if (FNR==1 && line == "---") { infm=1; havefm=1; next }
      if (infm) {
        if (line == "---") { infm=0; next }
        if (line ~ /^type:[ \t]*/) {
          ntypes++
          t=line; sub(/^type:[ \t]*/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", t)
          if (t != "entity" && t != "concept" && t != "comparison" && t != "query" \
              && t != "decision" && t != "reference" && t != "plan") badtype=t
        }
        if (line ~ /^tags:[ \t]*\[/) {
          t=line; sub(/^tags:[ \t]*\[/, "", t); sub(/\].*$/, "", t)
          n=split(t, toks, ",")
          for (i=1; i<=n; i++) {
            g=toks[i]; gsub(/^[ \t]+|[ \t]+$/, "", g)
            if (g == "") continue
            if (!(g in ok)) offtag = (offtag == "" ? g : offtag "," g)
          }
        }
        next
      }
      # body only: a link inside the frontmatter must not satisfy the link rule
      rest=line
      while (match(rest, /\[\[[^]]+\]\]/)) {
        if (link(substr(rest, RSTART+2, RLENGTH-4))) nlinks++
        rest=substr(rest, RSTART+RLENGTH)
      }
    }
    END { report() }
  ' "$WIKI/$page" >> "$TMP/awkin" 2>>"$TMP/awkerr"; then
    n_pages_failed=$((n_pages_failed + 1))
    echo "check_wiki_pages: HARNESS ERROR — the rule pass failed on $page" >&2
  else
    n_covered=$((n_covered + 1))
  fi
done < "$TMP/pages"

if [ -s "$TMP/awkerr" ]; then
  echo "check_wiki_pages: HARNESS ERROR — awk wrote to stderr:" >&2
  cat "$TMP/awkerr" >&2
  exit 1
fi
if [ "$n_pages_failed" -ne 0 ]; then
  exit 1
fi

# THE COVERAGE ASSERTION. If the rule pass silently processed fewer pages than
# it was handed — an awk missing a construct this script uses, a parse that
# skipped everything, a future edit that loses a branch, or the list-vs-pages
# mistake recorded above — then the violation set is incomplete and a SMALLER
# violation set looks CLEANER, not broken. Comparing the two counts turns that
# false green into a loud failure. It is the reason this gate can be trusted
# about the pages it did not look at.
if [ "$n_covered" -ne "$n_pages" ]; then
  echo "check_wiki_pages: HARNESS ERROR — the rule pass covered $n_covered of" >&2
  echo "  $n_pages pages. An incomplete violation set is not a clean wiki; it is" >&2
  echo "  a checker that stopped looking. Not reporting a pass." >&2
  exit 1
fi

# Strip the per-page coverage trailers and keep the violation set. Sorted,
# because the comparison below is line-based and a diff that depends on read
# order is a diff nobody can reason about at 2am.
grep -v '^@COVERED@ ' "$TMP/awkin" | LC_ALL=C sort > "$TMP/actual"
n_actual=$(wc -l < "$TMP/actual" | tr -d ' ')

# ---- the baseline, parsed ---------------------------------------------------
# Fields 1 and 2 are the machine-read pair; the rest is a reason and is never
# parsed. A MALFORMED line is an error, not a skip: a baseline entry this
# checker cannot read is an entry that has silently stopped being enforced,
# which is the exact failure the STALE check exists to prevent.
n_base=0
: > "$TMP/baseline.pairs"
: > "$TMP/baseline.reasons"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  # shellcheck disable=SC2086  # the word splitting is the point: $1/$2/$3...
  set -- $line
  if [ "$#" -lt 3 ]; then
    echo "check_wiki_pages: HARNESS ERROR — malformed baseline line in $BASELINE:" >&2
    echo "  $line" >&2
    echo "  expected: <page> <rule> <reason>" >&2
    exit 1
  fi
  printf '%s %s\n' "$1" "$2" >> "$TMP/baseline.pairs"
  printf '%s\n' "$line" >> "$TMP/baseline.reasons"
  n_base=$((n_base + 1))
done < "$BASELINE"
LC_ALL=C sort -u -o "$TMP/baseline.pairs" "$TMP/baseline.pairs"
n_base_u=$(wc -l < "$TMP/baseline.pairs" | tr -d ' ')

awk '{print $1, $2}' "$TMP/actual" | LC_ALL=C sort -u > "$TMP/actual.pairs"
LC_ALL=C comm -13 "$TMP/baseline.pairs" "$TMP/actual.pairs" > "$TMP/new"
LC_ALL=C comm -23 "$TMP/baseline.pairs" "$TMP/actual.pairs" > "$TMP/stale"
n_new=$(wc -l < "$TMP/new" | tr -d ' ')
n_stale=$(wc -l < "$TMP/stale" | tr -d ' ')

echo "check_wiki_pages: $n_pages hand-written pages, $n_tax taxonomy tags read from $SCHEMA"
echo "  violations found: $n_actual across $(awk '{print $1}' "$TMP/actual.pairs" | sort -u | wc -l | tr -d ' ') page(s)"
echo "  baseline: $n_base_u pinned violation(s) ($n_base line(s) read)"

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "  --- actual violation set (--list judges nothing) ---"
  if [ -s "$TMP/actual" ]; then cat "$TMP/actual"; else echo "  (none)"; fi
  exit 0
fi

bad=0
if [ "$n_new" -ne 0 ]; then
  echo "  NEW — $n_new violation(s) not in $BASELINE:" >&2
  while read -r p r; do
    [ -n "$p" ] || continue
    d=$(awk -v k="$p $r" '$1" "$2==k { $1=""; $2=""; sub(/^  /,""); print; exit }' "$TMP/actual")
    echo "    $p  $r  ${d:-<no detail>}" >&2
  done < "$TMP/new"
  bad=1
fi
if [ "$n_stale" -ne 0 ]; then
  echo "  STALE — $n_stale baseline entr(ies) no longer fail; the baseline is out of date:" >&2
  while read -r p r; do
    [ -n "$p" ] || continue
    why=$(awk -v k="$p $r" '$1" "$2==k { $1=""; $2=""; sub(/^  /,""); print; exit }' "$TMP/baseline.reasons")
    echo "    $p  $r" >&2
    echo "      pinned reason: ${why:-<none>}" >&2
    echo "      FIXED the page, then DELETE this line from $BASELINE." >&2
  done < "$TMP/stale"
  bad=1
fi
if [ "$bad" -ne 0 ]; then
  echo "check_wiki_pages: FAILED" >&2
  exit 1
fi
echo "check_wiki_pages: OK — 0 new, 0 stale; $n_actual known violation(s) pinned in the baseline"
exit 0
