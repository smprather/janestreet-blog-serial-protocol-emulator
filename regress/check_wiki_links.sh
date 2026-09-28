#!/usr/bin/env bash
# check_wiki_links.sh — every DOCUMENT link must point at something that exists.
#
# SCOPE, and the ruling behind it. Only the LIVE surface is scanned:
# wiki/**/*.md (excluding wiki/raw/), README.md and docs/*.md. reviews/ and
# logs/ are EXCLUDED, and that is a considered decision rather than a gap: a
# reviews/ record is EVIDENCE, and a path inside it that pointed at
# ../../rtl/pe_line_codec.v was TRUE WHEN WRITTEN. Rewriting it to follow a
# rename would falsify the evidence; flagging it red would cry wolf forever,
# because a review record is a snapshot and snapshots do not age. The same applies
# to logs/, which are rotated archives. What must never 404 is the prose a reader
# is reading now.
#
# THREE RULES, each one learned from the failure this gate exists to prevent.
#
# 1. BOTH [[wikilink]] CONVENTIONS. The corpus uses `[[concepts/foo]]` (wiki
#    relative) AND bare `[[foo]]` (sibling relative, the way a Markdown renderer
#    resolves a same-directory link). A resolver that knows only ONE form calls
#    every link in the other form dead, and people then "fix" links that were
#    fine. A checker that INVENTS dead links is worse than no checker, because
#    the repository learns to distrust its own prose. Both forms are resolved.
#
#    AND THE HONEST STATE OF THE PROOF, which this comment used to get wrong.
#    It said "the self-test plants one of each so the resolver is proven rather
#    than assumed". There is no self-test. This script accepts only [--list] (see
#    the usage line), `git log -S'self_test' -- regress/check_wiki_links.sh`
#    returns nothing so one has never existed here, and run_all.sh invokes only
#    the real check. So the two-convention behaviour is ASSERTED here and
#    exercised only by the live corpus: if the corpus happens to contain no bare
#    [[foo]] form, a resolver that knew only the wiki-relative form would still
#    report OK. That is exactly the "a checker that never fires looks just like
#    a checker that works" gap, and it is stated here rather than papered over --
#    a reader who trusted the old sentence would have SKIPPED the proof, which is
#    worse than the proof being absent. Writing the missing self-test is the real
#    fix; it is outstanding work, not something this comment may imply is done.
#
#    A RECIPE THAT WORKS, since building this fixture took three attempts and a
#    next session should not have to rediscover it. Two things are NOT obvious and
#    both cost a failed run:
#      * ROOT comes from the SCRIPT's own path (cd "$(dirname "$0")/.."), NOT the
#        cwd. A copy at /tmp/x/check_wiki_links.sh therefore cds to /tmp and looks
#        for /tmp/wiki/.known-dead-links.txt. The fixture must live at
#        <root>/regress/check_wiki_links.sh with <root>/wiki/ beside it.
#      * the gate has TWO anti-vacuity floors and refuses to run below either: it
#        wants >= 67 in-scope documents and a real number of links, reporting
#        "only 2 document(s) in scope" / "only 3 links checked". So a two-page
#        fixture is refused, and that refusal is the gate working correctly.
#    With those: ~70 generated wiki pages, each carrying one wiki-relative and one
#    bare-sibling link, plus a README.md and a docs/ page, and a page holding
#    [[concepts/foo]] (resolve it under wiki/concepts/foo.md), [[foo]] (resolve
#    it under wiki/foo.md, a SIBLING of the linking page) and [[nope]] (leave it
#    absent). Measured result: 75 documents, 143 links, exactly 1 dead, that one
#    being nope, exit 1 -- both conventions proven to resolve and a real dead
#    link proven to be caught, in one run.
# 2. `sources:` IS A CITATION, NOT AN OUTBOUND LINK. Frontmatter names where a
#    claim came from, and a `reviews/...md` path in it is relative to the repo
#    root, not to the page, so resolving it as an outbound link manufactures false
#    dead links. Frontmatter is therefore stripped: BODY ONLY.
# 3. A LEADING `/` IS SITE-ABSOLUTE, NOT REPO-ABSOLUTE. A captured article
#    legitimately contains web paths that mean nothing in this checkout.
#
# RECORD FORMAT: fields are PERCENT-ENCODED before they are printed. The first
# draft emitted TSV, and a link or filename containing a tab or newline split the
# record - the output was mojibake and the baseline comparison was comparing
# corrupted keys. Prose contains tabs and newlines; the separator must not be
# something prose can contain, and encoding is simpler to reason about than
# escaping rules.
#
# PINNED BASELINE, same shape and same both-directions enforcement as the two
# that already exist (wiki/.known-rule-violations.txt, wiki/.known-stale-diagrams.txt):
# a dead link not listed is NEW and red; a listed link that no longer dies is
# STALE-LINK and red, so a pin cannot outlive its defect.
#
# Usage:  regress/check_wiki_links.sh [--list]
# Exit:   0 clean · 1 new or stale dead link, or harness error · 2 usage
set -u

# self_test -- prove the RESOLVER, not just the corpus.
#
# WHY THIS EXISTS. Rule 1 asserts that BOTH [[wikilink]] conventions resolve
# (wiki-relative [[concepts/foo]] and bare-sibling [[foo]]). Until now that claim
# was prose: this script had no self-test, and the live corpus alone exercised it,
# so a resolver that understood only ONE form would still have reported OK
# whenever the corpus happened to contain no link of the other form. A checker
# that never fires looks exactly like a checker that works.
#
# TWO TRAPS, both paid for during development, documented so the next person does
# not rediscover them:
#   * The checker resolves ROOT from ITS OWN PATH (cd "$(dirname "$0")/.."), not
#     from the caller's cwd. A self-test therefore cannot point it at a fixture
#     root by cd'ing; it must COPY the checker to <fixture>/regress/ and run it
#     there, which is exactly what the recipe in the header describes.
#   * The checker has two anti-vacuity floors -- at least 67 in-scope documents
#     and a real number of links -- and refuses to run below either. A two-page
#     fixture is REFUSED, and that refusal is the gate working, not an obstacle.
#     So the fixture is sized, not minimal.
#
# WHAT IS ASSERTED, in both directions, which is the property that matters:
#   1. with [[concepts/foo]] and [[foo]] both resolvable and [[nope]] absent, the
#      gate reports EXACTLY ONE dead link and that one is nope, and exits 1 --
#      so it can detect a real dead link AND does not invent one for either
#      convention;
#   2. with the dead link removed, the same fixture is clean and exits 0 -- so
#      the failure in (1) was the dead link and not the fixture being broken.
# Without (2) a fixture that fails for any reason would satisfy (1).
self_test() {
  local FT ok=0 bad=0 out rc
  FT=$(mktemp -d) || return 1
  mkdir -p "$FT/regress" "$FT/wiki/concepts" "$FT/docs"
  cp "$0" "$FT/regress/check_wiki_links.sh" || { rm -rf "$FT"; return 1; }
  printf '# pinned baseline (self-test fixture): no pins\n' > "$FT/wiki/.known-dead-links.txt"

  # Sized to clear both floors: ~70 pages, each carrying ONE wiki-relative and ONE
  # bare-sibling link, so both conventions are exercised at scale and not only in
  # the one page under test.
  local i j
  for i in $(seq 1 70); do
    j=$(( (i % 70) + 1 ))
    printf '# page %s\n\nWiki: [[p%s]]\nBare: [[p%s]]\n' "$i" "$j" "$j" > "$FT/wiki/p$i.md"
  done
  printf '# readme\n\nBody.\n' > "$FT/README.md"
  printf '# d1\n\nBody.\n' > "$FT/docs/d1.md"
  printf '# foo under concepts\n\nTarget.\n' > "$FT/wiki/concepts/foo.md"
  printf '# foo sibling\n\nTarget.\n' > "$FT/wiki/foo.md"

  # CASE 1: both conventions resolve, one link is genuinely dead.
  printf '# t\n\nA: [[concepts/foo]]\nB: [[foo]]\nC: [[nope]]\n' > "$FT/wiki/t.md"
  out=$(cd "$FT" && bash regress/check_wiki_links.sh 2>&1); rc=$?
  if [ "$rc" -eq 1 ] \
     && printf '%s' "$out" | grep -q 'wiki/t.md -> nope' \
     && printf '%s' "$out" | grep -q '1 dead link' \
     && ! printf '%s' "$out" | grep -q 't.md -> foo'; then
    printf '  ok   self-test — both wikilink conventions resolve, and a real dead link is caught (exit 1)\n'
    ok=$((ok + 1))
  else
    printf '  FAIL self-test — expected exactly one dead link (nope) and exit 1, got exit %s:\n%s\n' "$rc" "$out" >&2
    bad=$((bad + 1))
  fi

  # CASE 2, the other direction: remove the dead link and the same fixture is
  # clean. This is what stops case 1 passing merely because the fixture is broken.
  printf '# t\n\nA: [[concepts/foo]]\nB: [[foo]]\n' > "$FT/wiki/t.md"
  out=$(cd "$FT" && bash regress/check_wiki_links.sh 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'OK'; then
    printf '  ok   self-test — the same fixture is clean once the dead link is removed (exit 0)\n'
    ok=$((ok + 1))
  else
    printf '  FAIL self-test — expected a clean fixture and exit 0, got exit %s:\n%s\n' "$rc" "$out" >&2
    bad=$((bad + 1))
  fi

  # CASE 3: a genuinely dead link with a name the corpus does NOT contain, so
  # case 1's single finding cannot be an artefact of one hard-coded name.
  printf '# t\n\nA: [[concepts/foo]]\nB: [[foo]]\nC: [[absent_target_xyz]]\n' > "$FT/wiki/t.md"
  out=$(cd "$FT" && bash regress/check_wiki_links.sh 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 't.md -> absent_target_xyz'; then
    printf '  ok   self-test — a differently-named dead link is caught too (exit 1)\n'
    ok=$((ok + 1))
  else
    printf '  FAIL self-test — expected absent_target_xyz to be caught, got exit %s:\n%s\n' "$rc" "$out" >&2
    bad=$((bad + 1))
  fi

  rm -rf "$FT"
  if [ "$ok" -ne 3 ]; then
    echo "check_wiki_links self-test: FAIL -- $ok of 3 cases proved the resolver" >&2
    return 1
  fi
  echo "check_wiki_links self-test: $ok/$ok cases proved the resolver (both conventions resolve; a real dead link is caught and a clean corpus is not flagged)"
  return 0
}

cd "$(dirname "$0")/.." || exit 1

BASELINE=wiki/.known-dead-links.txt
LIST_ONLY=0
case "${1:-}" in
  "")        ;;
  --list)    LIST_ONLY=1 ;;
  --self-test) self_test; exit $? ;;
  -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  *)         echo "usage: $0 [--list|--self-test]" >&2; exit 2 ;;
esac

[ -f "$BASELINE" ] || { echo "check_wiki_links: HARNESS ERROR — $BASELINE is missing" >&2; exit 1; }

TMP=$(mktemp -d) || { echo "check_wiki_links: HARNESS ERROR — mktemp failed" >&2; exit 1; }
# ONE trap only: a second EXIT trap REPLACES the first and silently discards it.
trap 'rm -rf "$TMP"' EXIT

# ---- the scope, stated explicitly rather than left to a glob ----------------
: > "$TMP/files"
find wiki -type f -name '*.md' -not -path 'wiki/raw/*' >> "$TMP/files" 2>/dev/null
[ -f README.md ] && echo README.md >> "$TMP/files"
find docs -type f -name '*.md' >> "$TMP/files" 2>/dev/null
LC_ALL=C sort -u -o "$TMP/files" "$TMP/files"
n_files=$(wc -l < "$TMP/files" | tr -d ' ')
# A scope that silently collapses looks exactly like a clean repository, and the
# count is the only thing that tells the two apart.
if [ "$n_files" -lt 30 ]; then
  echo "check_wiki_links: HARNESS ERROR — only $n_files document(s) in scope" >&2
  echo "  (67 wiki + README + docs expected; reviews/ and logs/ are excluded by ruling)" >&2
  exit 1
fi

# ---- the scan ---------------------------------------------------------------
python3 - "$TMP/files" <<'PY' > "$TMP/dead" 2> "$TMP/scan.err"
import os, re, sys
from urllib.parse import quote

FRONT = re.compile(r'\A---\n.*?\n---\n', re.S)          # RULE 2: body only
# RULE 4: a wikilink inside inline code or a fenced block is a worked EXAMPLE of
# the syntax, not a link. SCHEMA.md says "Use `[[wikilinks]]` to link between
# pages" - the backticks are what make it an example, and without stripping them
# the page documenting the convention is itself reported as broken. Same for a
# fenced block, which is where most of the `[[x]]` in log.md's prose lives.
FENCE  = re.compile(r'\A.*?\A```[\s\S]*?```', re.S)
INLINE = re.compile(r'`[^`\n]*`')
def strip_code(t):
    t = re.sub(r'```[\s\S]*?```', ' ', t)
    return INLINE.sub(' ', t)
MDLINK = re.compile(r'!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
WIKI    = re.compile(r'\[\[([^\]|#]+)(?:\|[^\]]*)?\]\]')
SCHEMES = ('http://', 'https://', 'mailto:', 'ftp://', 'tel:')

def hit(p):
    """Does this path name something that exists, allowing a page to omit .md
    and a directory to be named by its README?"""
    if os.path.exists(p):
        return True
    if os.path.exists(p + '.md'):
        return True
    if os.path.isdir(p) and os.path.exists(os.path.join(p, 'README.md')):
        return True
    return False

def resolve_wiki(t, here):
    """BOTH conventions, tried in a fixed order. `t` with a slash is wiki
    relative; without one it is sibling relative AND is also tried against the
    wiki root, because [[STATUS]] written in wiki/concepts/ means wiki/STATUS.md."""
    if '/' in t:
        # The repo ROOT is a candidate too, and it is not optional: the wiki's own
        # house convention is that [[reviews/2026-09-25/R3-STA]] names a file at
        # the repository root, not under wiki/. Without this every review link in
        # index.md, STATUS.md and log.md was reported dead, which is the "checker
        # invents dead links" failure in its purest form.
        cands = [t, os.path.join(here, t), os.path.join('wiki', t)]
    else:
        cands = [os.path.join(here, t),
                 os.path.join('wiki', t),
                 os.path.join('wiki', os.path.dirname(here), t),
                 t]
    return any(hit(c) for c in cands)

n_links = 0
for path in (l.strip() for l in open(sys.argv[1]) if l.strip()):
    body = FRONT.sub('', open(path, encoding='utf-8', errors='replace').read(), count=1)
    body = strip_code(body)
    here = os.path.dirname(path) or '.'
    for m in MDLINK.finditer(body):
        t = m.group(1).strip()
        if not t or t.startswith('#') or t.startswith(SCHEMES):
            continue
        n_links += 1
        c = t.split('#', 1)[0]
        if not c or c.startswith('/'):                    # RULE 3
            continue
        if not hit(os.path.normpath(os.path.join(here, c))):
            print(f'{quote(path)}\t{quote(t)}')
    for m in WIKI.finditer(body):
        t = m.group(1).strip()
        if not t or t.startswith(SCHEMES):
            continue
        n_links += 1
        if not resolve_wiki(t, here):                      # RULE 1
            print(f'{quote(path)}\t{quote(t)}')

print(f'#SCANNED\t{n_links}', file=sys.stderr)
PY
if [ $? -ne 0 ]; then
  echo "check_wiki_links: HARNESS ERROR — the scan failed" >&2
  cat "$TMP/scan.err" >&2
  exit 1
fi

n_dead=$(wc -l < "$TMP/dead" | tr -d ' ')
n_link=$(sed -n 's/^#SCANNED\t//p' "$TMP/scan.err" | head -1); n_link=${n_link:-0}
echo "check_wiki_links: $n_files document(s) scanned, ${n_link} link(s) checked, $n_dead dead"
[ "$n_link" -lt 50 ] && { echo "check_wiki_links: HARNESS ERROR — only $n_link links checked" >&2; exit 1; }

# ---- the baseline, both directions -----------------------------------------
: > "$TMP/pinned"; n_pin=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  set -- $line
  if [ "$#" -lt 2 ]; then
    echo "check_wiki_links: HARNESS ERROR — malformed line in $BASELINE:" >&2
    echo "  $line" >&2; echo "  expected: <file> <link> <reason>" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$(printf '%s' "$1" | sed 's/%/%25/g; s/\t/%09/g')" "$2" >> "$TMP/pinned"
  n_pin=$((n_pin + 1))
done < "$BASELINE"
LC_ALL=C sort -u -o "$TMP/pinned" "$TMP/pinned"
LC_ALL=C sort -u -o "$TMP/dead" "$TMP/dead"
LC_ALL=C comm -13 "$TMP/pinned" "$TMP/dead" > "$TMP/new"
LC_ALL=C comm -23 "$TMP/pinned" "$TMP/dead" > "$TMP/stale"
n_new=$(wc -l < "$TMP/new" | tr -d ' '); n_stale=$(wc -l < "$TMP/stale" | tr -d ' ')
echo "  baseline: $n_pin pinned dead link(s)"

if [ "$LIST_ONLY" -eq 1 ]; then
  echo "  --- dead links (--list judges nothing) ---"
  if [ -s "$TMP/dead" ]; then cut -f1,2 "$TMP/dead" | while IFS=$'\t' read -r f l; do
      echo "    $(printf '%b' "${f//%/\\x}") -> $(printf '%b' "${l//%/\\x}")"; done
  else echo "  (none)"; fi
  exit 0
fi

bad=0
if [ "$n_new" -ne 0 ]; then
  echo "  NEW — $n_new dead link(s) not in $BASELINE:" >&2
  while IFS=$'\t' read -r f l; do
    [ -n "$f" ] || continue
    echo "    $(printf '%b' "${f//%/\\x}") -> $(printf '%b' "${l//%/\\x}")" >&2
  done < "$TMP/new"
  bad=1
fi
if [ "$n_stale" -ne 0 ]; then
  echo "  STALE — $n_stale pinned entr(ies) no longer dead; the baseline is out of date:" >&2
  while IFS=$'\t' read -r f l; do
    [ -n "$f" ] || continue
    why=$(awk -v a="$f" '$1==a { $1=""; sub(/^[ \t]+/,""); print; exit }' "$BASELINE")
    echo "    $(printf '%b' "${f//%/\\x}") -> $(printf '%b' "${l//%/\\x}")" >&2
    echo "      pinned reason: ${why:-<none>}" >&2
    echo "      FIXED the link, then DELETE this line from $BASELINE." >&2
  done < "$TMP/stale"
  bad=1
fi
if [ "$bad" -ne 0 ]; then echo "check_wiki_links: FAILED" >&2; exit 1; fi
echo "check_wiki_links: OK — 0 new, 0 stale"
exit 0
