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
  mkdir -p "$d/wiki" "$d/regress" "$d/diagrams"
  cp -a wiki/. "$d/wiki/"
  cp "$CHECKER" "$d/regress/"
  cp "$RENDER_CHECK" "$d/regress/"
  # two sources, chosen for having the fewest files, plus every render either
  # produces (including PlantUML's numbered _00N siblings)
  for f in $(ls -S diagrams/*.puml | tail -2); do
    b=$(basename "$f")
    cp "diagrams/$b" "$d/diagrams/"
    for r in diagrams/${b%.puml}*.png diagrams/${b%.puml}*.svg; do
      [ -f "$r" ] && cp "$r" "$d/diagrams/"
    done
  done
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
  n=21
  for i in $(seq -w 1 $n); do
    d1=$(( (10#$i % 20) + 1 )); d2=$(( (10#$i % 20) + 2 ))
    printf '%% fixture page %s\n' "$i" > "$d/wiki/concepts/f$i.md"
    sed -i '1i ---\ntitle: Fixture f'"$i"'\ncreated: 2026-09-25\nupdated: 2026-09-25\ntype: concept\ntags: [alpha, bravo]\nconfidence: high\n---' \
      "$d/wiki/concepts/f$i.md"
    printf '\nSee also [[concepts/f%d]] and [[concepts/f%d]].\n' "$d1" "$d2" >> "$d/wiki/concepts/f$i.md"
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
d=$(fresh new-tag)
if mutate "NEW off-taxonomy tag" "$d/wiki/concepts/spi-as-firmware.md" \
        's/^tags: \[/tags: [not-a-real-tag, /'; then
  expect "NEW off-taxonomy tag is red" 1 "not-a-real-tag" "$d"
fi

# ---- 3. a NEW missing frontmatter is red -----------------------------------
d=$(fresh new-frontmatter)
# strip the frontmatter off a page that has one
if mutate "NEW missing frontmatter" "$d/wiki/concepts/spi-as-firmware.md" \
        '1,/^---$/d; 1,/^---$/d'; then
  expect "NEW missing frontmatter is red" 1 "no-frontmatter" "$d"
fi

# ---- 4. a NEW page with no outbound links is red ---------------------------
# Every wikilink is rewritten to plain text, whatever the page happened to link
# to, so the case does not depend on which links it starts with.
d=$(fresh new-links)
if mutate "NEW page with <2 outbound links" "$d/wiki/concepts/spi-as-firmware.md" \
        's/\[\[[^]]*\]\]/plain-text/g'; then
  expect "NEW page with <2 outbound links is red" 1 "zero-outbound-links" "$d"
fi

# ---- 5. a page missing from the index is red -------------------------------
d=$(fresh new-index)
if mutate "page dropped from index.md" "$d/wiki/index.md" \
        's/\[\[concepts\/spi-as-firmware\]\]/spi-as-firmware/'; then
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
d=$(fresh no-baseline); rm -f "$d/wiki/.known-rule-violations.txt"
expect "missing baseline is a HARNESS ERROR, not a pass" 1 "HARNESS ERROR" "$d"
d=$(fresh no-schema);   rm -f "$d/wiki/SCHEMA.md"
expect "missing schema is a HARNESS ERROR, not a pass" 1 "HARNESS ERROR" "$d"
# a page list that collapses means the checker stopped looking, which must not
# read as a clean wiki
d=$(fresh empty-wiki); find "$d/wiki" -name '*.md' -delete
expect "no pages at all is a HARNESS ERROR, not a pass" 1 "HARNESS ERROR" "$d"

# ---- 11. a malformed baseline line is an error, not a skip -----------------
# A baseline entry the checker cannot read is an entry that has silently stopped
# being enforced — which is precisely what the STALE direction exists to
# prevent, so it has to fail closed too.
d=$(fresh bad-baseline)
printf 'plans/spi-pads.md zero-outbound-links\n' >> "$d/wiki/.known-rule-violations.txt"
expect "baseline line with no reason is a HARNESS ERROR" 1 "HARNESS ERROR" "$d"

# ---- 12. a broken taxonomy parse must not empty the taxonomy ---------------
# If the section heading is renamed, the parse yields nothing and every tag in
# the wiki would be "off taxonomy" — loud, so this is the safe direction — but
# it must be a HARNESS ERROR naming the cause, not a flood that hides a real
# NEW violation in the noise.
d=$(fresh bad-taxonomy)
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

RENDER_CHECK=regress/check_diagram_renders.sh
# ---- 20-25: the DIAGRAM RENDER gate ------------------------------------------
# Same reason as everything above, for the sibling check: nothing gated
# diagrams/ at all, the directory went 26 -> 106 files, and a stale render is
# invisible because the picture still looks like a correct picture OF SOMETHING.
# This gate was only built after measuring that the renders are byte-
# REPRODUCIBLE (otherwise it could only ever be red) and that 84/84 are current
# (otherwise it would ship as a wall of known failures nobody routes around).
# A gate whose feasibility was measured but whose FAILURE paths were never seen
# is half a gate.
# 20. the gate exists and parses
if [ -f "$RENDER_CHECK" ] && bash -n "$RENDER_CHECK" 2>/dev/null; then
  ok "the diagram render gate exists and parses"
else
  bad "the diagram render gate exists and parses" "$RENDER_CHECK missing or unparseable"
fi

# 21. it is green on a KNOWN-COMPLIANT diagram set.
# It used to assert green on the REAL tree, which is the same latent coupling
# diag-timing caught in the STALE case: the case then only passes while the whole
# corpus happens to be clean, so a genuine defect anywhere in diagrams/ turns a
# negative control red and the suite reports "the gate is broken" when the gate is
# in fact working perfectly. It went red for real within a merge of landing,
# because two project-map renders genuinely ARE stale. Corpus health is the GATE's
# job — it is wired into run_all.sh and reports that defect by name — so a
# self-test asserting it is measuring the wrong thing twice.
#
# So the fixture is built here: a couple of trivial sources, rendered in place with
# the documented command, which makes them compliant by construction. This proves
# the green path deterministically, whatever the repository holds.
d=$(fresh_render render-green)
rm -rf "$d/diagrams"; mkdir -p "$d/diagrams"
cat > "$d/diagrams/fixture-a.puml" <<'PUML'
@startuml
rectangle "fixture A" as A
A -> A : self loop
@enduml
PUML
cat > "$d/diagrams/fixture-b.puml" <<'PUML'
@startuml
rectangle "fixture B" as B
B -> B : also self
@enduml
PUML
( cd "$d" && JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192" \
    plantuml -tsvg diagrams/fixture-a.puml diagrams/fixture-b.puml >/dev/null 2>&1 \
  && JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -DPLANTUML_LIMIT_SIZE=8192" \
    plantuml -tpng diagrams/fixture-a.puml diagrams/fixture-b.puml >/dev/null 2>&1 )
out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'diagram renders: OK'; then
  ok "render gate is green on a known-compliant diagram set"
else
  bad "render gate is green on a known-compliant diagram set" "exit $rc
$(printf '%s\n' "$out" | tail -6 | sed 's/^/        | /')"
fi

# 21b. and the REAL tree, reported but not asserted. The corpus is currently
# carrying two stale project-map renders (a .puml edited in 5c6db3d without a
# re-render), which is the gate doing its job. Recording it here means a reader of
# this file learns the state of the corpus without the suite going red over it —
# and if the corpus is ever clean, this says so too.
rout=$(bash "$RENDER_CHECK" 2>&1); rrc=$?
if [ "$rrc" -eq 0 ]; then
  ok "real-tree render state: CLEAN (no stale render in diagrams/)"
else
  n_stale=$(printf '%s\n' "$rout" | grep -c '^STALE ')
  ok "real-tree render state: $n_stale stale render(s) reported by the gate (informational, not a failure here)"
  printf '%s\n' "$rout" | grep '^STALE ' | sed 's/^/        | /'
fi

# 22-24. a stale render, an ORPHANED render and a NO-SOURCE render are each red.
# All three in a scratch copy; the real diagrams/ is never touched.
# 22. STALE: a checked-in render that is no longer the render of its source.
# The RENDER is corrupted, not the source: appending a byte cannot fail to
# change the file, whereas an earlier attempt edited a .puml with a sed pattern
# that matched nothing - which the no-op guard above caught, in a case that
# would otherwise have quietly tested a pristine tree.
d=$(fresh_render render-stale)
# Derive the victim from the FIXTURE, do not name a corpus file. Naming
# project-progress.png worked while fresh_render copied the whole diagrams tree
# and broke the moment the fixture became minimal: the file was absent, so
# `printf >>` CREATED it, the mutation "succeeded", and the case silently ended
# up testing the no-source direction instead of the stale one. A mutation that
# creates the thing it meant to corrupt is not a no-op, so the no-op guard could
# not catch it — the guard for this is asserting the victim existed FIRST.
victim=$(ls "$d"/diagrams/*.png 2>/dev/null | head -1)
if [ -z "$victim" ]; then
  bad "a checked-in render that no longer matches its source is STALE-red" "the fixture produced no .png to corrupt, so the case tested nothing"
else
  printf 'x' >> "$victim"
  out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "STALE.*$(basename "$victim")"; then
    ok "a checked-in render that no longer matches its source is STALE-red"
  else
    bad "a checked-in render that no longer matches its source is STALE-red" "exit $rc, corrupting $(basename "$victim")
$(printf '%s\n' "$out" | tail -5 | sed 's/^/        | /')"
  fi
fi

# 23. ORPHANED: a checked-in render the source does not produce.
d=$(fresh_render render-orphan)
# a render the fixture provably does not contain, again derived rather than named
base=$(basename "$(ls "$d"/diagrams/*.puml 2>/dev/null | head -1)" .puml)
printf 'not a real png\n' > "$d/diagrams/${base}_009.png"
out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "${base}_009.png"; then
  ok "a render with no source-produced counterpart is red"
else
  bad "a render with no source-produced counterpart is red" "exit $rc
$(printf '%s\n' "$out" | tail -5 | sed 's/^/        | /')"
fi

# 24. NO-SOURCE: a render whose .puml is gone, so nothing can regenerate it.
# The first version deleted proto-midi-frame.puml — which does not exist, so `rm`
# was a silent no-op and the case asserted against an untouched tree, which is the
# same trap the sed guard above exists for. The source is now chosen from what is
# actually present, and the case refuses to continue if the removal was a no-op.
d=$(fresh_render render-nosource)
victim=$(ls "$d"/diagrams/*.puml | head -1)
victim_rel=$(basename "$victim")
rm -f "$victim"
if [ -f "$victim" ]; then
  bad "a render whose source was deleted is red" "the rm was a no-op, so the case tested nothing ($victim_rel)"
else
  out=$(cd "$d" && bash "$RENDER_CHECK" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'NO-SOURCE'; then
    ok "a render whose source was deleted is red ($victim_rel removed)"
  else
    bad "a render whose source was deleted is red" "exit $rc after removing $victim_rel
$(printf '%s\n' "$out" | tail -5 | sed 's/^/        | /')"
  fi
fi

# 25. and the loud SKIP: no plantuml must be a printed skip, never a silent pass.
# A box without a diagram renderer is normal, so this cannot be a hard failure;
# but a green run must still distinguish "checked" from "not checked".
# The PATH holds exactly the three commands the script reaches BEFORE it tests for
# plantuml. An empty PATH does not work: find/wc/tr are used first, so the script
# would die on the page-count floor and report the wrong reason entirely.
d=$(fresh_render render-noplantuml)
mkdir -p "$d/bin"
for t in find wc tr; do p=$(command -v "$t") && ln -sf "$p" "$d/bin/$t"; done
out=$(cd "$d" && PATH="$d/bin" /bin/bash regress/check_diagram_renders.sh 2>&1); rc=$?
if printf '%s\n' "$out" | grep -q 'SKIPPED' && [ "$rc" -eq 0 ]; then
  ok "a missing plantuml is a loud SKIP with exit 0, not a silent pass"
else
  bad "a missing plantuml is a loud SKIP with exit 0, not a silent pass" "exit $rc
$(printf '%s\n' "$out" | tail -4 | sed 's/^/        | /')"
fi

# ---- 30-32: ALL THREE are CALLED, including this file -----------------------
# Cases 14-19 already assert the page gate's wiring. They did NOT assert the
# render gate's, or this file's own — and that is the same bug I had just fixed,
# one level up. All three of these were written, all three had been run by hand,
# and TWO of them were not executed by the full regression at all: a run could be
# green with the render gate never invoked. A negative control that does not
# assert its own wiring is the thing it exists to prevent.
for s in check_wiki_pages check_diagram_renders test_check_wiki_pages; do
  if grep -qE "^if bash regress/${s}\.sh" "$RUN_ALL"; then
    ok "run_all.sh CALLS regress/$s.sh (not merely mentions it)"
  else
    bad "run_all.sh CALLS regress/$s.sh" "no '^if bash regress/$s.sh' in $RUN_ALL - a run can be green with it never executed, which is exactly how the render gate and this self-test both sat unwired"
  fi
done
# And each of the three must be able to turn the run red, not merely print a
# line. Checked by shape rather than by running the suite: the call must be a
# guarded `if` whose else sets the accumulator that becomes the exit code.
for s in check_diagram_renders test_check_wiki_pages; do
  blk=$(awk -v pat="^if bash regress/${s}\\.sh" '$0 ~ pat {on=1} on {print} on && /^fi$/ {exit}' "$RUN_ALL")
  if [ -n "$blk" ] && printf '%s\n' "$blk" | grep -q 'stale=1'; then
    ok "$s is wired so a failure turns the run red"
  else
    bad "$s is wired so a failure turns the run red" "the block does not set stale=1, so a failing gate would print FAILED and the suite would continue green:
$(printf '%s\n' "$blk" | sed 's/^/        | /')"
  fi
done



echo "test_check_wiki_pages: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0