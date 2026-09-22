#!/usr/bin/env python3
"""Guard the Live Canvas viewer's intrinsic-size and fit arithmetic.

WHY THIS EXISTS. The pane rendered most mermaid diagrams as a blank stage until
the user clicked Fit. Two independent defects, both found by measurement after
visual inspection:

  A. Percent width mis-parsed. The viewer read the SVG's intrinsic size with
     parseFloat(svg.getAttribute('width')). Mermaid emits width="100%", and
     parseFloat("100%") returns 100 -- a truthy number -- so the viewBox
     fallback never fired and the viewer believed the drawing was 100 px wide
     instead of its viewBox width. Every derived scale was wrong by that ratio:
     the fit box, the reported fit ratio, and the 100% button.

  B. The initial apply raced layout. The iframe is created by the pane and React
     commits its geometry AFTER the srcdoc has parsed, so the first apply saw a
     zero-width wrap and, via `wrap.clientWidth || 1`, sized the drawing to a
     1 px sliver. Nothing re-measured, because only the WINDOW resize was
     observed -- and that does not fire when an iframe is resized by its parent.
     The stage then looked blank until Fit was clicked.

HOW IT CHECKS. It does not paraphrase the viewer. It extracts the shipped
FRAME_SCRIPT from the plugin, runs it in node against a DOM stub with a known
pane width, and reads what the script actually decided. Then it mutates the
script back to each pre-fix form and requires the check to FAIL -- a guard that
cannot fail is indistinguishable from a guard that passes, and an earlier draft
of this file proved the point by silently passing the very bug it was written
for (a Python re-implementation of the *fixed* arithmetic cannot detect a JS
regression).

Run: python3 tools/check_canvas_viewer.py
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
SRC = REPO / "tools/live-canvas/dashboard/dist/index.js"

# The pane's measured geometry, from the live dashboard over CDP.
PANE_W = 741

HARNESS = r"""
// Runs the REAL viewer script against a DOM stub and reports what it decided.
// argv: svgPath paneW mode(measured|unmeasured) scriptPath
var fs = require('fs');
var svgPath = process.argv[2];
var paneW = parseInt(process.argv[3], 10);
var unmeasured = process.argv[4] === 'unmeasured';
var scriptPath = process.argv[5];

var raw = fs.readFileSync(svgPath, 'utf8');
var tagMatch = raw.match(/<svg\b[^>]*>/);
var tag = tagMatch ? tagMatch[0] : '';
var attrs = {};
var re = /([\w:-]+)="([^"]*)"/g;
var m;
while ((m = re.exec(tag))) { attrs[m[1]] = m[2]; }

var setCalls = [];
var posted = [];
function makeEl(a) {
  var at = Object.assign({}, a);
  return {
    style: {},
    clientWidth: unmeasured ? 0 : paneW,
    clientHeight: unmeasured ? 0 : 452,
    scrollLeft: 0,
    scrollTop: 0,
    getAttribute: function (k) { return (k in at) ? at[k] : null; },
    setAttribute: function (k, v) { at[k] = String(v); setCalls.push([k, String(v)]); },
    addEventListener: function () {},
    getBoundingClientRect: function () { return { width: 0, height: 0, x: 0, y: 0 }; },
    querySelector: function () { return null; }
  };
}
var svg = makeEl(attrs);
var wrap = makeEl({});
var document = { getElementById: function () { return wrap; },
                 querySelector: function () { return svg; } };
var window = { addEventListener: function () {} };
var parent = { postMessage: function (msg) { posted.push(msg); } };

var code = fs.readFileSync(scriptPath, 'utf8');
code = code.replace('__LC_VIEW__', JSON.stringify({ mode: 'fit', scale: 1 }));
eval(code);

var out = { setWidthCalls: [], fit: null,
            widthAttr: svg.getAttribute('width'),
            heightAttr: svg.getAttribute('height'),
            fileWidth: ('width' in attrs) ? attrs['width'] : null,
            viewBox: attrs.viewBox || null };
for (var i = 0; i < setCalls.length; i++) {
  if (setCalls[i][0] === 'width') out.setWidthCalls.push(setCalls[i][1]);
}
for (var j = 0; j < posted.length; j++) {
  if (posted[j] && posted[j].type === 'lc-fit') out.fit = posted[j].value;
}
process.stdout.write(JSON.stringify(out));
"""


def extract_frame_script(src_text: str) -> str:
    """The shipped in-frame viewer script, verbatim."""
    start = src_text.index("var FRAME_SCRIPT = [")
    ob = src_text.index("[", start)
    end = src_text.index('].join("\\n");', ob)
    out = subprocess.run(
        ["node", "-e", "console.log(JSON.stringify(" + src_text[ob : end + 1] + "))"],
        capture_output=True, text=True, check=True,
    )
    return "\n".join(json.loads(out.stdout))


def run_case(script: str, svg: pathlib.Path, mode: str, tmp: pathlib.Path) -> dict:
    sp = tmp / "frame_script.js"
    sp.write_text(script)
    hp = tmp / "harness.js"
    hp.write_text(HARNESS)
    r = subprocess.run(
        ["node", str(hp), str(svg), str(PANE_W), mode, str(sp)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(r.stdout)


def viewbox_width(svg: pathlib.Path) -> float:
    m = re.search(r"<svg\b[^>]*>", svg.read_text())
    if m is None:
        return 0.0
    vb = dict(re.findall(r'([\w:-]+)="([^"]*)"', m.group(0))).get("viewBox", "")
    return float(re.split(r"[\s,]+", vb)[2])


def main() -> int:
    if shutil.which("node") is None:
        print("canvas viewer: SKIPPED (node not found)")
        return 0

    problems = []
    src_text = SRC.read_text()
    fs = extract_frame_script(src_text)
    svg = REPO / "diagrams/block-diagram-chip.svg"

    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)

        # --- 1. the shipped script must measure every diagram correctly -----
        print(f"  pane {PANE_W}px; running the shipped viewer script per diagram")
        for p in sorted((REPO / "diagrams").glob("*.svg")):
            vw = viewbox_width(p)
            got = run_case(fs, p, "measured", tmp)
            fit = got["fit"]
            implied = (PANE_W / fit) if fit else None
            ok = implied is not None and abs(implied - vw) < 1.5
            print(f"    {p.name:<28} fit={fit!s:<20} implies iw={implied and round(implied,1)!s:<9} viewBox={vw:.0f}  {'ok' if ok else 'WRONG'}")
            if not ok:
                problems.append(f"{p.name}: viewer implies iw={implied}, viewBox says {vw}")

        # --- 2. an unmeasured pane must NOT produce a degenerate size -------
        got = run_case(fs, svg, "unmeasured", tmp)
        ws = got["setWidthCalls"]
        degenerate = [w for w in ws if w and float(w) <= 1]
        print(f"    unmeasured-pane run: width calls={ws}  {'ok (refused)' if not degenerate else 'WRONG (sized to ' + degenerate[0] + 'px)'}")
        if degenerate:
            problems.append(f"fix B broken: sized to {degenerate[0]}px against an unmeasured pane")
        if got["fit"] is not None:
            problems.append("fix B broken: reported a fit ratio against an unmeasured pane")

        # --- 3. MUTATION TEST: each pre-fix form must be DETECTED -----------
        # Restore exactly the code as it was before each fix and require that
        # the checks above would have caught it.
        mut_a = fs.replace("= px(svg.getAttribute", "= num(svg.getAttribute")
        assert mut_a != fs, "mutation A did not apply — anchor changed"
        got = run_case(mut_a, svg, "measured", tmp)
        imp = (PANE_W / got["fit"]) if got["fit"] else None
        caught_a = imp is not None and abs(imp - viewbox_width(svg)) >= 1.5
        print(f"    mutation A (num instead of px): implies iw={imp and round(imp,1)}  "
              f"{'DETECTED' if caught_a else 'NOT DETECTED'}")
        if not caught_a:
            problems.append("the percent-width bug would NOT be detected")

        mut_b = fs.replace("return wrap.clientWidth || 0", "return wrap.clientWidth || 1")
        mut_b = mut_b.replace("if(pw <= 1) return;", "")
        assert mut_b != fs, "mutation B did not apply — anchor changed"
        got = run_case(mut_b, svg, "unmeasured", tmp)
        ws = got["setWidthCalls"]
        degenerate = [w for w in ws if w and float(w) <= 1]
        caught_b = bool(degenerate)
        print(f"    mutation B (1px floor, no guard): width calls={ws}  "
              f"{'DETECTED' if caught_b else 'NOT DETECTED'}")
        if not caught_b:
            problems.append("the layout-race bug would NOT be detected")

    print()
    if problems:
        print("FAIL:")
        for x in problems:
            print("  -", x)
        return 1
    print("canvas viewer: OK — measures every diagram correctly, survives neither mutation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
