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
import re
import subprocess
import sys
from pathlib import Path

probe = Path(sys.argv[1]).read_text()
out, root = sys.argv[2], Path(sys.argv[3])
# *** THE L_<label> NAMES ARE SUBSTITUTED TEXTUALLY, AND NOT PASSED AS
# VERILOG `define MACROS, AND THE REASON IS A FAULT THIS ACT PAID FOR. ***
# A probe here has ALWAYS been written as `if (dbg_pc == L_enc_drive)`, and
# the backtick has never once reached the file: every L_ reference in
# tb/probes/*.v is a BARE IDENTIFIER, and Icarus answers that with
#   Unable to bind wire/reg/memory `L_enc_drive' in `tb_pe_soc_bmc'
# which is why a previous session recorded "a probe using the macro failed to
# elaborate for a reason not diagnosed" and why probe_levels.v carries a
# comment saying it uses a hand-written decimal instead. It was never Icarus
# and never labels.py: the macro was not in the text.
#
# So the labels arrive as a TEXT SUBSTITUTION of the assembler's own listing,
# which cannot depend on a character surviving the trip, and a name that is not
# in the map is a LOUD failure rather than an identifier that silently becomes
# an unelaborated -- and, in a simulator that tolerated it, a WRONG ADDRESS.
sys.path.insert(0, str(root / "tb/probes"))
import labels

addrs = {"L_" + name: value for name, value in labels.addresses(root).items()}

used = set(re.findall(r"\bL_[A-Za-z_][A-Za-z0-9_]*", probe))
unknown = sorted(used - set(addrs))
if unknown:
    raise SystemExit(
        f"probe names {', '.join(unknown)} and the firmware has no such "
        f"label; a probe that guessed an address is worse than no probe"
    )
for name in used:
    probe = re.sub(rf"\b{name}\b", str(addrs[name]), probe)
src = (root / "tb/tb_pe_soc_bmc.v").read_text()
anchor = "  integer rx_micro = 0;"
if src.count(anchor) != 1:
    raise SystemExit(f"the injection anchor appears {src.count(anchor)} times")
Path(out).write_text(src.replace(anchor, f"{probe}\n{anchor}"))
PY
  # *** A FAILED INJECTION MUST NOT LEAVE A STALE TESTBENCH BEHIND. *** The
  # build below reads $TB whatever happened up here, so without this a probe
  # that failed to build -- an unknown label, a typo, a traceback -- silently
  # compiled and ran the PREVIOUS session's probe, and reported its numbers.
  # That is the worst failure this file can have: an instrument that is wrong
  # and says nothing.
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "run.sh: the probe injection FAILED (exit $rc); not building" >&2
    exit 1
  fi
else
  cp "$ROOT/tb/tb_pe_soc_bmc.v" "$TB"
fi

cd "$ROOT/sim" || exit 1
SRAM=$("$ROOT/regress/sram_model.sh")
rm -f /tmp/bmc_run.vvp
iverilog -g2012 -s tb_pe_soc_bmc -o /tmp/bmc_run.vvp \
  ../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v \
  ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v \
  ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v \
  ../rtl/pe_eth_tx.v ../rtl/pe_soc.v $SRAM "$TB" 2>&1 | grep -v 'sorry:' | head -20
# AND THE COMPILE ITSELF MUST BE CHECKED, for the same reason: the pipe above
# ends in `head`, so its exit code is head's and not iverilog's, and a probe
# with a bad signal name compiled to nothing and then RAN THE PREVIOUS BUILD.
# rm -f above makes the stale vvp impossible; this makes the absence loud.
[ -f /tmp/bmc_run.vvp ] || { echo "run.sh: the BUILD FAILED; nothing was run" >&2; exit 1; }
timeout 300 vvp /tmp/bmc_run.vvp 2>&1 | grep -vE '^VCD info|^WARNING.*readmemh'
