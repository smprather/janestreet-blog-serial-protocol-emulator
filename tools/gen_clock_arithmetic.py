#!/usr/bin/env python3
"""Generate wiki/reference/clock-arithmetic.md — every constant at 60 MHz.

Answers one question: what does 60 MHz make exact, and what does it leave
approximate? This is a LOOKUP TABLE that is COMPUTED, not remembered.

WHY THIS PAGE IS GENERATED. The 40 -> 60 MHz switch left stale tick arithmetic
in comments across four files (173 vs 260) and left the I2C plan claiming a
40-clock microsecond long after it had become 60. Both errors were the same
shape: a derived constant written down by hand next to a clock rate that moved.
So the constants are derived here from CLK_HZ, and the page is drift-gated like
every other reference in this wiki.

CLK_HZ is read from rtl/pe_uart_soc.v itself. If the RTL's clock ever changes
and this page is not regenerated, --check fails. That is the point: the RTL
owns the number and this page follows it.

    python3 tools/gen_clock_arithmetic.py           # write the page
    python3 tools/gen_clock_arithmetic.py --check    # exit 1 if stale
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOC = REPO / "rtl" / "pe_uart_soc.v"
OUT = REPO / "wiki" / "reference" / "clock-arithmetic.md"


def read_clk_hz() -> int:
    """Read CLK_HZ from the RTL. The RTL is the source of truth."""
    src = SOC.read_text(encoding="utf-8")
    m = re.search(r"localparam\s+int\s+CLK_HZ\s*=\s*([0-9_]+)", src)
    if not m:
        raise SystemExit(
            f"gen_clock_arithmetic: no 'localparam int CLK_HZ = ...' in {SOC}. "
            "The RTL owns the operating point; this generator follows it."
        )
    return int(m.group(1).replace("_", ""))


def read_baud() -> int:
    """Read the UART BAUD default from the RTL parameter list."""
    src = SOC.read_text(encoding="utf-8")
    m = re.search(r"parameter\s+int\s+BAUD\s*=\s*([0-9_]+)", src)
    return int(m.group(1).replace("_", "")) if m else 115_200


# ---- the protocol constants ---------------------------------------------------
# (label, nanoseconds, is_a_hard_requirement, note)
#
# "hard" means a protocol whose timing MUST be an integer number of clocks for
# the design to be spec-legal (the competition's timing emphasis). Those are the
# rows that justify 60 MHz over every other candidate.
PROTOCOLS = [
    ("10BASE-T half-UI", 50.0, True,
     "The one that eliminates every alternative clock. 50 ns is exactly 3 ticks."),
    ("10BASE-T bit time", 100.0, True,
     "6 ticks. Also the DRU's sampling window: SPB = 12 on the dual-edge grid."),
    ("USB full-speed bit", 1e9 / 12e6, True,
     "83.33 ns = exactly 5 ticks."),
    ("USB low-speed bit", 1e9 / 1.5e6, True,
     "666.67 ns = exactly 40 ticks. At 40 MHz this was 26.67 and needed a dither."),
    ("I2C Standard-mode 1 us tick", 1000.0, True,
     "60 clocks. See plans/through-i2c.md for the 5/6 tick tLOW/tHIGH split."),
    ("I2C Fast-mode 0.5 us tick", 500.0, True,
     "30 clocks. Fast mode is a step-8 feasibility check, not built."),
    ("SPI SCK (10 MHz target)", 100.0, True,
     "6 ticks. SPI is push-pull firmware on the shared 8-bit port."),
    ("UART 115200 half-bit", 1e9 / 115_200 / 2, False,
     "NOT exact: 260.417 ticks. Integer division gives 260 (+0.160% baud error)."),
]

# Protocols the design must speak but which are NOT integer at any clock,
# recorded so the table is honest about what "exact for every hard protocol" means.
NOT_EXACT = [
    ("UART 115200", "+0.160% baud error",
     "The only protocol constant at 60 MHz that is an approximation. Inside the "
     "~2% UART budget, and half the error the 40 MHz point had (+0.353%)."),
]


def build() -> tuple[str, list[str]]:
    clk = read_clk_hz()
    baud = read_baud()
    period_ns = 1e9 / clk
    problems: list[str] = []

    def ticks(ns: float) -> float:
        return ns / period_ns

    L: list[str] = []
    L += [
        "---",
        'title: "Clock arithmetic at 60 MHz"',
        "created: 2026-09-22",
        "updated: 2026-09-22",
        "type: reference",
        "tags: [clocking, protocol, reference, verification]",
        "sources: [rtl/pe_uart_soc.v, wiki/decisions/adr-005-60mhz-turbo.md]",
        "confidence: high",
        "---",
        "",
        "# Clock arithmetic at 60 MHz",
        "",
        "> **Generated** by `tools/gen_clock_arithmetic.py` from `rtl/pe_uart_soc.v`.",
        "> `CLK_HZ` is read from the RTL, not restated here — if the RTL's clock",
        "> changes and this page is not regenerated, `--check` fails.",
        "",
        "The operating point is **locked at 60 MHz**. It is a `localparam` in",
        "`pe_uart_soc`, not a parameter: nothing ever instantiated the SoC at any",
        "other rate, so the parameter was a second place for the arithmetic to be",
        "wrong rather than a knob (see the header of `rtl/pe_uart_soc.v`).",
        "",
        f"    CLK_HZ   = {clk:,} Hz",
        f"    period   = {period_ns:.3f} ns",
        "",
        "## What 60 MHz makes exact",
        "",
        "| protocol constant | ns | ticks | exact? |",
        "|---|---|---|---|",
    ]

    for label, ns, hard, note in PROTOCOLS:
        t = ticks(ns)
        exact = abs(t - round(t)) < 1e-9
        mark = "**EXACT**" if exact else "approx"
        L.append(f"| {label} | {ns:.3f} | {t:.3f} | {mark} |")

    L += [
        "",
        "Every row marked EXACT is a protocol requirement that lands on an integer",
        "clock count. That is the property that chose 60 MHz, and the reason a",
        "different rate cannot be substituted without re-doing the protocol",
        "timing (ADR-005).",
        "",
        "## Derived constants in the RTL",
        "",
        "| constant | expression | value |",
        "|---|---|---|",
    ]

    spb = int(round(2 * clk / 10e6))
    tpb = clk // baud // 2
    delivered = clk / (tpb * 2)
    err = (delivered / baud - 1) * 100
    i2c_tick = int(clk / 1e6)
    cnw = (tpb).bit_length()

    L += [
        f"| `SPB` (DRU samples/bit, dual-edge) | `2 * CLK_HZ / 10 Mbps` | **{spb}** |",
        f"| `TICKS_PER_BIT` (UART half-bit timer) | `CLK_HZ / BAUD / 2` | **{tpb}** |",
        f"| `CNTW` (timer counter width) | `$clog2(TICKS_PER_BIT)` | **{cnw}** |",
        f"| I2C microsecond tick (plan step 5) | `CLK_HZ / 1e6` | **{i2c_tick}** |",
        "",
        f"Delivered UART baud: `{clk} / ({tpb} * 2)` = **{delivered:,.1f}** "
        f"({err:+.3f}%).",
        "",
        "## What is NOT exact, and why that is acceptable",
        "",
        "| protocol | error | why it is fine |",
        "|---|---|---|",
    ]

    for name, e, why in NOT_EXACT:
        L.append(f"| {name} | {e} | {why} |")

    L += [
        "",
        "The distinction matters for the competition's timing emphasis: a protocol",
        "that must be *bit-exact* (10BASE-T, USB) has an integer tick at 60 MHz, and",
        "one that tolerates a few percent (UART, ±2-4%) does not need one.",
        "",
        "## The retired 66 MHz signoff target",
        "",
        "Blocks used to be signed off at `CLOCK_PERIOD` 15.15 ns = 66 MHz (the",
        "pad-macro ceiling) on the reasoning that closing at 66 and running at 60",
        "leaves free margin. **That target is retired.** It made every reported",
        "slack number require a conversion by the reader, and a longer period is",
        "strictly easier for setup — so a design that closes at 66 has already",
        "closed at 60, and saying so directly is the clearer statement.",
        "",
        "Both flow configs now carry `CLOCK_PERIOD` 16.667 ns, so the number in the",
        "STA report IS the operating point.",
        "",
        "## Related",
        "",
        "- [[decisions/adr-005-60mhz-turbo]] — why 60 and not 40 or 66.",
        "- [[concepts/tx-timing-generation]] — the jitter proof against 66.",
        "- [[concepts/cdr-oversampling]] — the SPB grid this arithmetic feeds.",
        "- [[plans/through-i2c]] — the I2C tick plan that uses the 60-clock µs\n"
        "  (a completed plan, kept for its findings; [[STATUS]] has the live work list).",
        "- [[STATUS]] — the timing margin actually measured at this point.",
        "",
    ]

    # sanity: the constants other files depend on. If these move, those files need
    # regenerating too, and this is the tripwire.
    if spb != 12:
        problems.append(f"SPB is {spb}, but ADR-005 and pe_dru's default say 12")
    if tpb != 260:
        problems.append(f"TICKS_PER_BIT is {tpb}, but the UART firmware and TBs assume 260")

    return "\n".join(L), problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    rendered, problems = build()
    for p in problems:
        print(f"WARN: {p}", file=sys.stderr)

    if args.check:
        if not OUT.exists():
            print(f"gen_clock_arithmetic: {OUT} is missing", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != rendered:
            print(f"gen_clock_arithmetic: {OUT} is STALE — re-run without --check",
                  file=sys.stderr)
            return 1
        print("clock arithmetic up to date")
        return 0 if not problems else 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT} ({len(rendered)} bytes)")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
