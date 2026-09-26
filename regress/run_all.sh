#!/usr/bin/env bash
# run_all.sh — full regression: every testbench, one command.
#
# Usage:  regress/run_all.sh            (from anywhere in the repo)
#         regress/run_all.sh --fast     parallel testbench loop (see below)
#         regress/run_all.sh --fast -j8 explicit job count
# Exit:   0 = all pass, 1 = at least one failure
#
# VCDs are written into sim/ (gitignored per-run artifacts; the checked-in
# copies are snapshots). Requires iverilog (>= 11, -g2012 support).
#
# WHAT --fast ACTUALLY DOES, because the name invites the wrong assumption: it
# runs the SAME 4-state iverilog simulation, in parallel. It does NOT switch to
# Verilator. Measured, a Verilator swap would make this suite 69.6x SLOWER --
# Verilator builds per --top-module with no shared cache (median 5.6 s per
# testbench), so 24 testbenches cost 167 s of compilation against 2.4 s for all
# 24 iverilog compiles AND runs. The per-run 12-19x speedup only pays back at
# ~27 runs of the same testbench, and this suite runs each one once.
#
# So --fast buys concurrency, not a different simulator, and the default path is
# byte-identical in what it simulates. tb_pe_pinmux is the hard blocker for a
# Verilator path anyway: it models the bus at strength levels to test the od
# bit's contention property, and Verilator aborts it with DIDNOTCONVERGE.

set -u
cd "$(dirname "$0")/.." || exit 1
# The single-run lock. This worktree is shared, and two concurrent runs would
# have their mutation harnesses mutating and restoring the SAME RTL at once —
# the 2026-09-25 incident (manager's run_all_merge + the worker's run_all).
# The lock is inherited by the harnesses this script invokes, so they run
# without re-taking it. See regress/run_lock.sh for the full contract.
# shellcheck source=regress/run_lock.sh
. "$(dirname "$0")/run_lock.sh"
chip_take_run_lock "run_all.sh"
# THE HARNESS-EDIT PRE-FLIGHT. A run may not report a verdict from scripts that
# changed underneath it: bash reads a script INCREMENTALLY, so editing a harness
# mid-run can make it report a FALSE PASS as easily as a false failure, and a
# false pass is the worst thing a gate in this project can do. The dependency
# guard stamps the CONTENT of the scripts this run executes and re-checks it on
# the way out; a change exits 4 (INCONCLUSIVE) and never a green. See
# regress/dep_guard.sh for why a content hash and not an mtime, and
# regress/test_dep_guard.sh for the guard's own seven-case test — including the
# negative control that proves it can fail.
# shellcheck source=regress/dep_guard.sh
. "$(dirname "$0")/dep_guard.sh"
_on_exit() {
  local rc=$?
  # The pre-flight runs FIRST, before the lock is released: a run whose scripts
  # moved has no verdict to protect, and the lock must not be held while this
  # decides.
  if ! chip_dep_check run_all; then rc=4; fi
  chip_release_run_lock
  exit "$rc"
}
trap '_on_exit' EXIT
# Capture the repo root NOW, as an absolute path. This script cds into sim/ and
# then back to the root, and `$0` may itself be relative ("./regress/run_all.sh"), so
# any later `dirname "$0"` resolves against the wrong directory. Gates that are
# invoked mid-script use this. (The param-guard gate failed exactly this way.)
REPO_ROOT="$(pwd)"
# Stamp the dependency set now that the root is known. Every regress/ script is
# included because this file invokes most of them and any of them could be the
# one under edit.
_chip_deps=()
for _f in "$REPO_ROOT"/regress/*.sh; do
  [ -f "$_f" ] && _chip_deps+=("$_f")
done
chip_dep_stamp run_all "${_chip_deps[@]}"
mkdir -p sim

# ---- options ---------------------------------------------------------------
FAST=0
JOBS=$(nproc 2>/dev/null || echo 4)
while [ $# -gt 0 ]; do
  case "$1" in
    --fast)   FAST=1 ;;
    # Most specific first: `--cases=REGEX` before the bare `--cases REGEX`.
    # They do not actually overlap (the bare pattern has no glob characters, so
    # it matches only the literal string), but shellcheck reports the later one
    # as unreachable and a reader has to stop and re-derive that.
    --cases=*) FILTER_CASES="${1#--cases=}" ;;
    --cases)  FILTER_CASES="${2:-}"; shift ;;
    -j*)      JOBS="${1#-j}" ;;
    -j)       shift; JOBS="${1:-$JOBS}" ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "run_all.sh: unknown option '$1' (try --help)" >&2
      exit 2 ;;
  esac
  shift
done
# A bad -j would make xargs fail in a way that reads like a test failure.
case "$JOBS" in
  ''|*[!0-9]*) echo "run_all.sh: -j needs a positive integer, got '$JOBS'" >&2; exit 2 ;;
  0)           echo "run_all.sh: -j 0 would run nothing" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ]; then
  echo "(--fast: parallel testbench loop, $JOBS jobs, same 4-state simulation)"
fi

# Firmware first: it assembles firmware/*.hex, and tb_pe_soc_uart.v $readmemh's
# one of them. Running it here means the RTL test can never simulate a stale
# image without the regression saying so.
echo "=== firmware (assemble + emulator) ==="
if ./regress/run_firmware_tests.sh; then
  fw_rc=0
else
  fw_rc=1
fi
echo
echo "=== RTL testbenches ==="

cd sim || exit 1

# The SRAM macro's behavioural model lives in the PDK, outside the repo. Every
# case that elaborates pe_imem needs it. A missing model is a HARD failure here,
# not a silent fall back to pe_imem's FLOP array -- a testbench that runs against
# the fallback has verified nothing about the memory that will actually ship.
if ! SRAM_MODEL=$(../regress/sram_model.sh); then
  echo "FATAL: SRAM behavioural model unavailable; cannot simulate the SoC." 
  exit 1
fi
SRAM_FLAGS=$(printf '%s ' $SRAM_MODEL)

# tb file : rtl files : top module
CASES=(
  "tb_pe_serdes|../rtl/pe_serdes.v|tb_pe_serdes"
  "tb_pe_uart|../rtl/pe_serdes.v|tb_pe_uart"
  "tb_pe_spi|../rtl/pe_serdes.v|tb_pe_spi"
  "tb_pe_i2c|../rtl/pe_serdes.v|tb_pe_i2c"
  "tb_pe_jtag|../rtl/pe_serdes.v|tb_pe_jtag"
  "tb_pe_swd|../rtl/pe_serdes.v|tb_pe_swd"
  "tb_pe_ps2|../rtl/pe_serdes.v|tb_pe_ps2"
  "tb_pe_can|../rtl/pe_serdes.v|tb_pe_can"
  "tb_pe_usb|../rtl/pe_serdes.v|tb_pe_usb"
  "tb_pe_eth|../rtl/pe_serdes.v|tb_pe_eth"
  "tb_pe_line_codec|../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v|tb_pe_nrzi"
  "tb_pe_line_codec|../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v|tb_pe_manch"
  "tb_pe_line_codec|../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v|tb_pe_bitstuff"
  "tb_pe_codec_mux|../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v|tb_pe_codec_mux"
  # The CRC / LFSR engine. Its constants are checked against the RevEng
  # catalogue (tools/gen/crc_config.py), and this TB is the only place the
  # "one right-shift datapath serves both CRC families" claim is measured.
  "tb_pe_crc|../rtl/pe_crc.v|tb_pe_crc"
  # Instruction memory against the PDK's REAL SRAM model: one-cycle latency, the
  # BM write no-op, and the REN write-through trap. Mutation-checked.
  "tb_pe_imem|../rtl/pe_imem.v|tb_pe_imem"
  # The DRU (oversampled Manchester receive). Its TB is the only place the
  # "phase 2 and 6 of an edge-reset counter are the half-cell centres" claim is
  # measured -- against every Manchester transition pattern.
  "tb_pe_dru|../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v ../rtl/pe_dru.v|tb_pe_dru"
  # The pin matrix: runtime per-pin direction, open-drain, read-back. The I2C
  # gate -- it makes arbitration (reading a pin we are also driving) and
  # bus-contention safety structural rather than a firmware convention.
  "tb_pe_pinmux|../rtl/pe_pinmux.v|tb_pe_pinmux"
  # The firmware processor, its unit TB, and the software-UART SoC TB. The SoC TB
  # $readmemh's firmware/uart_echo.hex, so run_firmware_tests.sh (below) must have
  # assembled a current copy -- it runs first for exactly that reason.
  "tb_pe_cpu|../rtl/pe_cpu.v|tb_pe_cpu"
  "tb_pe_soc_uart|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_uart"
  # The STATUS port. Nothing exercised it until firmware/tick_count.pe existed,
  # which is how a two-driver tick_flag survived a green regression: it raced
  # in Icarus and synthesised to a constant 0, and no test read the port.
  "tb_pe_soc_tick|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_tick"
  # The Tiny Tapeout top level: the pad contract (no X on an output, ena gates
  # nothing, open-drain pins never drive high). This is the only submittable
  # module in the repo.
  "tb_tt_um_protocol_emulator|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v ../rtl/pe_ctrl.v ../rtl/tt_um_protocol_emulator.v|tb_tt_um_protocol_emulator"
  # I2C on the pin matrix: the runtime direction file driven by firmware, and
  # the open-drain property checked on the RTL's own pin_oe output. This is the
  # test that makes "the matrix is enough to speak I2C" a measured claim.
  # The three TIMING acts: protocols where the waveform IS the specification.
  # What makes them different from every case above is that the DUT is partly the
  # FIRMWARE -- a WS2812 cell, a servo pulse width and a DHT11 sample instant are
  # instruction counts, and nothing in rtl/ knows what any of them is. Their
  # regression cost is milliseconds of simulation (52.5 ms and 22 ms), which is
  # two orders of magnitude more than any other TB here; that is the honest price
  # of a protocol whose unit of correctness is the millisecond, and it is why the
  # frame rate is measured on two slots rather than five. regress/mutate_timing_tb.sh
  # proves each testbench fails when the firmware is broken.
  "tb_pe_soc_ws2812|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_ws2812"
  "tb_pe_soc_servo|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_servo"
  "tb_pe_soc_dht11|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_dht11"
  # 1-WIRE (Block 2 act a). The DHT11 act above is a sensor the host READS on
  # a schedule it chooses; this one is the shape 1-Wire actually is. The DEVICE
  # initiates: after the host's reset pulse the sensor drives a presence pulse
  # back, and every read slot is answered by the sensor, so the firmware's
  # edge-wait loops and the pin matrix's read-back are both load-bearing in a
  # way nothing else here is. The claim is the whole slot, both directions:
  # the commands are decoded FROM THE PADS (so a wrong command, a wrong bit
  # order or a slot of the wrong length fails rather than agreeing with a
  # model built from the same reading of it), and the sample instant is
  # measured to sit inside the sensor's data window with margin at both ends.
  # ~2.2 ms of 60 MHz: the reset, sixteen write slots, sixteen read slots.
  "tb_pe_soc_ds18b20|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_ds18b20"
  # 1-WIRE (Block 2 act a). The DHT11 act above is a sensor the host READS on
  # a schedule it chooses; this one is the shape 1-Wire actually is. The DEVICE
  # initiates: after the host's reset pulse the sensor drives a presence pulse
  # back, and every read slot is answered by the sensor, so the firmware's
  # edge-wait loops and the pin matrix's read-back are both load-bearing in a
  # way nothing else here is. The claim is the whole slot, both directions:
  # the commands are decoded FROM THE PADS (so a wrong command, a wrong bit
  # order or a slot of the wrong length fails rather than agreeing with a
  # model built from the same reading of it), and the sample instant is
  # measured to sit inside the sensor's data window with margin at both ends.
  # ~2.2 ms of 60 MHz: the reset, sixteen write slots, sixteen read slots.
  # NEC INFRARED (Block 2 act b). The sharpest timing claim in the repository
  # and the only one with NO WIRE: the only thing that leaves the pin is light,
  # so a receiver has to find a 38 kHz burst and time the silences between
  # bursts to know what was sent. Nothing resynchronises to anything -- the
  # carrier is fitted to the CLOCK (789 clocks a half period, 38.049 kHz off the
  # pin) and the two half periods are checked separately and for constancy to
  # within a clock, because a carrier that alternates 37.9/38.1 is a program
  # that is out by a fraction of a clock on every other edge. 32 ms of 60 MHz.
  "tb_pe_soc_ir_nec|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_ir_nec"
  # STEPPER STEP/DIR RAMP (Block 2 act c). The only act in this block that
  # drives a MECHANISM: the driver chip counts STEP edges and the motor's
  # position IS that count, so there is no acknowledgement, no status word and
  # nothing at the far end to resynchronise to. The claim is therefore the
  # sharpest and the simplest here -- every step period is an exact instruction
  # count measured on the pin, and the ramp is exactly linear TO THE CLOCK:
  # the firmware subtracts ten outer steps of the (4,40) pair, 5110 clocks, per
  # step, so the constancy is in the program rather than assumed about a table.
  # Checked as an EQUALITY against 5110, not a tolerance, and the one interval
  # that is not on the line -- the direction change, which is the only thing
  # in the program that is not a step -- is pinned by a SUM with its
  # neighbour rather than excused. ~14 ms of 60 MHz, the sum of the periods.
  "tb_pe_soc_stepper_ramp|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_stepper_ramp"
  # The INPUT acts: the pin is an INPUT and the firmware recovers numbers from
  # a waveform it does not control, so the number that is the claim is the
  # ACCURACY OF A COUNT. Twelve banked points from 158 Hz to 10 kHz with a
  # varying duty, each checked against a SECOND, independent measurement of the
  # pad (the receiver in the TB) rather than against the generator's table --
  # a generator that knew the answer would agree with a firmware that had the
  # sweep wrong. The 100 Hz point is the point of the act: 10 000 us does not
  # fit in a byte, and a firmware counting into one reports 16 us with no
  # symptom at 10 kHz. The sweep is six runs of three periods because the
  # MACHINE HAS SIXTEEN BYTES of data memory and a period plus a high time is
  # four of them. ~43 ms of 60 MHz, the largest simulation in the repository;
  # the generator is edge-driven with absolute delays rather than clocked,
  # which is what keeps it inside ~55 s of wall.
  "tb_pe_soc_freqmeter|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_freqmeter"
  "tb_pe_soc_i2c|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_i2c"
  # The I2C TRANSACTION layer on real RTL: firmware/i2c_xfer.pe against a
  # Verilog slave FSM that decodes the wire, with timing and grammar asserted
  # on the pads. The emulator check is the fast loop; this is the real CPU,
  # matrix, pads and 1 us tick.
  "tb_pe_soc_i2c_xfer|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_i2c_xfer"
  # SPI mode 0 as firmware, with a real mode-0 SLAVE modelled in the TB. SPI is
  # a baseline protocol whose only executable spec was tools/fw/peemu.py -- a model
  # written from the same understanding as the firmware, so it can agree with it
  # about a wrong bit order and pass. The slave here decodes MOSI from the pins.
  "tb_pe_soc_spi|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_spi"
  # The frame buffer: 2 KB behind a byte interface, on the same SRAM macro
  # as the instruction memory (ADR-003). Byte granularity comes from the
  # macro's bit-mask port and the read lane is a register -- two silent
  # failure modes, both mutation-tested.
  # The HC-SR04 RANGING ACT — WIRED, AND KNOWN-RED ON PURPOSE (2026-09-26).
  # It used to be absent from this list entirely, and that was the defect: a red
  # act nobody can see is a claim hazard, because "46/46 PASS" then reads as
  # "the ranging act is verified" when in fact nothing has ever run it. It is
  # wired here behind a <<wip>> marking rather than left out, and the marking is
  # SELF-EXPIRING: a <<wip>> case that PASSES is reported as a FAILURE telling
  # you to remove the marking, so the exemption cannot outlive the act it covers.
  # That is the same discipline as the wiki-pages gate's pinned baseline with its
  # STALE check — an exemption that can silently outlive its defect is a
  # checklist, not a gate.
  "tb_pe_soc_sr04|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_sr04|<<wip>>"
  "tb_pe_fbuf|../rtl/pe_fbuf.v|tb_pe_fbuf"

  # 10BASE-T on the SoC: wire -> DRU -> Manchester -> MAC + CRC + frame
  # buffer, and firmware/eth_rx.pe consuming an ARP frame through the frame
  # window. tb_pe_eth_mac proves the chain; this proves a PROGRAM can use it.
  "tb_pe_soc_eth|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_eth"

  # The word engine inside the SoC: the 0xF window a program drives, the
  # split payload-only enables under stuffing, two codec instances at
  # different cadences, the half-cell level, and the wire loopback through
  # the matrix overlay. Directed stuffed-Manchester case included; the
  # matching harness is regress/mutate_soc_serdes_tb.sh.
  "tb_pe_soc_serdes|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_serdes"

  # The 10BASE-T TX frame engine inside the SoC: firmware -> the extended
  # 0xF window's upper bank -> pe_eth_tx -> the owner mux -> u_tx_codec ->
  # the Manchester wire. Decodes the frame and its FCS at the codec output,
  # so the window, the FIFO backpressure, DIV=6 and the pad overlay are all
  # exercised. Task-3 integration TB for wiki/plans/eth-tx-frame-path.md.
  "tb_pe_soc_eth_tx|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_eth_tx"

  # The TX frame path closed on itself: pin_out[7] wired to pin_in[7], the
  # frame loops through the real RX chain and eth_arp_echo.pe walks it back;
  # plus the two-frame minimum-IFG acceptance and the two directed cases
  # deferred from Task 3 (the 16-23 push wrap and the start-while-busy
  # refusal). Task-5 loopback TB for wiki/plans/eth-tx-frame-path.md.
  "tb_pe_soc_eth_loop|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_eth_loop"
  # The passive SPI loader: pads in, host write port out. Unit TB first; the
  # TT top-level TB then proves a program loaded through the pads executes.
  "tb_pe_ctrl|../rtl/pe_ctrl.v|tb_pe_ctrl"
  # R2 conformance: the SAME pe_ctrl driven by the HOST's own bytes. Every
  # request and response comes from the gui-worker golden package via
  # $readmemh (tb/r2-vectors/), the model image is loaded per vector, and the
  # response is compared byte-exactly -- CRC included, R2 wait words skipped.
  "tb_pe_ctrl_r2|../rtl/pe_ctrl.v|tb_pe_ctrl_r2"
  # R3 debug control: the SAME pe_ctrl with a REAL pe_cpu and a registered
  # imem model, wired as the SoC and the top route the three debug wires
  # (dbg_hold/dbg_step/dbg_next_pc). Single-step, the PC breakpoint's
  # stop-before semantics, the hit readback and the state encoding; contract:
  # reviews/2026-09-25/R3-DEBUG-CONTROL-CONTRACT.md.
  "tb_pe_ctrl_r3|../rtl/pe_ctrl.v ../rtl/pe_cpu.v|tb_pe_ctrl_r3"
  # R3 CONFORMANCE: the SAME pe_ctrl, driven by the HOST's own bytes. Every
  # request and response comes from the gui-worker's golden package via
  # $readmemh (tb/r3-vectors/), the model image is preloaded per vector, and
  # the response is compared byte-exactly -- CRC included. Seven words across
  # three steps are pinned as KNOWN divergences in
  # tb/r3-vectors/R3_KNOWN_DIVERGENCES.txt (two are host-side vector defects
  # where the chip is right, one is a TB model boundary); the lock compares the
  # observed SET against that list, so a known divergence that changes, or any
  # new one, turns this red.
  "tb_pe_ctrl_r3_conf|../rtl/pe_ctrl.v ../rtl/pe_cpu.v|tb_pe_ctrl_r3_conf"

  # The 10BASE-T receive path, end to end on real RTL: raw Manchester
  # levels into pe_dru, through pe_manch and pe_crc, into pe_fbuf. Every
  # other Ethernet TB models the framing in the testbench; this drives a
  # wire, so the bytes checked are the bytes a real receiver recovers.
  "tb_pe_eth_mac|../rtl/pe_dru.v ../rtl/pe_nrzi.v ../rtl/pe_manch.v ../rtl/pe_bitstuff.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v|tb_pe_eth_mac"

  # The 10BASE-T TX frame engine, unit level (wiki/plans/eth-tx-frame-path.md).
  # Firmware-styled stored bytes in, a decoded Manchester frame out: prelude,
  # pad-to-64, hardware FCS, 96-cell IFG, runt/jabber/underrun faults. Its own
  # TX-dedicated pe_crc is the second instantiation of the shared engine.
  "tb_pe_eth_tx|../rtl/pe_eth_tx.v ../rtl/pe_crc.v|tb_pe_eth_tx"

  # ---- the advanced BUS protocols, as firmware --------------------------
  # Three acts, three obligations the baseline protocols do not have, each
  # proved on the real CPU, matrix and pads. The same-list rule: a protocol
  # that is not in this list is not in the regression, however well it works
  # when run by hand. firmware/i2c_xfer.pe's TB is the baseline for act 1.
  #
  # (1) I2C COMBINED FORMAT with a STRETCHING slave. firmware/i2c_adv.pe sends
  #     two data bytes, a repeated START, then a THREE-BYTE read burst in which
  #     the master DRIVES SDA low on the 9th clock to ask for the next byte --
  #     a transmit behaviour in a receive phase, and the obligation a
  #     single-byte read never has. The slave owns SCL, so every high-phase
  #     wait polls the pad; dmem[0] counts those polls and the cases require it
  #     to be 0 with no stretch and non-zero with one.
  "tb_pe_soc_i2c_adv|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_i2c_adv"
  # (2) SPI MODE 3 (CPOL=1/CPHA=1) with a PER-WORD CRC. firmware/spi_mode3.pe
  #     is a three-word transaction, one CS_N frame per word, each word
  #     followed by a CRC-8 computed IN SOFTWARE in an ISA with no XOR. Both
  #     modes sample on the rising edge, so the failure a mode-0 program makes
  #     is a silent one-bit shift; the TB's mode-3 slave decodes the pins, the
  #     CRC is checked against an independent Verilog reference on BOTH sides
  #     of the wire, and one case corrupts a response CRC so the firmware's own
  #     comparison is proved non-vacuous.
  "tb_pe_soc_spi3|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_spi3"
  # (3) UART with RTS/CTS HARDWARE FLOW CONTROL. firmware/uart_flow.pe holds
  #     RTS across every bit cell of a frame and waits for CTS before the
  #     first start bit. The TB's claim is an invariant over time, not an
  #     event: THE WIRE IS IDLE FOR EVERY INSTANT CTS IS LOW, sampled per
  #     clock on the pin. A second case holds CTS low for ever and requires
  #     that nothing at all is transmitted.
  "tb_pe_soc_uart_flow|../rtl/pe_cpu.v ../rtl/pe_imem.v ../rtl/pe_pinmux.v ../rtl/pe_dru.v ../rtl/pe_manch.v ../rtl/pe_crc.v ../rtl/pe_eth_mac.v ../rtl/pe_fbuf.v ../rtl/pe_serdes.v ../rtl/pe_nrzi.v ../rtl/pe_bitstuff.v ../rtl/pe_codec_mux.v ../rtl/pe_eth_tx.v ../rtl/pe_soc.v|tb_pe_soc_uart_flow"
)

# ---- OPTIONAL case filter (OFF by default; the merge gate's driver) --------
# `--cases REGEX` runs only the cases whose NAME or TOP matches. Unused, the
# ordinary full gate is byte-for-byte unchanged. When it IS used it PRINTS the
# selected and skipped counts, and the summary line says FILTERED, because a
# gate that silently runs less than it claims is worse than no gate -- that is
# precisely how a red merge gets pushed.
if [ -n "${FILTER_CASES:-}" ]; then
  _sel=(); _skip=0
  for c in "${CASES[@]}"; do
    IFS='|' read -r _n _r _t <<< "$c"
    # NAME and TOP are matched as SEPARATE lines, not as one "$_n $_t" line.
    # That matters: a caller who anchors its pattern (^(a|b)$, which is what
    # regress/verify_merge.sh builds from the case table) can then never match
    # a two-field line, and the filter silently selects nothing. That is not
    # hypothetical — verify_merge.sh's own GREEN demonstration hit it, and the
    # only reason it was caught rather than believed is that the gate refuses
    # to report a pass it cannot count.
    if printf '%s\n' "$_n" "$_t" | grep -qE "${FILTER_CASES}"; then _sel+=("$c"); else _skip=$((_skip + 1)); fi
  done
  echo "(--cases ${FILTER_CASES}: ${#_sel[@]} selected, ${_skip} skipped)"
  if [ "${#_sel[@]}" -eq 0 ]; then
    echo "run_all.sh: --cases '${FILTER_CASES}' matched NO case" >&2
    exit 2
  fi
  CASES=("${_sel[@]}")
fi

pass=0; fail=0; failed_names=(); WIP_LIST=""

if [ "$FAST" -eq 1 ]; then
  # ---- parallel path --------------------------------------------------------
  # PARALLELISM, NOT A DIFFERENT SIMULATOR, and that is a measured decision.
  #
  # The obvious reading of "fast mode" is to swap iverilog for Verilator, which
  # is 12-19x faster per run. Measured, that makes THIS SUITE 69.6x SLOWER:
  # Verilator compiles one testbench at a time (median 5.6 s, max 33.7 s, no
  # shared cache across --top-module), so 24 testbenches need 24 builds -- 167 s
  # against 2.4 s for all 24 iverilog compiles AND runs. The per-run speedup is
  # real but it is paid back at ~27 runs of the SAME testbench, and a regression
  # suite runs each testbench once. See wiki/reference/simulator-bakeoff.md.
  #
  # What the suite is actually short of is CONCURRENCY: 24 independent cases on
  # 24 hardware threads, run one at a time. That is the win, and it needs no new
  # simulator, so it cannot weaken verification by being 2-state.
  #
  # VERILATOR'S ONE HARD BLOCKER, recorded here because it is the reason a
  # `--fast --verilator` flag does not exist: tb_pe_pinmux.v models the bus at
  # STRENGTH LEVELS (pull-up vs strong 0/1, so the od bit's contention property
  # is testable) and Verilator aborts it with
  #   %Error-DIDNOTCONVERGE ... Active region did not converge
  # 2-state simulation cannot express the weak/strong distinction the TB is
  # built on. So the fast path stays on the 4-state simulator, where it belongs.
  work=$(mktemp -d)
  trap 'rm -rf "$work"; _on_exit' EXIT

  printf '%s\n' "${CASES[@]}" \
    | xargs -P "$JOBS" -I{} "$REPO_ROOT/regress/run_one_tb.sh" "{}" "$work"

  # Read the verdicts back IN CASES ORDER. Collecting into files and printing
  # afterwards is what keeps one table row per case: letting the workers print
  # directly would interleave, and a verdict could appear under another case's
  # name.
  for c in "${CASES[@]}"; do
        IFS='|' read -r name rtl top wip <<< "$c"
        result="$work/$top.result"
        if [ ! -f "$result" ]; then
          printf '%-18s NO-RESULT (worker died without writing one)\n' "$top"
          fail=$((fail+1)); failed_names+=("$top(no-result)")
          continue
        fi
        verdict=$(head -1 "$result")
        if [ "$verdict" = "PASS" ]; then
          if [ "$wip" = "<<wip>>" ]; then
            printf '%-18s WIP-NOW-PASSING (remove the <<wip>> marking)\n' "$top"
            fail=$((fail+1)); failed_names+=("$top(wip-now-passing)")
            continue
          fi
          printf '%-18s PASS\n' "$top"
          pass=$((pass+1))
        elif [ "$wip" = "<<wip>>" ]; then
          printf '%-18s KNOWN-WIP (expected red; the act is not finished)\n' "$top"
          tail -n +2 "$result" | sed 's/^/  /'
          WIP_LIST="$WIP_LIST $top"
        else
          printf '%-18s %s\n' "$top" "$verdict"
          tail -n +2 "$result" | sed 's/^/  /'
          fail=$((fail+1)); failed_names+=("$top")
    fi
  done
else
  # ---- serial path (default) ------------------------------------------------
for c in "${CASES[@]}"; do
  IFS='|' read -r name rtl top wip <<< "$c"
  tb="../tb/${name}.v"
  if ! iverilog -g2012 -s "$top" -o "/tmp/${top}.vvp" $rtl $SRAM_FLAGS "$tb" 2>"/tmp/${top}.err"; then
    printf '%-18s COMPILE-FAIL\n' "$top"
    sed -n '1,3p' "/tmp/${top}.err"
    fail=$((fail+1)); failed_names+=("$top(compile)")
    continue
  fi
  out=$(vvp "/tmp/${top}.vvp" 2>&1)
  if grep -q '^PASS' <<< "$out"; then
    if [ "$wip" = "<<wip>>" ]; then
      printf '%-18s WIP-NOW-PASSING (remove the <<wip>> marking)\n' "$top"
      fail=$((fail+1)); failed_names+=("$top(wip-now-passing)")
      continue
    fi
    printf '%-18s PASS\n' "$top"
    pass=$((pass+1))
  elif [ "$wip" = "<<wip>>" ]; then
    printf '%-18s KNOWN-WIP (expected red; the act is not finished)\n' "$top"
    grep -E '^FAIL' <<< "$out" | head -5 | sed 's/^/  /'
    WIP_LIST="$WIP_LIST $top"
  else
    printf '%-18s FAIL\n' "$top"
    grep -E '^FAIL' <<< "$out" | head -5
    fail=$((fail+1)); failed_names+=("$top")
  fi
done
fi

echo
echo "========================================"
echo "TOTAL: $((pass+fail))   PASS: $pass   FAIL: $fail"
# The known-red acts are NAMED in the summary, every run, so a <<wip>> case can
# never become invisible the way an unwired one was. An empty list prints
# nothing rather than a reassuring dash, so "no WIP acts" is distinguishable
# from "the summary was truncated".
if [ -n "$WIP_LIST" ]; then
  echo "KNOWN-WIP (ran, expected red, act unfinished):$WIP_LIST"
fi
if [ "$fw_rc" -ne 0 ]; then
  echo "firmware regression: FAILED (see above)"
  fail=$((fail+1))
fi

# Elaboration guards are only real if they actually reject. A parameterised
# block is only tested at the values something instantiates, so the BOUNDARY is
# where silent breakage hides -- pe_dru's 4-bit phase counter truncated above
# SPB=16 and the block went completely dead with no error at all. This gate
# compiles each guarded block at an out-of-range parameter and requires a hard
# failure, plus an in-range compile at the boundary itself.
#
# Invoked via REPO_ROOT captured at the top: this file cds into sim/ and back,
# and $0 may be relative, so any later `dirname "$0"` resolves wrongly.
if "$REPO_ROOT/regress/param_guards.sh" > /tmp/param_guards.log 2>&1; then
  echo "param guards: OK"
else
  echo "param guards: FAILED"
  cat /tmp/param_guards.log
  fail=$((fail+1))
  failed_names+=("param_guards")
fi

# Every regress/ script must PARSE, one file per bash -n. This is a gate
# because the failure it prevents is invisible in the output: a broken lock
# helper made all sixteen mutation suites run to completion, report their real
# verdicts, and exit 4 — and `bash -n regress/*.sh` had said "all parse", because
# bash -n over a glob parses the FIRST file and passes the rest as arguments.
if "$REPO_ROOT/regress/check_shell_syntax.sh" > /tmp/check_shell_syntax.log 2>&1; then
  echo "regress script syntax: OK ($(tail -1 /tmp/check_shell_syntax.log))"
else
  echo "regress script syntax: FAILED"
  cat /tmp/check_shell_syntax.log
  fail=$((fail+1))
  failed_names+=("check_shell_syntax")
fi

# Every mutation harness must be covered by the harness-edit pre-flight. The
# wiring is correct today because of an edit, not because of a gate, and the next
# harness added would take the lock, be stamped and never be checked - which is a
# mid-run edit yielding a false pass with nothing saying so. Same drift class as
# the MUTABLE check below, one layer over.
if "$REPO_ROOT/regress/check_harness_preflight.sh" > /tmp/check_harness_preflight.log 2>&1; then
  echo "harness pre-flight coverage: OK ($(tail -1 /tmp/check_harness_preflight.log))"
else
  echo "harness pre-flight coverage: FAILED"
  cat /tmp/check_harness_preflight.log
  fail=$((fail+1))
  failed_names+=("check_harness_preflight")
fi

# The mutation suites' MUTABLE lists decide which suites a NARROWED merge gate
# has to run (regress/verify_merge.sh), so a list that stopped covering the
# files its harness writes would make that gate skip a suite guarding a changed
# file. The check belongs in the FULL gate too, not only in the mapper: a list is
# only trustworthy while something keeps proving it, and this is the master gate
# that everything else trusts.
if "$REPO_ROOT/regress/check_mutation_lists.sh" > /tmp/check_mutation_lists.log 2>&1; then
  echo "mutation MUTABLE lists: OK"
else
  echo "mutation MUTABLE lists: FAILED"
  cat /tmp/check_mutation_lists.log
  fail=$((fail+1))
  failed_names+=("check_mutation_lists")
fi

[ "$fail" -eq 0 ] || { echo "failed: ${failed_names[*]}"; exit 1; }
echo "all testbenches pass"

# The static gate. It runs HERE, in the regression, and not on request, because
# the two defects it was written for (a two-driver flop that yosys resolved to a
# constant, and a hierarchical reference that yosys drove backwards) were both
# reported by the tools on every single run and discarded unread. A simulator's
# resolution of illegal RTL is not the synthesiser's, so a green testbench says
# nothing about the netlist.
cd .. || exit 1
if ./regress/lint.sh; then
  lint_rc=0
else
  lint_rc=1
fi
echo

# Docs that are generated from the RTL are checked too: a renamed port must not
# leave wiki/reference/signal-names.md describing an interface that no longer
# exists, and a deleted TB must not leave the pin budget claiming coverage.
# Regenerate with: python3 tools/gen/signal_glossary.py / tools/gen/pin_budget.py
stale=0

# ---- THE MUTATION SUITES, and the narrowing regress/verify_merge.sh asks for --
#
# MUTATE_ONLY is a REGEX over the suite basenames. Unset (the ordinary full gate,
# the master/nightly run), EVERY suite runs and this file behaves exactly as
# before. Set, only the matching suites run — and the run says so, loudly, with
# the counts, because a gate that silently runs less than it claims is worse
# than no gate. The manager's ruling (2026-09-25) is MAPPED, NOT SKIPPED: the
# mapping lives in verify_merge.sh, which prints WHICH suites it selected and
# WHY, and this file only carries out the selection.
#
# The narrowing is by the suite's own published MUTABLE list, so a merge that
# changes a file a suite does not mutate never pays for that suite, while a
# merge that changes one it DOES mutate always runs it. A suite that mutates
# nothing in the repo (MUTABLE empty) is never narrowed away: the mapper keeps
# it, and that is deliberate.
# The key a suite is matched and reported by: the basename WITHOUT the .sh.
# ONE place on purpose. The first version of this block derived the key in the
# pre-flight loop but compared the RAW argument (mutate_x_tb.sh) in the runtime
# wrapper, so an anchored MUTATE_ONLY selected 4 suites in the pre-flight and
# then skipped all 16 at run time — a run with ZERO mutation coverage. The
# gate's count cross-check caught it (that is what it is for), but a narrowing
# that can disagree with itself in the same file is the defect, not the
# cross-check.
mut_key() { local b="${1##*/}"; printf '%s' "${b%.sh}"; }

MUT_RAN=0; MUT_SKIPPED=0; MUT_SKIP_LIST=""
MUT_ALL=(regress/mutate_*.sh)
MUT_TOTAL=${#MUT_ALL[@]}
if [ -n "${MUTATE_ONLY:-}" ]; then
  _mhit=0
  for _m in "${MUT_ALL[@]}"; do
    if printf '%s\n' "$(mut_key "$_m")" | grep -qE "${MUTATE_ONLY}"; then _mhit=$((_mhit + 1)); fi
  done
  if [ "$_mhit" -eq 0 ]; then
    echo "FATAL: MUTATE_ONLY='${MUTATE_ONLY}' matches NO mutation suite." >&2
    echo "  A narrowed gate that runs zero mutation suites would report a green it did not earn." >&2
    echo "  Matching suites are named mutate_<topic>_tb.sh; list them with:" >&2
    echo "    grep -m1 '^# mutate' regress/mutate_*.sh" >&2
    exit 2
  fi
  echo "(MUTATE_ONLY=${MUTATE_ONLY}: $((MUT_TOTAL - _mhit)) of $MUT_TOTAL mutation suites will be SKIPPED by mapping)"
fi

# One suite, or skipped-by-mapping. Sets MUT_RAN / MUT_SKIPPED and the list of
# skipped names, which the summary prints — so the log alone says what ran.
run_mutation_suite() {
  local n="$1"; shift
  local key
  key=$(mut_key "$n")
  if [ -n "${MUTATE_ONLY:-}" ] && ! printf '%s\n' "$key" | grep -qE "${MUTATE_ONLY}"; then
    MUT_SKIPPED=$((MUT_SKIPPED + 1)); MUT_SKIP_LIST="$MUT_SKIP_LIST $key"
    return 0
  fi
  MUT_RAN=$((MUT_RAN + 1))
  # THE SUITE'S OWN PRE-FLIGHT, AND NOW ITS DUT TOO. This is the wrapper rather
  # than 16 separate edits because it is the one place that knows which script
  # each suite is — and because a harness's own `trap cleanup EXIT` would
  # overwrite a trap installed inside it, so a per-harness EXIT trap cannot be
  # made to work without editing all sixteen by hand.
  #
  # The MUTABLE targets are dependencies for the same reason the script is: a
  # harness that mutates rtl/pe_soc.v is EXECUTING AGAINST that file, so an
  # external edit to it is the same interference class as an edit to the script,
  # and on 2026-09-25 that class produced a possible false survivor in
  # mutate_eth_mac_tb.sh while the guard could not see it. The harness already
  # publishes the exact file set it mutates, so the dependency list is already
  # written down; it just was not being read as one.
  _mut_deps=()
  if [ -f "$1" ]; then
    while IFS= read -r _md; do
      [ -n "$_md" ] && _mut_deps+=("$(chip_dep_abspath "$_md")")
    done < <(grep -m1 '^MUTABLE=' "$1" | cut -d'"' -f2 | tr ' ' '\n')
  fi
  chip_dep_stamp "suite_$n" "$1" ${_mut_deps[@]+"${_mut_deps[@]}"}
  # ... AND THE SAMPLER, which is the only mechanism that can see an external
  # actor RESTORING a target mid-run, because a restore leaves the end state
  # exactly as chip_dep_check expects to find it. That was the real 2026-09-25
  # incident. See regress/dep_guard.sh for why this is a declaration protocol
  # and not the pattern-detector that was measured failing on clean runs.
  #
  # THE LABEL IS THE HARNESS'S OWN, derived the way the harness derives it inside
  # chip_dep_expect, because that is where its declarations land. Deriving it
  # here from the script path gives the same string, and if the two ever
  # disagreed the failure would be visible rather than silent: sample_stop
  # reports every target the harness never declared, and a disagreement means it
  # declared none of them.
  _sampler_label="run_$(basename "$1")"
  chip_dep_sample_start "$_sampler_label" ${_mut_deps[@]+"${_mut_deps[@]}"}
  "$@"
  local rc=$?
  # The sampler is stopped before the check so its verdict is in hand either way,
  # and BOTH verdicts force the same INCONCLUSIVE: a suite whose DUT was
  # interfered with has verified nothing, whichever check noticed.
  local samp_rc=0
  chip_dep_sample_stop "$_sampler_label" || samp_rc=1
  if [ "$samp_rc" -ne 0 ] || ! chip_dep_check "suite_$n"; then
    echo "mutation suite $n: INCONCLUSIVE — the harness script or one of its MUTABLE targets changed while it was running" >&2
    return 4
  fi
  return $rc
}

if python3 tools/gen/signal_glossary.py --check >/dev/null 2>&1; then
  echo "signal glossary up to date"
else
  echo "STALE: wiki/reference/signal-names.md — run python3 tools/gen/signal_glossary.py"
  stale=1
fi
if python3 tools/gen/pin_budget.py --check >/dev/null 2>&1; then
  echo "protocol pin budget up to date"
else
  echo "STALE: wiki/reference/protocol-pin-budget.md — run python3 tools/gen/pin_budget.py"
  stale=1
fi
# The SRAM budget reads the PDK, which lives outside the repo. Skip it (loudly)
# when the PDK is not cloned rather than failing a regression on a missing
# dependency.
if [ -d "$HOME/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/lef" ]; then
  if python3 tools/gen/sram_budget.py --check >/dev/null 2>&1; then
    echo "sram budget up to date"
  else
    echo "STALE: wiki/reference/sram-budget.md — run python3 tools/gen/sram_budget.py"
    stale=1
  fi
  # The floorplan feasibility page is arithmetic over the LEF, the flow config
  # and the measured synthesis cache (STATUS item 5). It never runs the flow.
  if python3 tools/gen/floorplan_feasibility.py --check >/dev/null 2>&1; then
    echo "floorplan feasibility up to date"
  else
    echo "STALE: wiki/reference/floorplan-feasibility.md — run python3 tools/gen/floorplan_feasibility.py"
    stale=1
  fi
else
  echo "sram budget: SKIPPED (PDK not at ~/pdk/IHP-Open-PDK)"
fi

# The flow config's macro hardening metadata (E2): every SRAM macro the RTL
# instantiates needs a legal placement and hooks for all three of its supplies,
# or LibreLane leaves it unplaced and unpowered. Static check only -- no
# physical flow, DRC or LVS.
python3 tools/checks/macro_flow_config.py > /tmp/macro_flow.log 2>&1
macro_rc=$?
if [ "$macro_rc" -eq 0 ]; then
  echo "macro flow config: OK (placements, pin-to-net hooks and the Metal4 ladder complete)"
elif [ "$macro_rc" -eq 2 ]; then
  # E2-3: the geometry check cannot run without the PDK LEF. That is an
  # INCOMPLETE (a supported PDK-less skip), not a regression failure; the
  # checker returns 2 ONLY for that case, so findings and yosys failures
  # still land in the FAILED branch below.
  echo "macro flow config: SKIPPED (required PDK geometry unavailable)"
  cat /tmp/macro_flow.log
else
  echo "macro flow config: FAILED"
  cat /tmp/macro_flow.log
  stale=1
fi
# The gate's own negative tests (E2-1/E2-2/E2-3): a wrong pin-to-net mapping,
# a missing PDN ladder clause, a wrong/reversed layer pair, an exit-2 blanket
# skip and a yosys-elaboration failure must all behave as designed. The
# mutations run on a COPY of the flow config/PDN script, never the tracked
# files, and the harness reports SKIPPED when its baseline is incomplete.
if run_mutation_suite mutate_macro_flow_config.sh ./regress/mutate_macro_flow_config.sh > /tmp/mutate_macro_flow.log 2>&1; then
  if grep -q "^SKIPPED" /tmp/mutate_macro_flow.log; then
    echo "macro flow config negatives: SKIPPED (required PDK geometry unavailable)"
  else
    echo "macro flow config negatives: OK (pin-to-net, typed views, per-type geometry, ladder, skip and yosys-failure checks)"
  fi
else
  echo "macro flow config negatives: FAILED"
  tail -20 /tmp/mutate_macro_flow.log
  stale=1
fi
# The CRC constants are checked against the RevEng catalogue on every run, not
# just regenerated on request: a wrong polynomial or seed is a silent wrong
# answer on the wire, and it is cheap to catch here (the script also derives
# every constant before it writes anything).
if python3 tools/gen/crc_config.py --check >/dev/null 2>&1; then
  echo "crc config up to date"
else
  echo "STALE: wiki/reference/crc-config.md — run python3 tools/gen/crc_config.py"
  stale=1
fi
# The clock arithmetic is READ FROM THE RTL by the generator, so this gate is
# what makes the locked 60 MHz operating point stick: if pe_soc's CLK_HZ
# moves and the derived constants elsewhere are not updated with it, the page
# regenerates differently and this fails. It also asserts SPB=12 and
# TICKS_PER_BIT=260, which are the two constants the DRU and the UART firmware
# hardcode in other languages.
if python3 tools/gen/clock_arithmetic.py --check >/dev/null 2>&1; then
  echo "clock arithmetic up to date"
else
  echo "STALE: wiki/reference/clock-arithmetic.md — run python3 tools/gen/clock_arithmetic.py"
  stale=1
fi
# The block diagram is checked against rtl/ and run_all.sh: a block is drawn as
# instantiated only if some RTL names it, and as verified only if its TB is in
# run_all.sh. The hand-drawn ASCII version this replaces claimed a pin matrix
# that did not exist and a flop memory that had been replaced by an SRAM.
if python3 tools/gen/block_diagram.py --check >/dev/null 2>&1; then
  echo "block diagram up to date"
else
  echo "STALE: wiki/reference/block-diagram.md — run python3 tools/gen/block_diagram.py"
  stale=1
fi
# The HAND-WRITTEN wiki pages, against the five rules wiki/SCHEMA.md states and
# that nothing had ever checked. Every other documentation gate above is a
# GENERATED-page drift check — it compares wiki/reference/* against tools/gen/* —
# so a hand-written page could break every rule in the schema and no gate would
# notice. The known violations are PINNED in wiki/.known-rule-violations.txt, one
# line each with a reason, and the checker enforces the pin in BOTH directions: a
# NEW violation is red, and a pinned violation that has been FIXED is also red,
# because a baseline that silently outlives its defect is a checklist rather than
# a pin. Its negative control (13 cases, including the stale direction and the
# fail-closed paths) is regress/test_check_wiki_pages.sh.
if bash regress/check_wiki_pages.sh > /tmp/check_wiki_pages.log 2>&1; then
  echo "wiki page rules: OK ($(grep -c . /tmp/check_wiki_pages.log) line(s); see regress/check_wiki_pages.sh)"
else
  echo "wiki page rules: FAILED (see /tmp/check_wiki_pages.log)"
  tail -20 /tmp/check_wiki_pages.log
  stale=1
fi
# THE NEGATIVE CONTROL FOR BOTH GATES ABOVE, and this is the line whose absence
# is the real lesson. The gates had been wired and green while nothing ever ran
# the test that proves they can fail - so a future edit could break a case, or
# break the wiring, and the full regression would be green and say nothing about
# it. That is the same drift regress/check_harness_preflight.sh exists to stop for
# the mutation harnesses, one level up: there, the wiring was correct on the day
# it was written and nothing asserted it; here, the wiring was not even being
# executed. Its own cases are built on synthetic fixtures rather than on corpus
# pages, because a corpus page's state must never be a precondition for the test
# that verifies the corpus - that coupling was found by another worker, in the
# STALE case, after it had already been written that way.
if bash regress/test_check_wiki_pages.sh > /tmp/test_check_wiki_pages.log 2>&1; then
  echo "wiki gate negative control: OK ($(tail -1 /tmp/test_check_wiki_pages.log))"
else
  echo "wiki gate negative control: FAILED (see /tmp/test_check_wiki_pages.log)"
  tail -25 /tmp/test_check_wiki_pages.log
  stale=1
fi

# The DIAGRAMS, which until this gate existed had NO gate at all: 22 .puml
# sources and 84 renders whose entire value is that they are correct pictures of
# the code, with nothing in the suite that would have noticed one going stale,
# one gaining a syntax error, or one losing its colocated SVG. PlantUML makes
# this class of failure especially quiet: a .puml with a syntax error still
# RENDERS, as an error image, so the committed artifact is a valid PNG of a
# parser complaint and looks like a diagram to anything that only looks at files.
#
# It checks: every .puml parses (plantuml --check-syntax); every block has BOTH
# formats colocated under the multi-block naming convention (<stem>, then
# <stem>_001..<stem>_(N-1)); every render is neither older than its source nor
# different from a fresh render of it (byte comparison, which is what catches the
# data-source-line drift class an mtime test cannot see); and no render is
# unclaimed by any source. Aspect is checked too, as a smoke alarm for a layout
# accident rather than a style rule.
#
# The log paths are WORKTREE-SCOPED, unlike their neighbours above, on purpose:
# sharing /tmp paths across gate logs is a known open defect here (14 logs at the
# time of writing), and a new bare path would add to it rather than fix it. The
# digest is the same one regress/mutate_fwbus_tb.sh adopted.
_diag_wt=$(git rev-parse --show-toplevel 2>/dev/null | md5sum | cut -c1-8)
[ -n "$_diag_wt" ] || _diag_wt=shared
# The FILE-LINK gate. The gates above ask whether the wiki's own RULES hold; this
# one asks the question a reader actually has — does this link go anywhere. It is
# the check that would have caught the README gallery losing its `proto-` prefix,
# which broke 37 links in one commit and was found by a person reading the
# rendered page. Scoped to the LIVE surface (wiki/** minus raw/, README, docs/) by
# ruling: reviews/ records are evidence, and a path in one that was true when
# written must not be rewritten to follow a rename, nor flagged forever.
if bash regress/check_wiki_links.sh > /tmp/check_wiki_links.log 2>&1; then
  echo "document links: OK ($(grep -m1 'document(s) scanned' /tmp/check_wiki_links.log | sed 's/^ *//'))"
else
  echo "document links: FAILED (see /tmp/check_wiki_links.log)"
  tail -20 /tmp/check_wiki_links.log
  stale=1
fi
if bash tools/diag/check_diagrams.sh > "/tmp/check_diagrams.${_diag_wt}.log" 2>&1; then
  echo "diagrams: OK ($(grep -c '^  ok:' "/tmp/check_diagrams.${_diag_wt}.log") check(s) passed; see tools/diag/check_diagrams.sh)"
else
  echo "diagrams: FAILED (see /tmp/check_diagrams.${_diag_wt}.log)"
  tail -20 "/tmp/check_diagrams.${_diag_wt}.log"
  stale=1
fi
# The OTHER direction of the document index. check_wiki_links.sh proves every
# link POINTS AT SOMETHING; nothing proved that every figure is LISTED, which is
# the defect reviews/2026-09-26/DOCS-ACCURACY-REVIEW-PASS11.md F3 recorded (47 of
# 54 renders, four act sets absent) and which the regenerated gallery closed
# WITHOUT anything keeping it closed. An index that is complete by hand and
# unchecked is a list that drifts the first time someone adds a figure. Its
# self-test is wired with it rather than left on request, for the reason every
# other gate's is: a checker that stops detecting reports OK on a broken tree.
if bash regress/check_doc_index.sh > "/tmp/check_doc_index.${_diag_wt}.log" 2>&1; then
  echo "document index: OK ($(grep -m1 'render(s) listed' "/tmp/check_doc_index.${_diag_wt}.log" | sed 's/^ *//'))"
else
  echo "document index: FAILED (see /tmp/check_doc_index.${_diag_wt}.log)"
  tail -20 "/tmp/check_doc_index.${_diag_wt}.log"
  stale=1
fi
if bash regress/check_doc_index.sh --self-test > "/tmp/check_doc_index_selftest.${_diag_wt}.log" 2>&1; then
  echo "document index gate self-test: OK ($(grep -c 'ok:   self-test' "/tmp/check_doc_index_selftest.${_diag_wt}.log") of 3 cases behaved correctly)"
else
  echo "document index gate self-test: FAILED (see /tmp/check_doc_index_selftest.${_diag_wt}.log)"
  tail -20 "/tmp/check_doc_index_selftest.${_diag_wt}.log"
  stale=1
fi
# Its NEGATIVE CONTROL, in the suite and not merely available on request. A gate
# that stops detecting is worse than no gate: it reports OK on a tree that is
# broken, and the suite goes green on a claim nothing is testing. The self-test
# plants a stale render, a hand-edited render, a broken .puml, a committed error
# image, an unclaimed render and a missing block render, and requires the checker
# to fail on every one while passing on an untouched synthetic fixture. It also
# verifies each PLANTING actually changed something, because a no-op planting
# otherwise reports itself as a broken checker.
if bash tools/diag/check_diagrams.sh --self-test > "/tmp/check_diagrams_selftest.${_diag_wt}.log" 2>&1; then
  echo "diagrams gate self-test: OK ($(grep -c 'ok:   self-test' "/tmp/check_diagrams_selftest.${_diag_wt}.log") of $(grep -c 'self-test —' "/tmp/check_diagrams_selftest.${_diag_wt}.log") cases behaved correctly)"
else
  echo "diagrams gate self-test: FAILED (see /tmp/check_diagrams_selftest.${_diag_wt}.log)"
  tail -20 "/tmp/check_diagrams_selftest.${_diag_wt}.log"
  stale=1
fi
# THE NUMBERS GATE, and its self-test, in the suite at last. Nothing invoked
# tools/diag/delay_lattice.py: run_all.sh referenced seventy tool and script
# paths and this was not one of them, so a gate that recomputes every "N clocks
# = X us" in the timing figures and pages was a CHECK NOBODY PERFORMED. That is
# the same hole one level up as a testbench nothing runs -- the suite is green
# on a claim nothing is testing, which is the failure this project keeps paying
# for. Wiring it is not an endorsement of its scope: it checks the pages its
# owner maintains, and it is deliberately not asked about the rest of the wiki.
#
# The self-test is wired BESIDE the gate rather than left available on request,
# for the reason the diagram gate's is: a gate that stops detecting reports OK
# on a broken tree. The step counts are read out of the log at run time instead
# of being written into this line, because a hardcoded "13/13" is a number that
# goes stale in a file nobody re-reads -- and the count has already moved once.
if python3 tools/diag/delay_lattice.py > "/tmp/delay_lattice.${_diag_wt}.log" 2>&1; then
  echo "delay-lattice numbers: OK ($(grep -m1 '^RESULT' "/tmp/delay_lattice.${_diag_wt}.log"))"
else
  echo "delay-lattice numbers: FAILED (see /tmp/delay_lattice.${_diag_wt}.log)"
  grep -E '^(FAIL|RESULT)' "/tmp/delay_lattice.${_diag_wt}.log" | head -10 | sed 's/^/    /'
  stale=1
fi
if python3 tools/diag/delay_lattice.py --selftest > "/tmp/delay_lattice_selftest.${_diag_wt}.log" 2>&1; then
  echo "delay-lattice gate self-test: OK ($(grep -c '^ok' "/tmp/delay_lattice_selftest.${_diag_wt}.log") check(s) passed, $(grep -c '^FAIL' "/tmp/delay_lattice_selftest.${_diag_wt}.log") failed)"
else
  echo "delay-lattice gate self-test: FAILED (see /tmp/delay_lattice_selftest.${_diag_wt}.log)"
  tail -20 "/tmp/delay_lattice_selftest.${_diag_wt}.log"
  stale=1
fi
# The local presentation viewer's fit arithmetic has its own focused check.
# This uses an embedded SVG fixture and does not consume the project diagrams,
# which are maintained as PlantUML source in diagrams/.
if python3 tools/checks/canvas_viewer.py > /tmp/canvas_viewer.log 2>&1; then
  echo "canvas viewer: OK"
else
  echo "canvas viewer: FAILED"
  cat /tmp/canvas_viewer.log
  stale=1
fi

# Formal safety proofs (yosys built-in sat; sby and every SMT solver are
# absent on this host). Proves the pe_pinmux open-drain invariant and the
# pe_eth_tx frame/IFG/underrun claims. Bounded, and the depth at which each
# property becomes non-vacuous — plus the two targets that are NOT proved —
# are documented in reviews/2026-09-25/FORMAL-VERIFICATION.md. A "proved" that
# never reaches the state it is about is worse than none, so this gate ships
# with its non-vacuity mutants recorded rather than a bare green tick.
# The FORMAL-IFDEF GATE: `ifdef FORMAL` instrumentation (the observation ports
# for formal targets 2 and 4) must never be live on a synthesis path. This
# checks that no build script defines FORMAL, and that a real synthesis
# elaboration contains no fv_* wire at all.
if bash tools/check_formal_ifdef.sh > /tmp/check_formal_ifdef.log 2>&1; then
  echo "formal-ifdef gate: OK (FORMAL never defined on a synthesis path; taps compile out)"
else
  echo "formal-ifdef gate: FAILED (see /tmp/check_formal_ifdef.log)"
  tail -12 /tmp/check_formal_ifdef.log
  stale=1
fi

if bash formal/run_formal.sh > /tmp/run_formal.log 2>&1; then
  echo "formal safety proofs: OK (see formal/results/summary.txt for per-property status)"
else
  echo "formal safety proofs: FAILED (counterexample or build error)"
  tail -20 /tmp/run_formal.log
  stale=1
fi

# The non-vacuity evidence for those proofs: every proof must kill the mutant
# that attacks its claim. Runs in its own proof shape per case (BMC or
# induction) and takes the run lock reentrantly via CHIP_RUN_LOCK_HELD.
if bash formal/mutants.sh > /tmp/run_formal_mutants.log 2>&1; then
  echo "formal mutant checks: OK (see formal/results/mutants.txt for the per-mutant table)"
else
  echo "formal mutant checks: FAILED (a mutant survived -- a claim is a blind spot)"
  tail -20 /tmp/run_formal_mutants.log
  stale=1
fi

# The chip<->host wait-word CROSS-CHECK. The chip's 0xFFFF filler (rtl/pe_ctrl.v)
# and the host's leading-filler skip (tools/host_bridge/pe_frame.py) are two
# independent implementations of one contract, and each side's own tests run
# against its OWN filler bytes -- the actual bytes crossing the SPI wire are
# what neither covers. This gate feeds the chip-produced stream to the host's
# real stripper for every 0..15 wait words, so the seam that held finding B1
# cannot silently reopen. It also asserts an all-filler stream raises rather
# than decoding to a plausible-looking success.
if python3 regress/cross_check_wait_words.py > /tmp/cross_wait_words.log 2>&1; then
  echo "wait-word cross-check: OK (chip filler <-> host stripper, 0..15)"
else
  echo "wait-word cross-check: FAILED"
  cat /tmp/cross_wait_words.log
  stale=1
fi

# The RUN LOCK's process-tree contract. The lock is what keeps two mutation
# harnesses off the same RTL, and its failure mode is quiet: flock releases when
# the holder dies, but the holder's CHILDREN do not, so a killed run used to
# leave a mutator running AND the lock held (a refusal "for a lock nobody is
# holding"). This gate proves the fix on real process trees with real signals --
# SIGINT, SIGTERM, SIGKILL (no trap can run, so the watchdog covers it), a clean
# exit, a reentrant child, and a background subshell that must NOT fire the
# kill trap. It uses a private lock file, so it never touches the worktree lock
# and is safe to run beside a real run.
if bash regress/test_run_lock.sh > /tmp/test_run_lock.log 2>&1; then
  echo "run-lock process tree: OK (every signal reaps the run; no bystander killed)"
else
  echo "run-lock process tree: FAILED"
  cat /tmp/test_run_lock.log
  stale=1
fi

# The R2 golden package the conformance harness consumes: tb/r2-vectors/ is a
# DERIVED SNAPSHOT of the host's package (reviews/2026-09-25/r2-hex), and this
# gate is what stops it quietly becoming a second source of truth. The class
# died twice on 2026-09-25/26 — the copy sat at 18 steps while the host was at
# 22, the derived table never named three of its own steps, and the package
# notice claimed "every golden step passes" while the same file's conformance
# line said 15/15. Every existing gate compared the .hex BYTES and none looked
# at the FLAGS. Unlike the R3 gate, manifest.json is NOT excluded here: this
# snapshot is a byte copy, and the chip's evidence for each confirmation lives
# in reviews/2026-09-25/R2-HELD-CORE-CHIP-SIDE.md rather than in an edited copy
# of somebody else's file.
if "$REPO_ROOT/regress/check_r2_package.sh" > /tmp/check_r2_package.log 2>&1; then
  echo "R2 golden package: OK ($(tail -1 /tmp/check_r2_package.log))"
else
  echo "R2 golden package: FAILED (snapshot drift, or a claim that does not match its own flags)"
  cat /tmp/check_r2_package.log
  fail=$((fail+1))
  failed_names+=("check_r2_package")
fi

# The R3 golden package the conformance harness consumes, in TWO places: the
# review artifact and the TB's copy. A conformance gate is only worth the bytes
# it compares, so the .hex streams must be byte-identical and the checked-in
# include must match what the generator derives from the manifest (which also
# re-CRCs every request frame and re-checks every length field).
#
# manifest.json is EXCLUDED from the byte comparison, deliberately: it is the one
# file the chip side annotates, because chip_confirmed is a claim about the chip
# and the evidence behind it lives with the harness. That is the R2 precedent
# exactly (the two R2 manifests differ, and the TB-side one carries the chip's
# citations). reviews/2026-09-25/r3-hex/manifest.json stays the host's own byte
# for byte. What is asserted INSTEAD is stronger than a byte diff of that file:
# annotate_r3_confirmations.py --check re-derives the claim from the pinned
# divergences and requires the vector/step structure, the file names and the byte
# counts to still match the host's copy, so the harness can never end up
# comparing the chip's own edits to itself.
if diff -r --exclude='*.vh' --exclude='R3_KNOWN_DIVERGENCES.txt' \
        --exclude='manifest.json' \
        reviews/2026-09-25/r3-hex tb/r3-vectors \
     > /tmp/r3_package_diff.log 2>&1 \
   && python3 tools/gen/gen_r3_vectors.py --check >> /tmp/r3_package_diff.log 2>&1 \
   && python3 tools/gen/annotate_r3_confirmations.py --check \
        >> /tmp/r3_package_diff.log 2>&1; then
  echo "R3 golden package: OK (tb copy byte-exact; include and confirmations current)"
else
  echo "R3 golden package: FAILED (package drift or a stale generated include)"
  cat /tmp/r3_package_diff.log
  stale=1
fi

# The I2C pin timing, measured on the wire across all 60 tick phases against the
# standard-mode table. This is a SPEC check, so it runs every time rather than on
# request -- a firmware edit that shortens a delay is exactly the change that
# looks harmless in review.
if python3 tools/checks/i2c_timing.py > /tmp/i2c_timing.log 2>&1; then
  echo "i2c pin timing: OK (tLOW/tHIGH/period clear their floors)"
else
  echo "i2c pin timing: FAILED"
  cat /tmp/i2c_timing.log
  stale=1
fi

# The I2C TRANSACTION, end to end on the emulator against an independent slave
# model: address, ACKs, the read path, the repeated START, timing and grammar,
# across all 60 tick phases. The RTL TB is the same claim on real RTL; these
# must agree, and a disagreement is a signal (STATUS gotcha 11).
if python3 tools/checks/i2c_xfer_check.py > /tmp/i2c_xfer.log 2>&1; then
  echo "i2c transaction: OK (bytes, ACKs, read path, timing, grammar)"
else
  echo "i2c transaction: FAILED"
  cat /tmp/i2c_xfer.log
  stale=1
fi

# The I2C testbench's own mutation suite. It is slower than the rest, but a
# testbench nobody mutation-tests is a testbench that quietly stops testing --
# and this one has already been caught being vacuous twice (a wrong edge index
# that made both interval checks unfailable, and a missing interval check).
if run_mutation_suite mutate_i2c_tb.sh ./regress/mutate_i2c_tb.sh > /tmp/mutate_i2c.log 2>&1; then
  echo "i2c TB mutations: OK (no unexplained survivors)"
else
  echo "i2c TB mutations: FAILED"
  tail -20 /tmp/mutate_i2c.log
  stale=1
fi

# The SPI testbench's mutation suite. Same reasoning: SPI is a baseline protocol
# and its TB makes a strong claim (the slave decodes the master's byte MSB-first
# from the pins), so the claim is tested by making it false.
# The three TIMING testbenches' suite. These are the only cases in the repository
# whose DUT is partly firmware, so their mutations are firmware edits: a cell one
# clock short, a pulse 0.75 ms wide, a bit order reversed, a start signal 70x too
# short. It runs its 14 cases in parallel on PRIVATE COPIES of the firmware and
# then cmp-verifies that the tree was never written to -- a stronger statement
# than "restored correctly". It is the slowest suite here (the servo TB is 66 s
# per case) and runs at MUTATE_TIMING_JOBS, default 6.
if run_mutation_suite mutate_timing_tb.sh ./regress/mutate_timing_tb.sh > /tmp/mutate_timing.log 2>&1; then
  echo "timing TB mutations: OK (no unexplained survivors)"
else
  echo "timing TB mutations: FAILED"
  tail -20 /tmp/mutate_timing.log
  stale=1
fi

if run_mutation_suite mutate_spi_tb.sh ./regress/mutate_spi_tb.sh > /tmp/mutate_spi.log 2>&1; then
  echo "spi TB mutations: OK (no unexplained survivors)"
else
  echo "spi TB mutations: FAILED"
  tail -20 /tmp/mutate_spi.log
  stale=1
fi

# The frame buffer's TB, mutation-tested on BOTH implementations (the macro and
# the FLOP=1 fallback), because the fallback exists to stand in for the macro --
# so a test that only covered one would leave that claim unchecked.
if run_mutation_suite mutate_fbuf_tb.sh ./regress/mutate_fbuf_tb.sh > /tmp/mutate_fbuf.log 2>&1; then
  echo "fbuf TB mutations: OK (no unexplained survivors)"
else
  echo "fbuf TB mutations: FAILED"
  tail -20 /tmp/mutate_fbuf.log
  stale=1
fi

if run_mutation_suite mutate_eth_mac_tb.sh ./regress/mutate_eth_mac_tb.sh > /tmp/mutate_eth_mac.log 2>&1; then
  echo "eth_mac TB mutations: OK (no unexplained survivors)"
else
  echo "eth_mac TB mutations: FAILED"
  tail -20 /tmp/mutate_eth_mac.log
  stale=1
fi

# The SoC-level Ethernet TB is the only proof a PROGRAM can consume a frame,
# so it gets the same treatment the block TBs get.
if run_mutation_suite mutate_eth_soc_tb.sh ./regress/mutate_eth_soc_tb.sh > /tmp/mutate_eth_soc.log 2>&1; then
  echo "eth_soc TB mutations: OK (no unexplained survivors)"
else
  echo "eth_soc TB mutations: FAILED"
  tail -20 /tmp/mutate_eth_soc.log
  stale=1
fi

# The loader is how a program reaches silicon; its TB gets the same gate. The
# run-transition cases (run rising in W_IDLE, W_PULSE or W_DONE) are the ones
# the independent review found missing.
if run_mutation_suite mutate_ctrl_tb.sh ./regress/mutate_ctrl_tb.sh > /tmp/mutate_ctrl.log 2>&1; then
  echo "ctrl TB mutations: OK (no unexplained survivors)"
else
  echo "ctrl TB mutations: FAILED"
  tail -20 /tmp/mutate_ctrl.log
  stale=1
fi

# The I2C transaction TB's DUT is the firmware, so its mutations are firmware
# edits (bit order, repeated START, tLOW, STOP, arbitration, the tHD;DAT hold,
# the read accumulator). Both the .pe and the .hex are restored and verified.
if run_mutation_suite mutate_i2c_xfer_tb.sh ./regress/mutate_i2c_xfer_tb.sh > /tmp/mutate_i2c_xfer.log 2>&1; then
  echo "i2c_xfer TB mutations: OK (no unexplained survivors)"
else
  echo "i2c_xfer TB mutations: FAILED"
  tail -20 /tmp/mutate_i2c_xfer.log
  stale=1
fi

# The word engine's unit suite: the integration split bit_en into tx/rx
# enables, and the TB's directed split case is what proves the sides are
# independent.
if run_mutation_suite mutate_serdes_tb.sh ./regress/mutate_serdes_tb.sh > /tmp/mutate_serdes.log 2>&1; then
  echo "serdes TB mutations: OK (no unexplained survivors)"
else
  echo "serdes TB mutations: FAILED"
  tail -20 /tmp/mutate_serdes.log
  stale=1
fi

# The word-engine integration: the plan's four required mutations (TX hold,
# RX skip, doubled cell enable, strobe cross-wire) plus the two alignment
# defects and the grid-aligned load. Each must fail tb_pe_soc_serdes.
if run_mutation_suite mutate_soc_serdes_tb.sh ./regress/mutate_soc_serdes_tb.sh > /tmp/mutate_soc_serdes.log 2>&1; then
  echo "soc serdes TB mutations: OK (no unexplained survivors)"
else
  echo "soc serdes TB mutations: FAILED"
  tail -20 /tmp/mutate_soc_serdes.log
  stale=1
fi

# The codec pipeline unit TB. The integration instantiated pe_codec_mux twice
# in pe_soc, so its unit suite now guards shared silicon: the documented CAN
# preset 0x51, the ones-only cfg[7] rule and the cfg[6:4] run length, the
# registered clr/rx_err contract (clr reaches every stage), and the pipeline
# order / bypass subsets / half_phase. All 13 mutations must fail the TB.
if run_mutation_suite mutate_codec_tb.sh ./regress/mutate_codec_tb.sh > /tmp/mutate_codec.log 2>&1; then
  echo "codec TB mutations: OK (no unexplained survivors)"
else
  echo "codec TB mutations: FAILED"
  tail -20 /tmp/mutate_codec.log
  stale=1
fi

# The 10BASE-T TX frame engine, unit level (suite 11). 18 mutations over
# pe_eth_tx.v: the three prelude/SFD traps, the CRC field-mode traps, pad as
# data, the IFG, runt/jabber, the underrun fault, constant idle, octet order
# and the done pulse. Two of them (pad-extra, ifg-95) SURVIVED the first
# version of the suite and found two real gaps in tb_pe_eth_tx.v, which the
# suite's own record carries.
if run_mutation_suite mutate_ctrl_r3_tb.sh ./regress/mutate_ctrl_r3_tb.sh > /tmp/mutate_ctrl_r3.log 2>&1; then
  echo "ctrl R3 debug mutations: OK (no unexplained survivors)"
else
  echo "ctrl R3 debug mutations: FAILED"
  tail -20 /tmp/mutate_ctrl_r3.log
  stale=1
fi

if run_mutation_suite mutate_eth_tx_tb.sh ./regress/mutate_eth_tx_tb.sh > /tmp/mutate_eth_tx.log 2>&1; then
  echo "eth_tx TB mutations: OK (no unexplained survivors)"
else
  echo "eth_tx TB mutations: FAILED"
  tail -20 /tmp/mutate_eth_tx.log
  stale=1
fi

# The same path, integration level (suite 12): 7 mutations across pe_soc.v,
# pe_eth_mac.v and the wrapper -- the owner mux, the pad overlay, the G6 pad
# mapping, the cell-boundary pacing, the RX capture, the FCS verdict
# convention and the window's push wrap. The pad mapping is only visible at
# the PAD, so this harness runs BOTH tb_pe_soc_eth_loop and the pad-level
# case in tb_tt_um_protocol_emulator.
if run_mutation_suite mutate_eth_tx_loop_tb.sh ./regress/mutate_eth_tx_loop_tb.sh > /tmp/mutate_eth_tx_loop.log 2>&1; then
  echo "eth_tx loopback TB mutations: OK (no unexplained survivors)"
else
  echo "eth_tx loopback TB mutations: FAILED"
  tail -20 /tmp/mutate_eth_tx_loop.log
  stale=1
fi

# The three advanced BUS protocols' TBs, mutation-tested together. Their DUT
# is the FIRMWARE, so the mutations are firmware edits -- the read-burst ACK,
# the SCL stretch poll, the mode-3 idle level, the CRC's reduction step, the
# CRC's comparison, the CTS wait, the RTS assertion -- and each TB must catch
# every one that applies to it. A survivor means the TB does not test what it
# claims, which is the failure mode this project treats as worse than a red.
if run_mutation_suite mutate_fwbus_tb.sh ./regress/mutate_fwbus_tb.sh > /tmp/mutate_fwbus.log 2>&1; then
  echo "fw-bus TB mutations: OK (no unexplained survivors)"
else
  echo "fw-bus TB mutations: FAILED"
  tail -20 /tmp/mutate_fwbus.log
  stale=1
fi

# The harness-edit pre-flight's OWN test. It is a gate for the same reason the
# run lock's contract test is: a guard that cannot fail looks exactly like a
# guard that works, and this project's log holds three rules that reported
# numbers they had never been shown to compute. The negative control (a guard
# whose comparison never fires) fails 3 of its 7 cases, so the test is not
# vacuous. It uses a private stamp directory and touches nothing in the repo, so
# it is safe to run while a real run holds the worktree lock.
if bash "$REPO_ROOT/regress/test_dep_guard.sh" > /tmp/test_dep_guard.log 2>&1; then
  echo "harness-edit pre-flight: OK (fires on a changed script, quiet on an unchanged one)"
else
  echo "harness-edit pre-flight: FAILED"
  cat /tmp/test_dep_guard.log
  stale=1
fi

if [ -n "${MUTATE_ONLY:-}" ]; then
  echo "mutation suites: $MUT_RAN ran, $MUT_SKIPPED SKIPPED by mapping (MUTATE_ONLY=${MUTATE_ONLY})"
  [ -n "$MUT_SKIP_LIST" ] && echo "  skipped:$MUT_SKIP_LIST"
  [ "$MUT_RAN" -eq 0 ] && { echo "  FATAL: zero mutation suites ran"; exit 2; }
else
  echo "mutation suites: $MUT_RAN ran (full gate — no narrowing)"
fi

[ "$stale" -eq 0 ] || exit 1
[ "$lint_rc" -eq 0 ] || { echo "lint gate FAILED (see above)"; exit 1; }
