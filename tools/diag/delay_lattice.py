#!/usr/bin/env python3
"""Check the delay-lattice arithmetic quoted in the timing-protocol figures.

WHY THIS EXISTS. The manager's review passes 3 and 4 on the servo and DS18B20
figure sets found THREE numbers that were wrong in exactly one way: each was
internally consistent and inconsistent with the arithmetic printed a few lines
away.

  D1  servo  pulse step  quoted 4*152+11  =  619 clocks = 10.3 us
  D2  servo  gap   step  quoted 10+10*499 = 4655 clocks = 77.6 us
  D3  ds18b20 slot step  quoted 69 clocks = 1.22 us   (69/60 = 1.15)

A reader who tried to REPRODUCE the table from the figure got a different answer
from the measured one, and had no way to tell which of the two was wrong. All
three had been copied from a source-of-truth comment rather than derived. Then
re-deriving the whole lattice found a FOURTH nobody had flagged: the DS18B20
reset, 29 172 clocks printed against 29 131 actual.

That is four in one pass, and the reviewer is right to call it a pattern. The
three D's are all the SAME arithmetic -- a clock count and its microsecond
conversion, printed side by side, and only one of them derived. So the checker
does not look for those three strings. It recomputes every "N clocks = X us" in
every figure and every page, which catches D1, D2 and D3 without having been told
they exist, and would catch the next one nobody has found yet.

THE MODEL. One formula, shared by servo_sweep.pe, dht11_read.pe, ds18b20.pe and
nec_ir.pe:

    total(n1,n2,n3) = (n1-1) * (10 + (n2-1) * (4*n3 + 7)) + 4   clocks
    step(n2,n3)     =           10 + (n2-1) * (4*n3 + 7)           clocks
    CLK_HZ          = 60_000_000

The two-level form in the WS2812 header, (n1-1)*(4*n2+7)+4, is the same
expression with n2 pinned to 1. It is deliberately NOT folded in here: two
spellings of one model is exactly the confusion this file exists to prevent.

WHAT IT CHECKS, and all three halves matter:
  1. the CLOCK->us AUDIT, over every figure and every page. This is the one
     that matters; the rest are here because a checker with one kind of check
     invites the assumption that the others are covered too.
  2. every derived step and total, against the MEASURED wire value with a stated
     tolerance -- so the derivation is checked against the hardware and not
     merely against itself.
  3. that the claim shapes the review caught stay absent, so a later edit cannot
     quietly reintroduce them.

It also proves it can fail. See the negative control at the end.

Usage:  tools/diag/delay_lattice.py [repo-root]
        tools/diag/delay_lattice.py --selftest [repo-root]
Exit 0 = every quoted number agrees, 1 = a disagreement, each one named.
--selftest plants real errors in a copy of the real files and demands that
THIS PROGRAM exit non-zero, then demands it goes green again once they are
removed. It is the only control that tests the exit code rather than a function
inside this file.
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

CLK_HZ = 60_000_000
# Options are filtered out before the root is resolved. The first version of
# this line took sys.argv[1] blindly, so `delay_lattice.py --selftest` set ROOT
# to a directory literally named "--selftest" and the self-test reported "cannot
# run, required files are absent" - which is the gate refusing for the right
# reason and the WRONG one, and indistinguishable from a real missing file.
# A gate that cannot tell those two apart will eventually be believed.
_args = [a for a in sys.argv[1:] if not a.startswith("--")]


def _default_root() -> Path:
    """the repo root, without assuming how deep this file sits.

    The obvious spelling is Path(__file__).resolve().parents[2], and it
    CRASHES with IndexError when the script is run from a copy that is not at
    that depth - a copy at /tmp, a symlink target, a vendored checkout. Found
    by running the self-test from a copy of the file, which is the sort of
    thing the self-test is for. A gate that tracebacks on a path it did not
    expect reports nothing about anything, and the reader concludes the gate is
    broken rather than that the numbers are unchecked.

    So: walk up from here until the expected directories appear, and say so
    plainly if they do not.
    """
    here = Path(__file__).resolve()
    for cand in (here.parent, *here.parents):
        if (cand / "tools" / "diag").is_dir() and (cand / "diagrams").is_dir():
            return cand
    print(f"note: no repo root above {here}; scanning {here.parent} instead")
    return here.parent


ROOT = Path(_args[0]).resolve() if _args else _default_root()

# "1 250 clocks = 20.8 us", "60 004 clocks = 1 000.07 us", "69 clocks = 1.15 µs",
# "a 69-clock (1.15 µs) step", "511 clocks, i.e. 8.52 us", "625 clocks - 10.42 us".
#
# The unit may be the ASCII "us" or U+00B5 MICRO SIGN: the wiki pages use the
# sign and the diagrams use the ASCII, and the first version of this file
# searched only the ASCII -- so a "10.3 µs" in a page would have passed it. A
# gate that is blind to half the documents it claims to cover is worse than no
# gate, because the blind half is the half a reader is most likely to trust.
#
# The CONNECTIVE is the part that bit twice. v1 required "=" / "is" / "of", which
# covers the diagrams and misses the pages, because a page writes the same fact as
# an appositive: "a 69-clock (1.15 µs) step". So D3 sat live in
# protocol-ds18b20.md with the gate green, on the same class of error the gate
# exists for. The connective is now optional and a parenthetical is allowed, and
# the negative control below uses the APPOSITIVE form specifically -- the shape
# that got through.
#
# Thousands separators inside the count are spaces ("60 004"), commas, or NBSP.
#
# The leading lookbehinds are not decoration. Without the first the pattern
# matched "95 clocks" inside "788.95 clocks", recomputed 95/60 = 1.58 us and
# reported the NEC figure's own correct "788.95 clocks = 13.149 us" as an 11.6 us
# error; without the second it read "75 clocks" out of "24 x 75 clocks = 30.000
# us", which is 1800 clocks and not 75. A gate that reports false findings gets
# its tolerance loosened by the next reader, and then it reports nothing.
CONV = re.compile(
    r"(?<![\d.,])(?<!x )(?<!× )"  # never mid-number, never out of "24 x 75"
    r"([\d][\d , ]*)\s*(?:clocks?|-clock)"
    r"\s*(?:=|is|of|:|,?\s*i\.e\.,?|-|–)?\s*\(?"
    # the VALUE may carry a space thousands separator too ("1 000.07 us")
    r"\s*([\d][\d ]*(?:\.[\d]+)?)\s*(?:us|µs)\b"
)


def step(n2: int, n3: int) -> int:
    """clocks the total gains per pass of the outer loop"""
    return 10 + (n2 - 1) * (4 * n3 + 7)


def total(n1: int, n2: int, n3: int) -> int:
    return (n1 - 1) * step(n2, n3) + 4


def us(clocks: int) -> float:
    return clocks * 1e6 / CLK_HZ


def _tolerance_as_printed(value: str) -> float:
    """half a unit in the last printed decimal place, plus float slack.

    "8.5" is a fair statement of 8.5167; "1.22" is not a fair statement of
    1.15. Rounding the truth to the printed precision captures exactly that
    difference, which a fixed tolerance does not: a 0.1 us error is fine in one
    place and a defect in another.
    """
    decimals = len(value.split(".")[1]) if "." in value else 0
    return 0.5 * 10**-decimals * 1.0001


SIC = "[sic]"


def audit_conversions(path: Path) -> list[str]:
    """every 'N clocks = X us' in one file, recomputed. Returns the failures.

    A conversion that will not PARSE is reported as a failure rather than
    raised. A gate that dies on a malformed number reports nothing about
    anything, and a reader who sees a traceback reads it as "the checker is
    broken" rather than "the figure is wrong" -- which is the one conclusion
    that must not be available.

    A line marked [sic] is EXEMPT, and the exemption is deliberately narrow and
    deliberately visible in the source. It exists for exactly one case: a
    verbatim quotation of a message that is ITSELF wrong.
    tb_pe_soc_sr04.v's failing check prints "600 clocks = 10000.000 us", which
    is 1000x out -- 600 clocks at 60 MHz is 10.000 us -- and a page that quotes
    that message has to show it verbatim or it is misquoting the thing it is
    reporting on.

    An exemption is where a gate stops being believed, so it is not left on
    trust: the self-test plants a wrong conversion, shows the gate failing,
    adds the marker, shows the gate passing, and removes it again. If the marker
    ever stops being what does the work, the self-test fails.

    THE MARKER IS SELF-LIMITING, and that is the part this function used to be
    missing. A [sic] used to skip its line FOREVER, which meant the moment the
    defect it marked got fixed -- which is the entire expected life story of a
    documented defect -- the marker started switching off a REAL CHECK on a line
    that had become correct. Nothing noticed. That is the same shape as the wiki
    baseline's STALE direction: a pin that stops failing must come out, and
    I built that direction into somebody else's gate and not into my own.

    So a marked line is still recomputed, and the marker's standing depends on the
    answer:
      * the conversion is WRONG  -> the marker is earning its place, suppress it
      * the conversion is RIGHT  -> the marker is STALE, that IS the finding
      * there is no conversion   -> the marker suppresses nothing, that is noise
    The exemption can therefore only ever suppress a genuinely-wrong claim, never
    a right one, and a marker cannot outlive its defect.
    """
    failures = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        marked = SIC in line
        found = list(CONV.finditer(line))
        if marked and not found:
            failures.append(
                f"{path.name}:{lineno}: {SIC} marks a line with no conversion to exempt, "
                "so it suppresses nothing - remove it"
            )
            continue
        for m in found:
            raw = m.group(1)
            printed = m.group(2)
            try:
                clocks = int(raw.replace(" ", "").replace(",", "").replace("\u00a0", ""))
                # float() rejects an internal space but accepts PEP 515
                # underscores, so "1 000.07" normalises to "1_000.07". The
                # value group has to allow a space for a thousands separator,
                # which is the whole reason this branch exists at all.
                claimed = float(printed.strip().replace("\u00a0", "_").replace(" ", "_"))
            except ValueError:
                # An unparseable conversion is never exempt: a marker cannot make
                # a claim the checker cannot read into a claim it can.
                failures.append(
                    f"{path.name}:{lineno}: unparseable conversion "
                    f"{raw!r} clocks = {printed!r}"
                )
                continue
            got = us(clocks)
            wrong = abs(got - claimed) > _tolerance_as_printed(printed)
            if marked:
                if not wrong:
                    failures.append(
                        f"{path.name}:{lineno}: STALE {SIC} - the conversion it marks is "
                        f"CORRECT ({clocks} clocks = {got:.4f} us, printed {claimed} us), "
                        "so the marker is switching off a real check. Remove it."
                    )
                continue
            if wrong:
                failures.append(
                    f"{path.name}:{lineno}: {clocks} clocks = {got:.4f} us, "
                    f"printed {claimed} us  (off by {claimed - got:+.4f})"
                )
    return failures


# (file the figure names, label, n1, n2, n3)
ENTRIES = [
    # servo_sweep.pe -- pulse table on (2,152), gap table on (11,123)
    ("proto-servo.puml", "servo pulse 0", 97, 2, 152),
    ("proto-servo.puml", "servo pulse 1", 145, 2, 152),
    ("proto-servo.puml", "servo pulse 2", 169, 2, 152),
    ("proto-servo.puml", "servo pulse 3", 121, 2, 152),
    ("proto-servo.puml", "servo pulse 4", 193, 2, 152),
    ("proto-servo.puml", "servo gap 0", 229, 11, 123),
    ("proto-servo.puml", "servo gap 1", 223, 11, 123),
    ("proto-servo.puml", "servo short gap", 31, 11, 123),
    # dht11_read.pe -- the long pair (6,255) for the 18 ms start,
    # the fine pair (2,6) for the 30 us, 45 us and 170 us delays
    ("proto-dht11.puml", "dht11 18 ms start", 212, 6, 255),
    ("proto-dht11.puml", "dht11 host window 30 us", 45, 2, 6),
    ("proto-dht11.puml", "dht11 sample 45 us", 67, 2, 6),
    ("proto-dht11.puml", "dht11 coarse 170 us", 250, 2, 6),
    # ds18b20.pe -- OW_RST on the coarse pair (4,40), the slots on (2,13)
    ("proto-ds18b20.puml", "ds18b20 reset 480 us", 58, 4, 40),
    ("proto-ds18b20.puml", "ds18b20 settle 15 us", 14, 2, 13),
    ("proto-ds18b20.puml", "ds18b20 write-1 low 5 us", 5, 2, 13),
    ("proto-ds18b20.puml", "ds18b20 write-0 low 65 us", 57, 2, 13),
    ("proto-ds18b20.puml", "ds18b20 sample 40 us", 23, 2, 13),
    ("proto-ds18b20.puml", "ds18b20 write-1 high 55 us", 49, 2, 13),
    # nec_ir.pe -- the two carrier half periods, fitted on (2,44) and (2,34).
    # The MEASURED value carries the phase ladder, which the formula does not
    # model, so the tolerance is 15 us rather than 1. This is stated rather than
    # tuned: the point of the entry is the STEP, which is exact.
    ("proto-nec-ir.puml", "nec carrier high half", 5, 2, 44),
    ("proto-nec-ir.puml", "nec carrier low half", 6, 2, 34),
]

# The measured values, so the derivation is checked against the WIRE and not only
# against itself. Source: the tb_pe_soc_* runs on real RTL, each quoted in the
# wiki page for that protocol. (measured_us, tolerance_us)
MEASURED_US = {
    "servo pulse 0": (1000.15, 1.0),
    "servo pulse 1": (1500.13, 1.0),
    "servo pulse 2": (1750.12, 1.0),
    "servo pulse 3": (1250.13, 1.0),
    "servo pulse 4": (2000.10, 1.0),
    "servo gap 0": (19000.07, 0.20),
    "servo gap 1": (18500.07, 0.20),
    "servo short gap": (2500.07, 0.20),
    "dht11 18 ms start": (18093.0, 30.0),
    "dht11 host window 30 us": (30.0, 1.0),
    "dht11 sample 45 us": (45.0, 5.0),
    "dht11 coarse 170 us": (170.0, 5.0),
    "ds18b20 reset 480 us": (485.7, 1.0),
    "ds18b20 settle 15 us": (15.0, 2.0),
    "ds18b20 write-1 low 5 us": (5.0, 0.5),
    "ds18b20 write-0 low 65 us": (64.8, 1.0),
    "ds18b20 sample 40 us": (25.4, 2.0),
    "ds18b20 write-1 high 55 us": (55.3, 1.0),
    "nec carrier high half": (13.149, 15.0),
    "nec carrier low half": (13.19, 15.0),
}

# The wrong claims the review pass caught, kept as negative controls.
# These are CLAIM shapes, not bare digits, and the distinction is not pedantry.
# The servo page legitimately prints "619" while explaining why 4*n3+11 is the
# wrong form of the outer step; a check that forbade the digit would forbid the
# correction. A check that forbade only the correct form would be the same error
# one level down: a gate element that reports success without asserting
# anything. So: forbid the wrong DERIVATION, permit the wrong NUMBER in prose
# that is explaining the trap.
FORBIDDEN = [
    ("(4*152 + 11) = 619", "the pulse outer step, quoted as a derivation"),
    ("(4*152+11) = 619", "the pulse outer step, quoted as a derivation"),
    ("4 655 clocks", "no (n2,n3) pair produces this step"),
    ("10 + 10*499) = 4 655", "the gap outer step, quoted as a derivation"),
    ("10.3 us", "the pulse step is 625 clocks = 10.4167 us"),
    ("77.6 us", "the gap step is 5000 clocks = 83.3333 us"),
    ("29 172", "the OW_RST total is 29 131 clocks"),
    ("29,172", "the OW_RST total is 29,131 clocks"),
]

TARGETS = [
    "diagrams/proto-ws2812.puml",
    "diagrams/proto-ws2812-frame.puml",
    "diagrams/proto-ws2812-timing.puml",
    "diagrams/proto-servo.puml",
    "diagrams/proto-servo-frame.puml",
    "diagrams/proto-servo-timing.puml",
    "diagrams/proto-dht11.puml",
    "diagrams/proto-dht11-frame.puml",
    "diagrams/proto-dht11-timing.puml",
    "diagrams/proto-ds18b20.puml",
    "diagrams/proto-ds18b20-frame.puml",
    "diagrams/proto-ds18b20-timing.puml",
    "diagrams/proto-nec-ir.puml",
    "diagrams/proto-nec-ir-frame.puml",
    "diagrams/proto-nec-ir-timing.puml",
    "diagrams/proto-freqmeter.puml",
    "diagrams/proto-freqmeter-frame.puml",
    "diagrams/proto-freqmeter-timing.puml",
    "diagrams/proto-sr04.puml",
    "diagrams/proto-sr04-frame.puml",
    "diagrams/proto-sr04-timing.puml",
    "diagrams/proto-fm-biphase.puml",
    "diagrams/proto-fm-biphase-frame.puml",
    "diagrams/proto-fm-biphase-timing.puml",
    "wiki/concepts/protocol-ws2812.md",
    "wiki/concepts/protocol-servo.md",
    "wiki/concepts/protocol-dht11.md",
    "wiki/concepts/protocol-ds18b20.md",
    "wiki/concepts/protocol-nec-ir.md",
    "wiki/concepts/protocol-freqmeter.md",
    "wiki/concepts/protocol-sr04.md",
    "wiki/concepts/protocol-fm-biphase.md",
]

# The files that must EXIST for the scan to mean anything. A missing file is a
# failure, not a skip: a checker that silently ignores a renamed figure is a
# checker that stops checking without saying so.
REQUIRED = TARGETS

# THE COVERAGE LIST ITSELF IS A HAND-MAINTAINED LIST, and that is the last
# drift hole in this file. The list above is complete today - verified, 24/24
# figures and 8/8 pages - but nothing ENFORCES that. Add one figure or one page
# tomorrow and the gate silently stops checking it: the file is simply absent
# from the list, so there is no failure to observe and nothing to notice.
#
# That is regress/check_mutation_lists.sh's exact failure mode - a MISSING ENTRY
# made a gate SKIP work it was supposed to do - and it is the same shape as the
# four number errors this file exists for. A coverage list that can drift is a
# coverage claim that is not checked.
#
# So the list is asserted against the filesystem, in both directions:
#   * a listed file that does not exist      -> a checker that reads nothing
#   * a file on disk that is NOT listed      -> a checker that quietly covers less
# The second is the one that had no defence at all, and it is the one that would
# have bitten: a new figure is the normal way this branch grows.
COVERAGE_GLOBS = ("diagrams/proto-*.puml", "wiki/concepts/protocol-*.md")
# proto-<x>.* where <x> is one of the seven protocols this branch owns. The
# explicit set matters: a sibling worker owns diagrams/proto-bus-* and
# diagrams/proto-proto-*, and those files are NOT mine and NOT this gate's. A
# glob that swept them in would make the gate fail on a sibling's figure, which
# is a worse failure than not checking it.
OWNED_PROTOCOLS = (
    "ws2812",
    "servo",
    "dht11",
    "ds18b20",
    "nec-ir",
    "freqmeter",
    "sr04",
    "fm-biphase",
)

# The pages whose `updated:` this gate also checks. Every protocol in the list
# above has one page, so this is derived rather than hand-maintained -- a second
# hand-maintained list in the same file is a second thing that can drift.
OWNED_PAGES = tuple(f"wiki/concepts/protocol-{p}.md" for p in OWNED_PROTOCOLS)

# Links a page may use as a BARE name with no directory, because they sit at the
# wiki root. The corpus already uses this form - [[STATUS]] appears 21 times -
# so a resolver that only understood wiki-relative targets would call every one
# of them dead.
SHORT_NAMES = ("STATUS", "SCHEMA", "index", "log")


def _declared_updated(path: Path) -> str | None:
    """the page's `updated:` field, or None if it has no readable one"""
    for line in path.read_text().splitlines()[:20]:
        if line.startswith("updated:"):
            return line.split(":", 1)[1].strip()
    return None


def _last_content_change(rel: str) -> str | None:
    """when git last touched this file, as YYYY-MM-DD, or None if unknowable.

    A checkout that is not a git working tree -- an exported tarball, or the
    self-test's throwaway fixture -- has no history, and the honest answer there
    is "cannot determine", not "passes". The caller reports that state loudly
    instead of counting it as a check, because not stamping is a decision and a
    reader should be able to see which pages were not stamped.

    DELAY_LATTICE_UPDATED is a test seam, and the only reason one exists here: the
    self-test's fixture has no git history, so without a seam the comparison could
    not be exercised end to end at all.
    """
    seam = os.environ.get("DELAY_LATTICE_UPDATED", "")
    if seam:
        name, _, when = seam.rpartition("+")
        if name == rel:
            return when
    try:
        out = subprocess.run(
            [
                "git",
                "-C",
                str(ROOT),
                "log",
                "-1",
                "--format=%ad",
                "--date=short",
                "--",
                rel,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    when = out.stdout.strip()
    return when if out.returncode == 0 and when else None


WIKI_DIRS = (
    "concepts",
    "plans",
    "reference",
    "decisions",
    "entities",
    "comparisons",
    "queries",
)


def resolve_link(target: str) -> str | None:
    """resolve a wikilink target to a file, or None if it is dead.

    THE CORPUS USES TWO CONVENTIONS and a resolver that knows only one invents
    dead links: index.md and most pages write `[[concepts/ethernet-scope]]`
    (wiki-relative), while a set of concept pages write `[[physical-layer-gpio]]`
    (bare name). The first version of this check tried only the wiki-relative
    form and reported 32 dead links across the eight pages - every one of them a
    false alarm caused by the checker, which is worse than no checker because
    it invites "fixing" links that are fine.
    """
    t = target.strip()
    if not t:
        return None
    if (ROOT / "wiki" / (t + ".md")).exists():
        return f"wiki/{t}.md"
    for d in WIKI_DIRS:
        if (ROOT / "wiki" / d / (t + ".md")).exists():
            return f"wiki/{d}/{t}.md"
    return None


def check_file_paths() -> int:
    """every backticked REPO path in my pages must exist in this tree.

    The sibling of the outbound-link check, and it exists because a page in this
    set shipped two paths that resolve to nothing: the FM0/FM1 page named
    firmware/bmc_frame.pe and tb/tb_pe_soc_bmc.v as plainly as any other, and
    both live only on fw-timing-protocols. The page was HONEST about it - the
    next line said so - but a reader who scans the first mention gets a path
    that does not open, on a page whose entire subject is being honest about
    status. So the paths are now written branch-qualified, and this check is
    what keeps them that way.

    A path that names another branch explicitly (`branch:path`) is exempt: that
    is the qualified form, and the exemption is a property of the TEXT rather
    than a list of known-absent files, so a path that moves to another branch
    later does not need this file edited.

    A BARE FILENAME is a name, not a path, and is resolved by looking it up
    ANYWHERE in the tree. The first version of this check required every match to
    exist at the repo root, so `i2c_pins.pe` and `tb_pe_soc_sr04.v` - both of
    which exist, in firmware/ and tb/ - were reported missing, the clean fixture
    went red, and the two findings were the check's fault. A checker that invents
    failures is the same defect as one that invents dead links, and the second
    time this branch has walked into it for the same reason.
    """
    import re

    path_re = re.compile(
        r"`([A-Za-z0-9_][A-Za-z0-9_./-]*"
        r"\.(?:md|puml|svg|png|pe|hex|v|sh|py|txt|json|yaml))`"
    )
    # every file in the tree, by basename, so a bare name can be resolved
    by_name: set[str] = set()
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", ".pi-lens-probe-home")]
        by_name.update(filenames)
    failures = 0
    total = 0
    for rel in OWNED_PAGES:
        page = ROOT / rel
        if not page.exists():
            continue
        for lineno, line in enumerate(page.read_text().splitlines(), 1):
            for m in path_re.finditer(line):
                target = m.group(1)
                total += 1
                if ":" in target:
                    continue          # branch-qualified: exempt by construction
                if "/" in target:
                    ok = (ROOT / target).exists()
                else:
                    ok = target in by_name
                if not ok:
                    print(f"FAIL  {rel}:{lineno}: `{target}` is not in this tree - "
                          "qualify it with its branch, or fix the path")
                    failures += 1
    print(f"ok    {total} repo path(s) across {len(OWNED_PAGES)} page(s) resolve")
    return failures


def check_updated_dates() -> int:
    """assert each page's `updated:` is not older than its last content change.

    wiki/SCHEMA.md says "When updating a page, always bump the `updated` date",
    and check_wiki_pages.sh enforces four of the five SCHEMA rules. This is the
    fifth, and it is the one about a page being HONEST about when it was last
    checked -- which is the same species as every other gap this gate has closed:
    a rule that is stated and not enforced is a rule that is a convention.
    """
    import re

    stamped = unknown = 0
    failures = 0
    isodate = re.compile(r"^\d{4}-\d{2}-\d{2}$")
    for rel in OWNED_PAGES:
        path = ROOT / rel
        if not path.exists():
            print(f"FAIL  {rel}: absent, so its `updated` cannot be checked")
            failures += 1
            continue
        declared = _declared_updated(path)
        if declared is None:
            print(
                f"FAIL  {rel}: no `updated:` field, so the page cannot say when "
                "it was last checked"
            )
            failures += 1
            continue
        if not isodate.match(declared):
            print(f"FAIL  {rel}: `updated: {declared}` is not YYYY-MM-DD")
            failures += 1
            continue
        changed = _last_content_change(rel)
        if changed is None:
            unknown += 1
            print(
                f"note  {rel}: declared {declared}, last content change UNKNOWN "
                "(not a git working tree) - not counted as a check"
            )
            continue
        if declared < changed:
            print(
                f"FAIL  {rel}: `updated: {declared}` but the content last changed "
                f"{changed}. Bump the date or revert the change."
            )
            failures += 1
        else:
            stamped += 1
    print(
        f"ok    `updated` verified against git for {stamped} page(s)"
        + (f"; {unknown} not determinable and NOT counted" if unknown else "")
    )
    return failures


def check_outbound_links() -> int:
    """every [[wikilink]] in my pages must resolve to a file that exists.

    check_wiki_pages.sh counts DISTINCT outbound wikilinks and fails below two -
    which is the rule, and it is a good one. It does NOT check that the targets
    exist, so a page satisfies it with two links to pages that were never
    written, or that have since been renamed. A count is not a check.

    That is the same shape as every other gap this gate has closed, and the
    interesting part is that the wiki gate could not have caught it: its rule is
    "at least two", and a link to nothing is still a link.

    Only the eight pages this branch owns are checked; the corpus-wide version
    belongs to whoever owns regress/.
    """
    import re

    link = re.compile(r"\[\[([^\]|#]+)(?:\|[^\]]*)?\]\]")
    failures = 0
    total = 0
    for rel in OWNED_PAGES:
        path = ROOT / rel
        if not path.exists():
            continue
        # BODY only, matching the wiki gate's own rule: a link inside
        # `sources:` is a citation, not an outbound link, and must not be
        # counted as one here either - or a page could pass this by listing
        # itself in its own frontmatter.
        body, in_fm = [], True
        for i, line in enumerate(path.read_text().splitlines()):
            if i == 0 and line == "---":
                in_fm = True
                continue
            if in_fm and line == "---":
                in_fm = False
                continue
            if not in_fm:
                body.append((i + 1, line))
        for lineno, line in body:
            for m in link.finditer(line):
                target = m.group(1).strip()
                if target in SHORT_NAMES:
                    continue
                total += 1
                if resolve_link(target) is None:
                    print(f"FAIL  {rel}:{lineno}: [[{target}]] resolves to nothing")
                    failures += 1
    print(
        f"ok    {total} outbound link(s) across {len(OWNED_PAGES)} page(s) resolve"
        if not failures
        else ""
    )
    return failures
    """assert each page's `updated:` is not older than its last content change.

    wiki/SCHEMA.md says "When updating a page, always bump the `updated` date",
    and check_wiki_pages.sh enforces four of the five SCHEMA rules. This is the
    fifth, and it is the one about a page being HONEST about when it was last
    checked -- which is the same species as every other gap this gate has closed:
    a rule that is stated and not enforced is a rule that is a convention.
    """
    import re

    stamped = unknown = 0
    failures = 0
    isodate = re.compile(r"^\d{4}-\d{2}-\d{2}$")
    for rel in OWNED_PAGES:
        path = ROOT / rel
        if not path.exists():
            print(f"FAIL  {rel}: absent, so its `updated` cannot be checked")
            failures += 1
            continue
        declared = _declared_updated(path)
        if declared is None:
            print(
                f"FAIL  {rel}: no `updated:` field, so the page cannot say when "
                "it was last checked"
            )
            failures += 1
            continue
        if not isodate.match(declared):
            print(f"FAIL  {rel}: `updated: {declared}` is not YYYY-MM-DD")
            failures += 1
            continue
        changed = _last_content_change(rel)
        if changed is None:
            unknown += 1
            print(
                f"note  {rel}: declared {declared}, last content change UNKNOWN "
                "(not a git working tree) - not counted as a check"
            )
            continue
        if declared < changed:
            print(
                f"FAIL  {rel}: `updated: {declared}` but the content last changed "
                f"{changed}. Bump the date or revert the change."
            )
            failures += 1
        else:
            stamped += 1
    print(
        f"ok    `updated` verified against git for {stamped} page(s)"
        + (f"; {unknown} not determinable and NOT counted" if unknown else "")
    )
    return failures


def _owner_of(base: str) -> str | None:
    """which protocol owns a stem, or None if it is not ours.

    A PREFIX test, longest name first, and NOT base.split("-")[0]. Two of the
    seven protocol names contain a hyphen -- "fm-biphase" and "nec-ir" -- so a
    first-token test silently drops them, and it drops them SILENTLY: the gate
    reports a smaller count and the coverage check reads as having passed. That
    is the under-counting failure written into a comment two functions above,
    then reproduced by the code beside it.
    """
    for name in sorted(OWNED_PROTOCOLS, key=len, reverse=True):
        if base == name or base.startswith(name + "-"):
            return name
    return None


def discover() -> tuple[set[str], set[str]]:
    """(files on disk this branch owns, files the list claims)"""
    found: set[str] = set()
    for pat in COVERAGE_GLOBS:
        parent, _, star = pat.rpartition("/")
        # Split the pattern at the WILDCARD, not at the first dash:
        # "proto-*.puml" -> head "proto-", tail ".puml".  Splitting at the
        # first dash instead makes the head "proto" and the tail "*.puml",
        # which silently finds fewer files and reports the rest as absent.
        head, _, tail = star.partition("*")
        for f in sorted((ROOT / parent).glob(star)):
            if not f.name.startswith(head) or not f.name.endswith(tail):
                continue
            base = f.name[len(head) : len(f.name) - len(tail)]
            if _owner_of(base) is not None:
                found.add(f.relative_to(ROOT).as_posix())
    return found, set(REQUIRED)


def check_coverage() -> int:
    """assert the hand list and the filesystem agree. Returns a failure count."""
    on_disk, listed = discover()
    missing = sorted(on_disk - listed)
    phantom = sorted(listed - on_disk)
    if missing:
        print(f"FAIL  {len(missing)} owned file(s) on disk are NOT in the coverage list,")
        print("      so this gate is quietly checking less than it appears to:")
        for p in missing:
            print(f"      + {p}")
        print("      Add each one to TARGETS above. A missing entry here is the")
        print("      same defect as a missing MUTABLE line in a mutation harness.")
    else:
        print(f"ok    every one of the {len(on_disk)} owned file(s) on disk is listed")
    if phantom:
        print(f"FAIL  {len(phantom)} listed file(s) are not on disk,")
        print("      so the scan would prove nothing about them:")
        for p in phantom:
            print(f"      - {p}")
    else:
        print(f"ok    all {len(listed)} listed file(s) exist")
    return len(missing) + len(phantom)


def selftest() -> int:
    """Prove the GATE fails, end to end, by running it as a subprocess.

    WHY THIS IS SEPARATE FROM THE IN-PROCESS CONTROLS IN main(). Those prove
    that audit_conversions() and the FORBIDDEN scan notice a planted error. They
    do NOT prove that the GATE exits non-zero when it notices -- a bug in main()
    that discarded the returned list, or forgot to fold `fail` into the exit
    code, would pass every in-process control in this file and report PASS over
    a wrong figure. The only thing that tests the exit code is the exit code,
    observed from outside this process.

    And it has to be non-vacuous in the other direction: a run that returns 1
    "correctly" because the fixture is broken anyway would satisfy a naive
    assertion. So the clean fixture must PASS first, and the planted fixture
    must then fail, and the un-planted one must pass again. A gate only ever
    seen green is a gate nobody has tested; a gate seen failing on demand is a
    gate that has been.
    """
    if not all((ROOT / p).exists() for p in REQUIRED):
        print("SELFTEST: cannot run, required files are absent")
        return 1

    with tempfile.TemporaryDirectory() as td:
        # A fixture that is a real copy, not a toy: a toy would not contain the
        # very lines the gate is supposed to be reading.
        #
        # The WHOLE wiki/ tree is copied, not just REQUIRED, and that is not
        # tidiness. My pages link to concepts/i2c-on-the-matrix, concepts/
        # pin-matrix and five others, and the outbound-link check resolves a
        # target by looking for the file. Copying only the 8 pages under test
        # therefore made every one of those links unresolvable and the CLEAN
        # FIXTURE FAILED - which looked like a broken gate and was a broken
        # fixture. A control that starts red teaches you nothing, and the fix
        # is to make the fixture faithful rather than to relax the check.
        fixture = Path(td) / "repo"
        # Every TEXT file in the tree, not just wiki/ and not just the pages
        # under test. The pages under test name firmware/*.pe, tb/*.v, rtl/*.v
        # and tools/*, and the path check resolves a bare filename by looking
        # it up ANYWHERE - so a fixture holding only wiki/ makes every one of
        # those unresolvable and the CLEAN FIXTURE FAILS. Twice now this has
        # looked like a broken gate and been a broken fixture, and the second
        # time the honest answer was again to fix the fixture rather than
        # relax the check.
        #
        # Renders and wave dumps are skipped: they are large, binary, and no
        # check in this file reads their contents - the RENDER gate does, and
        # that is checked against the real tree, not a fixture.
        skip_dirs = {".git", "node_modules", ".pi-lens-probe-home", "sim", "logs"}
        skip_suffix = (".png", ".svg", ".vcd", ".pyc")
        for src in ROOT.rglob("*"):
            if not src.is_file():
                continue
            if any(part in skip_dirs for part in src.relative_to(ROOT).parts):
                continue
            if src.suffix in skip_suffix:
                continue
            dst = fixture / src.relative_to(ROOT)
            dst.parent.mkdir(parents=True, exist_ok=True)
            try:
                dst.write_text(src.read_text())
            except UnicodeDecodeError:
                # A file that is not valid UTF-8 is a binary - a firmware .hex,
                # a VCD - and nothing in this gate reads its CONTENTS. What the
                # checks need is that it EXISTS, so it is written as an empty
                # placeholder: skipping it would make a bare filename that
                # genuinely exists in the tree look dead, which is the same
                # invented-failure defect as the bare-name bug above.
                dst.write_bytes(b"")

        def run_gate() -> tuple[int, str]:
            proc = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), str(fixture)],
                capture_output=True,
                text=True,
                check=False,
            )
            return proc.returncode, proc.stdout

        def require(label: str, want_fail: bool) -> bool:
            rc, out = run_gate()
            if want_fail and rc == 0:
                print(f"FAIL  {label}: the gate returned 0 and should have failed")
                print(
                    "      "
                    + "\n      ".join(
                        l for l in out.splitlines() if l.startswith("FAIL")
                    )[:400]
                )
                return False
            if not want_fail and rc != 0:
                print(f"FAIL  {label}: the gate returned {rc} and should have passed")
                return False
            print(f"ok    {label}: gate exit {rc}")
            return True

        print("== end-to-end self-test: plant a real error, demand the gate fail ==")
        good = True
        # (0) the clean fixture must PASS, or everything after is meaningless
        if not require("clean fixture", want_fail=False):
            return 1

        # (1) the conversion audit's own class: a wrong conversion, in the
        #     appositive form and the micro sign, which is the shape D3 took
        #     when it sat live in a wiki page with this gate green
        target = fixture / TARGETS[-1]
        original = target.read_text()
        target.write_text(original + "\na 69-clock (1.22 \u00b5s) step\n")
        good &= require("planted wrong conversion (69 clocks = 1.22 us)", want_fail=True)
        target.write_text(original)

        # (2) the FORBIDDEN scan's class: a caught number re-inserted
        target.write_text(original + f"\none outer step is ({FORBIDDEN[0][0]})\n")
        good &= require(f"planted {FORBIDDEN[0][0]!r}", want_fail=True)
        target.write_text(original)

        # (3) a lattice entry that disagrees with the MEASURED wire value: the
        #     check the script exists for, exercised end to end rather than
        #     only in the table it prints. It is planted through the environment
        #     rather than by mutating this process's MEASURED_US, because the
        #     gate runs as a SUBPROCESS and would never see an in-process edit --
        #     a self-test that passed vacuously for that reason would be worse
        #     than none.
        env = dict(os.environ, DELAY_LATTICE_MEASURED=f"{ENTRIES[0][1]}+500")
        proc = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), str(fixture)],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        if proc.returncode == 0:
            good = False
            print(
                "FAIL  planted a wrong MEASURED_US: the gate returned 0 and "
                "should have failed"
            )
        else:
            print(
                f"ok    planted a wrong MEASURED_US for {ENTRIES[0][1]!r}: "
                f"gate exit {proc.returncode}"
            )
        target.write_text(original)

        # (4) THE EXEMPTION MUST BE THE ONLY THING THAT SUPPRESSES A FINDING.
        #     Without this, [sic] could stop working at any time and the gate
        #     would simply stop catching that class - which is how a gate rots.
        target.write_text(original + "\n69 clocks = 1.22 \u00b5s\n")
        good &= require("planted wrong conversion, no marker", want_fail=True)
        target.write_text(original + f"\n69 clocks = 1.22 \u00b5s  {SIC}\n")
        good &= require(f"same conversion marked {SIC!r}", want_fail=False)
        target.write_text(original)

        # (5) THE MARKER MUST NOT BE ABLE TO SURVIVE ITS DEFECT. This is the
        #     other half of (4) and the half that used to be missing: a marker
        #     on a conversion that is now CORRECT is a marker switching off a
        #     real check, and the whole expected life of a documented defect is
        #     that it gets fixed - at which point an unexamined exemption turns
        #     itself off. So this must FAIL, in the gate's own exit code.
        target.write_text(original + f"\n69 clocks = 1.15 \u00b5s  {SIC}\n")
        good &= require(
            f"STALE marker: a CORRECT conversion marked {SIC!r}", want_fail=True
        )
        # and a marker on a line with no conversion at all suppresses nothing
        target.write_text(original + f"\nthis line carries a {SIC} and no conversion\n")
        good &= require("marker with no conversion to exempt", want_fail=True)
        target.write_text(original)

        # (6) and the gate must be green again once every planted error is gone
        if not require("all planted errors removed", want_fail=False):
            return 1

        # (7) THE `updated` FIELD, which SCHEMA states and nothing enforced. The
        #     fixture is a copy of the FILES with no git history, so the clean
        #     run reports every page as UNKNOWN and counts none of them - which is
        #     the honest answer for a non-git checkout, and the reason the seam
        #     exists at all. The two controls below are what make this a check
        #     rather than a report: one plants a page whose content moved past the
        #     date it declares, and the gate must fail on it.
        env = dict(os.environ, DELAY_LATTICE_UPDATED=f"{OWNED_PAGES[0]}+2099-01-01")
        proc = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), str(fixture)],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        if proc.returncode == 0:
            good = False
            print("FAIL  a stale `updated` was planted and the gate returned 0")
        else:
            print(
                f"ok    stale `updated` (content 2099-01-01, page declares less): "
                f"gate exit {proc.returncode}"
            )

        # and the SAME page with a date that covers its change must pass, so the
        # control is not satisfied by a check that simply always fails
        env = dict(os.environ, DELAY_LATTICE_UPDATED=f"{OWNED_PAGES[0]}+2000-01-01")
        proc = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), str(fixture)],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        if proc.returncode != 0:
            good = False
            print(
                "FAIL  a covered `updated` was planted and the gate failed; "
                "the control is satisfied by always-red"
            )
        else:
            print(f"ok    `updated` covering its change: gate exit {proc.returncode}")

        # and a page whose `updated` is not a date at all is caught, because
        # "bump the date" is only checkable if the field is machine-readable
        target = fixture / OWNED_PAGES[0]
        keep = target.read_text()
        target.write_text(keep.replace("updated: ", "updated: not-a-date ", 1))
        good &= require("`updated` that is not YYYY-MM-DD", want_fail=True)
        target.write_text(keep)

        # (8) OUTBOUND LINKS MUST RESOLVE, which check_wiki_pages.sh does not
        #     do: its rule is "at least two links", and a link to a page that
        #     was never written still counts. Three controls, and the MIDDLE
        #     one is the one that matters, because it is exactly the bug this
        #     check was born with - a resolver that only understood the
        #     wiki-relative form reported all 32 of my links dead.
        page = fixture / OWNED_PAGES[0]
        keep = page.read_text()
        page.write_text(keep + "\nA link to nothing: [[concepts/does-not-exist]]\n")
        good &= require("planted a DEAD outbound link", want_fail=True)
        page.write_text(keep + "\nA link that resolves: [[concepts/pin-matrix]]\n")
        good &= require("planted a RESOLVING link (wiki-relative form)", want_fail=False)
        page.write_text(keep + "\nA link that resolves: [[pin-matrix]]\n")
        good &= require(
            "planted a RESOLVING link (BARE form - the convention "
            "a first-token resolver calls dead)",
            want_fail=False,
        )
        # body-only, matching the wiki gate's own rule: a dead link inside
        # `sources:` is a citation, not an outbound link, and must not fail here
        page.write_text(keep.replace("sources: [", "sources: [[concepts/ghost]], [", 1))
        good &= require(
            "dead link in `sources:` is NOT an outbound link", want_fail=False
        )
        page.write_text(keep)

        page = fixture / OWNED_PAGES[0]
        keep = page.read_text()
        page.write_text(keep + "\nA path to nothing: `firmware/no_such_file.pe`\n")
        good &= require("planted a MISSING repo path", want_fail=True)
        page.write_text(keep + "\nA cross-branch path: `other-branch:firmware/x.pe`\n")
        good &= require("branch-qualified path is exempt", want_fail=False)
        page.write_text(keep + "\nA real path: `firmware/ws2812.pe`\n")
        good &= require("planted a RESOLVING repo path", want_fail=False)
        # a BARE FILENAME is a name, not a path: it must resolve if the file
        # exists ANYWHERE, which is the false positive the first version had
        page.write_text(keep + "\nA bare name that exists in firmware/: `i2c_pins.pe`\n")
        good &= require("bare filename resolved by basename, not at the root",
                        want_fail=False)
        page.write_text(keep + "\nA bare name that exists nowhere: `no_such_file.v`\n")
        good &= require("bare filename that exists nowhere", want_fail=True)
        page.write_text(keep)

        if not require("final green re-check", want_fail=False):
            return 1

    if not good:
        print("SELFTEST: FAILED")
        return 1
    print("SELFTEST: PASS")
    return 0


def main() -> int:
    fail = 0

    print("== the derivation, and how it sits against the measured wire ==")
    # A test seam, and only for the self-test: override one entry's measured
    # value by LABEL+DELTA so a subprocess can be made to disagree with the
    # derivation. It is the one way a fixture can reach the table, because the
    # table lives in this file rather than in the tree being scanned.
    _plant = os.environ.get("DELAY_LATTICE_MEASURED", "")
    if _plant and "+" in _plant:
        _lbl, _delta = _plant.rsplit("+", 1)
        try:
            _delta_f = float(_delta)
        except ValueError:
            _delta_f = None
        if _lbl in MEASURED_US and _delta_f is not None:
            MEASURED_US[_lbl] = (MEASURED_US[_lbl][0] + _delta_f, MEASURED_US[_lbl][1])
    for _fig, label, n1, n2, n3 in ENTRIES:
        s, t = step(n2, n3), total(n1, n2, n3)
        line = (
            f"{label:<28} n1={n1:3d} ({n2:2d},{n3:3d})  step {s:6d} clk "
            f"= {us(s):9.4f} us   total {t:9d} clk = {us(t):10.4f} us"
        )
        if label in MEASURED_US:
            meas, tol = MEASURED_US[label]
            delta = us(t) - meas
            line += f"   measured {meas:10.2f} us  (delta {delta:+6.2f}, tol {tol:.2f})"
            if abs(delta) > tol:
                line += "  <-- OUT OF TOLERANCE"
                fail += 1
        print(line)

    print()
    print("== the numbers the review passes caught, asserted absent ==")
    present = [p for p in TARGETS if (ROOT / p).exists()]
    for bad, why in FORBIDDEN:
        hits = [p for p in present if bad in (ROOT / p).read_text()]
        if hits:
            fail += 1
            print(f"FAIL  {bad!r} still present in: {', '.join(hits)}")
            print(f"      {why}")
        else:
            print(f"ok    {bad!r} absent from all {len(present)} present files")

    print()
    # THE CLOCK->us AUDIT. This is the check that matters, and it is the one
    # that would have found D1, D2 and D3 without being told they exist: the
    # three were the same arithmetic, a clock count and its conversion printed
    # side by side with only one of them derived. It reads the figures AND the
    # pages, because a corrected figure beside a stale page is the worst
    # combination available -- the page is the one a reader quotes.
    print("== clock -> us audit, every conversion in every figure and page ==")
    audited, conversions = 0, 0
    for rel in present:
        before = len(CONV.findall((ROOT / rel).read_text()))
        conversions += before
        bad_lines = audit_conversions(ROOT / rel)
        audited += 1
        if bad_lines:
            fail += len(bad_lines)
            for b in bad_lines:
                print(f"FAIL  {b}")
    print(f"ok    {conversions} conversion(s) recomputed across {audited} files")

    print()
    print("== the coverage list, asserted against the filesystem ==")
    fail += check_coverage()

    print()
    print("== outbound links: every target must resolve to a file ==")
    fail += check_outbound_links()

    print()
    print("== repo paths named in my pages must exist in this tree ==")
    fail += check_file_paths()

    print()
    print("== the `updated` field, against git (SCHEMA's fifth rule) ==")
    fail += check_updated_dates()

    print()
    # The checker must be capable of failing, and that has three halves. Each
    # one exists because the absence of it is a way for this file to go green
    # while proving nothing.
    #
    # (a) every required file must exist. Otherwise the checks above pass
    #     without having read anything, and a typo in a path is enough. A green
    #     checker that reads nothing is worse than no checker, because it is
    #     believed.
    missing = [p for p in REQUIRED if not (ROOT / p).exists()]
    if missing:
        fail += 1
        print(f"FAIL  {len(missing)} required file(s) absent; the scan proves nothing:")
        for p in missing:
            print(f"      {p}")
    else:
        print(f"ok    all {len(REQUIRED)} required files present")

    # (b) a negative control on the FORBIDDEN scan: plant one of the caught
    #     numbers in a scratch copy and confirm it is reported.
    # (c) a negative control on the CONVERSION AUDIT, which is the check most
    #     likely to rot into a no-op -- an empty scan and a correct scan look
    #     identical in the output above, and only (c) tells them apart.
    with tempfile.TemporaryDirectory() as td:
        for p in present:
            (Path(td) / Path(p).name).write_text((ROOT / p).read_text())
        planted = FORBIDDEN[0][0]
        target = Path(td) / Path(present[0]).name
        target.write_text(target.read_text() + f"\none outer step is ({planted})\n")
        caught = [q.name for q in Path(td).iterdir() if planted in q.read_text()]
        if not caught:
            print("FAIL  the negative control did not trip; the FORBIDDEN scan is inert")
            return 1
        print(
            f"ok    negative control: a planted {planted!r} is caught in {caught[0]}, "
            "so the FORBIDDEN scan really reads the files"
        )

        # (c) plant a wrong CONVERSION in the APPOSITIVE form the first version
        #     of this file could not see, with the MICRO SIGN unit, and require
        #     the audit to report it. This is the control that matters: it is
        #     the exact shape D3 took when it sat live in a wiki page with this
        #     gate green - "a 69-clock (1.22 µs) step" - so a control using the
        #     "=" form would pass while the hole was still open.
        target.write_text(target.read_text() + "\na 69-clock (1.22 \u00b5s) step\n")
        conv_caught = audit_conversions(target)
        if not conv_caught:
            print("FAIL  the conversion audit did not trip; it is inert")
            return 1
        print(
            f"ok    negative control: a planted '69-clock (1.22 \u00b5s) step' is caught "
            f"({conv_caught[0].split(': ', 1)[1]}), so the audit reads the appositive "
            "form and both unit spellings"
        )

    print(
        f"{len(present)} files scanned, {len(ENTRIES)} lattice entries derived, "
        f"{conversions} conversions recomputed"
    )
    if fail:
        print(f"RESULT: FAILED ({fail} problem(s))")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv else main())
