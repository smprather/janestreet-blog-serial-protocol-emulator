#!/usr/bin/env bash
# Follow-up Ethernet structural checks. Exits nonzero while malformed frames
# are accepted. All compilation output is temporary.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d /tmp/eth-boundaries.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
if ! iverilog -g2012 -s tb_pe_eth_mac -o "$WORK/probe.vvp" \
    rtl/pe_dru.v rtl/pe_line_codec.v rtl/pe_crc.v rtl/pe_eth_mac.v rtl/pe_fbuf.v \
    reviews/2026-09-23/mac_boundaries.v >"$WORK/compile.txt" 2>&1; then
    cat "$WORK/compile.txt"
    exit 2
fi
vvp "$WORK/probe.vvp"
