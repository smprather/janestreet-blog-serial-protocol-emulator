# E1/E2 fix follow-up review — 2026-09-23

## Scope and result

Read-only independent review of the E1 frame-buffer ownership fix and E2 SRAM
flow-configuration fix against the current RTL, regressions, static gate and
flow config. Both original findings have substantive fixes, but this review
found residual issues: two E1 capacity leaks and gaps in the E2 guard. The
current `flow/pe_soc.json` passes `python3 tools/checks/macro_flow_config.py`
with both macro instances present. No repo RTL/config edits, physical flow,
DRC, or LVS ran. The two E1 findings and the two E2 gate-coverage findings
were fixed after the review; the fixes and their evidence are in the two
resolution sections at the end; E2-5 is closed there too.

A later independent audit found an additional E1 contract defect: the consume
bound counted allocated in-flight bytes as releasable. That issue is fixed and
verified with the `published_used` counter; see
`E1-PUBLISHED-OWNERSHIP-REVIEW.md` and the follow-up section in
`E1-RESOLUTION.md` for its tests, mutation results, and hardening screen.

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
- Temporary directed simulations reproduced E1-1 and E1-2 at review time; both
  are now permanent directed tests in `tb/tb_pe_eth_mac.v` (resolution below).
- No full RTL regression was run during this review. The post-fix regression
  (after the harness corrections) is recorded in the resolution below; it
  covers the original, non-wrapping cases as well.
- No synthesis, STA, physical flow, DRC, or LVS ran.

## Disposition

**At review time**, the original E1/E2 fixes closed their original reproduced
failures but E1 ring release was not correct for all wrap/collision timings,
and E2's guard was not yet strong enough to preserve all configuration
invariants. Review findings only; no source fix had been attempted then. The
E1-1/E1-2 fix is in the resolution section below and the E2-1/E2-2 fix is in
the section after it; E2-5 is closed in its own section.

## E1-1 / E1-2 resolution (2026-09-23)

**Fixed.** `rtl/pe_eth_mac.v` now measures the release distance modulo
`BUF_BYTES` (`assign freed = {1'b0, (buf_consume_addr - rptr)};`) and folds the
validated consumer credit into every producer `room` update through
`consume_credit` (the consume branch plus `S_PAYLOAD`, `S_SETTLE` and
`S_ERR`). The assignments were summed, not reordered, so neither delta is
dropped.

Directed tests were written first in `tb/tb_pe_eth_mac.v` and failed on the
pre-fix RTL:

- wrapped release (rptr 1996, a 196-byte frame ending at 144): `rptr = 1996,
  want 144` and `room = 1852, want 2048`;
- simultaneous nonzero consume and payload byte write (freed 46):
  `room = 2001, want 2047 (= 2002 + 46 - 1)`.

They pass after the fix. Validating the gate exposed two harness defects: the
directed waits in `tb/tb_pe_eth_mac.v` are now bounded (a mutant that never
reaches S_PAYLOAD used to spin until the 300 s timeout), and `run_tb` counts
only a printed FAIL as a detection -- a timeout, compile error or simulator
crash is a harness error. Two mutants were added for this fix (the AW+1
subtraction and dropping `consume_credit` on a payload update), so
`regress/mutate_eth_mac_tb.sh` was 18 detected / 0 survived / 0 harness errors
at that point; `regress/mutate_eth_soc_tb.sh` 8/8; and
`./regress/run_all.sh --fast -j8` exits 0 (29/29 RTL, 20/20 firmware, lint and
all generated gates clean).

Pure Yosys/OpenSTA recheck with the existing `eth-soc` screen: `check -assert`
2 x 0 problems; worst setup 0.00 at all corners; worst hold slow -0.87 / typ
-0.61 / fast -0.48 ns, identical to the recorded post-E1 screen
(`e1-recheck/sta-*-fixed.txt`) with only the OpenSTA banner and the
auto-generated net names differing. The canonical `synth_area.sh` refresh
after the fix reports `pe_eth_mac` 1,354 cells / 19,789.74 um2, `pe_soc` 3,306
/ 53,615.56 um2 and `tt_um_top` 3,579 / 59,286.81 um2. No physical flow, DRC
or LVS.

E1-3 (a release of exactly `BUF_BYTES` reads as a duplicate) remains
documented in the RTL; the address-only API cannot express it without a count
or wrap bit.

## Independent E1 accounting-coverage audit (2026-09-23)

A fresh read-only review traced release validation, modulo wrap distance,
`room` bounds, and consumer collisions across payload, both settle outcomes,
`S_ERR`, and the reset/empty/full boundaries. It found no RTL defect. It did
find an evidence gap: the shipped TB and mutation gate covered consume credit
on payload writes, but not the other three room-update sites. Temporary
mutants that removed the credit from type-success settle, bad-frame settle,
and `S_ERR` all passed the shipped TB, while temporary directed probes failed
each mutant at the corresponding room check and passed on pristine RTL.

Permanent directed tests and matching mutations then covered all three sites in
`tb/tb_pe_eth_mac.v` and `regress/mutate_eth_mac_tb.sh`. The baseline Ethernet
MAC TB passes; the three mutants each produce the expected room assertion
failure. At that point the full MAC mutation harness reported 21 detected, 0
survived, and 0 harness errors. No RTL behavior changed. The SoC binds consume
to a firmware write of the current Ethernet buffer window address; the source trace confirms
that verdict and error collisions are reachable clock alignments. Reset is
debug-only and tied low in the SoC; whole-ring reset remains constrained to an
empty ring with no frame in flight. E1-3 remains an API ambiguity for an exact
full-ring release. No physical flow, DRC, or LVS was run.

## Full-ring bad-settle reclaim coverage (2026-09-23)

A read-only follow-up verified the new collision tests and mutants, then found
one remaining gap in the bad-frame settle branch: no test drove `pay_cnt` to
2,048 there. The existing `truncated-reclaim` mutation targeted the separate
`S_ERR` assignment, so a settle mutant truncating `pay_cnt[AW]` still passed
the shipped TB. A type frame with 2,044 data bytes and a corrupted FCS reaches
bad settle after charging all 2,048 bytes. With the truncated-width mutant,
`room` remained zero and a later 46-byte recovery frame was rejected.

The permanent TB now checks `pay_cnt == 2048`, full room reclaim, pointer
rollback, and acceptance/pointer of a recovery frame. The `S_ERR` collision
probe now overflows a type frame after a 1,500-byte published frame, asserts a
nonzero partial `pay_cnt`, consumes the published frame on the `S_ERR` edge,
and checks that both the credit and partial allocation are reclaimed. An
independent temporary watcher measured `room=0`, `pay_cnt=548`, `used=2048`,
and valid `freed=1500` at that edge. A new
`truncated-reclaim-bad-settle` mutant catches width truncation at the settle
site; the full MAC mutation gate is now 22 detected, 0 survived, 0 harness
errors. `./regress/run_all.sh --fast -j8` passes with the final tests: 29/29
RTL benches, 20/20 firmware tests, lint/elaboration, generated gates, and all
seven TB mutation suites. The RTL did not change. No physical flow, DRC, or LVS
was run.

## E2-1 / E2-2 resolution (2026-09-23)

**Fixed.** `tools/checks/macro_flow_config.py` now validates each
`PDN_MACRO_CONNECTIONS` entry's five fields and its mapping, not just the pin
names: every power pin (`VDD!`, `VDDARRAY!`) must be bound to the flow's power
net (`VPWR`), `VSS!` to its ground net (`VGND`), and each pin must sit in its
correct slot. It also parses the PDN script (comments stripped,
backslash-newline continuations joined) and requires the macro grid's own
`add_pdn_stripe -layer Metal4`, `add_pdn_connect "Metal4
$::env(PDN_VERTICAL_LAYER)"` and `add_pdn_connect "$::env(PDN_VERTICAL_LAYER)
$::env(PDN_HORIZONTAL_LAYER)"` commands, matching the ordered `-layers` pair in
the same command rather than mere token presence. A `--flow` option lets the
negative tests run against copies.

**Negative tests (permanent).** `regress/mutate_macro_flow_config.sh` mutates a
copy of the flow config and PDN script and requires the gate to reject:
`wrong-net` (VPWR/VGND swapped, pin names intact),
`missing-metal4-to-vertical`, `missing-vertical-to-horizontal`,
`missing-metal4-stripe`, `wrong-layer` (`Metal5`) and `reversed-layers`. The
clean copy passes first, the tracked files are byte-compared after, and the
harness is wired into `run_all.sh`: the six mutations are each detected as
exit 1 (the E2-3 policy checks follow).

`./regress/run_all.sh --fast -j8` exits 0 (29/29 RTL, 20/20 firmware, lint and
all gates; the macro-gate negatives run alongside the macro gate). E2-4 is
closed in the next section; E2-5 is closed in its own section below.
No physical flow, DRC or LVS.

## E2-3 resolution (missing-PDK policy, 2026-09-23)

**Fixed.** `tools/checks/macro_flow_config.py` now has a three-way exit
taxonomy: 0 = complete and legal; 1 = findings, including a Yosys elaboration
failure; 2 = INCOMPLETE, returned **only** when the required macro LEF geometry
is unavailable and there are no other findings. A finding with the geometry
missing still exits 1 (with a note that the placement could not be checked),
so exit 2 is not a blanket skip. A `--lef` testhook (like `--flow`) lets the
policy be tested without touching the installed PDK.

`regress/run_all.sh` prints `macro flow config: SKIPPED (...)` for exit 2 and
keeps `FAILED` for every other non-zero; the negative harness prints a clean
`SKIPPED` (exit 0) when its own baseline is incomplete, and the regression's
summary follows it.

**Verification (both paths).** `regress/mutate_macro_flow_config.sh` now runs
20 checks: the clean copy with the real LEF passes; the six E2-1/E2-2
mutations are each detected as exit 1; the five E2-4 view mutations (missing
LEF view, missing GDS view, missing required lib corner, nonexistent path,
wrong view type) are each detected as exit 1; a clean config with `--lef`
missing returns exit 2 + INCOMPLETE; the wrong-net, missing-GDS and
wrong-view-type configs with the LEF missing (and, for the type case, the view
tree unavailable too) still return exit 1; and a forced Yosys failure returns
exit 1 + "yosys elaboration failed". The three E2-5 synthetic two-type checks
(die fit, per-type overlap, missing type LEF) are in the E2-5 resolution
below. With `HOME` pointing at a PDK-less tree
the harness prints `SKIPPED: the baseline is INCOMPLETE ...` and exits 0.

Full `./regress/run_all.sh --fast -j8` on the final tree exits 0 (29/29 RTL,
20/20 firmware, lint and every gate clean), with the macro gate OK and the
negatives reporting the pin-to-net/ladder/per-type geometry/skip/yosys
checks. E2-5 is closed in its own resolution below. To exercise the missing-LEF path end
to end while keeping the SRAM simulation models available, also ran
`HOME=/tmp/nopdk IHP_PDK=/home/mylesp/pdk/IHP-Open-PDK ./regress/run_all.sh
--fast -j8`: exit 0, 29/29 RTL and 20/20 firmware; the macro geometry/view
check and its PDK-dependent negative suite both reported SKIPPED. No physical
flow, DRC or LVS.

## E2-4 resolution (macro view validation, 2026-09-23)

**Fixed.** `tools/checks/macro_flow_config.py` now validates the `MACROS`
views for every configured macro type: `gds`, `lef` and `lib` must be present
and nonempty, every `./src/<name>` entry must resolve to exactly one file of
the matching **class and extension** in the PDK `sg13g2_sram` tree that
`run_librelane.sh` stages from (a `.gds` under `gds/`, a `.lef` under `lef/`,
a `.lib` under `lib/`; basename matching, never the repo cwd), and the `lib`
keys must cover the flow's required PVT corners. The class/extension check is
structural and runs outside the PDK-tree guard, so a `.lib` in the LEF slot
fails even when the view tree and the geometry LEF are both unavailable. The
corner list is the flow config's `DEFAULT_CORNER`/`STA_CORNERS` when set,
otherwise the PDK's LibreLane `sg13g2_stdcell/config.tcl`; `--pdk-root`
mirrors `run_librelane.sh`'s `PDK_ROOT`/`~/.ciel`.

The exit policy is unchanged: a missing PDK tree/LEF alone is INCOMPLETE
(exit 2, skip) only when there are no other findings, while view findings
(missing/empty view lists, a bad path shape, a wrong view class, a missing
required corner, or a view with no PDK source) fail with exit 1.

**Verification (test-first).** Before the fix, the checker accepted five bad
configs with exit 0 (including a LEF entry naming an existing `.lib` file).
After it, each exits 1 with the specific finding; the wrong-type config also
exits 1 with `--pdk-root` pointing at an empty tree and with the geometry LEF
missing. The harness is 20/20 with the PDK present (the E2-5 resolution below
adds three synthetic two-type checks), and the PDK-less baseline
still prints `SKIPPED: ... INCOMPLETE ...` and exits 0.

Full `./regress/run_all.sh --fast -j8` exits 0 (29/29 RTL, 20/20 firmware,
lint and every gate clean). E2-5 (per-type geometry) is closed below.
No physical flow, DRC or LVS.

## E2-5 resolution (per-type macro geometry, 2026-09-23)

**Fixed.** `tools/checks/macro_flow_config.py` no longer measures every macro
with one hard-coded LEF. Each configured `MACROS[type]` resolves its own
`./src` lef view under the PDK `sg13g2_sram` tree (the E2-4 resolution), and
that type's own LEF `SIZE` drives the `DIE_AREA` fit and the pairwise
placement-gap checks for that type's instances; the pairwise test now uses
each instance's own width/height. `--lef` remains an every-type override,
which keeps the E2-3 policy tests unchanged: unavailable geometry with no
other findings is still INCOMPLETE (exit 2), and findings still exit 1. A
configured type whose LEF cannot be resolved is reported as unchecked (never
silently measured) on top of its E2-4 finding. `--rtl` is a new
isolated-test hook so the harness can elaborate a synthetic two-macro netlist.

**Verification (test-first).** The RED setup was an isolated two-type flow:
two blackbox macros whose fake-PDK LEFs declare `SIZE 10 BY 10` and
`SIZE 100 BY 100`, with B placed so a single-size checker measuring both with
A's 10x10 accepts it. Before the fix, `--lef <A.lef>` returned exit 0 (RED);
after it, no override resolves each type's own LEF and the run exits 1 with
`u_b: 100.0x100.0 (type RM_IHPSG_FAKE_B) at (20.0,0.0) is not inside DIE_AREA
[0, 0, 50, 50]`. The permanent harness adds three synthetic checks: that
die-fit case, an overlap case where B's own 100-wide footprint spans under A
(a gap finding), and a missing-type-LEF config (the missing-lef finding plus
"its instances are not checked"). The harness is 20/20 with the PDK present
and still SKIPs cleanly with a PDK-less `HOME`.

Full `./regress/run_all.sh --fast -j8` exits 0 (29/29 RTL, 20/20 firmware,
lint and every gate clean). E2-1 through E2-5 are now fully closed; physical
flow, DRC and LVS remain deferred.
