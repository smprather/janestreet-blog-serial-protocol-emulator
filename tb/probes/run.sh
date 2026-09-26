#!/usr/bin/env bash
# Build tb/tb_pe_soc_bmc.v and run it, optionally with a probe injected.
#
#   tb/probes/run.sh                    # the testbench on its own
#   tb/probes/run.sh tb/probes/probe_out_seq.v
#
# A PROBE is injected immediately before the `integer rx_micro = 0;` anchor and
# is preceded by the L_<label> defines from labels.py, so a probe can name a
# label instead of an address: this act lost six placements to a probe that had
# a decimal written into it and an edit that moved the label underneath it.
#
# It is here, in the repository, because /tmp has been cleaned three times this
# block with an instrument in it, and the instruments are what found every fault
# in act (c): the three-clock delay loop, the missing MOV A,Y, the off-by-one
# byte dispatch, and the three-byte check that compared against a stale index.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROBE=${1:-}
TB=/tmp/bmc_probe_tb.v

if [ -n "$PROBE" ]; then
  python3 - "$PROBE" "$TB" "$ROOT" <<'PY'
import subprocess
import sys
from pathlib import Path

probe = Path(sys.argv[1]).read_text()
out, root = sys.argv[2], Path(sys.argv[3])
labels = subprocess.run(
    ["python3", str(root / "tb/probes/labels.py")],
    capture_output=True, text=True, cwd=root, check=True,
).stdout
src = (root / "tb/tb_pe_soc_bmc.v").read_text()
anchor = "  integer rx_micro = 0;"
if src.count(anchor) != 1:
    raise SystemExit(f"the injection anchor appears {src.count(anchor)} times")
Path(out).write_text(src.replace(anchor, f"{labels}\n{probe}\n{anchor}"))
PY
else
  cp "$ROOT/tb/tb_pe_soc_bmc.v" "$TB"
fi

cd "$ROOT/sim" || exit 1
SRAM=$("$ROOT/regress/sram_model.sh")
iverilog -g2012 -s tb_pe_soc_bmc -o /tmp/bmc_run.vvp \
  ../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v \
  ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v \
  ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v \
  ../rtl/pe_eth_tx.v ../rtl/pe_soc.v $SRAM "$TB" 2>&1 | grep -v 'sorry:' | head -20
timeout 300 vvp /tmp/bmc_run.vvp 2>&1 | grep -vE '^VCD info|^WARNING.*readmemh'
