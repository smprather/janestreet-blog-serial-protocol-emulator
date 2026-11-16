#!/usr/bin/env bash
# run_librelane.sh — place & route a block, reproducibly, from a clean clone.
#
# Usage:  flow/run_librelane.sh [config]        (default: flow/pe_serdes.json)
#
# WHY THE ARGUMENTS LOOK LIKE THIS.
#
# The competition target is IHP SG13CMOS5L, not the full SG13G2 BiCMOS PDK.
# CMOS5L is the 5-metal stack (M1-M4-TopMetal1) with the `sg13cmos5l_stdcell`
# library and `sg13cmos5l_*` cells. The PDK tree is the TinyTapeout-pinned
# IHP-Open-PDK commit, installed at ~/pdk/IHP-Open-PDK by default.
#
# LibreLane's `--dockerized` wrapper cannot auto-enable the IHP PDK, so the
# container is invoked directly with explicit -p / -s flags. Do not "simplify"
# this back to the wrapper without re-testing.
#
# Requires: docker, and the CMOS5L PDK under $PDK_ROOT (see
# wiki/concepts/pdk-toolchain.md for the one-time setup).

set -eu
cd "$(dirname "$0")/.." || exit 1

CONFIG="${1:-flow/pe_serdes.json}"
[ -f "$CONFIG" ] || { echo "no such config: $CONFIG"; exit 1; }

RUNS="${ASIC_RUNS:-$HOME/asic-runs}"
NAME="$(basename "$CONFIG" .json)"
OUT="$RUNS/$NAME"
: "${PDK_ROOT:=$HOME/pdk/IHP-Open-PDK}"
: "${LIBRELANE_IMAGE:=ghcr.io/librelane/librelane:3.1.0.dev3}"

[ -d "$PDK_ROOT/ihp-sg13cmos5l" ] || {
  echo "CMOS5L PDK not enabled at $PDK_ROOT/ihp-sg13cmos5l"
  echo "See wiki/concepts/pdk-toolchain.md (TinyTapeout pins IHP-Open-PDK"
  echo "commit 2bbec755dc67ca3db0261c3d6163e15735d66710)."
  exit 1
}

# Provenance: a run is only as reproducible as the PDK revision it read, and
# that tree is a git checkout a `git pull` can move (2026-11-15: e73adb40,
# 1,151 commits past the shuttle pin). Record it in the log every time.
echo "PDK: $PDK_ROOT @ $(git -C "$PDK_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo 'unknown (not a git checkout)')"
echo "PDK shuttle pin: 2bbec755dc67 (docs/tt-shared-silicon/sources/tt-gds-action-install-sg13cmos5l.sh)"

# LibreLane resolves VERILOG_FILES (and every other ./src/... path in the
# config) relative to the config, and the run directory lives outside the repo
# (build artifacts are not git state). So stage the sources the config names
# into $OUT/src/ and run from there. The config therefore says
# "./src/<file>" and this is what makes that true.
#
# Hard macros are staged the same way, and they MUST be: the SRAM's timing
# model reaches OpenROAD only through the config's MACROS block, whose lib/
# lef/gds entries are file paths. Without them the macro is unannotated and the
# instruction-fetch path is invisible to STA. The PDK is resolved through
# PDK_ROOT rather than hardcoded so a checkout can be moved or pinned without
# editing this script.
mkdir -p "$OUT/src"
cp "$CONFIG" "$OUT/config.json"

python3 - "$CONFIG" "$OUT" "$PDK_ROOT" <<'PYEOF'
import json, shutil, sys, pathlib
cfg, out, pdk_root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
spec = json.loads(cfg.read_text())

def stage(src, why):
    if not src.is_file():
        raise SystemExit(f"needed {why} but it is not at {src}")
    shutil.copy2(src, out / "src" / src.name)
    print(f"  staged {src.name}")

for entry in spec.get("VERILOG_FILES", []) + spec.get("EXTRA_VERILOG_MODELS", []):
    name = pathlib.Path(entry).name
    # rtl/ is flat for our modules, with vendor hard-macro shells under
    # rtl/vendor/, so resolve by name anywhere in the tree. Config entries stay
    # "./src/<basename>" because the staged copy is flat.
    hits = [h for h in pathlib.Path("rtl").rglob(name) if h.is_file()]
    if len(hits) != 1:
        raise SystemExit(
            f"config names {entry}, but rtl/**/{name} has {len(hits)} matches "
            f"(expected exactly 1)")
    stage(hits[0], "a source file the config names")

# Any SDC the config names (PNR_SDC_FILE / SIGNOFF_SDC_FILE). These live in
# flow/, not rtl/, and they source the LibreLane base template by absolute path,
# so all this has to do is put the file where ./src/<name> resolves.
# (Relative paths in config.json resolve against the RUN DIRECTORY, which is
# where LibreLane is invoked -- so a staged "./src/x.sdc" is real, and a bare
# "./x.sdc" would not be.)
for key in ("PNR_SDC_FILE", "SIGNOFF_SDC_FILE", "FALLBACK_SDC",
            "PDN_CFG"):
    entry = spec.get(key)
    if not entry:
        continue
    src = pathlib.Path("flow") / pathlib.Path(entry).name
    if not src.is_file():
        raise SystemExit(f"config names {entry} for {key}, but {src} does not exist")
    stage(src, f"{key}")

# Any macro referenced by the config: find the PDK copy of each staged name.
macro_names = set()
for macro in (spec.get("MACROS") or {}).values():
    for key in ("gds", "lef"):
        macro_names.update(pathlib.Path(p).name for p in macro.get(key, []))
    for libs in (macro.get("lib") or {}).values():
        macro_names.update(pathlib.Path(p).name for p in libs)

if macro_names:
    sram_dir = None
    # CMOS5L ships sg13cmos5l_sram as a symlink to the shared SG13G2 SRAM
    # macros; accept either name so a checkout that resolves the symlink
    # differently still works.
    for tree in ("sg13cmos5l_sram", "sg13g2_sram"):
        for cand in sorted(pdk_root.rglob(tree)):
            if cand.is_dir() and (cand / "lib").is_dir():
                sram_dir = cand
                break
        if sram_dir is not None:
            break
    if sram_dir is None:
        raise SystemExit(f"config declares MACROS but no CMOS5L/SG13G2 SRAM dir under {pdk_root}")
    print(f"  SRAM macro files from {sram_dir}")
    for name in sorted(macro_names):
        hits = [p for p in sram_dir.rglob(name) if p.is_file() and p.name == name]
        if len(hits) != 1:
            raise SystemExit(f"{name}: expected exactly 1 match under {sram_dir}, found {len(hits)}")
        stage(hits[0], "a MACROS entry")
PYEOF

echo "running LibreLane: $CONFIG -> $OUT"
docker run --rm -i --user "$(id -u):$(id -g)" \
  -v "$HOME:$HOME" -v "$PDK_ROOT:$PDK_ROOT" \
  -e PDK_ROOT="$PDK_ROOT" -w "$OUT" \
  "$LIBRELANE_IMAGE" \
  python3 -m librelane --manual-pdk -p ihp-sg13cmos5l -s sg13cmos5l_stdcell config.json

echo "done. results under $OUT/runs/"
