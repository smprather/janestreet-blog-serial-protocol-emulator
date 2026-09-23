# Ethernet SoC review — 2026-09-23

**Reviewed code:** `9a84c6e`, including integration `1d61011` and its mutation
suite `04d3c13`. Review and builds used isolated archives under `/tmp` while
the Pi harness continued the SPI loader work.

## E1 — P1: reclaiming frame 1 corrupts an in-flight frame 2

**Open.** Firmware's `OUT BUFCTRL, A` resets the MAC write pointer and room
while the MAC may already be receiving the next frame. The MAC does not abort
that frame or adjust its payload count/start bookkeeping. It subsequently
reports a good CRC and `frame_valid`, but `pe_soc` computes a wrapped window
start from the reset pointer minus the full payload length. Firmware reads
unwritten memory while believing it has a valid frame.

Locations: `rtl/pe_soc.v` (`eth_buf_reset`, `eth_frame_start` and window capture),
`rtl/pe_eth_mac.v` (independent `buf_reset` block), and `firmware/eth_rx.pe`
(`done` reclaims the whole ring).

### Reproduction

Two frames, each with a 200-byte payload and correct FCS, separated by 96 idle
bit cells. The length fits the firmware's documented 8-bit counter limit.
This uses the real SRAM model and unmodified firmware/RTL. The test extends the
existing SoC wire driver and observes the checksum at each firmware completion.

| Case | Accepted / rejected | Firmware checksums | Result |
|---|---|---|---|
| 200-byte payloads, 96-cell gap | 2 / 0 | `3c`, then `xx` (expected `04`) | FAIL |
| 200-byte payloads, 600-cell gap | 2 / 0 | `3c`, `04` | PASS |
| 46-byte payloads, 96-cell gap | 2 / 0 | `ab`, `59` | PASS |

The failing trace shows the first reclaim in MAC state 2 (`S_PAYLOAD`), with
frame 2 already at `pay_cnt=12`, `wptr=212`. At frame 2's acceptance, the pointer
is 188 and the length is 200, so the window starts at **2036**, rather than at
the beginning of a contiguous 200-byte frame. Both CRC verdicts are good.

The header comment's timing argument uses the short ARP demonstration's
roughly 500-cycle consumption time. A 200-byte walk takes about 37 us, allowing
the next frame to enter its payload before the reclaim. This is distinct from
the documented single-port read/write collision and header-overwrite limits.

**Required correction:** make reclaim and receive ownership coherent. A frame
must remain intact until consumed, or an overlapping arrival must be rejected
explicitly and its metadata withheld. Do not silently rebase the write pointer
inside a frame that will later be published as valid. Add a permanent
consecutive-frame test that does not wait for firmware consumption before
driving the next frame.

[Reproducer](eth-soc/window_reclaim.v), [failing trace](eth-soc/min-gap.txt),
[long-gap control](eth-soc/long-gap.txt), [ARP-size control](eth-soc/arp-gap.txt).
Build with the same source/model list as `tb_pe_soc_eth`, replacing its TB file
with the reproducer. Run from `sim/` so `../firmware/eth_rx.hex` resolves.
Default run fails; `+GAP=600` and `+LEN=46` are the two passing controls.

## Regression

Fresh archived `./regress/run_all.sh --fast -j4`: exit 0, **27/27 RTL**,
**19/19 firmware**, lint/elaboration and all five mutation suites pass.
[Full output](eth-soc/regression.txt). E1 is outside the current permanent TB's
traffic schedule: it waits for firmware completion between good frames.

## Preliminary hardening checks

The user authorized periodic synthesis and STA to detect RTL that cannot be
hardened. This pass ran native Yosys mapping and OpenSTA, without physical
flow, DRC or LVS.

- Mapped the SoC against sg13g2 typical standard cells. `check -assert` reports
  **0 problems**. The flattened design contains **2,981 standard cells and
  2 SRAM macro instances**; Yosys's eight `$scopeinfo` records are metadata.
  Both intended DDR latches map to characterized `sg13g2_dlhq_1` cells.
- OpenSTA links both SRAM instances with their Liberty timing models at the
  slow, typical and fast corners. No missing-cell or unconstrained-path
  diagnostics were reported by the screening script's `check_setup`.
- This is an **unplaced, ideal-clock screen**: period 16.667 ns, setup/hold
  uncertainty 1.0/0.25 ns, input/output max delay 3.3334 ns, input min delay 0,
  input transition 0.1 ns and output load 0.02 pF. These I/O assumptions are
  screening bounds, not a verified board contract; no wire parasitics or
  physical timing repair is included.
- No negative setup paths in these reports. The slow-corner instruction-SRAM
  path has **+2.0473 ns** slack; the global max report gives 0 because a
  transparent-latch path uses time borrowing. This is not a 0-margin flop path.
- Hold and electrical limits **do fail** before physical repair. Worst min
  slack: slow **−0.8692 ns**, typical **−0.6065 ns**, fast **−0.4778 ns**.
  The slow worst path is the exposed host data input directly into instruction
  SRAM under the assumed 0 ns input-min delay. Slew/cap violations also appear
  on unbuffered high-fanout logic. These require constraint/interface review
  and physical repair; these results do not establish that hardening is clean
  or impossible. Revisit the host path when the SPI loader lands.

Evidence: [synthesis](eth-soc/synthesis.txt), [slow STA](eth-soc/sta-slow.txt),
[typical STA](eth-soc/sta-typ.txt), [fast STA](eth-soc/sta-fast.txt).
The accompanying Yosys/Tcl scripts preserve the local PDK paths used for this
screen and write their netlist in the working directory. Run them in an
isolated checkout; archived transcripts identify this reviewed revision.
