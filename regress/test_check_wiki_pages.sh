#!/usr/bin/env bash
# test_check_wiki_pages.sh — prove check_wiki_pages.sh can FAIL.
#
# WHY THIS FILE EXISTS. A gate that has only ever been seen green is not a gate;
# it is a script that prints reassuring text. That is not a hypothetical worry in
# this repo: the pre-flight was correct on the day it was written and nothing
# asserted it, so the next harness arrived unprotected; a macro checker accepted
# an invalid placement; a self-test once passed while checking nothing. So the
# rule here is the one regress/test_dep_guard.sh and regress/test_run_lock.sh
# already follow: a guard gets a negative control or it is decoration.
#
# This is the negative control for the five SCHEMA rules gate. Every case here
# is a way of making that gate WRONG, and the case passes only when the gate
# notices. The two that matter most are at the ends:
#   * a NEW violation must be red, and
#   * a PINNED violation that has been FIXED must also be red (STALE), because
#     a baseline that can silently outlive its defect is a checklist.
# and the last pair are the fail-closed paths, because a checker that cannot
# see the wiki at all must not report a clean wiki.
#
# NOTHING HERE TOUCHES THE REAL TREE. Every case runs in a throwaway copy under
# mktemp -d, so the pages these tests deliberately break are copies. The single
# trap is one line and there is no lock: this suite mutates no RTL, takes no
# run lock, and is safe to run beside a real run.
#
# Usage: regress/test_check_wiki_pages.sh
# Exit:  0 all cases behaved as required · 1 a case did not
set -u
cd "$(dirname "$0")/.." || exit 1

CHECKER=regress/check_wiki_pages.sh
[ -f "$CHECKER" ] || { echo "test_check_wiki_pages: $CHECKER is missing" >&2; exit 1; }

TMP=$(mktemp -d) || { echo "test_check_wiki_pages: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; echo "        $2" >&2; fail=$((fail + 1)); }

# fresh <name> — a clean scratch copy of wiki/ + the checker, cwd'd into it.
# SRC is the pristine source; each case starts from it so no case inherits
# another case's damage, which would be a self-test that passes for the wrong
# reason.
fresh() {
  d="$TMP/$1"
  mkdir -p "$d/wiki" "$d/regress"
  cp -a wiki/. "$d/wiki/"
  cp "$CHECKER" "$d/regress/"
  echo "$d"
}

# expect <name> <want-rc> <want-substring|-> <dir> [page-to-modify ...]
# Runs the checker in <dir> and asserts the exit code and that the output
# contains the substring. A "-" substring skips the message assertion, which is
# only ever done where the message is genuinely incidental.
expect() {
  name=$1; want_rc=$2; want_msg=$3; dir=$4
  out=$(cd "$dir" && bash regress/check_wiki_pages.sh 2>&1); rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    bad "$name" "expected exit $want_rc, got $rc
$(printf '%s\n' "$out" | sed 's/^/        | /')"
    return
  fi
  if [ "$want_msg" != "-" ] && ! printf '%s\n' "$out" | grep -qF -- "$want_msg"; then
    bad "$name" "exit code right but output lacks: $want_msg
$(printf '%s\n' "$out" | sed 's/^/        | /')"
    return
  fi
  ok "$name"
}

# fresh_render <name> — like fresh(), but also carrying the diagram render gate
# and a MINIMAL diagrams/ tree.
#
# Two lessons are baked in here. The first version used plain fresh() and every
# render case died with exit 127 on a missing script, which is the shape of a test
# that never tested anything while looking busy. The second copied the WHOLE
# diagrams/ directory — 13 MB and 34 sources — into a throwaway tree for each of
# five cases, so the suite spent ~20 of its 24 seconds copying and re-rendering
# diagrams that the cases never look at. Each render case needs exactly ONE
# source and its renders: a stale one, an extra panel, a deleted source. Realism
# that costs 20 seconds and is never measured is not realism, it is latency.
fresh_render() {
  d="$TMP/$1"
  mkdir -p "$d/wiki" "$d/regress" "$d/tools/diag" "$d/diagrams"
  cp -a wiki/. "$d/wiki/"
  cp "$CHECKER" "$d/regress/"
  # the folded gate derives REPO from BASH_SOURCE/../.., so it MUST sit at
  # <fixture>/tools/diag/ for it to check the fixture rather than this repo
  cp "$RENDER_CHECK" "$d/tools/diag/"
  cp regress/check_wiki_links.sh "$d/regress/" 2>/dev/null
  # two sources, chosen for having the fewest files, plus every render either
  # produces (including PlantUML's numbered _00N siblings)
  for f in $(ls -S diagrams/*.puml | tail -2); do
    b=$(basename "$f")
    cp "diagrams/$b" "$d/diagrams/"
    for r in diagrams/${b%.puml}*.png diagrams/${b%.puml}*.svg; do
      [ -f "$r" ] && cp "$r" "$d/diagrams/"
    done
  done
  # diagrams/TOOLCHAIN.md is an INPUT to the gate, not a diagram: it pins the
  # renderer so a byte difference can be attributed to the toolchain rather than
  # to a stale render. Without it in the fixture the gate correctly reports the
  # toolchain as unknown and the "pinned and held green" case fails. This is the
  # THIRD time this fixture has under-modelled the gate's real inputs - the first
  # was not copying the gate at all, the second not copying the pin file - and
  # the rule is the same each time: a fixture must model everything the thing
  # under test READS, or the test is measuring the fixture.
  [ -f diagrams/TOOLCHAIN.md ] && cp diagrams/TOOLCHAIN.md "$d/diagrams/"
  echo "$d"
}

# fresh_minimal <name> — a SYNTHETIC wiki that satisfies every rule by
# construction, used by the cases that must see a GREEN gate.
#
# Why this exists, and it is a real design fault rather than a nicety: those
# cases used to copy the live wiki, so they asserted "green" on whatever state
# the repository happened to be in. The day another worker's page arrived with a
# rule violation — which is exactly what happened, on the day this was written —
# three green-asserting cases failed at once, and none of them was testing the
# gate. A self-test whose pass/fail depends on live state is a canary for other
# people's work. The red-asserting cases are fine copying the live tree, because
# extra violations cannot make a red tree green; only the GREEN assertions need a
# fixture under this worker's control.
#
# It must clear the checker's own floors (>=20 pages, >=15 taxonomy tags) or the
# checker reports a HARNESS ERROR instead of a verdict, and a HARNESS ERROR is not
# a green, so the fixture has to be big enough to be judged rather than skipped.
fresh_minimal() {
  d="$TMP/$1"
  mkdir -p "$d/wiki/concepts" "$d/wiki/plans" "$d/regress"
  cp "$CHECKER" "$d/regress/"
  # Letter-only tag names: the checker's taxonomy parser accepts ^[a-z][a-z-]*$,
  # so "tag1" was rejected, the fixture parsed as an EMPTY taxonomy, and the
  # checker correctly reported a HARNESS ERROR rather than a verdict. The
  # fixture has to be judgeable, not merely present.
  { echo "# Wiki Schema"; echo; echo "## Tag Taxonomy"
    for t in alpha bravo charlie delta echo foxtrot golf hotel india juliet \
             kilo lima mike november oscar papa; do echo "- $t"; done
    echo; echo "Rule: every tag on a page must appear in this taxonomy."
  } > "$d/wiki/SCHEMA.md"
  : > "$d/wiki/.known-rule-violations.txt"      # nothing pinned: nothing is wrong
  n=34   # clears the link gate's 30-document scope floor
  for i in $(seq -w 1 $n); do
    d1=$(( (10#$i % 20) + 1 )); d2=$(( (10#$i % 20) + 2 ))
    printf '%% fixture page %s\n' "$i" > "$d/wiki/concepts/f$i.md"
    sed -i '1i ---\ntitle: Fixture f'"$i"'\ncreated: 2026-09-25\nupdated: 2026-09-25\ntype: concept\ntags: [alpha, bravo]\nconfidence: high\n---' \
      "$d/wiki/concepts/f$i.md"
    # zero-padded, because the pages are f01..fNN: an UNPADDED f1 does not exist
    # when the page is f01, and the file-link gate correctly reported every one of
    # them dead. The fixture was wrong, not the gate.
    printf '\nSee also [[concepts/f%02d]] and [[concepts/f%02d]].\n' "$d1" "$d2" >> "$d/wiki/concepts/f$i.md"
    printf -- '- [[concepts/f%s]] — fixture.\n' "$i" >> "$d/wiki/index.md"
  done
  sed -i '1i # Index\n' "$d/wiki/index.md"
  echo "$d"
}

# mutate <case-name> <file> <sed-expr> — apply a mutation and REFUSE to let the
# case continue if it changed nothing.
#
# This exists because two cases in the first run of this file failed for a reason
# that had nothing to do with the checker: both seds were written against a page's
# exact current text, both silently matched nothing, and both cases then asserted
# on a page that had not been broken. The failures were visible, which is better
# than the alternative — but a case that does not set up its own condition is not a
# test, and the one that must not happen is a mutation that quietly becomes a
# no-op after an unrelated edit. So a no-op mutation is itself a FAILURE, named.
mutate() {
  m_name=$1; m_file=$2; m_expr=$3
  before=$(cksum < "$m_file")
  sed -i "$m_expr" "$m_file"
  after=$(cksum < "$m_file")
  if [ "$before" = "$after" ]; then
    bad "$m_name" "the MUTATION WAS A NO-OP, so the case tested nothing. sed: $m_expr"
    return 1
  fi
  return 0
}

echo "test_check_wiki_pages: exercising $CHECKER in a throwaway copy"

# ---- 1. the positive control: an unmodified copy is green ------------------
# Without this, every other case is unfalsifiable: a checker that always exits
# 1 would pass cases 2-9 and fail only here, and a checker that always exits 0
# would fail here and pass the rest. Both halves are needed for the set to mean
# anything, which is the same reason the dep-guard test carries a negative
# control.
d=$(fresh_minimal positive)
expect "an unmodified compliant wiki is green (positive control)" 0 "check_wiki_pages: OK" "$d"

# ---- 2. a NEW off-taxonomy tag is red ---------------------------------------
# The sed PREPENDS to whatever the tags line already holds rather than matching
# its exact contents, so the case keeps working when an unrelated page edit
# changes the tag list underneath it.
d=$(fresh_minimal new-tag)
if mutate "NEW off-taxonomy tag" "$d/wiki/concepts/f05.md" \
        's/^tags: \[/tags: [not-a-real-tag, /'; then
  expect "NEW off-taxonomy tag is red" 1 "not-a-real-tag" "$d"
fi

# ---- 3. a NEW missing frontmatter is red -----------------------------------
d=$(fresh_minimal new-frontmatter)
# strip the frontmatter off a page that has one
if mutate "NEW missing frontmatter" "$d/wiki/concepts/f05.md" \
        '1,/^---$/d; 1,/^---$/d'; then
  expect "NEW missing frontmatter is red" 1 "no-frontmatter" "$d"
fi

# ---- 4. a NEW page with no outbound links is red ---------------------------
# Every wikilink is rewritten to plain text, whatever the page happened to link
# to, so the case does not depend on which links it starts with.
d=$(fresh_minimal new-links)
if mutate "NEW page with <2 outbound links" "$d/wiki/concepts/f05.md" \
        's/\[\[[^]]*\]\]/plain-text/g'; then
  expect "NEW page with <2 outbound links is red" 1 "zero-outbound-links" "$d"
fi

# ---- 5. a page missing from the index is red -------------------------------
d=$(fresh_minimal new-index)
# The fixture's own index, and one of the fixture's own pages. This sed pointed at
# concepts/spi-as-firmware after the tree became the fixture, so it matched nothing
# and the case tested an untouched tree - caught by the no-op guard, which is the
# third time that guard has earned its keep.
if mutate "page dropped from index.md" "$d/wiki/index.md" \
        's/\[\[concepts\/f05\]\]/concepts-f05-unlinked/'; then
  expect "page dropped from index.md is red" 1 "not-in-index" "$d"
fi

# ---- 6. THE STALE DIRECTION: a fixed page whose pin survives is red ---------
# The case the whole baseline design turns on. Fix the page, leave the pin, and
# the gate must refuse to pass — otherwise the pin outlives its defect and the
# log and the tree disagree with nothing to say which is true.
#
# IT USED TO BORROW A CORPUS PAGE — plans/spi-pads.md, adding two links to it and
# expecting the pin to go stale. That is a latent coupling, and it was caught by
# diag-timing rather than by me: the case only works while that page is BOTH
# violating AND pinned, so the day someone fixed spi-pads and collected its pin —
# the correct thing to do, and the thing this very gate demands — the case would
# have broken. A corpus page's state is a precondition for the test that verifies
# the corpus, which is the same trap as testing a checker against whatever
# happened to be in the tree. So the fixture is BUILT here, from the compliant
# synthetic wiki, and the pin is written by the test.
d=$(fresh_minimal stale)
# break one fixture page, then pin exactly that violation
sed -i 's/^See also \[\[concepts\/f[0-9]*\]\] and \[\[concepts\/f[0-9]*\]\]\.$/See also concepts only, in prose./' \
  "$d/wiki/concepts/f07.md"
printf 'concepts/f07.md zero-outbound-links synthetic fixture, made non-compliant on purpose\n' \
  > "$d/wiki/.known-rule-violations.txt"
# first prove the pin is load-bearing: pinned and still violating must be GREEN,
# or "STALE below" would be satisfied by a gate that reports everything
expect "a pinned violation is held green, not reported NEW" 0 "check_wiki_pages: OK" "$d"
# now fix the page and leave the pin: that is the STALE condition
cat >> "$d/wiki/concepts/f07.md" <<'EOF'

See also: [[concepts/f08]] and [[concepts/f09]].
EOF
expect "FIXED page with a surviving pin is STALE-red" 1 "STALE" "$d"
# and it must name the page and the rule, not just the word STALE
out=$(cd "$d" && bash regress/check_wiki_pages.sh 2>&1)
if printf '%s\n' "$out" | grep -qF "concepts/f07.md  zero-outbound-links"; then
  ok "STALE report names the page and the rule"
else
  bad "STALE report names the page and the rule" "output did not name 'concepts/f07.md  zero-outbound-links':
$(printf '%s\n' "$out" | sed 's/^/        | /')"
fi

# ---- 7. and the pin can be CLOSED: fix the page AND drop the line ----------
# Case 6 alone would be satisfied by a gate that is simply always red. This is
# the case that makes the pin a workflow instead of a wall.
d=$(fresh_minimal closed)
# Build the pin this case closes: make one fixture page violate the link rule,
# pin it, and prove the pin HOLDS it green before the close is attempted. A pin
# that was never load-bearing would make the close case pass for free.
sed -i 's/^See also \[\[concepts\/f[0-9]*\]\] and \[\[concepts\/f[0-9]*\]\]\.$/See also concepts only, in prose./' \
  "$d/wiki/concepts/f03.md"
printf 'concepts/f03.md zero-outbound-links fixture page made non-compliant on purpose\n' \
  > "$d/wiki/.known-rule-violations.txt"
expect "a pinned violation is held green, not reported NEW" 0 "check_wiki_pages: OK" "$d"
# Now close it properly: fix the page AND drop the pin. Case 6 alone would be
# satisfied by a gate that is simply always red; this is the case that makes the
# pin a workflow instead of a wall.
cat >> "$d/wiki/concepts/f03.md" <<'EOF'

See also: [[concepts/f04]] and [[concepts/f05]].
EOF
: > "$d/wiki/.known-rule-violations.txt"
expect "fixed page AND removed pin is green (not STALE)" 0 "check_wiki_pages: OK" "$d"

# ---- 8-10. fail-closed: the checker must not pass when it cannot see -------
# Fixture-based like the rest: a case that copies the 63-page corpus pays for
# every page on every invocation, and the corpus is not what any of these is
# about. It also removes the last dependence on a page another worker may edit.
d=$(fresh_minimal no-baseline); rm -f "$d/wiki/.known-rule-violations.txt"
expect "missing baseline is a HARNESS ERROR, not a pass" 1 "HARNESS ERROR" "$d"
d=$(fresh_minimal no-schema);   rm -f "$d/wiki/SCHEMA.md"
expect "missing schema is a HARNESS ERROR, not a pass" 1 "HARNESS ERROR" "$d"
# a page list that collapses means the checker stopped looking, which must not
# read as a clean wiki
d=$(fresh_minimal empty-wiki); find "$d/wiki" -name '*.md' -delete
expect "no pages at all is a HARNESS ERROR, not a pass" 1 "HARNESS ERROR" "$d"

# ---- 11. a malformed baseline line is an error, not a skip -----------------
# A baseline entry the checker cannot read is an entry that has silently stopped
# being enforced — which is precisely what the STALE direction exists to
# prevent, so it has to fail closed too.
d=$(fresh_minimal bad-baseline)
printf 'plans/spi-pads.md zero-outbound-links\n' >> "$d/wiki/.known-rule-violations.txt"
expect "baseline line with no reason is a HARNESS ERROR" 1 "HARNESS ERROR" "$d"

# ---- 12. a broken taxonomy parse must not empty the taxonomy ---------------
# If the section heading is renamed, the parse yields nothing and every tag in
# the wiki would be "off taxonomy" — loud, so this is the safe direction — but
# it must be a HARNESS ERROR naming the cause, not a flood that hides a real
# NEW violation in the noise.
d=$(fresh_minimal bad-taxonomy)
if mutate "renamed taxonomy heading" "$d/wiki/SCHEMA.md" \
        's/^## Tag Taxonomy$/## Tag Lexicon/'; then
  expect "renamed taxonomy heading is a HARNESS ERROR" 1 "HARNESS ERROR" "$d"
fi

# ---- 14-19: THE WIRING, which is a separate thing from the gate -------------
# Everything above proves the GATE can fail. That is not the same as proving the
# gate is CALLED, and the gap between the two is where a gate quietly stops
# existing. Nothing in this repo asserts that my call is still in run_all.sh:
# regress/check_harness_preflight.sh globs regress/mutate_*.sh, so it does not
# cover this gate, and its own header records that the pre-flight's wiring "was
# correct on the day it was written and nothing asserted it" - the exact reason
# that file exists. So the wiring needs its own coverage, and the only file I am
# allowed to put it in is this one.
#
# Delete the block from run_all.sh and the suite goes green with the gate simply
# not running. That is the same drift class as a stale MUTABLE list making the
# mapper SKIP a suite, and it is silent in the worst direction: fewer checks, no
# red, no output.

# The wiring cases read regress/run_all.sh from the ambient working directory,
# and the first version did that with NO assertion that the file is there. Run
# from a tree that does not contain it -- a pushed-ref extract of wiki/ and
# diagrams/ without regress/, which is exactly how I first ran this -- four cases
# failed with "no invocation of regress/check_wiki_pages.sh", which reads as
# "the gate is not wired" and is a FALSE ALARM about the project's wiring. Worse,
# the negative control below PASSED in that state, because it passes whenever the
# extraction comes back empty -- including when there was never a file to
# extract. A case that passes for the wrong reason is the one failure mode this
# project cannot afford, and it is exactly what the guard is for.
RUN_ALL=regress/run_all.sh
if [ ! -f "$RUN_ALL" ]; then
  echo "  FAIL  run_all.sh is present to check the wiring against"
  echo "        $RUN_ALL is absent from $(pwd), so the six wiring cases cannot" >&2
  echo "        run. They are NOT reporting that the gate is unwired." >&2
  fail=$((fail + 1))
echo "test_check_wiki_pages: $pass passed, $fail failed"
  exit 1
fi
ok "run_all.sh is present to check the wiring against"

# the wiring block, extracted from run_all.sh exactly as it stands
extract_wiring() {
  awk '/^if bash regress\/check_wiki_pages\.sh/ {on=1} on {print} on && /^fi$/ {exit}' regress/run_all.sh
}

# 14. the call is present at all
if extract_wiring | grep -q 'regress/check_wiki_pages.sh'; then
  ok "run_all.sh still calls the gate"
else
  bad "run_all.sh still calls the gate" "no invocation of regress/check_wiki_pages.sh in regress/run_all.sh - the gate is no longer wired and the suite would be green without it"
fi

# 15. the call is GUARDED, and its failure path is not swallowed.
# Each condition is computed into its own variable first: a pipeline cannot be a
# `[ ]` operand, so writing `cmd | grep -q x && cmd | grep -q y` inside the test
# does not parse. (Shellcheck caught it; the fix is the shape, not a disable.)
blk=$(extract_wiring)
guard_head=$(printf '%s\n' "$blk" | head -1 | cut -c1-3)
guard_fi=$(printf '%s\n' "$blk" | grep -c '^fi$')
guard_stale=$(printf '%s\n' "$blk" | grep -c 'stale=1')
if [ "$guard_head" = "if " ] && [ "$guard_fi" -ge 1 ] && [ "$guard_stale" -ge 1 ]; then
  ok "the wiring is an if/else that sets stale=1 on failure"
else
  bad "the wiring is an if/else that sets stale=1 on failure" "the block is unguarded, or its failure path does not set stale=1, so a failing gate would print FAILED and the suite would continue green:
$(printf '%s\n' "$blk" | sed 's/^/        | /')"
fi

# 16. the `stale` accumulator is actually CONSUMED, and consumed AFTER this block.
# Three separate mistakes each make every documentation gate decorative: never
# initialising stale, or consuming it before the gates that set it.
init_line=$(grep -n '^stale=0$' regress/run_all.sh | head -1 | cut -d: -f1)
wire_line=$(grep -n '^if bash regress\/check_wiki_pages\.sh' regress/run_all.sh | head -1 | cut -d: -f1)
consume_line=$(grep -n '\[ "\$stale" -eq 0 \] || exit 1' regress/run_all.sh | head -1 | cut -d: -f1)
if [ -n "$init_line" ] && [ -n "$wire_line" ] && [ -n "$consume_line" ] \
   && [ "$init_line" -lt "$wire_line" ] && [ "$wire_line" -lt "$consume_line" ]; then
  ok "stale is initialised before the gate and consumed after it ($init_line < $wire_line < $consume_line)"
else
  bad "stale is initialised before the gate and consumed after it" "init=$init_line wiring=$wire_line consume=$consume_line - the accumulator must be set, then used by the gate, then turned into an exit code after it"
fi

# 17-18. EXECUTE the wiring, in both directions. Asserting the wiring's TEXT is
# not the same as running it, and "the wiring has never been executed" is the
# complaint that started this section - so it gets executed, from the block
# extracted out of run_all.sh rather than a copy of it.
#   pass direction: pristine wiki  -> stale stays 0
#   fail direction: a broken page  -> stale becomes 1
# The fixture, not the live tree: this case asserts a PASSING gate, and on the
# live tree the gate was legitimately red because of another worker's page, so
# the case was measuring their state rather than the wiring.
d=$(fresh_minimal wire-pass)
{ echo 'stale=0'; extract_wiring; echo 'echo "STALE=$stale"'; } > "$TMP/wiring.sh"
cp "$TMP/wiring.sh" "$d/"
got=$(cd "$d" && bash wiring.sh 2>/dev/null | tail -1)
if [ "$got" = "STALE=0" ]; then
  ok "wiring executed: a passing gate leaves stale=0"
else
  bad "wiring executed: a passing gate leaves stale=0" "got '$got'"
fi

d=$(fresh_minimal wire-fail)
if mutate "wiring fail-direction breakage" "$d/wiki/concepts/f05.md" \
        's/^tags: \[/tags: [not-a-real-tag, /'; then
  { echo 'stale=0'; extract_wiring; echo 'echo "STALE=$stale"'; } > "$TMP/wiring.sh"
  cp "$TMP/wiring.sh" "$d/"
  got=$(cd "$d" && bash wiring.sh 2>/dev/null | tail -1)
  if [ "$got" = "STALE=1" ]; then
    ok "wiring executed: a FAILING gate sets stale=1"
  else
    bad "wiring executed: a FAILING gate sets stale=1" "got '$got' - a broken page must turn the accumulator red, or the suite prints FAILED and carries on"
  fi
fi

# 19. the negative control for this whole section: remove the wiring from a COPY
# and confirm the extraction comes back empty. Without this, cases 14-18 would be
# satisfied by a checker that greps for anything at all.
cp regress/run_all.sh "$TMP/run_all_nowiring.sh"
# The removed lines, matched with grep -v rather than an awk regex: the awk form
# needed `s|...|...|` with escaped slashes inside, which prints "stray \ before /"
# to stderr, and noise in a gate's own output is how people learn to ignore it.
sed -e '/^  tail -20 \/tmp\/check_wiki_pages\.log$/d' -e '/^  stale=1$/d' \
  "$TMP/run_all_nowiring.sh" \
  | grep -v -e '^if bash regress/check_wiki_pages\.sh' \
            -e '^  echo "wiki page rules: OK' \
            -e '^  echo "wiki page rules: FAILED' \
  > "$TMP/run_all_rewired.sh"
# Prove the starting point really did contain the wiring, or this control is
# vacuous: an empty extraction must mean "removed", never "was never there".
if ! extract_wiring | grep -q 'regress/check_wiki_pages.sh'; then
  bad "removing the wiring is DETECTED" "the control is vacuous: the wiring was already absent from $RUN_ALL before any removal, so an empty extraction proves nothing"
elif awk '/^if bash regress\/check_wiki_pages\.sh/ {on=1} on {print} on && /^fi$/ {exit}' "$TMP/run_all_rewired.sh" | grep -q .; then
  bad "removing the wiring is DETECTED" "the block survived the removal, so cases 14-18 would pass on a copy with no gate wired at all"
else
  ok "removing the wiring is DETECTED (negative control for 14-18, and it started from a wired file)"
fi

# The diagram gate is tools/diag/check_diagrams.sh, which absorbed the retired
# regress/check_diagram_renders.sh (and its pinned-baseline mechanism) by manager
# ruling. It derives REPO from BASH_SOURCE, so a copy under <scratch>/tools/diag
# checks <scratch> — which is what lets the pin cases below run on a fixture.
RENDER_CHECK=tools/diag/check_diagrams.sh
# ---- 20-21: the folded DIAGRAM gate exists and is honest about the corpus ----
# The cases that used to live here - stale render, orphan render, missing format,
# puml syntax error - PLANTED DEFECTS AND ASKED THE GATE TO CATCH THEM. They are
# gone because that is now tools/diag/check_diagrams.sh's own `--self-test`, which
# regress/run_all.sh already runs, and duplicating it here would have meant two
# places to update for one behaviour. What is kept is what only THIS file can
# check: that the gate is present, and what the live corpus looks like.
if [ -f "$RENDER_CHECK" ] && bash -n "$RENDER_CHECK" 2>/dev/null; then
  ok "the diagram gate exists and parses (tools/diag/check_diagrams.sh)"
else
  bad "the diagram gate exists and parses" "$RENDER_CHECK missing or unparseable"
fi
# The real tree, REPORTED but not asserted - the same demotion the page gate got.
# A corpus defect is the GATE's finding to make, and a self-test that goes red
# over it reports "the gate is broken" when the gate is working perfectly.
rout=$(bash "$RENDER_CHECK" 2>&1); rrc=$?
if [ "$rrc" -eq 0 ]; then
  ok "real-tree diagram state: CLEAN"
else
  n_fail=$(printf '%s\n' "$rout" | grep -c '^  FAIL:')
  ok "real-tree diagram state: $n_fail finding(s) reported by the gate (informational, not a failure here)"
  printf '%s\n' "$rout" | grep '^  FAIL:' | sed 's/^/        | /'
fi

# ---- 33-37: the PINNED BASELINE now folded into the diagram gate ----------
# A pin mechanism with no negative control is the thing this file exists to stop,
# so both directions are proven, and so is the fail-closed path. The pin file is
# what keeps the full suite green while four known-stale renders are owned by
# someone else; it is only safe because a NEW stale render is still red and a pin
# that stops biting is still red.
# 33. a stale render that is NOT pinned is NEW and red
d=$(fresh_render pin-new)
victim=$(ls "$d"/diagrams/*.png 2>/dev/null | head -1)
: > "$d/wiki/.known-stale-diagrams.txt"          # an empty pin file = nothing known
printf 'x' >> "$victim"
out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
# Two plain substring greps, not one clever regex: the folded gate's finding is
# "FAIL: <name> differs from a fresh render of the current source", and the file
# name has no need to be interpolated into a pattern at all. An earlier version
# nested $(basename ...) inside a double-quoted alternation and bash could not
# parse it - a checker that will not parse is a checker that checks nothing.
vname=$(basename "$victim")
if [ "$rc" -ne 0 ] \
   && printf '%s\n' "$out" | grep -qF "differs from a fresh render" \
   && printf '%s\n' "$out" | grep -qF "$vname"; then
  ok "an UNPINNED stale render is NEW-red"
else
  bad "an UNPINNED stale render is NEW-red" "exit $rc
$(printf '%s\n' "$out" | tail -4 | sed 's/^/        | /')"
fi

# 34. and it is green when the same render IS pinned
d=$(fresh_render pin-ok)
victim=$(ls "$d"/diagrams/*.png 2>/dev/null | head -1)
printf 'x' >> "$victim"
printf '%s synthetic fixture, made stale on purpose\n' "$(basename "$victim")" \
  > "$d/wiki/.known-stale-diagrams.txt"
out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'diagrams: OK'; then
  ok "a PINNED stale render is held green, not reported NEW"
else
  bad "a PINNED stale render is held green, not reported NEW" "exit $rc
$(printf '%s\n' "$out" | tail -4 | sed 's/^/        | /')"
fi

# 35. a pin that NO LONGER BITES is red - the anti-staleness direction, and the
# half that stops a pin outliving its defect. The render is COMPLIANT; the pin
# claims it is stale. That contradiction is the finding.
#
# Two defects lived in this case as first written, and both are worth recording
# because together they made it PASS FOR THE WRONG REASON. The printf had no %s,
# so the filename argument was discarded and the pin actually named a file called
# "a" - which does not exist, so the gate reported STALE-PIN-ABSENT; and the
# assertion grepped for 'STALE-PIN', which is a SUBSTRING of 'STALE-PIN-ABSENT'.
# So the case went green while testing the absent-render path, which is a
# different defect with a different remedy. A test that cannot fail for the reason
# it claims is the one failure mode this file exists to prevent, and it is invisible
# precisely because it is green.
d=$(fresh_render pin-stale)
rel=$(ls "$d"/diagrams/*.png 2>/dev/null | head -1 | xargs basename)
if [ -z "$rel" ]; then
  bad "a pin that no longer bites is STALE-PIN-red" "the fixture produced no .png to pin, so the case tested nothing"
else
  printf '%s pinned but actually current, so the pin must be collected\n' "$rel" \
    > "$d/wiki/.known-stale-diagrams.txt"
  out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
  # The assertion is specific on purpose: it must match the re-rendered finding
  # and NOT the absent one, or this case can pass on the wrong defect again.
  if [ "$rc" -ne 0 ] \
     && printf '%s\n' "$out" | grep -q "STALE-PIN $rel " \
     && ! printf '%s\n' "$out" | grep -q 'STALE-PIN-ABSENT'; then
    ok "a pin that no longer bites is STALE-PIN-red (and not confused with absent)"
  else
    bad "a pin that no longer bites is STALE-PIN-red (and not confused with absent)" "exit $rc
$(printf '%s\n' "$out" | tail -4 | sed 's/^/        | /')"
  fi
fi

# 35b. and the OTHER way a pin stops biting: the render is simply GONE. Distinct
# remedy - collect the pin AND notice the render vanished - so it gets its own
# case rather than being folded into 35.
d=$(fresh_render pin-absent)
rel=$(ls "$d"/diagrams/*.png 2>/dev/null | head -1 | xargs basename)
if [ -z "$rel" ]; then
  bad "a pin whose render is absent is STALE-PIN-ABSENT-red" "the fixture produced no .png, so the case tested nothing"
else
  printf '%s pinned, and this render does not exist in the tree\n' "$rel" \
    > "$d/wiki/.known-stale-diagrams.txt"
  rm -f "$d/diagrams/$rel"
  out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "STALE-PIN-ABSENT $rel "; then
    ok "a pin whose render is absent is STALE-PIN-ABSENT-red"
  else
    bad "a pin whose render is absent is STALE-PIN-ABSENT-red" "exit $rc
$(printf '%s\n' "$out" | tail -4 | sed 's/^/        | /')"
  fi
fi

# 36. a missing pin file is a HARNESS ERROR, not a pass - an absent pin file
# would make every known-stale render look NEW and drown the real signal.
d=$(fresh_render pin-missing)
rm -f "$d/wiki/.known-stale-diagrams.txt"
out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'HARNESS ERROR'; then
  ok "a missing pin file is a HARNESS ERROR, not a pass"
else
  bad "a missing pin file is a HARNESS ERROR, not a pass" "exit $rc
$(printf '%s\n' "$out" | tail -3 | sed 's/^/        | /')"
fi

# 37. a malformed pin line is an error, not a skip, for the same reason the page
# baseline treats one that way: a pin this checker cannot read has silently
# stopped being enforced.
d=$(fresh_render pin-malformed)
printf 'onlyonefield\n' >> "$d/wiki/.known-stale-diagrams.txt"
out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'HARNESS ERROR'; then
  ok "a malformed pin line is a HARNESS ERROR, not a skip"
else
  bad "a malformed pin line is a HARNESS ERROR, not a skip" "exit $rc
$(printf '%s\n' "$out" | tail -3 | sed 's/^/        | /')"
fi

# ---- 38-45: the FILE-LINK gate ----------------------------------------------
# The requirement that earned this gate: resolve BOTH [[wikilink]] conventions,
# and PROVE it by planting one of each. A resolver that knows one form calls
# every link in the other dead, and people then "fix" links that were fine - a
# checker that invents dead links is worse than no checker, because the
# repository learns to distrust its own prose. The first draft of this gate
# reported 194 invented dead links and was reverted rather than shipped.
LINKS=regress/check_wiki_links.sh

# 38. the gate exists and parses
if [ -f "$LINKS" ] && bash -n "$LINKS" 2>/dev/null; then
  ok "the file-link gate exists and parses"
else
  bad "the file-link gate exists and parses" "$LINKS missing or unparseable"
fi

# 39. a clean fixture is green
d=$(fresh_minimal links-clean)
cp "$LINKS" "$d/regress/"
cp wiki/.known-dead-links.txt "$d/wiki/"
out=$(cd "$d" && bash "$LINKS" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'check_wiki_links: OK'; then
  ok "a clean document set is green"
else
  bad "a clean document set is green" "exit $rc
$(printf '%s\n' "$out" | tail -3 | sed 's/^/        | /')"
fi

# 40. BOTH conventions, LIVE, are not reported. This is the case diag-timing
# asked for: a resolver that knows one form reports the other as dead.
d=$(fresh_minimal links-both)
cp "$LINKS" "$d/regress/"; cp wiki/.known-dead-links.txt "$d/wiki/"
# a wiki-relative link ([[concepts/x]], the target exists) and a bare sibling
# link ([[f02]], also exists) - plus a markdown file link that exists
cat >> "$d/wiki/concepts/f05.md" <<'MD'

See [[concepts/f06]] and [[f07]], and [f08](f08.md).
MD
out=$(cd "$d" && bash "$LINKS" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'check_wiki_links: OK'; then
  ok "LIVE links in BOTH conventions plus a markdown link are not reported"
else
  bad "LIVE links in BOTH conventions plus a markdown link are not reported" "exit $rc
$(printf '%s\n' "$out" | head -6 | sed 's/^/        | /')"
fi

# 41. a genuinely dead link is red, in EACH convention
d=$(fresh_minimal links-dead)
cp "$LINKS" "$d/regress/"; cp wiki/.known-dead-links.txt "$d/wiki/"
cat >> "$d/wiki/concepts/f05.md" <<'MD'

Broken: [[concepts/nope]] and [[alsonope]] and [x](missing.md).
MD
out=$(cd "$d" && bash "$LINKS" 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s\n' "$out" | grep -q 'concepts/nope' \
   && printf '%s\n' "$out" | grep -q 'alsonope' \
   && printf '%s\n' "$out" | grep -q 'missing.md'; then
  ok "a dead link is red in BOTH conventions and as a markdown link"
else
  bad "a dead link is red in BOTH conventions and as a markdown link" "exit $rc
$(printf '%s\n' "$out" | head -6 | sed 's/^/        | /')"
fi

# 42. a sources: citation that does NOT resolve must not be reported - it is a
# citation, not an outbound link, and reporting it is the false positive that
# would invite "fixing" a citation which was never broken.
d=$(fresh_minimal links-citation)
cp "$LINKS" "$d/regress/"; cp wiki/.known-dead-links.txt "$d/wiki/"
sed -i 's|^sources:.*|sources: [reviews/2026-01-01/does-not-exist.md]|' "$d/wiki/concepts/f05.md"
out=$(cd "$d" && bash "$LINKS" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a non-resolving sources: citation is NOT reported (body-only rule)"
else
  bad "a non-resolving sources: citation is NOT reported (body-only rule)" "exit $rc
$(printf '%s\n' "$out" | head -4 | sed 's/^/        | /')"
fi

# 43-44. the pin, both directions
d=$(fresh_minimal links-pinned)
cp "$LINKS" "$d/regress/"; cp wiki/.known-dead-links.txt "$d/wiki/"
cat >> "$d/wiki/concepts/f05.md" <<'MD'

Broken: [[concepts/nope]].
MD
printf 'wiki/concepts/f05.md concepts/nope synthetic pin, made dead on purpose\n' \
  > "$d/wiki/.known-dead-links.txt"
out=$(cd "$d" && bash "$LINKS" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'check_wiki_links: OK'; then
  ok "a PINNED dead link is held green, not reported NEW"
else
  bad "a PINNED dead link is held green, not reported NEW" "exit $rc
$(printf '%s\n' "$out" | head -4 | sed 's/^/        | /')"
fi
# and the anti-staleness direction: the pin outlives the defect -> red
d=$(fresh_minimal links-stalepin)
cp "$LINKS" "$d/regress/"; cp wiki/.known-dead-links.txt "$d/wiki/"
printf 'wiki/concepts/f05.md concepts/nope pinned but nothing is broken\n' \
  > "$d/wiki/.known-dead-links.txt"
out=$(cd "$d" && bash "$LINKS" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'STALE'; then
  ok "a pin that no longer bites is STALE-red"
else
  bad "a pin that no longer bites is STALE-red" "exit $rc
$(printf '%s\n' "$out" | head -4 | sed 's/^/        | /')"
fi

# 45. a missing pin file is a HARNESS ERROR, not a pass
d=$(fresh_minimal links-nopin)
cp "$LINKS" "$d/regress/"; rm -f "$d/wiki/.known-dead-links.txt"
out=$(cd "$d" && bash "$LINKS" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'HARNESS ERROR'; then
  ok "a missing pin file is a HARNESS ERROR, not a pass"
else
  bad "a missing pin file is a HARNESS ERROR, not a pass" "exit $rc
$(printf '%s\n' "$out" | head -3 | sed 's/^/        | /')"
fi

echo "test_check_wiki_pages: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0