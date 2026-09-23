# E1/E2 fix follow-up review — 2026-09-23

## Scope and result

Read-only independent review of the E1 frame-buffer ownership fix and E2 SRAM
flow-configuration fix against the current RTL, regressions, static gate and
flow config. Both original findings have substantive fixes, but this review
found residual issues: two E1 capacity leaks and gaps in the E2 guard. The
current `flow/pe_soc.json` passes `python3 tools/checks/macro_flow_config.py`
with both macro instances present. No repo RTL/config edits, physical flow,
DRC, or LVS ran.

## E1 — consumer release and ring accounting

### E1-1 — wrapped releases are always rejected (high)

`rtl/pe_eth_mac.v` computes `freed` as an `AW+1`-bit subtraction of two
`AW`-bit ring addresses, then accepts only `freed <= used`. With the current
11-bit pointers and 2048-byte ring, subtraction is modulo 4096, while the
ring-address distance must be modulo 2048. If a valid forward release wraps
from a high address to a lower address, `freed` is the true distance plus
2048. Since `used = 2048 - room` is at most 2048, the guard rejects every such
release. `rptr` does not move and the released capacity cannot be recovered
through this API.

Concrete reachable state: after the consumer reaches address 1996, a new
196-byte frame advances the producer to address 144, wrapping the ring. The
consumer's release to 144 should free those 196 bytes. In a directed temporary
simulation, `rptr=1996`, `room=1800` (`used=248`), and consume address 144 left
`rptr=1996`, `room=1800`: the release was rejected. The arithmetic computes
`freed=2244`, which exceeds `used` despite the real forward distance being
196. Current permanent tests consume only low, non-wrapping addresses.

The implementation needs either a pointer difference modulo `BUF_BYTES` with
an explicit representation of the full-ring case, or a consumer API that
provides an unambiguous byte count. Add wraparound release tests.

### E1-2 — simultaneous consume and producer update loses a room delta (medium)

`buf_consume` assigns `room <= room + freed` early in the main sequential block
(`rtl/pe_eth_mac.v`, the buffer ownership branch). The later state-machine case
can assign `room` again on the same edge for a payload byte, settle/rollback,
or error. With nonblocking assignments, the later assignment wins. The
consumer's `rptr` update still commits, so its freed bytes are permanently
omitted from `room` and the ring gradually loses capacity. This is
under-crediting, not over-crediting: it cannot expose unreleased memory, but it
can reject frames while free storage remains.

A directed temporary simulation with old `room=100`, `rptr=0`, consume address
10, and a simultaneous payload-byte write produced `rptr=10`, `room=99`,
`wptr=101`. The expected combined accounting is `room=109`. The permanent
mid-payload test consumes the current `rptr` (distance zero), and the SoC
consecutive-frame test checks checksums; neither detects this lost nonzero
delta. Do not fix this by reordering the consumer assignment after the state
machine, which would instead drop the producer delta. The updates need a
combined next-room calculation, and directed tests should cover at least the
payload-byte and settle/error update edges.

### E1-3 — a full-ring release is indistinguishable from a duplicate (low)

If a consumer advances exactly 2048 bytes, its final address equals its
starting `rptr`, so the address-only API computes a zero distance and treats it
as a duplicate. Current single-window Ethernet use does not normally release a
full ring in one operation, but the generic ring API cannot represent this
case. Document the constraint or include an explicit count/wrap bit if full-ring
consumption is intended.

### E1 items confirmed

The producer `wptr` and consumer `rptr` are separate; the in-flight writer is
not rebased by consumer release. The guard rejects backward/non-forward
addresses for non-wrapping releases. Error rollback uses the full-width
`pay_cnt[AW:0]`; type-frame FCS rollback is four bytes; SoC ties `buf_reset`
low. The consecutive 200-byte-frame regression exercises the original E1
mid-frame rebase reproducer and the destructive-reclaim mutation is detected.
These checks do not cover E1-1 or E1-2.

## E2 — macro placement, supply hooks, and static gate

The current static check passes and reports both `u_imem.g_macro.u_sram` and
`u_eth_fbuf.g_macro.u_sram`. Current placements fit the declared die with the
configured gap, and the current `PDN_MACRO_CONNECTIONS` entries name all three
SRAM supply pins for both instances. The following findings concern the gate's
coverage; they do not show that the current config is wrong.

### E2-1 — supply pins checked, mapped nets not checked (medium)

`tools/checks/macro_flow_config.py` collects only `e.split()[3:5]` from each
connection string, which are the macro pin names. It never validates the
power/ground net fields (`VPWR`/`VGND`, positions 1 and 2 in the current config).
Changing an entry to map a power pin to the ground net can therefore leave the
required pin-name set intact and pass the check. Gate the pin-to-net mappings
as well as pin presence.

### E2-2 — PDN text check does not require the ladder connection (medium-low)

The current `flow/pe_soc_pdn.tcl` contains both the Metal4 macro stripes and
connections from Metal4 to the vertical grid and from vertical to horizontal
grid. But the gate only searches for the text `-layer Metal4` in the file.
Removing the `add_pdn_connect -layers "Metal4 $PDN_VERTICAL_LAYER"` clause
would still pass. Check that the expected connect steps are present, or test a
parsed structure with an appropriately scoped checker.

### E2-3 — incomplete PDK check becomes a regression failure (low)

`macro_flow_config.py` returns exit 2 when the required LEF geometry is
unavailable, explicitly meaning the check is incomplete. `regress/run_all.sh`
treats every nonzero result as `FAILED`; unlike the immediately preceding
PDK-backed generators, it has no missing-PDK skip. If PDK-less regression runs
are supported, this check needs a clearly reported skip/incomplete policy.

### E2-4 — macro timing and layout views are not validated (low)

The gate checks instance placement metadata and PDN entries, but does not check
that each configured macro's `lib`, `lef`, and `gds` view lists exist and cover
the required corners. The current config contains those views; a future typo or
missing view would not be caught by this gate.

### E2-5 — placement uses one hard-coded LEF for every macro type (low)

`macro_cells()` collects all cell types containing `IHPSG`, while `lef_size()`
always reads the 1P 1024x16 SRAM LEF. This matches both current macro instances,
which share that type, but would use the wrong geometry if another macro type
were added.

## Verification boundaries

- `python3 tools/checks/macro_flow_config.py` passed for the current tree and
  found both macro instances.
- Temporary directed simulations reproduced E1-1 and E1-2; they are not yet
  permanent regressions.
- No full RTL regression was run during this review. The previous documented
  regression predates this review but covers the original, non-wrapping cases.
- No synthesis, STA, physical flow, DRC, or LVS ran.

## Disposition

The original E1/E2 fixes remain useful and close their original reproduced
failures, but E1 ring release is not correct for all reachable wrap/collision
timings. E2's current configuration is consistent with the intended two-macro
setup, while its guard is not yet strong enough to preserve all configuration
invariants. Review findings only; no source fix was attempted.
