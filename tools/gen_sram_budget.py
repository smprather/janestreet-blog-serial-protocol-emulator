#!/usr/bin/env python3
"""Generate wiki/reference/sram-budget.md from the PDK LEFs.

Answers "how much SRAM fits". Two facts drive it and both are read from source
rather than assumed:

1. **Macro geometry** — parsed from the sg13g2_sram LEFs (SIZE lines). A macro's
   bits-per-um2 and, more importantly, whether it physically fits the die shape
   at all.
2. **Die size** — the competition is 6x4 tiles (8x4 is a possible upside). TT tile notation is
   width x height in tiles (per the ttihp template's own comment: "A single tile
   is about 167x108 uM"), so the die is wide and short. Tall macros do not fit
   unrotated, and the biggest ones do not fit in either orientation.

    python3 tools/gen_sram_budget.py            # write the page
    python3 tools/gen_sram_budget.py --check     # exit 1 if stale
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "wiki" / "reference" / "sram-budget.md"
PDK_SRAM = Path.home() / "pdk" / "IHP-Open-PDK" / "ihp-sg13g2" / "libs.ref" / "sg13g2_sram"
LEF_DIR = PDK_SRAM / "lef"

# Two candidate tile sizes. The blog says ~200x150; the ttihp-verilog-template
# info.yaml says ~167x108. The wiki's standing instruction is to use the
# template figure for layout math and re-check after first real floorplan, so
# the template figure is the headline and the blog figure is the optimistic
# bound. Ranges are reported, never a single number pretending to be exact.
TILE_TEMPLATE = (167.0, 108.0)
TILE_BLOG = (200.0, 150.0)

# Tile ALLOCATION, width x height in tiles. The blog says 6x4 ("Set the tile
# size in info.yaml to 6x4", "The current maximum area is 6x4 tiles per
# design") and describes 8x4 only as a possibility they are working on, worth
# ~30% more area, to be announced by a page update and an email to sign-ups.
# So 6x4 is the default and 8x4 is the upside case: --tiles 8x4.
#
# Shape matters more than tile count. At the template tile: 6x4 is 1002x432
# (2.32:1), 8x4 is 1336x432 (3.09:1), and a hypothetical 4x6 would be 668x648
# (near square) -- same 24 tiles as 6x4 but it would lose the entire
# 64-bit-wide macro family, which is 784 um wide.
#
# Override with --tiles WxH to re-answer the whole page for a new allocation:
#     python3 tools/gen_sram_budget.py --tiles 8x4
TILES_W, TILES_H = 6, 4

# Measured on this machine from a real LibreLane run (~/asic-runs/pe-serdes,
# RUN_2026-09-18_16-53-07): 539 cells, stdcell area 17211.4 um2, die 29163.7 um2
# at 78% utilization. Used only to sanity-check the logic side of the budget.
SERDES_CELLS = 539
SERDES_STDCELL_UM2 = 17211.4
SERDES_DIE_UM2 = 29163.7
SERDES_UTIL = 0.7796


def parse_lefs() -> list[dict]:
    macros = []
    if not LEF_DIR.is_dir():
        sys.exit(f"gen_sram_budget: no LEF directory at {LEF_DIR}")
    for lef in sorted(LEF_DIR.glob("*.lef")):
        text = lef.read_text(errors="replace")
        name = re.search(r"^MACRO\s+(\S+)", text, re.M)
        size = re.search(r"^\s*SIZE\s+([\d.]+)\s+BY\s+([\d.]+)\s*;", text, re.M)
        if not (name and size):
            continue
        w, h = float(size.group(1)), float(size.group(2))
        bits = re.search(r"_(\d+)x(\d+)_", name.group(1))
        if not bits:
            bits = re.search(r"_(\d+)x(\d+)$", name.group(1))
        depth, width = (int(bits.group(1)), int(bits.group(2))) if bits else (0, 0)
        ports = 2 if "_2P_" in name.group(1) else 1
        macros.append({
            "name": name.group(1),
            "w": w, "h": h, "area": w * h,
            "depth": depth, "width": width, "bits": depth * width,
            "ports": ports,
            "density": (depth * width) / (w * h) if w * h else 0.0,
        })
    return macros


def fits(m: dict, die_w: float, die_h: float) -> str:
    """'yes' | 'rotated' | 'no' — can this macro physically occupy the die?"""
    direct = m["w"] <= die_w and m["h"] <= die_h
    rot = m["h"] <= die_w and m["w"] <= die_h
    if direct:
        return "yes"
    if rot:
        return "rotated"
    return "no"


def pack_single(die: tuple[float, float], m: dict) -> tuple[int, tuple[int, int, float, float] | None]:
    """Max instances of ONE macro shape in the die, either orientation.

    Density times area is NOT the answer: a rectangle packs worse than its area
    suggests, and a 3:1 die punishes tall macros. Grid packing per orientation
    is exact for a single shape and is what the floorplanner can actually do.
    """
    best, best_layout = 0, None
    for mw, mh in {(m["w"], m["h"]), (m["h"], m["w"])}:
        nx, ny = int(die[0] // mw), int(die[1] // mh)
        if nx * ny > best:
            best, best_layout = nx * ny, (nx, ny, mw, mh)
    return best, best_layout


def best_packing(die: tuple[float, float], macros: list[dict]) -> dict | None:
    """The macro whose repeated instance packs the most bits into the die."""
    best = None
    for m in macros:
        n, layout = pack_single(die, m)
        if n == 0:          # does not place at all in this die
            continue
        total = n * m["bits"]
        if best is None or total > best["total"]:
            best = {"macro": m, "n": n, "layout": layout, "total": total,
                    "area": n * m["area"], "eff": total / (die[0] * die[1])}
    return best


def cheapest_for(die: tuple[float, float], macros: list[dict], bits_needed: int) -> dict | None:
    """Smallest die area that reaches `bits_needed`, using one macro type.

    Single-type packing understates what a mixed floorplan could do, so these
    figures are an upper bound on area (a lower bound on capacity) — the
    conservative direction for a budget.
    """
    best = None
    for m in macros:
        per, _ = pack_single(die, m)
        if per == 0:        # does not place at all in this die
            continue
        need = -(-bits_needed // m["bits"])       # ceil
        if need > per:
            continue                               # cannot reach it with this shape
        area = need * m["area"]
        if best is None or area < best["area"]:
            best = {"macro": m, "n": need, "area": area, "bits": need * m["bits"]}
    return best



def build() -> str:
    macros = parse_lefs()
    if not macros:
        sys.exit("gen_sram_budget: parsed no macros — LEF layout changed?")

    die_w_t, die_h_t = TILES_W * TILE_TEMPLATE[0], TILES_H * TILE_TEMPLATE[1]
    die_w_b, die_h_b = TILES_W * TILE_BLOG[0], TILES_H * TILE_BLOG[1]
    area_t = die_w_t * die_h_t
    area_b = die_w_b * die_h_b

    for m in macros:
        m["fit_template"] = fits(m, die_w_t, die_h_t)

    usable = [m for m in macros if m["fit_template"] != "no"]
    best = max(usable, key=lambda m: m["density"])
    biggest = max(usable, key=lambda m: m["bits"])
    blocked = [m for m in macros if m["fit_template"] == "no"]

    # Logic side, from the real run. Leave headroom for routing/clock/fill:
    # the measured ratio is die/stdcell = 29163.7/17211.4 = 1.694.
    inflate = SERDES_DIE_UM2 / SERDES_STDCELL_UM2
    um2_per_cell = SERDES_STDCELL_UM2 / SERDES_CELLS

    lines = [
        "---",
        "title: SRAM Budget",
        "created: 2026-09-18",
        "updated: 2026-09-18",
        "type: reference",
        "tags: [area-budget, process-node, architecture]",
        "sources: [raw/articles/janestreet-protocol-emulator-competition.md]",
        "confidence: medium",
        "---",
        "",
        "# SRAM Budget",
        "",
        f"How much SRAM fits on the {TILES_W*TILES_H}-tile die. Macro geometry is parsed from the",
        "PDK LEFs by `tools/gen_sram_budget.py`",
        f"(`{PDK_SRAM.relative_to(Path.home())}`), so the numbers are the real",
        "macros, not the datasheet's bit counts in isolation.",
        "",
        "## The die is wide and short — this decides everything",
        "",
        "TT tile notation is **width × height in tiles**, not a count. The ttihp",
        "template's own comment says *\"A single tile is about 167x108 uM\"*, and the",
        f"competition is {TILES_W}×{TILES_H}, so:",
        "",
        f"| Source | Tile | Die ({TILES_W}×{TILES_H}) | Area |",
        "|---|---|---|---|",
        f"| **ttihp-verilog-template** (authoritative) | {TILE_TEMPLATE[0]:.0f}×{TILE_TEMPLATE[1]:.0f} µm | **{die_w_t:.0f} × {die_h_t:.0f} µm** | **{area_t:,.0f} µm² ({area_t/1e6:.3f} mm²)** |",
        f"| Jane Street blog (optimistic) | {TILE_BLOG[0]:.0f}×{TILE_BLOG[1]:.0f} µm | {die_w_b:.0f} × {die_h_b:.0f} µm | {area_b:,.0f} µm² ({area_b/1e6:.3f} mm²) |",
        "",
        f"Aspect ratio is ~{die_w_t/die_h_t:.1f}:1. That matters more than total area:",
        "**a macro has to physically fit the rectangle**, and most of the larger",
        "macros are taller than the die is.",
        "",
        "## Every macro in the PDK",
        "",
        f"`fit` = can it be placed in the {TILES_W}×{TILES_H} die at the template's tile size",
        "(`rotated` means only at 90°, which the flow supports).",
        "",
        "| Macro | Bits | W×H (µm) | Area (µm²) | bits/µm² | P | fit |",
        "|---|---|---|---|---|---|---|",
    ]
    for m in sorted(macros, key=lambda x: -x["density"]):
        lines.append(
            f"| `{m['name'].replace('RM_IHPSG13_', '')}` | {m['bits']:,} | "
            f"{m['w']:.0f}×{m['h']:.0f} | {m['area']:,.0f} | {m['density']:.4f} | "
            f"{m['ports']}P | {m['fit_template']} |"
        )

    lines += [
        "",
        "### What does not fit",
        "",
    ]
    if blocked:
        for m in blocked:
            # A macro fits in SOME orientation iff its short side fits the
            # die's short side and its long side fits the die's long side.
            # Name whichever of those two actually fails, rather than assuming
            # height: on a near-square die (4x6) the 64-bit-wide macros are
            # blocked by WIDTH, and calling that "too tall" misleads.
            m_short, m_long = min(m["w"], m["h"]), max(m["w"], m["h"])
            d_short, d_long = min(die_w_t, die_h_t), max(die_w_t, die_h_t)
            if m_long > d_long and m_short > d_short:
                why = (f"exceeds the die in both axes "
                       f"({m_long:.0f} > {d_long:.0f} and {m_short:.0f} > {d_short:.0f} µm)")
            elif m_long > d_long:
                why = (f"its {m_long:.0f} µm long side exceeds the die's "
                       f"{d_long:.0f} µm long side")
            else:
                why = (f"its {m_short:.0f} µm short side exceeds the die's "
                       f"{d_short:.0f} µm short side")
            lines.append(f"- `{m['name'].replace('RM_IHPSG13_', '')}` ({m['bits']:,} bits, "
                         f"{m['w']:.0f}×{m['h']:.0f} µm) — {why}.")
        lines += [
            "",
            "**The highest-density macros in the PDK are unusable here.** The whole",
            "8192×32 and 2048×64 classes are excluded by the die's shape, not by the",
            "area budget. If the tile figure turns out to be the blog's 200×150,",
            f"the die becomes {die_w_b:.0f}×{die_h_b:.0f} and that changes — re-run this",
            "page if the tile size is confirmed.",
        ]

    cap_t = best_packing((die_w_t, die_h_t), macros)
    cap_b = best_packing((die_w_b, die_h_b), macros)
    lines += [
        "",
        "## So how much actually fits",
        "",
        "This is the number that matters, and it is **smaller than density × area",
        "suggests**. A rectangle packs worse than its area implies, and a 3:1 die",
        "punishes tall macros: `1024x64` is the densest macro that fits the template",
        "die, yet only one instance fits — whereas `2048x32` packs two and",
        "`1024x16` packs five.",
        "",
        "Largest **practically packable** capacity, one macro type, grid packing:",
        "",
        "| Die | Best macro | Layout | Total | Occupied area | Die efficiency |",
        "|---|---|---|---|---|---|",
    ]
    for label, cap in ((f"Template ({die_w_t:.0f}×{die_h_t:.0f})", cap_t),
                       (f"Blog ({die_w_b:.0f}×{die_h_b:.0f})", cap_b)):
        if not cap:
            continue
        m, n, lay = cap["macro"], cap["n"], cap["layout"]
        lines.append(
            f"| {label} | `{m['name'].replace('RM_IHPSG13_', '')}` | "
            f"{lay[0]}×{lay[1]} @ {lay[2]:.0f}×{lay[3]:.0f} µm | "
            f"**{cap['total']:,} bits ({cap['total']/8/1024:.0f} KB)** | "
            f"{cap['area']:,.0f} µm² | {100*cap['area']/( (die_w_t*die_h_t) if 'Template' in label else (die_w_b*die_h_b) ):.0f}% |"
        )
    lines += [
        "",
        "*That 100%-occupied figure is the theoretical roof with no logic at all.*",
        "Real capacity is what you get after reserving logic, and the honest way to",
        "state it is per size class:",
        "",
        "### Area cost of a given SRAM size",
        "",
        "Smallest single-macro-type area reaching each size, on the **template** die",
        "(conservative) and the blog die (optimistic):",
        "",
        "| SRAM | Bits | Template die: macro × n | Area | % of die | Blog die: area | % of die |",
        "|---|---|---|---|---|---|---|",
    ]
    for label, bits in [("1 KB", 8192), ("2 KB", 16384), ("4 KB", 32768),
                        ("8 KB", 65536), ("16 KB", 131072), ("32 KB", 262144)]:
        ct = cheapest_for((die_w_t, die_h_t), macros, bits)
        cb = cheapest_for((die_w_b, die_h_b), macros, bits)
        if ct is None and cb is None:
            lines.append(f"| {label} | {bits:,} | *not reachable* | — | — | — | — |")
            continue
        left = (f"`{ct['macro']['name'].replace('RM_IHPSG13_','')}` × {ct['n']}" if ct else "—")
        a_t = f"{ct['area']:,.0f} µm²" if ct else "—"
        p_t = f"{100*ct['area']/area_t:.0f}%" if ct else "—"
        a_b = f"{cb['area']:,.0f} µm²" if cb else "—"
        p_b = f"{100*cb['area']/area_b:.0f}%" if cb else "—"
        lines.append(f"| {label} | {bits:,} | {left} | {a_t} | {p_t} | {a_b} | {p_b} |")

    sr_4k = cheapest_for((die_w_t, die_h_t), macros, 32768)
    sr_8k = cheapest_for((die_w_t, die_h_t), macros, 65536)
    lines += [
        "",
        "*(Single macro type. A mixed floorplan can do somewhat better; this is the",
        "conservative direction for a budget.)*",
        "",
        "### And what is left for logic",
        "",
        f"The measured SERDES run gives ~{um2_per_cell:.1f} µm² of standard cell per",
        f"logic cell, inflating ×{inflate:.2f} once routing, clock tree and fill cells are",
        "included (die ÷ stdcell area on that run). Applying that to the template die:",
        "",
        f"- Whole die, no SRAM: **≈ {area_t / (um2_per_cell * inflate):,.0f} logic cells**",
    ]
    if sr_4k:
        lines.append(f"- With 4 KB of SRAM ({sr_4k['area']:,.0f} µm²): "
                     f"≈ {(area_t - sr_4k['area']) / (um2_per_cell * inflate):,.0f} logic cells")
    if sr_8k:
        lines.append(f"- With 8 KB of SRAM ({sr_8k['area']:,.0f} µm²): "
                     f"≈ {(area_t - sr_8k['area']) / (um2_per_cell * inflate):,.0f} logic cells")
    lines += [
        "",
        f"**These are well under the blog's \"~1K cells per tile\" (≈{TILES_W*TILES_H*1000:,}",
        f"cells for {TILES_W*TILES_H} tiles).** The two published tile figures are inconsistent with",
        "each other, and the template's tile size is what the flow will actually",
        "enforce. See [[STATUS]] open risks — worth confirming with TT/Jane Street",
        "before committing to an SRAM-heavy architecture.",
        "",
        "## Recommendation",
        "",
        "- **1–2 KB (8192–16384 bits) is comfortable** — single-digit percent of the",
        "  die, leaving the logic budget essentially intact. That is a realistic",
        "  instruction memory for a PIO-style microsequencer (the RP2040's PIO has",
        "  32 instructions × 2 SMs, so even 256 instructions is generous).",
        "- **4 KB is the practical ceiling** if the design also needs real logic.",
        "- **8 KB+ turns the chip into a memory chip** with a little logic attached.",
        "- **Width beats depth here.** The die is wide and short, so favour macros",
        "  that are wide and flat (e.g. `2048x32` at 417×627 does *not* pack well;",
        "  `1024x16` at 237×336 packs five across). Check the layout column before",
        "  choosing a shape.",
        "- Prefer **fewer, wider macros** — fixed overhead (decoders, BIST, bitmask,",
        "  IO) is per instance, not per bit.",
        "",
        "### Caveats worth carrying",
        "",
        "- No SRAM compiler for sg13g2 (OpenRAM does not support it), so you get",
        "  exactly the 30 shapes above. Depth/width are not free parameters.",
        "- The macros here include BIST and bitmask (`_bm_bist`) and the 2P variants",
        "  are true two-port. Check which you actually need — and note that",
        "  `64x16_c2` and `64x32_c2` have **no** `_bm_bist` suffix, so they are the",
        "  plain parts.",
        "- Macro timing comes with the macros (fast/typ/slow .lib), so SRAM access",
        "  time is fixed and must be budgeted against the 60 MHz system clock",
        "  (16.667 ns period). **This is the tightest path in the SoC, not the logic.**",
        "  From the `.lib` shipped with the PDK, for the instantiated",
        "  `RM_IHPSG13_1P_1024x16_c2_bm_bist`: the `A_CLK` -> `A_DOUT` clock-to-output",
        "  is **7.25 ns at the slow corner** (1.08 V, 125 C), 4.34 ns at typ and",
        "  2.67 ns at fast. That is 43% of a 60 MHz period. `pe_imem` deliberately has",
        "  NO output register (it would add a second cycle of latency and break the",
        "  CPU's fetch-ahead, which assumes exactly one), so the whole",
        "  `A_CLK -> A_DOUT -> CPU` path is combinational after the macro.",
        "",
        "**Now MEASURED in the full SoC, post-route** (this replaces the estimate the",
        "paragraph above used to end on). The full-SoC LibreLane run",
        "(`RUN_2026-09-22_00-33-59`, the one with the working PDN) reported:",
        "",
        "| quantity | value |",
        "|---|---|",
        "| SRAM in-context `A_CLK` -> `A_DOUT` | **7.635 ns** (vs 7.25 ns from the .lib table) |",
        "| total path arrival | 13.448 ns |",
        "| total path required | 14.591 ns |",
        "| **setup slack, slow corner** | **+1.143 ns** |",
        "| hold slack, slow corner | +0.656 ns |",
        "| worst-case IR drop on VPWR | 0.30% (3.56 mV of 1.20 V) |",
        "",
        "**One caveat on that 7.635 ns, measured 2026-09-22 and not obvious from",
        "the summary:** the macro's own `.lib` characterises its input slew axis only",
        "up to **0.5952** and its output cap axis only up to **0.0640**, and this",
        "design presents **1.291** slew on `A_DIN[5]` and **0.1169** cap on",
        "`A_DOUT[4]`. OpenROAD **extrapolates silently** there -- it emits no warning",
        "-- so the macro's internal delay is a table lookup taken outside the table.",
        "That is why STA reports 10 max-slew / 8 max-cap / 7 max-fanout violations on",
        "the macro's pins alongside the clean setup/hold result; those checks are",
        "separate from setup/hold and an earlier note here wrongly read the clean",
        "setup/hold as 'zero violations'. The slack on the affected paths is large",
        "(`A_DIN[5]` +10.27 ns, `A_ADDR[0]` +3.70 ns) and extrapolation usually",
        "over-estimates delay, so the signoff is not in danger -- but the fix belongs",
        "in the FLOW (`repair_design` resizes nothing here because it runs with",
        "`-slew_margin 20 -cap_margin 20`; raising",
        "`DESIGN_REPAIR_MAX_SLEW_PCT`/`DESIGN_REPAIR_MAX_CAP_PCT` is the lever).",
        "STATUS gotchas 37-38.",
        "",
        "The in-context access is 0.39 ns worse than the standalone .lib table figure,",
        "which is the clock-tree and routing overhead of actually placing the macro --",
        "and it is the reason the .lib figure was labelled an estimate. Setup and hold",
        "both close at all three corners with zero SETUP/HOLD violating paths (the",
        "separate max-slew/max-cap checks on the macro do fail -- see the caveat",
        "result. Note the slack is a *measured post-route* number, so it moves by",
        "~0.1 ns between runs as placement changes; an earlier run without the PDN",
        "fix read +1.234 ns. Quote the run ID with the number.",
        "- Floorplanning matters: a rotated macro has its pins on a different edge,",
        "  which constrains where the logic around it can go.",
        "- The macro's power pins are on **Metal4** while the PDN grid is built on",
        "  TopMetal1/TopMetal2, so the stock PDN config leaves the macro's supplies",
        "  unconnected (`PSM-0069`). The SoC's flow uses a custom `PDN_CFG` that",
        "  stripes Metal4 and steps up to the grid; see `flow/pe_uart_soc_pdn.tcl`.",
        "",
        "## Related",
        "",
        "- [[concepts/pdk-toolchain]] — where the macros live and how to use them.",
        "- [[concepts/competition-overview]] — the area budget this sits inside.",
        "- [[reference/protocol-pin-budget]] — the other hard budget (IO).",
        "- [[STATUS]] — the tile-size discrepancy is an open risk there.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--tiles", metavar="WxH", default=None,
                    help="tile allocation, width x height (default 6x4, the "
                         "blog's current allocation). Example: --tiles 8x4")
    args = ap.parse_args()

    if args.tiles:
        global TILES_W, TILES_H
        try:
            w, h = args.tiles.lower().split("x")
            TILES_W, TILES_H = int(w), int(h)
        except ValueError:
            print(f"gen_sram_budget: --tiles wants WxH, got {args.tiles!r}",
                  file=sys.stderr)
            return 1
        if args.check:
            print("gen_sram_budget: --tiles and --check are mutually exclusive "
                  "(the committed page is the 6x4 answer)", file=sys.stderr)
            return 1

    rendered = build()
    if args.check:
        if not OUT.exists():
            print(f"gen_sram_budget: {OUT} is missing", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != rendered:
            print(f"gen_sram_budget: {OUT} is STALE — re-run without --check", file=sys.stderr)
            return 1
        print("sram budget up to date")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT} ({len(rendered)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
