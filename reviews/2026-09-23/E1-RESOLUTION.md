# E1 resolution — coherent reclaim / receive ownership

**Finding:** E1 (P1) in `reviews/2026-09-23/ETHERNET-SOC-REVIEW.md`, reviewed at
`9a84c6e`.
**Status:** fixed. Consumer-owned reclaim replaced the destructive whole-ring
reclaim; the review's reproducer passes all three cases, and the schedule is now
a permanent regression.

## Root cause (confirmed by the archived trace)

Firmware's `OUT BUFCTRL, A` drove `pe_eth_mac.buf_reset`, which reset `wptr` and
`room` unconditionally. With a 200-byte payload the firmware walk (~37 µs)
outlasts the 96-bit inter-frame gap (~9.6 µs), so the reclaim for frame A lands
while frame B is already in `S_PAYLOAD`. The MAC then finished B with
`frame_start` unchanged but `wptr` rebased, so `pe_soc` published
`frame_len = 200`, `frame_ptr = 188`, and a window start of `188 - 200 mod 2048
= 2036` — twelve bytes of never-written memory. Both CRC verdicts were good;
only the window was a lie.

This was a *destructive* reclaim racing the receiver, not the documented
single-port read collision or the one-window/two-frame limit.

## Fix

**Two pointers, two owners.** `pe_eth_mac` keeps the producer's `wptr` and adds
the consumer's `rptr`. `room` is the free space ahead of the producer and
`used = BUF_BYTES - room` is what is allocated; the producer never touches
`rptr` and the consumer never touches `wptr`.

- New inputs: `buf_consume` (pulse) and `buf_consume_addr[AW-1:0]`.
- On `buf_consume`, `rptr` advances to the named address and `room` grows by
  the forward distance. The step is accepted only when the distance is no
  greater than `used`: a duplicate (distance 0) is a no-op, and a backward
  address is ignored rather than clamped, so a firmware mistake cannot
  over-credit `room` and hand out memory that still holds an unconsumed frame.
- `buf_reset` is retained but demoted to a testbench/debug control: it is the
  whole-ring reset and is only legal with nothing in flight. The SoC wires it
  to `1'b0` and never pulses it in traffic.
- `pe_soc` decodes `BUFCTRL` (IO `0xE`) as `buf_consume`, with
  `buf_consume_addr = eth_buf_raddr` — the current `BUFBYTE` window position.
  The window pointer is monotonically forward across frames (a new frame starts
  where the previous one ended), so releasing "up to the window pointer" frees
  exactly the frames firmware walked and none it did not.
- `firmware/eth_rx.pe` is unchanged in instructions; its `BUFCTRL` write and
  comments now say "release consumed bytes", not "reclaim the ring".

An in-flight frame's `frame_start`/`pay_cnt`/`wptr` are therefore never modified
by a reclaim, and unconsumed frames cannot be overwritten because `room` only
counts space that the consumer has actually released.

## Evidence

**The review's reproducer, on the fixed RTL** (`e1-recheck/reproducer-fixed.txt`):

| Case | Accepted / rejected | Firmware checksums | Result |
|---|---|---|---|
| 200-byte payloads, 96-cell gap | 2 / 0 | `3c`, `04` | PASS |
| 200-byte payloads, 600-cell gap | 2 / 0 | `3c`, `04` | PASS |
| 46-byte payloads, 96-cell gap | 2 / 0 | `ab`, `59` | PASS |

The decisive trace line: `RECLAIM state=2 pay_cnt=12 wptr=212` — the release
still happens mid-frame, and `wptr` stays 212. Frame B then publishes
`ptr=400, start=200`, and the walk reads only frame B's bytes.

**Permanent regression.** `tb/tb_pe_soc_eth.v` now drives two 200-byte frames
with a 96-cell gap and does not wait for the first to be consumed; a completion
monitor checks each checksum as firmware commits it, so a corrupted first frame
cannot be masked by the second. The case failed before the fix (`sum=xx
want=bc`) and passes after. `tb_pe_eth_mac.v` gained block-level ownership
checks: a consume moves only `rptr`, a duplicate frees nothing, a backward
address is ignored, and a consume pulsed while a frame is mid-payload leaves the
frame's bytes and `wptr` intact.

**Mutation gates at the original resolution.** `regress/mutate_eth_mac_tb.sh`
then had 16 mutations (16 detected, 0 survived), including `consume-rebases-wptr`,
`consume-ignored` and `consume-no-guard`. `regress/mutate_eth_soc_tb.sh` is now
8 (8 detected, 0 survived), including `destructive-reclaim`, which restores the
E1 wiring and is caught by the consecutive-frame case.

The 2026-09-23 independent E1 accounting-coverage audit later added permanent
tests and three more mutations for consume collisions at type settle, bad-frame
settle, and `S_ERR`. A second coverage pass added a full-ring bad-FCS settle
reclaim test and mutation. At that stage, the MAC gate was 22/22. See
`reviews/2026-09-23/E1-E2-FOLLOWUP-REVIEW.md`.

**Full regression at the original resolution** (`e1-recheck/regression-fixed.txt`):
RTL 27/27, firmware 19/19, lint clean, five mutation suites green, all
generated-doc gates green. Later regression counts are recorded above and in
the current handoff.

**Hardening screen** (authorized 2026-09-23; unplaced, ideal clock, same scripts
as the review — `e1-recheck/sta-summary.txt` and the three `sta-*-fixed.txt`):

- Yosys mapping: both `check -assert` passes report 0 problems.
- Worst hold slack is unchanged from the review's screen (slow −0.87 vs
  −0.8692, typical −0.61 vs −0.6065, fast −0.48 vs −0.4778); setup remains
  nonnegative under the screening assumptions, no missing cells or
  unconstrained-path diagnostics were introduced. The pre-existing hold and
  electrical (slew/cap) failures still require constraint review and physical
  repair; this screen does not establish that hardening is clean.
- Cost of the ownership logic: `pe_eth_mac` mapped 17,315 → 20,200 µm²,
  `pe_soc` 50,895 → 53,731 µm².

## E1 published-byte ownership follow-up (2026-09-23)

A later independent audit found that `used` also includes an in-flight frame.
An over-read consume could release those unpublished bytes, then receive a
second credit from that frame's rollback or TYPE FCS windback. The MAC now
tracks `published_used` and accepts a release only within both `used` and
`published_used`. Directed tests cover a bad-FCS in-flight release and a
same-cycle pre-windback TYPE endpoint; both failed against the old RTL and pass
with the guard. TYPE and length publication are checked on consume-collision
edges; TYPE FCS exclusion is asserted directly, with matching mutants for all
three arithmetic terms. Bad settle and `S_ERR` tests also partially consume an
older frame while reclaiming the failing frame and assert that its remaining
published-byte count is preserved. The mid-payload rebase test now uses
distinct producer and consumer addresses.

The final MAC mutation gate is 30/30, the full regression is 29/29 RTL and
20/20 firmware with all gates clean, and mapped synthesis reports `pe_eth_mac`
1,681 cells / 23,749.63 µm². The fresh three-corner mapped screen reports zero
Yosys check problems, setup 0.00 ns at all corners and unchanged hold slack
−0.87/−0.61/−0.48 ns (slow/typ/fast); prior hold/electrical violations remain
and no signoff is claimed. Details and evidence are in
`E1-PUBLISHED-OWNERSHIP-REVIEW.md`. No physical flow, DRC or LVS.

## Residual limits (documented, not regressions)

- One window, not a queue: a second completed frame overwrites the latched
  header; frames are consumed in order and the ring keeps unconsumed frames
  intact until released.
- The frame buffer has one access port; a walk read that lands on a frame write
  returns the held byte. Firmware's loop spaces reads by nine cycles, so a
  capture for the current address always happens between the address change and
  the read; back-to-back `BUFBYTE` reads remain out of contract.
- A full ring rejects new frames explicitly (header/per-byte bounds), and those
  rejections roll their bytes back; consumption then frees space. There is no
  silent overwrite of unconsumed data.
- The STA hold/electrical failures are pre-existing and remain pre-repair.

## Files changed

- `rtl/pe_eth_mac.v`, `rtl/pe_soc.v`, `firmware/eth_rx.pe`
- `tb/tb_pe_eth_mac.v`, `tb/tb_pe_soc_eth.v`
- `regress/mutate_eth_mac_tb.sh`, `regress/mutate_eth_soc_tb.sh`
- `tools/gen/signal_glossary.py`, `wiki/reference/signal-names.md`
