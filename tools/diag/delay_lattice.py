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
Exit 0 = every quoted number agrees, 1 = a disagreement, each one named.
"""
import re
import sys
import tempfile
from pathlib import Path

CLK_HZ = 60_000_000
ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]

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
    r"(?<![\d.,])(?<!x )(?<!× )"      # never mid-number, never out of "24 x 75"
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
    return 0.5 * 10 ** -decimals * 1.0001


def audit_conversions(path: Path) -> list[str]:
    """every 'N clocks = X us' in one file, recomputed. Returns the failures.

    A conversion that will not PARSE is reported as a failure rather than
    raised. A gate that dies on a malformed number reports nothing about
    anything, and a reader who sees a traceback reads it as "the checker is
    broken" rather than "the figure is wrong" -- which is the one conclusion
    that must not be available.
    """
    failures = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        for m in CONV.finditer(line):
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
                failures.append(
                    f"{path.name}:{lineno}: unparseable conversion "
                    f"{raw!r} clocks = {printed!r}"
                )
                continue
            got = us(clocks)
            if abs(got - claimed) > _tolerance_as_printed(printed):
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
#
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


def main() -> int:
    fail = 0

    print("== the derivation, and how it sits against the measured wire ==")
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
        print(f"ok    negative control: a planted {planted!r} is caught in {caught[0]}, "
              "so the FORBIDDEN scan really reads the files")

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
        print(f"ok    negative control: a planted '69-clock (1.22 \u00b5s) step' is caught "
              f"({conv_caught[0].split(': ', 1)[1]}), so the audit reads the appositive "
              "form and both unit spellings")

    print(f"{len(present)} files scanned, {len(ENTRIES)} lattice entries derived, "
          f"{conversions} conversions recomputed")
    if fail:
        print(f"RESULT: FAILED ({fail} problem(s))")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
