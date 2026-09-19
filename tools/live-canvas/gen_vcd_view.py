#!/usr/bin/env python3
"""Render a window of a VCD as a labelled timing/flow diagram (SVG).

The point is teaching, not waveform browsing: a VCD shows *what* the wires did,
this shows *why* — which edge committed which value, where the strobe lands, and
what each column of the transfer means.

    python3 gen_vcd_view.py --vcd sim/tb_pe_uart.vcd \
        --signals line,bit_en,tx_load,tx_busy,tx_ser,rx_ser,rx_busy,rx_valid \
        --from 250000 --to 500000 --title "UART TX: one byte, 8N1"

Time is in the VCD's own units scaled to the diagram; ``--from``/``--to`` are
VCD time ticks (the TBs use 1 ns, dumped with a 1 ps timescale).

Only the four VCD value codes that matter here are supported: ``0/1/x/z`` scalar
and ``b<bits>`` vectors (vectors are shown as hex, plus decimal in the label).

The renderer refuses to lie: it draws the *sampled* value of every signal on
every clock edge it can find (from ``--clock``), so a signal that is only valid
mid-cycle is visibly so, and an edge that commits nothing is visibly flat.
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOTS_JSON = HERE / "canvas_roots.json"

# --- palette -----------------------------------------------------------------
INK = "#1f2328"
MUTED = "#57606a"
GRID = "#e6e8eb"
EDGE_COL = "#c9ced6"      # clock edge ticks
WAVE_HI = "#2da44e"
WAVE_LO = "#8c959f"
WAVE_X = "#cf222e"
WIRE = "#d0d7de"
FILL_WINDOW = "#fff8c5"   # the highlighted decision window
COMMIT = "#0969da"        # the committing-edge marker
STROBE = "#8250df"        # the strobe marker

ROW_H = 44.0
LABEL_W = 168.0
PAD_L = 22.0
PAD_T = 118.0             # title + subtitle + optional note
PAD_R = 30.0
PAD_B = 26.0
FONT = 15.0
SMALL = 12.5
TICK_TOP = 14.0

CHAR_W = 0.545


def esc(text: str) -> str:
    out = []
    for ch in str(text):
        out.append(html.escape(ch) if ord(ch) < 128 else f"&#{ord(ch)};")
    return "".join(out)


def tw(text: str, font: float = FONT) -> float:
    """Approximate rendered text width."""
    return len(str(text)) * CHAR_W * font


# ---------------------------------------------------------------------------
# VCD parsing (just enough for these TBs)
# ---------------------------------------------------------------------------

class Vcd:
    def __init__(self, path: Path):
        self.path = path
        self.syms: dict[str, str] = {}        # symbol -> "scope.name"
        self.widths: dict[str, int] = {}
        self.changes: dict[str, list[tuple[int, str]]] = {}
        self._parse()

    def _parse(self) -> None:
        scope: list[str] = []
        in_defs = True
        t = 0
        for raw in self.path.read_text(errors="replace").splitlines():
            line = raw.strip()
            if not line:
                continue
            if in_defs:
                if line.startswith("$scope"):
                    scope.append(line.split()[2])
                elif line.startswith("$upscope"):
                    scope.pop() if scope else None
                elif line.startswith("$var"):
                    parts = line.split()
                    # $var wire 1 ! name $end   (type width sym name ...)
                    w, sym, name = int(parts[2]), parts[3], parts[4]
                    key = ".".join([*scope, name])
                    self.syms[sym] = key
                    self.widths[sym] = w
                    self.changes.setdefault(sym, [(0, "x")])
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue

            if line[0] == "#":
                t = int(line[1:])
            elif line[0] == "b":
                val, sym = line[1:].split()
                self.changes.setdefault(sym, [(0, "x")]).append((t, val))
            elif line[0] in "01xzXZ":
                self.changes.setdefault(line[1:], [(0, "x")]).append((t, line[0]))

    def resolve(self, name: str) -> str:
        """Symbol for a signal name; exact dotted path or unique leaf."""
        for sym, key in self.syms.items():
            if key == name:
                return sym
        hits = [sym for sym, key in self.syms.items() if key.split(".")[-1] == name]
        if len(hits) == 1:
            return hits[0]
        if not hits:
            sys.exit(f"gen_vcd_view: no signal named {name!r} in {self.path}")
        sys.exit(f"gen_vcd_view: {name!r} is ambiguous ({len(hits)} matches)")

    def value_at(self, sym: str, t: int) -> str:
        last = "x"
        for ct, val in self.changes.get(sym, [(0, "x")]):
            if ct > t:
                break
            last = val
        return last

    def edges(self, sym: str, lo: int, hi: int, rising: bool = True) -> list[int]:
        out = []
        prev = self.value_at(sym, lo - 1)
        for ct, val in self.changes.get(sym, []):
            if ct < lo:
                prev = val
                continue
            if ct > hi:
                break
            if rising and prev in "0x" and val == "1":
                out.append(ct)
            elif not rising and prev == "1" and val in "0x":
                out.append(ct)
            prev = val
        return out


def hexval(raw: str) -> str:
    if any(c in "xzXZ" for c in raw):
        return "x"
    try:
        return f"0x{int(raw, 2):X}"
    except ValueError:
        return "x"


def wave_level(raw: str) -> str:
    """'1' | '0' | 'x' — and for vectors, a stable non-x reads as a level band."""
    if raw in ("1", "0"):
        return raw
    if raw in "xzXZ":
        return "x"
    return "v"  # vector


# ---------------------------------------------------------------------------
# drawing
# ---------------------------------------------------------------------------

def build(args) -> str:
    vcd = Vcd(Path(args.vcd))
    clock_sym = vcd.resolve(args.clock)
    sigs = [s.strip() for s in args.signals.split(",") if s.strip()]
    syms = [vcd.resolve(s) for s in sigs]

    lo, hi = args.start, args.end
    if hi <= lo:
        sys.exit("gen_vcd_view: --to must be greater than --from")

    clock_edges = vcd.edges(clock_sym, lo, hi, rising=True)
    if not clock_edges:
        sys.exit(f"gen_vcd_view: no rising edges of {args.clock!r} in "
                 f"[{lo}, {hi}] — is this the right window?")
    step = clock_edges[1] - clock_edges[0] if len(clock_edges) > 1 else 1

    plot_w = max(360.0, (hi - lo) / step * args.px_per_edge)
    width = PAD_L + LABEL_W + plot_w + PAD_R
    height = PAD_T + len(sigs) * ROW_H + PAD_B

    def x_of(t: int) -> float:
        return PAD_L + LABEL_W + (t - lo) / (hi - lo) * plot_w

    out: list[str] = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}" '
        f'viewBox="0 0 {width:.0f} {height:.0f}" '
        f'font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif">',
        f'<rect width="{width:.0f}" height="{height:.0f}" fill="#ffffff"/>',
        f'<text x="{PAD_L}" y="44" fill="{INK}" font-size="22" font-weight="700">'
        f'{esc(args.title)}</text>',
    ]
    if args.subtitle:
        out.append(f'<text x="{PAD_L}" y="70" fill="{MUTED}" font-size="14">'
                   f'{esc(args.subtitle)}</text>')

    # highlighted decision window (drawn under everything)
    if args.window:
        w_lo, w_hi = (int(v) for v in args.window.split(","))
        out.append(f'<rect x="{x_of(w_lo):.1f}" y="{PAD_T - 10:.1f}" '
                   f'width="{x_of(w_hi) - x_of(w_lo):.1f}" height="{len(sigs)*ROW_H + 10:.1f}" '
                   f'fill="{FILL_WINDOW}" opacity="0.55"/>')

    # clock-edge gridlines + tick labels
    every = max(1, int(len(clock_edges) / max(1, args.max_ticks)))
    for i, t in enumerate(clock_edges):
        x = x_of(t)
        major = (i % every == 0)
        out.append(f'<line x1="{x:.1f}" y1="{PAD_T - TICK_TOP:.1f}" x2="{x:.1f}" '
                   f'y2="{height - PAD_B:.1f}" stroke="{EDGE_COL if major else GRID}" '
                   f'stroke-width="{1.2 if major else 0.8}"/>')
        if major:
            # Keep the label inside the canvas: the last ticks would otherwise
            # clip against the right margin.
            anchor = "end" if x > width - PAD_R - 40 else "start"
            dx = -4 if anchor == "end" else 4
            out.append(f'<text x="{x + dx:.1f}" y="{PAD_T - TICK_TOP - 4:.1f}" '
                       f'fill="{MUTED}" font-size="11" text-anchor="{anchor}">#{i}</text>')

    # marker verticals (strobe / committing edge), with labelled callouts
    for spec, colour, default_label in (
        (args.commit, COMMIT, "committing edge"),
        (args.strobe, STROBE, "strobe"),
    ):
        if not spec:
            continue
        name, _, label = spec.partition("=")
        label = label or default_label
        for t in vcd.edges(vcd.resolve(name.strip()), lo, hi, rising=True):
            x = x_of(t)
            out.append(f'<line x1="{x:.1f}" y1="{PAD_T - 6:.1f}" x2="{x:.1f}" '
                       f'y2="{height - PAD_B:.1f}" stroke="{colour}" stroke-width="2" '
                       f'stroke-dasharray="5 4"/>')
            lx = min(x + 5, width - PAD_R - tw(label, SMALL) - 6)
            out.append(f'<rect x="{lx - 3:.1f}" y="{PAD_T - 30:.1f}" '
                       f'width="{tw(label, SMALL) + 6:.1f}" height="16" fill="#ffffff" opacity="0.95"/>')
            out.append(f'<text x="{lx:.1f}" y="{PAD_T - 18:.1f}" fill="{colour}" '
                       f'font-size="{SMALL}" font-weight="600">{esc(label)}</text>')

    # signal rows: sample at every clock edge, draw the sampled value as a step
    for r, (name, sym) in enumerate(zip(sigs, syms)):
        y = PAD_T + r * ROW_H
        mid = y + ROW_H / 2
        hi_y, lo_y = mid - 11, mid + 11
        out.append(f'<text x="{PAD_L}" y="{mid + 5:.1f}" fill="{INK}" font-size="{FONT}" '
                   f'font-weight="600">{esc(name)}</text>')
        wid = vcd.widths.get(sym, 1)
        out.append(f'<text x="{PAD_L + tw(name, FONT) + 8:.1f}" y="{mid + 5:.1f}" '
                   f'fill="{MUTED}" font-size="11">{wid}b</text>')
        out.append(f'<line x1="{PAD_L + LABEL_W - 10:.1f}" y1="{y:.1f}" '
                   f'x2="{width - PAD_R:.1f}" y2="{y:.1f}" stroke="{WIRE}" stroke-width="0.8"/>')

        # The clock is the timebase, not a sampled data line: sampled at its own
        # rising edges it would read a constant 1 and tell the reader nothing.
        # Draw its real transitions instead.
        if sym == clock_sym:
            prev_t = lo
            prev_v = vcd.value_at(sym, lo)
            for ct, val in vcd.changes.get(sym, []):
                if ct < lo or ct > hi:
                    continue
                out.append(f'<line x1="{x_of(prev_t):.1f}" y1="{hi_y if prev_v == "1" else lo_y:.1f}" '
                           f'x2="{x_of(ct):.1f}" y2="{hi_y if prev_v == "1" else lo_y:.1f}" '
                           f'stroke="{INK}" stroke-width="2.2"/>')
                out.append(f'<line x1="{x_of(ct):.1f}" y1="{lo_y:.1f}" x2="{x_of(ct):.1f}" '
                           f'y2="{hi_y:.1f}" stroke="{INK}" stroke-width="2.2"/>')
                prev_t, prev_v = ct, val
            out.append(f'<line x1="{x_of(prev_t):.1f}" y1="{hi_y if prev_v == "1" else lo_y:.1f}" '
                       f'x2="{x_of(hi):.1f}" y2="{hi_y if prev_v == "1" else lo_y:.1f}" '
                       f'stroke="{INK}" stroke-width="2.2"/>')
            continue

        # one point per clock edge: sample AFTER the edge (that is when an edge
        # has committed its new value)
        samples = [(t, vcd.value_at(sym, t)) for t in clock_edges]
        for i, (t, raw) in enumerate(samples):
            lvl = wave_level(raw)
            x0 = x_of(t)
            x1 = x_of(samples[i + 1][0]) if i + 1 < len(samples) else x_of(hi)
            if lvl == "1":
                out.append(f'<line x1="{x0:.1f}" y1="{hi_y:.1f}" x2="{x1:.1f}" y2="{hi_y:.1f}" '
                           f'stroke="{WAVE_HI}" stroke-width="2.4"/>')
                if i == 0 or wave_level(samples[i - 1][1]) != "1":
                    out.append(f'<line x1="{x0:.1f}" y1="{lo_y:.1f}" x2="{x0:.1f}" y2="{hi_y:.1f}" '
                               f'stroke="{WAVE_HI}" stroke-width="2.4"/>')
            elif lvl == "0":
                out.append(f'<line x1="{x0:.1f}" y1="{lo_y:.1f}" x2="{x1:.1f}" y2="{lo_y:.1f}" '
                           f'stroke="{WAVE_LO}" stroke-width="2.4"/>')
                if i == 0 or wave_level(samples[i - 1][1]) != "0":
                    out.append(f'<line x1="{x0:.1f}" y1="{hi_y:.1f}" x2="{x0:.1f}" y2="{lo_y:.1f}" '
                               f'stroke="{WAVE_LO}" stroke-width="2.4"/>')
            elif lvl == "x":
                out.append(f'<rect x="{x0:.1f}" y="{hi_y:.1f}" width="{max(2.0, x1 - x0):.1f}" '
                           f'height="{lo_y - hi_y:.1f}" fill="{WAVE_X}" opacity="0.35"/>')
            else:  # vector: a band between the rails, with its value printed when it changes
                out.append(f'<rect x="{x0:.1f}" y="{hi_y + 5:.1f}" width="{max(2.0, x1 - x0):.1f}" '
                           f'height="{lo_y - hi_y - 10:.1f}" fill="{WAVE_HI}" opacity="0.30" '
                           f'stroke="{WAVE_HI}" stroke-width="1"/>')
                if i == 0 or samples[i - 1][1] != raw:
                    out.append(f'<text x="{x0 + 3:.1f}" y="{mid + 4:.1f}" fill="{INK}" '
                               f'font-size="11" font-weight="600">{esc(hexval(raw))}</text>')

    # footer
    if args.note:
        out.append(f'<text x="{PAD_L}" y="{height - 8:.1f}" fill="{MUTED}" font-size="{SMALL}">'
                   f'{esc(args.note)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def default_output(name: str) -> Path:
    try:
        roots = json.loads(ROOTS_JSON.read_text(encoding="utf-8"))
        first = next(r for r in roots if isinstance(r, str) and r.strip())
    except Exception:
        first = str(HERE.parents[1] / "diagrams")
    return Path(first).expanduser() / name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vcd", required=True)
    ap.add_argument("--signals", required=True, help="comma-separated signal names")
    ap.add_argument("--from", dest="start", type=int, required=True)
    ap.add_argument("--to", dest="end", type=int, required=True)
    ap.add_argument("--clock", default="clk")
    ap.add_argument("--px-per-edge", type=float, default=34.0)
    ap.add_argument("--max-ticks", type=int, default=26, help="how many edges get a label")
    ap.add_argument("--title", default="")
    ap.add_argument("--subtitle", default="")
    ap.add_argument("--note", default="")
    ap.add_argument("--window", default="", help="lo,hi VCD ticks to highlight")
    ap.add_argument("--commit", default="", help="signal[=label] whose rising edge commits")
    ap.add_argument("--strobe", default="", help="signal[=label] marking the strobe")
    ap.add_argument("-o", "--out", type=Path, default=None)
    args = ap.parse_args()

    if not args.title:
        args.title = Path(args.vcd).stem
    svg = build(args)
    out = args.out or default_output(f"{Path(args.vcd).stem}-flow.svg")
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(f".{out.name}.part")
    tmp.write_text(svg, encoding="utf-8")
    tmp.replace(out)
    print(f"wrote {out} ({len(svg)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
