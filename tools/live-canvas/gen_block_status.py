#!/usr/bin/env python3
"""Render the block-status table from wiki/STATUS.md as an SVG for the Canvas pane.

Single source of truth: the "What is built and verified" table in
``wiki/STATUS.md``. Nothing here is hardcoded — no table rows, no cell counts,
no areas. If STATUS.md is wrong, the diagram is wrong in exactly the same way,
which is the point: the picture cannot drift from the status doc.

    python3 tools/live-canvas/gen_block_status.py [-o diagrams/block-status.svg]

Default output path is the first live-canvas watch root + ``block-status.svg``.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
STATUS = REPO / "wiki" / "STATUS.md"
ROOTS_JSON = Path(__file__).resolve().parent / "canvas_roots.json"

TABLE_HEADING = "## What is built and verified"

# Dark palette matching the dashboard; kept small on purpose.
BG = "#0d1117"
FG = "#c9d1d9"
MUTED = "#8b949e"
ACCENT = "#7ee787"
LINE = "#30363d"
HEADER_BG = "#161b22"


def parse_rows(text: str) -> tuple[list[str], list[list[str]]]:
    """The markdown table under the 'What is built and verified' heading."""
    start = text.find(TABLE_HEADING)
    if start < 0:
        sys.exit(f"gen_block_status: heading {TABLE_HEADING!r} not found in {STATUS}")
    body = text[start:]
    rows: list[list[str]] = []
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("## ") and rows:
            break
        if not line.startswith("|"):
            if rows:  # table ended
                break
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(set(c) <= set("-: ") for c in cells):  # separator row
            continue
        rows.append(cells)
    if len(rows) < 2:
        sys.exit("gen_block_status: could not parse a table with a header and >=1 row")
    return rows[0], rows[1:]


def estimate_widths(header: list[str], rows: list[list[str]]) -> list[int]:
    widths = [len(h) for h in header]
    for row in rows:
        for i, cell in enumerate(row[: len(widths)]):
            widths[i] = max(widths[i], len(cell))
    return widths


def wrap(text: str, width: int) -> list[str]:
    """Character-count wrap — cell text is prose, not code, so this is enough."""
    limit = max(8, int(width * 1.15))
    words, lines, cur = text.split(), [], ""
    for w in words:
        cand = f"{cur} {w}".strip()
        if len(cand) <= limit:
            cur = cand
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines or [""]


def build_svg(header: list[str], rows: list[list[str]], title: str, subtitle: str) -> str:
    ch_w = 8.2  # monospace advance at font-size 14
    widths = estimate_widths(header, rows)
    pad = 14
    row_h, line_h = 34, 17
    x0, y0 = 24, 92

    wrapped = [[wrap(cell, widths[i]) for i, cell in enumerate(row)] for row in rows]
    heights = [max(row_h, pad * 2 + line_h * max(len(c) for c in cells)) for cells in wrapped]

    col_w = [int(w * ch_w + pad * 2) for w in widths]
    total_w = sum(col_w) + x0 * 2
    total_h = y0 + row_h + sum(heights) + 40

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="{total_h}" '
        f'viewBox="0 0 {total_w} {total_h}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">',
        f'<rect width="{total_w}" height="{total_h}" fill="{BG}"/>',
        f'<text x="{x0}" y="44" fill="{FG}" font-size="20" font-weight="700">{html.escape(title)}</text>',
        f'<text x="{x0}" y="70" fill="{MUTED}" font-size="13">{html.escape(subtitle)}</text>',
    ]

    # header band
    out.append(f'<rect x="{x0}" y="{y0}" width="{sum(col_w)}" height="{row_h}" fill="{HEADER_BG}"/>')
    cx = x0
    for i, name in enumerate(header):
        out.append(
            f'<text x="{cx + pad}" y="{y0 + row_h // 2 + 5}" fill="{ACCENT}" font-size="13" '
            f'font-weight="700">{html.escape(name)}</text>'
        )
        cx += col_w[i]

    # rows
    y = y0 + row_h
    for cells, h in zip(wrapped, heights):
        out.append(f'<line x1="{x0}" y1="{y}" x2="{x0 + sum(col_w)}" y2="{y}" stroke="{LINE}"/>')
        cx = x0
        for i, cell_lines in enumerate(cells):
            ty = y + pad + 11
            for ln in cell_lines:
                colour = FG if i == 0 else MUTED
                weight = "600" if i == 0 else "400"
                out.append(
                    f'<text x="{cx + pad}" y="{ty}" fill="{colour}" font-size="13" '
                    f'font-weight="{weight}">{html.escape(ln)}</text>'
                )
                ty += line_h
            cx += col_w[i]
        y += h
    out.append(f'<line x1="{x0}" y1="{y}" x2="{x0 + sum(col_w)}" y2="{y}" stroke="{LINE}"/>')
    out.append(
        f'<text x="{x0}" y="{y + 26}" fill="{MUTED}" font-size="12">'
        f'generated from wiki/STATUS.md — do not edit by hand</text>'
    )
    out.append("</svg>")
    return "\n".join(out)


def default_output() -> Path:
    try:
        roots = json.loads(ROOTS_JSON.read_text(encoding="utf-8"))
        first = next(r for r in roots if isinstance(r, str) and r.strip())
    except Exception:
        first = str(REPO / "diagrams")
    return Path(first).expanduser() / "block-status.svg"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", type=Path, default=None, help="output SVG path")
    args = ap.parse_args()

    text = STATUS.read_text(encoding="utf-8")
    m = re.search(r"^> Last updated: (.+?) · commit `([0-9a-f]+)`", text, re.M)
    subtitle = f"commit {m.group(2)} · updated {m.group(1)}" if m else "wiki/STATUS.md"

    header, rows = parse_rows(text)
    svg = build_svg(header, rows, "Milestone 1 — verified blocks", subtitle)

    out = args.out or default_output()
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(f".{out.name}.part")
    tmp.write_text(svg, encoding="utf-8")
    tmp.replace(out)  # atomic: the pane never sees a half-written SVG
    print(f"wrote {out} ({len(svg)} bytes, {len(rows)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
