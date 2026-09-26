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
d=$(fresh positive)
expect "unmodified copy is green (positive control)" 0 "check_wiki_pages: OK" "$d"

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
# log and the tree disagree with nothing to say so.
d=$(fresh stale)
# plans/spi-pads.md is pinned for zero-outbound-links; give it two real links
cat >> "$d/wiki/plans/spi-pads.md" <<'EOF'

See also: [[concepts/spi-as-firmware]] and [[concepts/pin-matrix]].
EOF
expect "FIXED page with a surviving pin is STALE-red" 1 "STALE" "$d"
# and it must name the page, not just the word STALE
out=$(cd "$d" && bash regress/check_wiki_pages.sh 2>&1)
if printf '%s\n' "$out" | grep -qF "plans/spi-pads.md"; then
  ok "STALE report names the page and the rule"
else
  bad "STALE report names the page and the rule" "output did not name plans/spi-pads.md:
$(printf '%s\n' "$out" | sed 's/^/        | /')"
fi

# ---- 7. and the pin can be CLOSED: fix the page AND drop the line ----------
# Case 6 alone would be satisfied by a gate that is simply always red. This is
# the case that makes the pin a workflow instead of a wall.
d=$(fresh closed)
cat >> "$d/wiki/plans/spi-pads.md" <<'EOF'

See also: [[concepts/spi-as-firmware]] and [[concepts/pin-matrix]].
EOF
grep -v '^plans/spi-pads.md zero-outbound-links' wiki/.known-rule-violations.txt \
  > "$d/wiki/.known-rule-violations.txt"
expect "fixed page AND removed pin is green" 0 "check_wiki_pages: OK" "$d"

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

echo "test_check_wiki_pages: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
