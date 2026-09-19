#!/usr/bin/env python3
"""Render a grid-placed flowchart spec (JSON) to a self-contained SVG.

Spec format (see ``flowcharts/rx-path.json``)::

    {
      "title": "…", "subtitle": "…", "legend": true,
      "output": "rx-path-flow.svg",
      "nodes": [
        {"id": "a", "kind": "start|process|decision|side|end|note",
         "text": "line one\\nline two", "row": 0, "col": 0,
         "w": 320, "h": 56}          # w/h optional
      ],
      "edges": [
        {"from": "a", "to": "b", "label": "yes", "route": "auto"}
      ]
    }

Layout: ``col`` is a grid column (may be negative — the spine is col 0, side
branches sit at col ±1), ``row`` stacks top-down. Columns are sized to their
widest node and centred; the renderer never needs pixel coordinates.

Routing is chosen from geometry, not from the spec:

* same row, different column -> straight across
* same column, different row  -> straight down
* different row and column    -> drop, then across, then into the target's top
* ``loop-left`` / ``loop-right`` -> out the side, along a gutter lane, back in
  (the loop-back case); a self-loop gets a *local* hook beside its own node
  rather than a lane on the far side of the diagram
* ``into-left`` / ``into-right`` -> accepted, but always resolved to the side
  vertex **facing the source**, so the approach never crosses the target

Every segment is checked against every node box after routing
(``find_crossings``); crossings are reported and exit code 3 is returned, so a
diagram that would draw a line through a shape cannot ship silently.

Writes atomically (stage + rename) so the Canvas pane never renders a
half-written file.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC_DIR = HERE / "flowcharts"
ROOTS_JSON = HERE / "canvas_roots.json"

# --- palette (light fills on the pane's white stage; dark ink for contrast) ---
INK = "#1f2328"
MUTED = "#57606a"
STROKE = "#2b2b2b"
FILL = {
    "start": "#b2f2bb",
    "end": "#b2f2bb",
    "process": "#a5d8ff",
    "decision": "#fff3bf",
    "side": "#d0bfff",
    "note": "#f1f3f5",
}

# --- geometry ---
FONT = 16.0          # node text
LINE_H = 21.0
PAD = 14.0
EDGE_FONT = 14.0
TITLE_FONT = 22.0
DEFAULT_W = {"start": 300.0, "end": 300.0, "process": 330.0,
             "decision": 300.0, "side": 250.0, "note": 330.0}
DECISION_H = 112.0
MIN_H = 52.0
COL_GAP = 46.0       # horizontal gap between grid columns
ROW_GAP = 50.0       # vertical gap between rows (arrow + label room)
LANE_PAD = 34.0      # gutter lane offset for loop-back routes
HOOK_OFF = 26.0      # how far a self-loop hook leans out from its own node
MARGIN = 44.0
HEADER_H = 104.0     # title + subtitle
LEGEND_H = 46.0
BOX_INSET = 3.0      # collision test ignores a few px of the box edge

CHAR_W = 0.545       # average glyph advance as a fraction of font size


def esc(text: str) -> str:
    """XML-escape, and force non-ASCII to numeric character references.

    The pane delivers SVG through ``srcdoc``, where a byte-level encoding
    disagreement shows up as mojibake (``—`` -> ``â€"``). Numeric references are
    encoding-independent, so the file renders correctly however it is shipped.
    """
    out = []
    for ch in str(text):
        if ord(ch) < 128:
            out.append(html.escape(ch))
        else:
            out.append(f"&#{ord(ch)};")
    return "".join(out)


def wrap(text: str, max_w: float, font: float = FONT) -> list[str]:
    """Greedy wrap; explicit ``\\n`` in the spec is a hard break."""
    out: list[str] = []
    for hard in str(text).split("\n"):
        words, cur = hard.split(), ""
        for w in words:
            cand = f"{cur} {w}".strip()
            if not cur or len(cand) * CHAR_W * font <= max_w:
                cur = cand
            else:
                out.append(cur)
                cur = w
        out.append(cur)
    return out or [""]


def node_size(n: dict) -> tuple[float, float]:
    kind = n.get("kind", "process")
    w = float(n.get("w") or DEFAULT_W.get(kind, 320.0))
    if n.get("h"):
        return w, float(n["h"])
    if kind == "decision":
        return w, DECISION_H
    inner = w - 2 * PAD
    lines = wrap(n.get("text", ""), inner * 0.62 if kind == "decision" else inner)
    h = max(MIN_H, 2 * PAD + len(lines) * LINE_H)
    return w, round(h)


def layout(nodes: list[dict]) -> dict:
    """Assign pixel boxes. Returns {id: (x, y, w, h)} plus canvas size."""
    sizes = {n["id"]: node_size(n) for n in nodes}
    cols: dict[int, list[dict]] = {}
    rows: dict[int, list[dict]] = {}
    for n in nodes:
        cols.setdefault(int(n.get("col", 0)), []).append(n)
        rows.setdefault(int(n.get("row", 0)), []).append(n)

    col_w = {c: max(sizes[n["id"]][0] for n in ns) for c, ns in cols.items()}
    row_h = {r: max(sizes[n["id"]][1] for n in ns) for r, ns in rows.items()}

    col_x: dict[int, float] = {}
    x = MARGIN
    for c in sorted(col_w):
        col_x[c] = x
        x += col_w[c] + COL_GAP
    width = x - COL_GAP + MARGIN

    row_y: dict[int, float] = {}
    y = HEADER_H
    for r in sorted(row_h):
        row_y[r] = y
        y += row_h[r] + ROW_GAP
    height = y - ROW_GAP + LEGEND_H + MARGIN

    boxes = {}
    for n in nodes:
        w, h = sizes[n["id"]]
        c, r = int(n.get("col", 0)), int(n.get("row", 0))
        boxes[n["id"]] = (
            col_x[c] + (col_w[c] - w) / 2,
            row_y[r] + (row_h[r] - h) / 2,
            w,
            h,
        )
    return {"boxes": boxes, "w": width, "h": height}


def pts(box: tuple[float, float, float, float]) -> dict[str, tuple[float, float]]:
    x, y, w, h = box
    return {
        "top": (x + w / 2, y),
        "bottom": (x + w / 2, y + h),
        "left": (x, y + h / 2),
        "right": (x + w, y + h / 2),
        "c": (x + w / 2, y + h / 2),
    }


def shape_svg(n: dict, box: tuple[float, float, float, float]) -> list[str]:
    x, y, w, h = box
    kind = n.get("kind", "process")
    fill = FILL.get(kind, FILL["process"])
    common = f'fill="{fill}" stroke="{STROKE}" stroke-width="2"'
    if kind in ("start", "end"):
        body = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h/2}" ry="{h/2}" {common}/>'
    elif kind == "decision":
        body = (f'<polygon points="{x+w/2},{y} {x+w},{y+h/2} {x+w/2},{y+h} {x},{y+h/2}" {common}/>')
    elif kind == "note":
        body = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" ry="6" '
                f'fill="{fill}" stroke="{MUTED}" stroke-width="1.6" stroke-dasharray="6 5"/>')
    else:
        body = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" ry="8" {common}/>'

    inner = w - 2 * PAD
    lines = wrap(n.get("text", ""), inner * 0.62 if kind == "decision" else inner)
    # centre the text block
    total = len(lines) * LINE_H
    ty = y + h / 2 - total / 2 + LINE_H * 0.72
    text = []
    for ln in lines:
        text.append(
            f'<text x="{x + w/2:.1f}" y="{ty:.1f}" fill="{INK}" font-size="{FONT}" '
            f'font-weight="500" text-anchor="middle">{esc(ln)}</text>'
        )
        ty += LINE_H
    return [body, *text]


def label_svg(text: str, x: float, y: float, anchor: str = "middle") -> list[str]:
    if not text:
        return []
    w = len(text) * CHAR_W * EDGE_FONT
    rx = {"middle": x - w / 2, "start": x, "end": x - w}[anchor]
    return [
        f'<rect x="{rx - 3:.1f}" y="{y - EDGE_FONT + 1:.1f}" width="{w + 6:.1f}" '
        f'height="{EDGE_FONT + 5:.1f}" fill="#ffffff" opacity="0.92"/>',
        f'<text x="{x:.1f}" y="{y:.1f}" fill="{MUTED}" font-size="{EDGE_FONT}" '
        f'text-anchor="{anchor}">{esc(text)}</text>',
    ]


# ---------------------------------------------------------------------------
# routing
# ---------------------------------------------------------------------------

Seg = tuple[str, float, float, float]   # ("H"|"V", fixed, lo, hi)


def _h(y: float, x1: float, x2: float) -> Seg:
    return ("H", y, min(x1, x2), max(x1, x2))


def _v(x: float, y1: float, y2: float) -> Seg:
    return ("V", x, min(y1, y2), max(y1, y2))


def find_crossings(edges: list[dict], boxes: dict) -> list[str]:
    """Segments that pass through a shape they do not start or end on.

    The renderer's whole job is that a reader can follow a line; a line through
    a box makes the diagram lie about the flow. Cheap to check, so it is checked
    every build rather than trusted.
    """
    problems: list[str] = []
    for e in edges:
        for kind, fixed, lo, hi in e.get("segs", []):
            for nid, (x, y, w, h) in boxes.items():
                if nid in (e["from"], e["to"]):
                    continue
                x1, y1 = x + BOX_INSET, y + BOX_INSET
                x2, y2 = x + w - BOX_INSET, y + h - BOX_INSET
                if x1 >= x2 or y1 >= y2:
                    continue
                if kind == "H":
                    hit = y1 < fixed < y2 and lo < x2 and hi > x1
                else:
                    hit = x1 < fixed < x2 and lo < y2 and hi > y1
                if hit:
                    problems.append(
                        f"{e['from']} -> {e['to']}: {kind} segment at "
                        f"{fixed:.0f} crosses node {nid!r}"
                    )
    return problems


def route_edge(edge: dict, boxes: dict, gutters: dict) -> dict:
    """One edge as {d, segs, svg}. Raises on an unknown node reference."""
    a, b = edge["from"], edge["to"]
    for nid in (a, b):
        if nid not in boxes:
            sys.exit(f"gen_flowchart: edge references unknown node {nid!r}")
    ba, bb = boxes[a], boxes[b]
    pa, pb = pts(ba), pts(bb)
    route = edge.get("route", "auto")
    lbl = edge.get("label", "")
    arrow = ' fill="none" stroke="%s" stroke-width="2" marker-end="url(#ah)"' % STROKE
    segs: list[Seg] = []
    svg: list[str] = []

    def emit(d: str) -> None:
        svg.append(f'<path d="{d}"{arrow}/>')

    # -- explicit loops (gutter lane, or a local hook for a self-loop) --------
    if route in ("loop-left", "loop-right"):
        side = "left" if route == "loop-left" else "right"

        if a == b:
            # A self-loop must not reach for the far gutter lane: that lane sits
            # outside every node, but the horizontal run getting there would cut
            # through whatever shares the row. Lean a short hook out beside the
            # node itself, in the inter-column gap.
            x, y, w, h = ba
            sx, sy = pa[side]
            lane = (x + w + HOOK_OFF) if side == "right" else (x - HOOK_OFF)
            tx, ty = pa["top"]
            top_y = ty - 16
            emit(f"M {sx:.1f} {sy:.1f} H {lane:.1f} V {top_y:.1f} H {tx:.1f} V {ty:.1f}")
            segs += [_h(sy, sx, lane), _v(lane, sy, top_y),
                     _h(top_y, lane, tx), _v(tx, top_y, ty)]
            mid_y = (sy + top_y) / 2
            # Anchor the label inside the hook, where the space is empty.
            if side == "right":
                svg += label_svg(lbl, lane - 6, mid_y, anchor="end")
            else:
                svg += label_svg(lbl, lane + 6, mid_y, anchor="start")
        else:
            lane = gutters[side]
            sx, sy = pa[side]
            tx, ty = pb[side]
            emit(f"M {sx:.1f} {sy:.1f} H {lane:.1f} V {ty:.1f} H {tx:.1f}")
            segs += [_h(sy, sx, lane), _v(lane, sy, ty), _h(ty, lane, tx)]
            # Label at the SOURCE end of the lane, not the midpoint: whatever
            # sits between the two nodes owns the midpoint, and a label parked
            # there lands on top of it.
            if side == "left":
                svg += label_svg(lbl, lane + 6, sy - 9, anchor="start")
            else:
                svg += label_svg(lbl, lane - 6, sy - 9, anchor="end")
        return {"from": a, "to": b, "segs": segs, "svg": svg}

    # -- same row: straight across -------------------------------------------
    if abs(pa["c"][1] - pb["c"][1]) < 1:
        ltr = pa["c"][0] < pb["c"][0]
        sx, sy = pa["right"] if ltr else pa["left"]
        tx, ty = pb["left"] if ltr else pb["right"]
        emit(f"M {sx:.1f} {sy:.1f} H {tx:.1f}")
        segs.append(_h(sy, sx, tx))
        svg += label_svg(lbl, (sx + tx) / 2, sy - 9)
        return {"from": a, "to": b, "segs": segs, "svg": svg}

    # -- same column: straight down ------------------------------------------
    if abs(pa["c"][0] - pb["c"][0]) < 1:
        sx, sy = pa["bottom"]
        tx, ty = pb["top"]
        emit(f"M {sx:.1f} {sy:.1f} V {ty:.1f}")
        segs.append(_v(sx, sy, ty))
        # Right of the line, anchored start, so a long label grows into the
        # channel beside the arrow instead of over the source node.
        svg += label_svg(lbl, sx + 9, (sy + ty) / 2, anchor="start")
        return {"from": a, "to": b, "segs": segs, "svg": svg}

    # -- different row and column: side vertex FACING the source -------------
    # Entering the far vertex would run the last leg straight through the
    # target box; entering the facing one means the horizontal leg spans only
    # the inter-column gap.
    sx, sy = pa["bottom"]
    entering_right = pa["c"][0] > pb["c"][0]
    side_key = "right" if entering_right else "left"
    tx, ty = pb[side_key]
    emit(f"M {sx:.1f} {sy:.1f} V {ty:.1f} H {tx:.1f}")
    segs += [_v(sx, sy, ty), _h(ty, sx, tx)]
    svg += label_svg(lbl, (sx + tx) / 2, ty - 9)
    return {"from": a, "to": b, "segs": segs, "svg": svg}


def legend_svg(y: float, x: float) -> list[str]:
    items = [("start", "start / end"), ("process", "process"),
             ("decision", "decision"), ("side", "counter op")]
    out, cx = [], x
    for kind, text in items:
        out.append(f'<rect x="{cx:.1f}" y="{y - 11:.1f}" width="20" height="14" rx="3" '
                   f'fill="{FILL[kind]}" stroke="{STROKE}" stroke-width="1.5"/>')
        out.append(f'<text x="{cx + 27:.1f}" y="{y:.1f}" fill="{MUTED}" '
                   f'font-size="13">{esc(text)}</text>')
        cx += 27 + len(text) * 7.2 + 26
    return out


def build(spec: dict) -> tuple[str, list[str]]:
    """Returns (svg, crossing problems)."""
    nodes, edges_in = spec["nodes"], spec.get("edges", [])
    lay = layout(nodes)
    boxes = lay["boxes"]

    # Reserve the left gutter lane inside the canvas, then route. Boxes move
    # right by the lane width so nothing (loop or label) lands off-canvas.
    min_x = min(b[0] for b in boxes.values())
    shift = LANE_PAD if (min_x - LANE_PAD) < MARGIN else 0.0
    if shift:
        boxes = {k: (x + shift, y, w, h) for k, (x, y, w, h) in boxes.items()}
    xr = [b[0] + b[2] for b in boxes.values()]
    gutters = {"left": min(b[0] for b in boxes.values()) - LANE_PAD,
               "right": max(xr) + LANE_PAD}
    width = max(xr) + LANE_PAD + MARGIN

    routed = [route_edge(e, boxes, gutters) for e in edges_in]
    problems = find_crossings(routed, boxes)

    body: list[str] = []
    for n in nodes:
        body += shape_svg(n, boxes[n["id"]])
    for r in routed:
        body += r["svg"]

    h = lay["h"]
    head = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{h:.0f}" '
        f'viewBox="0 0 {width:.0f} {h:.0f}" '
        f'font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif">',
        '<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
        f'markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" '
        f'fill="{STROKE}"/></marker></defs>',
        f'<rect width="{width:.0f}" height="{h:.0f}" fill="#ffffff"/>',
        f'<text x="{MARGIN}" y="46" fill="{INK}" font-size="{TITLE_FONT}" '
        f'font-weight="700">{esc(spec.get("title", ""))}</text>',
    ]
    if spec.get("subtitle"):
        head.append(f'<text x="{MARGIN}" y="72" fill="{MUTED}" font-size="14">'
                    f'{esc(spec["subtitle"])}</text>')
    tail = []
    if spec.get("legend", True):
        tail += legend_svg(h - MARGIN / 2 - 4, MARGIN)
    tail.append(
        f'<text x="{width - MARGIN:.0f}" y="{h - 14:.0f}" fill="{MUTED}" font-size="12" '
        f'text-anchor="end">generated from {esc(spec.get("_spec_name", "spec"))} '
        f'&#8212; do not edit by hand</text>')
    return "\n".join([*head, *body, *tail, "</svg>"]), problems


def default_output(spec: dict, spec_path: Path) -> Path:
    name = spec.get("output") or f"{re.sub(r'[^a-z0-9]+', '-', spec_path.stem).strip('-')}.svg"
    try:
        roots = json.loads(ROOTS_JSON.read_text(encoding="utf-8"))
        first = next(r for r in roots if isinstance(r, str) and r.strip())
    except Exception:
        first = str(HERE.parents[1] / "diagrams")
    return Path(first).expanduser() / name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec", nargs="?", default=str(SPEC_DIR / "rx-path.json"),
                    help="flowchart spec JSON (default: flowcharts/rx-path.json)")
    ap.add_argument("-o", "--out", type=Path, default=None)
    ap.add_argument("--allow-crossings", action="store_true",
                    help="write the SVG even if edge segments cross shapes")
    args = ap.parse_args()

    spec_path = Path(args.spec)
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    spec["_spec_name"] = spec_path.name
    svg, problems = build(spec)

    out = args.out or default_output(spec, spec_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(f".{out.name}.part")
    tmp.write_text(svg, encoding="utf-8")
    tmp.replace(out)
    print(f"wrote {out} ({len(svg)} bytes, {len(spec['nodes'])} nodes, "
          f"{len(spec.get('edges', []))} edges)")

    if problems:
        for p in problems:
            print(f"WARN: {p}", file=sys.stderr)
        if not args.allow_crossings:
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
