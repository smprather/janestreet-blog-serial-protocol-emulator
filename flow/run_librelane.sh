#!/usr/bin/env bash
# run_librelane.sh — place & route a block, reproducibly, from a clean clone.
#
# Usage:  flow/run_librelane.sh [config]        (default: flow/pe_serdes.json)
#
# WHY THE ARGUMENTS LOOK LIKE THIS.
#
# LibreLane's `--dockerized` wrapper CANNOT auto-enable the IHP PDK: it reports
# "PDK ihp-sg13g2 was not found" even when ~/.ciel/ihp-sg13g2 resolves and
# config.tcl is present. The smoke test and --run-example paths work; plain
# config runs do not. The workaround is to invoke the container directly with
# explicit -p / -s flags, which is what this script does. Do not "simplify" it
# back to the wrapper without re-testing.
#
# Requires: docker, and the IHP PDK enabled under ~/.ciel (see
# wiki/concepts/pdk-toolchain.md for the one-time setup).

set -eu
cd "$(dirname "$0")/.." || exit 1

CONFIG="${1:-flow/pe_serdes.json}"
[ -f "$CONFIG" ] || { echo "no such config: $CONFIG"; exit 1; }

RUNS="${ASIC_RUNS:-$HOME/asic-runs}"
NAME="$(basename "$CONFIG" .json)"
OUT="$RUNS/$NAME"
: "${PDK_ROOT:=$HOME/.ciel}"

[ -d "$PDK_ROOT/ihp-sg13g2" ] || {
  echo "PDK not enabled at $PDK_ROOT/ihp-sg13g2"
  echo "See wiki/concepts/pdk-toolchain.md (volare family is ihp_sg13g2, with"
  echo "an explicit version from 'volare ls-remote')."
  exit 1
}

# LibreLane resolves VERILOG_FILES (and every other ./src/... path in the
# config) relative to the config, and the run directory lives outside the repo
# (build artifacts are not git state). So stage the sources the config names
# into $OUT/src/ and run from there. The config therefore says
# "./src/<file>" and this is what makes that true.
#
# Hard macros are staged the same way, and they MUST be: the SRAM's timing
# model reaches OpenROAD only through the config's MACROS block, whose lib/
# lef/gds entries are file paths. Without them the macro is unannotated and the
# instruction-fetch path is invisible to STA. The PDK is resolved through Ciel
# rather than hardcoded, because the version hash in the path changes whenever
# the PDK is updated.
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
    src = pathlib.Path("rtl") / name
    if not src.is_file():
        raise SystemExit(f"config names {entry}, but rtl/{name} does not exist")
    stage(src, "a source file the config names")

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
    for cand in sorted(pdk_root.rglob("sg13g2_sram")):
        if cand.is_dir() and (cand / "lib").is_dir():
            sram_dir = cand
            break
    if sram_dir is None:
        raise SystemExit(f"config declares MACROS but no sg13g2_sram dir under {pdk_root}")
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
  ghcr.io/librelane/librelane:3.0.14 \
  python3 -m librelane -p ihp-sg13g2 -s sg13g2_stdcell config.json

echo "done. results under $OUT/runs/"
