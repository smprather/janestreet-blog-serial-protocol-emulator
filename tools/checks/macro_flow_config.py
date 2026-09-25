#!/usr/bin/env python3
"""Check flow/pe_soc.json's macro hardening metadata against the RTL netlist.

WHY THIS EXISTS (E2). The SoC instantiates TWO SRAM macros -- instruction
memory (`u_imem.g_macro.u_sram`) and frame buffer (`u_eth_fbuf.g_macro.u_sram`)
-- but the flow config listed only the instruction macro. LibreLane's manual
macro placement consumes configured instances only, and the macro's supplies
(`VDD!`/`VSS!`/`VDDARRAY!` on Metal4) are not covered by the standard-cell
power defaults (`VPWR`/`VGND`). So the frame buffer would have been left
unplaced and unpowered, and nothing in simulation would have noticed.

This gate derives the macro instance set from the ELABORATED SoC, each
macro type's own LEF SIZE from the PDK, and the die from the config, and
requires the config to be complete and legal:

  1. every hard-macro cell in the flattened netlist is named in
     `MACROS[type].instances`, and vice versa;
  2. every instance has hooks for all three supply pins (`VDD!`, `VDDARRAY!`,
     `VSS!`) in `PDN_MACRO_CONNECTIONS`;
  3. every placement fits inside `DIE_AREA` against its own macro type's LEF
     SIZE, and no two macros overlap (a 10 um gap is required);
  4. `PDN_CFG` is set, exists, and builds the Metal4 ladder the macro supplies
     need;
  5. every configured macro type has nonempty `gds`/`lef`/`lib` views, every
     referenced view resolves to exactly one file of the matching class and
     extension in the PDK `sg13g2_sram` tree that `run_librelane.sh` stages
     from, and the `lib` keys cover the PVT corners the flow resolves
     (`DEFAULT_CORNER`/`STA_CORNERS`);
  6. each configured type's views belong to that type (E2-6): the `lef` view
     must declare `MACRO <type>` (fail-closed: a LEF with no MACRO
     declaration is a finding), and a `lib` view that declares cells must
     declare one for the type -- without this, a type configured with ANOTHER
     type's LEF passes and its instances are measured with the wrong `SIZE`;
  7. no single `lib` file may serve two required corners (R3): corner
     coverage is key-pattern based, so one file (or a `*` key) used to satisfy
     every corner and two corners would silently read the same timing data.

Placement geometry and the macro view tree cannot be established without the
PDK (no type LEF resolvable, or no `sg13g2_sram`/corner list), so that is an
explicit INCOMPLETE run that exits 2 -- a supported PDK-less regression skips
the PDK-dependent checks rather than failing. Every finding still fails
(exit 1) even when those assets are unavailable, and a Yosys elaboration
failure is a failure, not a skip. `--lef` overrides every type's LEF for the
policy tests.

    python3 tools/checks/macro_flow_config.py
    exit 0 = complete and legal
    exit 1 = findings, including a Yosys elaboration failure
    exit 2 = INCOMPLETE: the required PDK LEF geometry or view tree/corner
             list is unavailable and there are no other findings (skip)

No physical flow, DRC or LVS: yosys elaboration plus static file checks only.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FLOW = REPO / "flow" / "pe_soc.json"
GAP_UM = 10.0

# run_librelane.sh resolves every MACROS view through Ciel (PDK_ROOT, default
# ~/.ciel) and stages it by basename. The checker mirrors that resolution so a
# ./src/<name> entry is matched against a real PDK source, never the repo cwd.
PDK_ROOT = Path(os.environ.get("PDK_ROOT", str(Path.home() / ".ciel")))

# The same source list the flow config and synth_area carry, so the netlist
# this gate sees is the netlist the flow would elaborate.
RTL = [
    "rtl/pe_cpu.v", "rtl/pe_imem.v", "rtl/pe_pinmux.v", "rtl/pe_dru.v",
    "rtl/pe_manch.v", "rtl/pe_crc.v", "rtl/pe_eth_mac.v", "rtl/pe_fbuf.v",
    "rtl/pe_serdes.v", "rtl/pe_nrzi.v", "rtl/pe_bitstuff.v",
    "rtl/pe_codec_mux.v", "rtl/pe_eth_tx.v",
    "rtl/vendor/RM_IHPSG13_1P_1024x16_c2_bm_bist.bb.v", "rtl/pe_soc.v",
]


def fail(problems: list[str], msg: str) -> None:
    problems.append(msg)


def macro_cells(rtl: list[str]) -> dict[str, str]:
    """{instance path: macro type} for the flattened pe_soc netlist."""
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "flat.json"
        script = ("read_verilog -sv " + " ".join(rtl)
                  + "; hierarchy -check -top pe_soc; proc; flatten; "
                  + f"write_json {out}")
        proc = subprocess.run(["yosys", "-q", "-p", script],
                              cwd=REPO, capture_output=True, text=True)
        if proc.returncode != 0 or not out.exists():
            print("macro flow config: yosys elaboration failed", file=sys.stderr)
            print(proc.stderr[-2000:], file=sys.stderr)
            # An elaboration failure is a FAILURE, not a skip: the RTL list
            # did not elaborate, so nothing here has been checked.
            sys.exit(1)
        data = json.loads(out.read_text())
    cells = data["modules"]["pe_soc"]["cells"]
    return {name: cell["type"] for name, cell in cells.items()
            if "IHPSG" in cell.get("type", "")}


def lef_size(lef: Path) -> tuple[float, float] | None:
    if not lef.is_file():
        return None
    m = re.search(r"SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)\s*;", lef.read_text())
    if not m:
        return None
    return float(m.group(1)), float(m.group(2))


def find_sram_dir(pdk_root: Path) -> Path | None:
    """The sg13g2_sram tree run_librelane.sh stages macro views from."""
    for cand in sorted(pdk_root.rglob("sg13g2_sram")):
        if cand.is_dir() and (cand / "lib").is_dir():
            return cand
    return None


def find_stdcell_config(pdk_root: Path) -> Path | None:
    """The PDK's LibreLane stdcell config.tcl (the corner source of truth)."""
    for p in sorted(pdk_root.rglob("config.tcl")):
        if p.parent.name == "sg13g2_stdcell":
            return p
    return None


def required_corners(cfg: dict, pdk_root: Path) -> set[str] | None:
    """The flow's PVT corners: the config's own STA_CORNERS/DEFAULT_CORNER if
    set, else the PDK LibreLane config.tcl the flow resolves them from."""
    sta = cfg.get("STA_CORNERS")
    default = cfg.get("DEFAULT_CORNER")
    if isinstance(sta, str):
        sta = sta.split()
    if isinstance(sta, list):
        sta = [str(s) for s in sta]
    if isinstance(default, list):
        default = default[0] if default else None
    if sta is None or default is None:
        pdk_cfg = find_stdcell_config(pdk_root)
        if pdk_cfg is None:
            return None
        text = pdk_cfg.read_text()
        if sta is None:
            m = re.search(r"STA_CORNERS\)\s+\"(.*?)\"", text, re.S)
            sta = (re.sub(r"\\\s*\n", " ", m.group(1)).split()
                   if m else None)
        if default is None:
            m = re.search(r"DEFAULT_CORNER\)\s+\"([^\"]*)\"", text)
            default = m.group(1) if m else None
    if not sta or not default:
        return None
    return set(sta) | {default}


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--flow", type=Path, default=FLOW,
                    help=f"flow config to check (default: {FLOW})")
    ap.add_argument("--lef", type=Path, default=None,
                    help="override every macro type's LEF for geometry "
                         "(default: resolve each configured type's own lef "
                         "view under --pdk-root)")
    ap.add_argument("--pdk-root", type=Path, default=PDK_ROOT,
                    help=f"PDK root the macro views are staged from "
                         f"(default: {PDK_ROOT})")
    ap.add_argument("--rtl", nargs="+", default=RTL,
                    help="RTL source list to elaborate (default: the flow's "
                         "source list); for isolated two-macro tests")
    args = ap.parse_args()

    problems: list[str] = []
    unable_to_run = False
    flow = args.flow.resolve()
    cfg = json.loads(flow.read_text())

    macros = macro_cells(args.rtl)
    if not macros:
        fail(problems, "no RM_IHPSG macro cells found in the elaborated pe_soc")
    print(f"netlist macro instances: {len(macros)} "
          f"({', '.join(sorted(macros))})")

    macros_cfg = cfg.get("MACROS", {})
    pdn = cfg.get("PDN_MACRO_CONNECTIONS", [])

    # The flow's standard-cell power/ground nets. LibreLane's defaults are
    # VPWR/VGND; read the keys if this config ever overrides them, so the gate
    # checks the mapping against the nets the flow actually uses.
    pwr_net = cfg.get("VDD_NET", "VPWR")
    gnd_net = cfg.get("GND_NET", "VGND")

    # 1 + 2: every netlist macro is configured, with all three supply pins
    # MAPPED to the right net (E2-1: the pin names alone are not the claim --
    # a power pin bound to the ground net keeps every name and used to pass),
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
        entries = [e for e in pdn if e.split() and e.split()[0] == escaped]
        if not entries:
            fail(problems, f"{name}: no PDN_MACRO_CONNECTIONS entry "
                           f"(supplies would be unconnected)")
        pins: set[str] = set()
        for entry in entries:
            toks = entry.split()
            if len(toks) != 5:
                fail(problems, f"{name}: malformed PDN_MACRO_CONNECTIONS "
                               f"entry {entry!r} (want 5 fields: instance "
                               f"power_net ground_net power_pin ground_pin)")
                continue
            _, e_pwr_net, e_gnd_net, e_pwr_pin, e_gnd_pin = toks
            pins.update((e_pwr_pin, e_gnd_pin))
            if e_pwr_net != pwr_net:
                fail(problems, f"{name}: power pin {e_pwr_pin} is bound to "
                               f"{e_pwr_net}, expected {pwr_net}")
            if e_gnd_net != gnd_net:
                fail(problems, f"{name}: ground pin {e_gnd_pin} is bound to "
                               f"{e_gnd_net}, expected {gnd_net}")
            if e_pwr_pin not in ("VDD!", "VDDARRAY!"):
                fail(problems, f"{name}: {e_pwr_pin} is not a macro power pin "
                               f"in the power slot")
            if e_gnd_pin != "VSS!":
                fail(problems, f"{name}: {e_gnd_pin} is not the macro ground "
                               f"pin in the ground slot")
        for pin in ("VDD!", "VDDARRAY!", "VSS!"):
            if pin not in pins:
                fail(problems, f"{name}: supply pin {pin} has no global "
                               f"connection (PDN-0189/PSM-0069)")

    for mtype, spec in macros_cfg.items():
        for name in spec.get("instances", {}):
            if name not in seen_names:
                fail(problems, f"MACROS[{mtype}].instances names {name}, "
                               f"which is not in the elaborated netlist")

    # 5: macro views (E2-4). Structural findings -- a missing/empty view list,
    # a path that is not './src/<name>', a view of the wrong type, or a lib
    # key missing for a required corner -- fail even when the PDK tree is
    # absent. A gds entry must be a .gds under sg13g2_sram/gds/, lef a .lef
    # under lef/, lib a .lib under lib/ (the class, not just the basename: a
    # lib file renamed into the lef slot must not pass). The corner list is
    # resolved from the flow config or the PDK's LibreLane config.tcl.
    sram_dir = find_sram_dir(args.pdk_root)
    corners = required_corners(cfg, args.pdk_root)
    # E2-5: each type's resolved lef view, so its own SIZE drives its
    # instances' fit/gap checks instead of one hard-coded LEF.
    type_lef: dict[str, Path] = {}
    if sram_dir is None or corners is None:
        unable_to_run = True
        missing = []
        if sram_dir is None:
            missing.append("the sg13g2_sram view tree")
        if corners is None:
            missing.append("the stdcell PVT corner list")
        print("view check: UNAVAILABLE (" + " and ".join(missing)
              + f" not found under {args.pdk_root})")
    for mtype, spec in sorted(macros_cfg.items()):
        for key in ("gds", "lef"):
            if not spec.get(key):
                fail(problems, f"MACROS[{mtype}].{key} is missing or empty; "
                               f"the flow would stage no {key.upper()}")
        libs = spec.get("lib")
        if not libs:
            fail(problems, f"MACROS[{mtype}].lib is missing or empty; the "
                           f"macro would be unannotated at every corner")
            libs = {}
        for lkey, plist in sorted(libs.items()):
            if not plist:
                fail(problems, f"MACROS[{mtype}].lib[{lkey!r}] is empty; "
                               f"corner {lkey!r} would have no timing view")
        if corners is not None:
            for corner in sorted(corners):
                if not any(fnmatch.fnmatchcase(corner, k) for k in libs):
                    fail(problems, f"MACROS[{mtype}].lib has no view for "
                                   f"required corner {corner!r}")
        # R3: coverage above is key-pattern based, so one file -- or a single
        # `*` key -- can satisfy every required corner while two corners read
        # the same timing data. Each required corner must resolve to its own
        # file; this is config-only (no PDK read) and fails even PDK-less.
        if corners is not None:
            served: dict[str, set[str]] = {}
            for corner in sorted(corners):
                for lkey, plist in sorted(libs.items()):
                    if fnmatch.fnmatchcase(corner, lkey):
                        for p in (plist or []):
                            served.setdefault(str(p), set()).add(corner)
            for p, cs in sorted(served.items()):
                if len(cs) > 1:
                    fail(problems, f"MACROS[{mtype}].lib serves required "
                                   f"corners {sorted(cs)} from the same file "
                                   f"{p}; each corner needs its own timing "
                                   f"view (R3: corner-key vs file identity)")
        views: list[tuple[str, str]] = []
        for key in ("gds", "lef"):
            views += [(key, p) for p in (spec.get(key) or [])]
        for lkey, plist in sorted(libs.items()):
            views += [(f"lib[{lkey}]", p) for p in (plist or [])]
        for label, p in views:
            if not str(p).startswith("./src/"):
                fail(problems, f"MACROS[{mtype}].{label} path {p!r} is not "
                               f"'./src/<name>'; the staged run would not "
                               f"resolve it")
            # The class/extension check is STRUCTURAL: the config itself says
            # which view class each entry belongs to, so it must fail even
            # when the PDK tree (and the geometry LEF) are unavailable.
            name = Path(p).name
            cls = "lib" if label.startswith("lib[") else label
            want_ext = {"gds": ".gds", "lef": ".lef", "lib": ".lib"}[cls]
            if Path(name).suffix != want_ext:
                fail(problems, f"MACROS[{mtype}].{label} names {name!r}, "
                               f"but the {cls} view class requires a "
                               f"{want_ext} file")
            if sram_dir is not None:
                view_dir = sram_dir / cls
                hits = ([h for h in view_dir.rglob(name)
                         if h.is_file() and h.name == name]
                        if view_dir.is_dir() else [])
                if len(hits) != 1:
                    fail(problems, f"MACROS[{mtype}].{label} names {name!r}, "
                                   f"but the PDK {cls}/ view directory has "
                                   f"{len(hits)} matches "
                                   f"(run_librelane.sh requires exactly 1)")
                elif cls == "lef":
                    # E2-6: type<->file identity. The geometry check below
                    # measures THIS type with whatever footprint the resolved
                    # file carries, so a type configured with ANOTHER type's
                    # LEF silently inherits its SIZE and passes placements it
                    # cannot fit. The LEF's own MACRO declaration is the
                    # file's identity; a LEF without one is fail-closed.
                    text = hits[0].read_text()
                    mm = re.search(r"(?m)^\s*MACRO\s+(\S+)", text)
                    if mm is None:
                        fail(problems, f"MACROS[{mtype}].lef {name!r} declares "
                                       f"no MACRO; type<->file identity "
                                       f"cannot be established")
                    elif mm.group(1) != mtype:
                        fail(problems, f"MACROS[{mtype}].lef {name!r} declares "
                                       f"MACRO {mm.group(1)}, not the "
                                       f"configured type {mtype} (E2-6: its "
                                       f"instances would be measured with "
                                       f"another type's footprint)")
                    type_lef.setdefault(mtype, hits[0])
                elif cls == "lib":
                    # The same identity check for timing views WHERE PRESENT:
                    # a macro lib declares cell(<macro>). A file with no cell
                    # declaration carries no identity to compare, so it is
                    # not flagged here (recorded as a limit of E2-6).
                    text = hits[0].read_text()
                    cells = re.findall(r'(?m)^\s*cell\s*\(\s*"?([^"\s)]+)"?',
                                       text)
                    if cells and mtype not in cells:
                        fail(problems, f"MACROS[{mtype}].{label} {name!r} "
                                       f"declares no cell for type {mtype} "
                                       f"(cells: "
                                       f"{', '.join(sorted(set(cells)))})")

    # 3: placement geometry, per configured macro type (E2-5). Each type's own
    # LEF SIZE drives the fit and gap checks for that type's instances, so two
    # macros with different footprints are measured with their own dimensions;
    # a single hard-coded LEF would let a larger type pass against the smaller
    # one's bounds. --lef overrides every type for the E2-3 unavailable-geometry
    # policy tests; otherwise the type's ./src lef view resolved above is used.
    def type_size(mtype: str) -> tuple[float, float] | None:
        if args.lef is not None:
            return lef_size(args.lef)
        p = type_lef.get(mtype)
        return lef_size(p) if p is not None else None

    sizes = {mtype: type_size(mtype) for mtype in macros_cfg}
    if not any(s is not None for s in sizes.values()):
        detail = (f"--lef {args.lef} is missing or has no SIZE"
                  if args.lef is not None else
                  "no configured type's lef view resolved to a LEF")
        print(f"placement check: UNAVAILABLE ({detail}); cannot establish "
              "placement legality")
        unable_to_run = True
    else:
        for mtype, size in sizes.items():
            if size is None and macros_cfg[mtype].get("instances"):
                print(f"placement check: no resolvable LEF SIZE for type "
                      f"{mtype}; its instances are not checked")
                unable_to_run = True
        die = cfg.get("DIE_AREA")
        if not die or len(die) != 4:
            fail(problems, "DIE_AREA is missing or not [x0, y0, x1, y1]")
        else:
            x0, y0, x1, y1 = (float(v) for v in die)
            # (name, x, y, w, h) per placed instance, each with its type size.
            placed: list[tuple[str, float, float, float, float]] = []
            for mtype, spec in macros_cfg.items():
                size = sizes[mtype]
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
                    if size is None:
                        continue
                    w, h = size
                    if x < x0 or y < y0 or x + w > x1 or y + h > y1:
                        fail(problems, f"{name}: {w}x{h} (type {mtype}) at "
                                       f"({x},{y}) is not inside DIE_AREA "
                                       f"{die}")
                    placed.append((name, x, y, w, h))
            for i in range(len(placed)):
                for j in range(i + 1, len(placed)):
                    n1, a, b, w1, h1 = placed[i]
                    n2, c, d, w2, h2 = placed[j]
                    overlap = (c < a + w1 + GAP_UM
                               and a < c + w2 + GAP_UM
                               and d < b + h1 + GAP_UM
                               and b < d + h2 + GAP_UM)
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
        # flow/<name> there, so resolve the basename beside the config first,
        # then under flow/ (the negative tests point --flow at a copy that
        # lives beside its own PDN script).
        name = Path(pdn_cfg).name
        candidates = [flow.parent / name, REPO / "flow" / name, REPO / name]
        p = next((c for c in candidates if c.is_file()), candidates[0])
        if not p.is_file():
            fail(problems, f"PDN_CFG {pdn_cfg} does not exist (looked for "
                           f"{p})")
        else:
            # E2-2: require the MACRO GRID's supply ladder, not just the word
            # "Metal4" anywhere in the file. Commented-out stock commands are
            # stripped first so a header example cannot satisfy a requirement
            # the live script no longer builds, and backslash-newline
            # continuations are joined so each Tcl command is one line.
            text = p.read_text()
            text = re.sub(r"(?m)^[ \t]*#.*$", "", text)
            flat = re.sub(r"\\[ \t]*\n[ \t]*", " ", text)
            cmds = re.findall(r"add_pdn_[a-z_]+[^\n]*", flat)

            # Layer-token identity: a connect must name the exact ordered pair
            # in its own -layers argument, in the macro-grid command. Token
            # presence anywhere in the file (or in another argument) is not the
            # claim; a reversed pair or a Metal5 typo must fail.
            def layer_of(tok: str) -> str | None:
                if tok == "Metal4":
                    return "Metal4"
                if tok == "$::env(PDN_VERTICAL_LAYER)":
                    return "vertical"
                if tok == "$::env(PDN_HORIZONTAL_LAYER)":
                    return "horizontal"
                return None

            def is_macro_grid(c: str) -> bool:
                return re.search(r"(?:^|\s)-grid\s+macro(?:\s|$)", c) is not None

            def has_stripe() -> bool:
                for c in cmds:
                    if (not c.startswith("add_pdn_stripe")
                            or not is_macro_grid(c)):
                        continue
                    m = re.search(r"-layer\s+(\S+)", c)
                    if m and m.group(1) == "Metal4":
                        return True
                return False

            def has_connect(seq: list[str]) -> bool:
                for c in cmds:
                    if (not c.startswith("add_pdn_connect")
                            or not is_macro_grid(c)):
                        continue
                    m = re.search(r'-layers\s+"([^"]*)"', c)
                    if not m:
                        continue
                    if [layer_of(t) for t in m.group(1).split()] == seq:
                        return True
                return False

            ladder = [
                ("macro-grid Metal4 stripe", has_stripe()),
                ("macro-grid Metal4-to-vertical connect",
                 has_connect(["Metal4", "vertical"])),
                ("macro-grid vertical-to-horizontal connect",
                 has_connect(["vertical", "horizontal"])),
            ]
            for label, present in ladder:
                if not present:
                    fail(problems, f"{pdn_cfg} is missing the {label}; the "
                                   f"macro supplies would have no physical "
                                   f"path to the grid")

    if problems:
        print("macro flow config: FAILED")
        for p in problems:
            print(f"  - {p}")
        if unable_to_run:
            print("  (the PDK-dependent placement/view checks could not run: "
                  "required geometry or view assets are unavailable -- the "
                  "findings above still fail)")
        return 1
    if unable_to_run:
        print("macro flow config: INCOMPLETE "
              "(required PDK geometry/views unavailable)")
        return 2
    print("macro flow config: OK (placements, pin-to-net hooks and the "
          "macro Metal4 ladder complete)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
