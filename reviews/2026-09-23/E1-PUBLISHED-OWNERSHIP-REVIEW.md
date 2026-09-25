# E1 published-byte ownership review — 2026-09-23

## Finding and fix

A fresh independent accounting audit found that `used = BUF_BYTES - room`
includes bytes allocated to the frame currently arriving. The old consume guard
accepted any forward distance within `used`, so a firmware over-read could
advance `rptr` into that in-flight frame. A later bad-frame rollback, `S_ERR`
reclaim, or successful TYPE-frame FCS windback would credit those same bytes a
second time, allowing `room > BUF_BYTES` and wrapping the next `used` value.
The firmware's normal receive loop is length-bounded; this was still a bug in
the MAC contract, which promises that invalid consumes cannot over-credit the
ring.

`rtl/pe_eth_mac.v` now tracks `published_used`, the committed subset of
allocated bytes. `consume_credit` must satisfy both `freed <= used` and
`freed <= published_used`. Length-frame settlement publishes `pay_cnt` bytes;
TYPE-frame settlement publishes `pay_cnt - FCS_BYTES`; bad settle and `S_ERR`
do not publish the current frame. Consume and publication on the same edge are
accounted together, so a release can cover only earlier committed frames.

## Directed evidence

`tb/tb_pe_eth_mac.v` now covers the original over-read cases:

- An empty-ring TYPE frame with bad FCS receives a consume naming 50
  in-flight bytes. The guard leaves `rptr` at 0, restores `room` to 2,048 and
  rolls `wptr` back.
- A valid 96-byte TYPE frame receives a consume at the pre-windback endpoint
  (100 bytes including FCS) on the settle edge. The uncommitted consume is
  ignored; settlement leaves `wptr=96`, `room=1,952`, and publishes 96 bytes.
  `published_used` is asserted as 96, excluding the four transient FCS bytes;
  releasing address 96 afterwards is accepted and restores the ring to 2,048.
- A length frame is released on the same edge a new length frame commits.
  Assertions require `published_used` to end at 46 bytes, proving the consume
  credit is subtracted from the combined old-plus-new publication count.
- The existing TYPE settle collision now asserts the same property: releasing
  the prior 46-byte length frame while a 46-byte TYPE frame commits leaves
  exactly 46 published bytes.
- Bad-FCS settlement partially releases an earlier 46-byte frame while
  rolling back a new TYPE frame; the old frame's remaining 23 committed bytes
  must stay published.
- `S_ERR` similarly partially releases a 1,500-byte committed frame while
  reclaiming an oversized TYPE frame. The remaining 1,477 committed bytes stay
  available and can then be fully drained.
- The mid-payload producer-pointer test now partially releases a prior frame
  while the next frame arrives, with different producer and consumer
  addresses. This makes the rebase mutation observable; the earlier version
  used identical addresses and did not test the claimed property.

The two in-flight tests were run before the RTL change and failed with
`room=2098` for bad-frame rollback and `room=2052` for TYPE windback. They pass
with the ownership bound. The existing settle and error collision cases still
exercise consume credits alongside other published frames.

## Verification

- `bash regress/mutate_eth_mac_tb.sh`: **30 detected, 0 survived, 0 harness
  errors**. New mutants remove the unpublished-byte bound, omit TYPE or length
  publication, count TYPE FCS as published, drop consume credit from TYPE or
  length publication, clear prior committed-byte counts on bad settle or
  `S_ERR`, and force the producer pointer to rebase during a partial consume.
- `./regress/run_all.sh --fast -j8`: exit 0; 29/29 RTL testbenches, 20/20
  firmware tests, lint/elaboration, generated documentation/config gates, and
  all seven mutation suites passed.
- `./regress/synth_area.sh`: exit 0, no surfaced synthesis diagnostics.
  `pe_eth_mac` maps to 1,681 cells / 23,749.6266 µm²; `pe_soc` to 3,571 cells /
  56,816.8776 µm²; `tt_um_top` to 3,888 cells / 62,745.4296 µm².
- A fresh Yosys mapping and three-corner OpenSTA screen used the existing SoC
  synthesis script and constraints. Yosys `check -assert` reported zero
  problems in both passes. Setup worst slack remained 0.00 ns at slow, typical
  and fast corners; hold worst slack remained −0.87/−0.61/−0.48 ns
  (slow/typ/fast), matching the prior screen. The known unplaced hold and
  electrical violations remain; this is a mapped screen, not hardening or
  signoff. Logs/netlist are in `/tmp/e1-published-synth/`.
- `python3 tools/gen/floorplan_feasibility.py --check` and the other generated
  documentation checks pass with refreshed mapped-area baselines.

No physical flow, DRC or LVS was run.

## Remaining contract limit

The address-only API cannot distinguish a duplicate address from a full-ring
release because both have modulo distance zero. Normal Ethernet traffic does
not release a full ring in one pulse; resolving that general case requires a
byte count or wrap bit and remains the documented E1-3 scope decision.

## Exact-source hardening recheck (2026-09-23)

An independent audit found the original mapped logs predated the final comment
edit in `rtl/pe_eth_mac.v`; the fresh source comparison confirmed the edit was
comment-only. Re-running mapping on the current source produced byte-identical
mapped Verilog. Yosys again reported zero problems in both `check` passes, the
three-corner area counts were unchanged, and all 30 MAC mutants were detected
with no survivors or harness errors.

The current-source OpenSTA logs are preserved in
`reviews/2026-09-23/e1-published-ownership/`. Slow is explicitly a hold-check
corner: its script applies 0.25 ns hold uncertainty and reports minimum paths
and worst minimum slack. Worst hold slack is −0.8692 ns slow, −0.6065 ns
typical, and −0.4778 ns fast. The 0.00 ns setup summary at slow comes from a
transparent-latch time-borrow path; its worst register-to-register setup path
is +2.2274 ns. Existing unplaced hold and electrical violations remain. The
mapping and STA screens are manual checks rather than regression gates; this
recheck ran no physical flow, DRC, or LVS.
