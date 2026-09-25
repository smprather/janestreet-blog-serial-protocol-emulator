#!/usr/bin/env python3
"""analyze_hold.py — attribute the negative min slacks in a screen report.

Usage:
  analyze_hold.py REPORT.txt                 # class table for one report
  analyze_hold.py ZERO.txt BOARD.txt         # zero vs board comparison

The screens write a "NEGATIVE-MIN INVENTORY" block (report_checks -path_delay
min -slack_max 0 -format summary) and the two `worst slack` summary lines. The
inventory lines are classified with the rule set recorded in
reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md:

  external-input        startpoint is a direct input port (data or removal)
  external-output       endpoint is an output port
  internal-within-unc   internal flop/latch path whose negative slack is
                        entirely inside the applied 0.25 ns hold uncertainty
                        (slack + 0.25 >= 0) -> screening artifact
  internal-reg-reg      internal flop/latch path beyond the screening
                        uncertainty (pre-CTS; the routed flow's hold repair
                        closed these at +0.1209 ns, 0 violating paths)
"""

import re
import sys

# Summary rows are `startpoint (type)  endpoint (type)  slack`; when the
# instance names are long the column padding collapses, so split on the first
# `)` (the end of the startpoint's parenthesised type) and on the trailing
# float.
PAT = re.compile(r"^(.+?\))\s+(.+?)\s+(-?\d+\.\d+)\s*$")
PAT_LOOSE = re.compile(r"^(\S.*?)\s{2,}(\S.*?)\s{2,}(-?\d+\.\d+)\s*$")


def parse(path):
    """Return (worst_slack dict, inventory list of (start, end, slack))."""
    worst = {}
    inv = []
    in_inv = False
    with open(path, errors="replace") as fh:
        for line in fh:
            if line.startswith("worst slack"):
                k, v = line.rsplit(None, 1)
                worst[f"worst slack {k}"] = float(v)
            if "NEGATIVE-MIN INVENTORY" in line:
                in_inv = True
                continue
            if in_inv:
                m = PAT.match(line.rstrip()) or PAT_LOOSE.match(line.rstrip())
                if m:
                    inv.append((m.group(1), m.group(2), float(m.group(3))))
    return worst, inv


def classify(sp, ep, slack):
    if " (input)" in sp:
        if ep.endswith("/RESET_B (sg13g2_dfrbpq_1)"):
            return "external-input (rst_n removal)"
        return "external-input (data)"
    if "(output)" in ep:
        return "external-output"
    if slack + 0.25 >= -1e-9:
        return "internal-within-unc (screening)"
    return "internal-reg-reg (pre-CTS)"


def summarize(inv):
    """class -> (count, worst_slack, worst_start, worst_end)."""
    counts = {}
    worst = {}
    for sp, ep, sl in inv:
        c = classify(sp, ep, sl)
        counts[c] = counts.get(c, 0) + 1
        if c not in worst or sl < worst[c][0]:
            worst[c] = (sl, sp, ep)
    return {c: (counts[c], *worst[c]) for c in counts}


def table(path):
    worst, inv = parse(path)
    print(f"== {path}")
    for k in ("worst slack max", "worst slack min"):
        if k in worst:
            print(f"   {k}: {worst[k]:+.4f}")
    for c, (n, sl, sp, ep) in sorted(summarize(inv).items()):
        print(f"   {c}: {n} paths, worst {sl:+.4f}")
        print(f"      {sp}  =>  {ep}")
    return worst, inv


if __name__ == "__main__":
    table(sys.argv[1])
    if len(sys.argv) > 2:
        print()
        _, inv_zero = parse(sys.argv[1])
        _, inv_board = parse(sys.argv[2])
        s_zero, s_board = summarize(inv_zero), summarize(inv_board)
        print(f"== comparison: {sys.argv[1]}  vs  {sys.argv[2]}")
        for c in sorted(set(s_zero) | set(s_board)):
            nz = s_zero.get(c, [0])[0]
            nb = s_board.get(c, [0])[0]
            wz = f"{s_zero[c][1]:+.4f}" if c in s_zero else "-"
            wb = f"{s_board[c][1]:+.4f}" if c in s_board else "-"
            print(
                f"   {c:34s} zero: {nz:5d} paths worst {wz:>8s} | board: {nb:5d} paths worst {wb:>8s}"
            )
