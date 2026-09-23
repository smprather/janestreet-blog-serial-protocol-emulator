#!/usr/bin/env python3
"""Check flow/pe_soc.json's macro hardening metadata against the RTL netlist.

WHY THIS EXISTS (E2). The SoC instantiates TWO SRAM macros -- instruction
memory (`u_imem.g_macro.u_sram`) and frame buffer (`u_eth_fbuf.g_macro.u_sram`)
-- but the flow config listed only the instruction macro. LibreLane's manual
macro placement consumes configured instances only, and the macro's supplies
(`VDD!`/`VSS!`/`VDDARRAY!` on Metal4) are not covered by the standard-cell
power defaults (`VPWR`/`VGND`). So the frame buffer would have been left
unplaced and unpowered, and nothing in simulation would have noticed.

This gate derives the macro instance set from the ELABORATED SoC, the macro
geometry from the vendor LEF, and the die from the config, and requires the
config to be complete and legal:

  1. every hard-macro cell in the flattened netlist is named in
     `MACROS[type].instances`, and vice versa;
  2. every instance has hooks for all three supply pins (`VDD!`, `VDDARRAY!`,
     `VSS!`) in `PDN_MACRO_CONNECTIONS`;
  3. every placement fits inside `DIE_AREA`, and no two macros overlap
     (a 10 um gap is required);
  4. `PDN_CFG` is set, exists, and builds the Metal4 ladder the macro supplies
     need.

Placement checks that need the PDK LEF are skipped loudly -- not silently
passed -- when the LEF is absent.

    python3 tools/checks/macro_flow_config.py
    exit 0 = complete and legal, 1 = findings, 2 = could not run

No physical flow, DRC or LVS: yosys elaboration plus static file checks only.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FLOW = REPO / "flow" / "pe_soc.json"
LEF = (Path.home() / "pdk" / "IHP-Open-PDK" / "ihp-sg13g2" / "libs.ref"
       / "sg13g2_sram" / "lef" / "RM_IHPSG13_1P_1024x16_c2_bm_bist.lef")
GAP_UM = 10.0

# The same source list the flow config and synth_area carry, so the netlist
# this gate sees is the netlist the flow would elaborate.
RTL = [
    "rtl/pe_cpu.v", "rtl/pe_imem.v", "rtl/pe_pinmux.v", "rtl/pe_dru.v",
    "rtl/pe_manch.v", "rtl/pe_crc.v", "rtl/pe_eth_mac.v", "rtl/pe_fbuf.v",
    "rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v", "rtl/pe_soc.v",
]


def fail(problems: list[str], msg: str) -> None:
    problems.append(msg)


def macro_cells() -> dict[str, str]:
    """{instance path: macro type} for the flattened pe_soc netlist."""
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "flat.json"
        script = ("read_verilog -sv " + " ".join(RTL)
                  + "; hierarchy -check -top pe_soc; proc; flatten; "
                  + f"write_json {out}")
        proc = subprocess.run(["yosys", "-q", "-p", script],
                              cwd=REPO, capture_output=True, text=True)
        if proc.returncode != 0 or not out.exists():
            print("macro flow config: yosys elaboration failed", file=sys.stderr)
            print(proc.stderr[-2000:], file=sys.stderr)
            sys.exit(2)
        data = json.loads(out.read_text())
    cells = data["modules"]["pe_soc"]["cells"]
    return {name: cell["type"] for name, cell in cells.items()
            if "IHPSG" in cell.get("type", "")}


def lef_size() -> tuple[float, float] | None:
    if not LEF.is_file():
        return None
    m = re.search(r"SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)\s*;", LEF.read_text())
    if not m:
        return None
    return float(m.group(1)), float(m.group(2))


def main() -> int:
    problems: list[str] = []
    cfg = json.loads(FLOW.read_text())

    macros = macro_cells()
    if not macros:
        fail(problems, "no RM_IHPSG macro cells found in the elaborated pe_soc")
    print(f"netlist macro instances: {len(macros)} "
          f"({', '.join(sorted(macros))})")

    macros_cfg = cfg.get("MACROS", {})
    pdn = cfg.get("PDN_MACRO_CONNECTIONS", [])

    # 1 + 2: every netlist macro is configured, with all three supply pins,
    # and every configured instance exists in the netlist.
    seen_names: set[str] = set()
    for name, mtype in sorted(macros.items()):
        seen_names.add(name)
        if mtype not in macros_cfg:
            fail(problems, f"{name}: macro type {mtype} is not in MACROS")
            continue
        inst_cfg = macros_cfg[mtype].get("instances", {})
        if name not in inst_cfg:
            fail(problems, f"{name}: no placement in MACROS[{mtype}].instances")
        escaped = re.escape(name)
        entries = [e for e in pdn if e.split()[0] == escaped]
        if not entries:
            fail(problems, f"{name}: no PDN_MACRO_CONNECTIONS entry "
                           f"(supplies would be unconnected)")
        pins = {tok for e in entries for tok in e.split()[3:5]}
        for pin in ("VDD!", "VDDARRAY!", "VSS!"):
            if pin not in pins:
                fail(problems, f"{name}: supply pin {pin} has no global "
                               f"connection (PDN-0189/PSM-0069)")

    for mtype, spec in macros_cfg.items():
        for name in spec.get("instances", {}):
            if name not in seen_names:
                fail(problems, f"MACROS[{mtype}].instances names {name}, "
                               f"which is not in the elaborated netlist")

    # 3: placement geometry.
    size = lef_size()
    if size is None:
        print("placement check: SKIPPED (macro LEF not found at "
              f"{LEF}); instance/supply checks still ran")
    else:
        w, h = size
        die = cfg.get("DIE_AREA")
        if not die or len(die) != 4:
            fail(problems, "DIE_AREA is missing or not [x0, y0, x1, y1]")
        else:
            x0, y0, x1, y1 = (float(v) for v in die)
            placed: list[tuple[str, float, float]] = []
            for mtype, spec in macros_cfg.items():
                for name, ispec in spec.get("instances", {}).items():
                    loc = ispec.get("location")
                    orient = ispec.get("orientation", "N")
                    if not loc or len(loc) != 2:
                        fail(problems, f"{name}: placement has no [x, y]")
                        continue
                    x, y = float(loc[0]), float(loc[1])
                    if orient != "N":
                        fail(problems, f"{name}: orientation {orient} is not "
                                       f"checked; keep N or extend this gate")
                    if x < x0 or y < y0 or x + w > x1 or y + h > y1:
                        fail(problems, f"{name}: {w}x{h} at ({x},{y}) is not "
                                       f"inside DIE_AREA {die}")
                    placed.append((name, x, y))
            for i in range(len(placed)):
                for j in range(i + 1, len(placed)):
                    n1, a, b = placed[i]
                    n2, c, d = placed[j]
                    overlap = not (c >= a + w + GAP_UM or
                                   a >= c + w + GAP_UM or
                                   d >= b + h + GAP_UM or
                                   b >= d + h + GAP_UM)
                    if overlap:
                        fail(problems, f"{n1} and {n2} are closer than the "
                                       f"{GAP_UM} um placement gap")

    # 4: the PDN config exists and still builds the Metal4 ladder.
    pdn_cfg = cfg.get("PDN_CFG")
    if not pdn_cfg:
        fail(problems, "PDN_CFG is not set; the macro Metal4 supplies would "
                       "have no physical path")
    else:
        # The config names the STAGED path (./src/...); run_librelane.sh copies
        # flow/<name> there, so resolve the basename under flow/ first.
        name = Path(pdn_cfg).name
        candidates = [REPO / "flow" / name, REPO / name]
        p = next((c for c in candidates if c.is_file()), candidates[0])
        if not p.is_file():
            fail(problems, f"PDN_CFG {pdn_cfg} does not exist (looked for "
                           f"{p})")
        else:
            text = p.read_text()
            if "-layer Metal4" not in text or "Metal4" not in text:
                fail(problems, f"{pdn_cfg} no longer stripes/connects Metal4; "
                               f"the macro supplies come out on Metal4")

    if problems:
        print("macro flow config: FAILED")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("macro flow config: OK (placements and supply hooks complete)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
