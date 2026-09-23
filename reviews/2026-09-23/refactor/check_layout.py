#!/usr/bin/env python3
"""Exercise relocated entrypoints and stage/compile manifests without a flow run.

Uses the current checkout and locally installed PDK. All outputs go to /tmp.
The only code extracted from run_librelane.sh is its Python file-copy stage;
the shell launcher, Docker, and physical tools are never invoked.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[3]


def run(argv, cwd):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    result.check_returncode()


with tempfile.TemporaryDirectory(prefix="refactor-layout-", dir="/tmp") as tmp:
    scratch = Path(tmp)
    for path in sorted((ROOT / "tools/gen").glob("*.py")):
        print(f"From /tmp: {path.relative_to(ROOT)} --check", flush=True)
        run([sys.executable, str(path), "--check"], cwd=scratch)
    for name in ("canvas_viewer.py", "i2c_timing.py"):
        path = ROOT / "tools/checks" / name
        print(f"From /tmp: {path.relative_to(ROOT)}", flush=True)
        run([sys.executable, str(path)], cwd=scratch)

    # info.yaml currently has a quoted, one-path-per-line source_files list.
    # Fail explicitly if its schema changes instead of silently compiling less.
    info = (ROOT / "info.yaml").read_text()
    source_block = info.split("source_files:", 1)[1].split("pinout:", 1)[0]
    source_files = re.findall(r'^\s*-\s*"([^"]+\.v)"', source_block, re.M)
    if len(source_files) != 6:
        raise RuntimeError(f"unexpected info.yaml source list: {source_files}")
    run(["iverilog", "-g2012", "-s", "tt_um_protocol_emulator",
         "-o", str(scratch / "tt.vvp"),
         *[str(ROOT / name) for name in source_files]], cwd=scratch)
    print(f"Tiny Tapeout: {len(source_files)} sources; compile PASS", flush=True)

    launcher = (ROOT / "flow/run_librelane.sh").read_text()
    stage_code = launcher.split("<<'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
    pdk_root = Path(os.environ.get("PDK_ROOT", str(Path.home() / ".ciel")))
    for config in sorted((ROOT / "flow").glob("*.json")):
        spec = json.loads(config.read_text())
        out = scratch / config.stem
        (out / "src").mkdir(parents=True)
        print(f"Stage only: {config.relative_to(ROOT)}", flush=True)
        run([sys.executable, "-c", stage_code,
             str(config), str(out), str(pdk_root)], cwd=ROOT)
        entries = spec.get("VERILOG_FILES", []) + spec.get("EXTRA_VERILOG_MODELS", [])
        staged_sources = []
        for entry in entries:
            name = Path(entry).name
            original, = (ROOT / "rtl").rglob(name)
            staged = out / "src" / name
            if staged.read_bytes() != original.read_bytes():
                raise RuntimeError(f"staging changed {name}")
            staged_sources.append(str(staged))
        run(["iverilog", "-g2012", "-s", spec["DESIGN_NAME"],
             "-o", str(out / "design.vvp"), *staged_sources], cwd=out)
        print(f"{config.name}: {len(entries)} sources; staged bytes identical; "
              "compile PASS", flush=True)

print("Layout checks PASS; no physical flow, DRC, or LVS invoked.")
