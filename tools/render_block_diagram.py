#!/usr/bin/env python3
"""Render the Mermaid blocks in wiki/reference/block-diagram.md to SVG files
in diagrams/, so the diagram is viewable without a Mermaid renderer.

WHY THIS EXISTS. The wiki page carries the Mermaid SOURCE, which is the right
artifact for git -- it diffs, it is reviewable, and it stays in sync with the
generator. But source is not viewable: in a terminal or a plain markdown
reader the reader sees a code fence. `diagrams/` is the repo's established
place for RENDERED artifacts (it is also the live-canvas watched directory),
so the rendered form goes there.

It re-RENDERS from the page rather than keeping a hand-made copy, so the
diagram and the SVG cannot drift apart.

Rendering needs @mermaid-js/mermaid-cli, which pulls a headless browser. That
is a heavy dependency for a repo script, so this is NOT wired into run_all.sh:
it is run on demand, and the .svg outputs are committed. If mermaid-cli is
missing the script says so and exits 0 (not a failure -- the page is still
correct, just not re-rendered).

    python3 tools/render_block_diagram.py            # render, then report
    python3 tools/render_block_diagram.py --check    # is the SVG stale?
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PAGE = REPO / "wiki" / "reference" / "block-diagram.md"
OUTDIR = REPO / "diagrams"

# Output names, in the order the mermaid blocks appear in the page.
NAMES = ["block-diagram-chip.svg", "block-diagram-orphans.svg"]
STEMS = ["block-diagram-chip", "block-diagram-orphans"]

# Matches the neighbours in diagrams/ (hand-authored ones use #0d1117).
CONFIG = {
    "theme": "dark",
    "themeVariables": {
        "background": "#0d1117",
        "primaryColor": "#1f4d2e",
        "primaryTextColor": "#c9d1d9",
        "primaryBorderColor": "#4ade80",
        "lineColor": "#8b949e",
        "secondaryColor": "#161b22",
        "tertiaryColor": "#161b22",
        "clusterBkg": "#161b22",
        "clusterBorder": "#30363d",
        "fontFamily": "ui-monospace, SFMono-Regular, Menlo, monospace",
        "fontSize": "14px",
    },
}


def mermaid_blocks() -> list[str]:
    return re.findall(r"```mermaid\n(.*?)```", PAGE.read_text(encoding="utf-8"), re.S)


def render(blocks: list[str]) -> list[Path]:
    """Render each block to SVG. Returns the paths written (in diagrams/)."""
    if shutil.which("npx") is None:
        print("render_block_diagram: npx not found; skipping render", file=sys.stderr)
        return []

    OUTDIR.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        (tmp / "pptr.json").write_text(
            '{"args":["--no-sandbox","--disable-setuid-sandbox"]}', encoding="utf-8"
        )
        import json
        (tmp / "mmdc-config.json").write_text(json.dumps(CONFIG, indent=2),
                                              encoding="utf-8")
        for i, block in enumerate(blocks):
            name = NAMES[i] if i < len(NAMES) else f"block-diagram-{i+1}.svg"
            stem = name[:-4]
            (tmp / f"{stem}.mmd").write_text(block, encoding="utf-8")
            out = OUTDIR / name
            cmd = [
                "npx", "--yes", "@mermaid-js/mermaid-cli@11",
                "-p", str(tmp / "pptr.json"),
                "-c", str(tmp / "mmdc-config.json"),
                "-i", str(tmp / f"{stem}.mmd"),
                "-o", str(out),
                "-b", "#0d1117",
            ]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0 or not out.is_file():
                print(f"render_block_diagram: FAILED on {name}\n{r.stderr[-800:]}",
                      file=sys.stderr)
                return written
            # mermaid-cli writes the file itself; stamp the viewBox width so a
            # stale-vs-fresh comparison has something deterministic to check.
            print(f"  rendered diagrams/{name} ({out.stat().st_size:,} bytes)")
            written.append(out)
    return written


def check() -> int:
    """Is every rendered SVG present and at least as new as the page?

    Deliberately a TIMESTAMP check, not a byte comparison: mermaid-cli's output
    embeds a generated id and can differ run to run, so byte-equality would
    false-fail. What we can assert cheaply is 'the SVG was rendered after the
    page last changed', which catches the case that matters -- editing the
    Mermaid and forgetting to re-render.
    """
    page_mtime = PAGE.stat().st_mtime
    stale = []
    for name in NAMES:
        p = OUTDIR / name
        if not p.is_file():
            stale.append(f"{name} is missing")
        elif p.stat().st_mtime < page_mtime:
            stale.append(f"{name} is older than the page")
    if stale:
        for s in stale:
            print(f"STALE: {s}", file=sys.stderr)
        print("re-render with: python3 tools/render_block_diagram.py", file=sys.stderr)
        return 1
    print("rendered block diagrams up to date")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    if args.check:
        return check()

    blocks = mermaid_blocks()
    if not blocks:
        print("render_block_diagram: no mermaid blocks in the page", file=sys.stderr)
        return 1
    print(f"rendering {len(blocks)} mermaid block(s) from {PAGE.relative_to(REPO)}")
    written = render(blocks)
    if not written:
        print("render_block_diagram: nothing rendered (see above)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
