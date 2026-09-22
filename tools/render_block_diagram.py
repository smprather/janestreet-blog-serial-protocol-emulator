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
it is run on demand. The SVG outputs are disposable render artifacts and stay
git-ignored (diagrams/README.md's rule), but the SOURCE HASH is committed as
diagrams/block-diagram.stamp -- that is what makes `--check` work in a fresh
clone. A timestamp check against an ignored file can only fail there, and did:
`git archive HEAD` has no SVGs, so the regression reported STALE on a clone
that was byte-identical to the tree it came from.

    python3 tools/render_block_diagram.py            # render, then stamp
    python3 tools/render_block_diagram.py --check    # is the page unrendered?
"""

from __future__ import annotations

import argparse
import hashlib
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

# The committed fixture. It holds the hash of the mermaid SOURCE that the last
# render consumed, so `--check` is a content comparison that works anywhere --
# unlike the SVGs, which are disposable and git-ignored.
STAMP = OUTDIR / "block-diagram.stamp"

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


def source_hash(blocks: list[str]) -> str:
    """Deterministic hash of the mermaid source the SVGs were rendered from."""
    h = hashlib.sha256()
    for b in blocks:
        h.update(b.encode("utf-8"))
        h.update(b"\0")
    return h.hexdigest()


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
    # Stamp only after every block rendered: a partial render is not a state the
    # page may be checked against.
    if len(written) == len(blocks):
        STAMP.write_text(source_hash(blocks) + "\n", encoding="utf-8")
        print(f"  stamped diagrams/{STAMP.name} (sha256 of the mermaid source)")
    return written


def check() -> int:
    """Has the mermaid source changed since the last render?

    A CONTENT check against the committed stamp, not a timestamp check against
    the ignored SVGs. The stamp records the hash of the source the last render
    read, so `--check` catches the thing that matters -- editing the Mermaid
    and forgetting to re-render -- in a fresh clone, in CI, and on a machine
    with no mermaid-cli installed. The SVGs themselves are reported when
    missing but do not fail the check: diagrams/README.md defines them as
    disposable outputs, and a clone has never had them.
    """
    blocks = mermaid_blocks()
    if not blocks:
        print("STALE: no mermaid blocks found in block-diagram.md", file=sys.stderr)
        return 1
    want = source_hash(blocks)
    if not STAMP.is_file():
        print(f"STALE: diagrams/{STAMP.name} is missing -- this page has never "
              f"been rendered here", file=sys.stderr)
        print("re-render with: python3 tools/render_block_diagram.py", file=sys.stderr)
        return 1
    got = STAMP.read_text(encoding="utf-8").strip()
    if got != want:
        print("STALE: the mermaid source has changed since "
              f"diagrams/{STAMP.name} was written", file=sys.stderr)
        print("re-render with: python3 tools/render_block_diagram.py", file=sys.stderr)
        return 1
    missing = [n for n in NAMES if not (OUTDIR / n).is_file()]
    if missing:
        print(f"rendered block diagrams up to date (SVGs not present: "
              f"{', '.join(missing)} -- disposable outputs)")
    else:
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
    if len(written) != len(blocks):
        print(f"render_block_diagram: rendered {len(written)} of {len(blocks)} block(s)",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
