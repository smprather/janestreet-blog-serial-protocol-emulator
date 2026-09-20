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

# LibreLane resolves VERILOG_FILES relative to the config, and the run
# directory lives outside the repo (build artifacts are not git state). So
# stage the sources the config names into $OUT/src/ and run from there. The
# config therefore says "./src/<file>" and this is what makes that true.
mkdir -p "$OUT/src"
cp "$CONFIG" "$OUT/config.json"

python3 - "$CONFIG" "$OUT" <<'PYEOF'
import json, shutil, sys, pathlib
cfg, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = json.loads(cfg.read_text())
for entry in spec["VERILOG_FILES"]:
    name = pathlib.Path(entry).name
    src = pathlib.Path("rtl") / name
    if not src.is_file():
        raise SystemExit(f"config names {entry}, but rtl/{name} does not exist")
    shutil.copy2(src, out / "src" / name)
    print(f"  staged rtl/{name}")
PYEOF

echo "running LibreLane: $CONFIG -> $OUT"
docker run --rm -i --user "$(id -u):$(id -g)" \
  -v "$HOME:$HOME" -v "$PDK_ROOT:$PDK_ROOT" \
  -e PDK_ROOT="$PDK_ROOT" -w "$OUT" \
  ghcr.io/librelane/librelane:3.0.14 \
  python3 -m librelane -p ihp-sg13g2 -s sg13g2_stdcell config.json

echo "done. results under $OUT/runs/"
