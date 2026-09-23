# F1/F2 fix recheck — 2026-09-23

> **Layout note (2026-09-23):** this report predates the project-layout rework.
> Paths quoted in the text (`tb/...`, `tools/...`, `rtl/pe_uart_soc.v`,
> `rtl/pe_line_codec.v`) describe the layout AT THE TIME OF THE REVIEW. The
> probe scripts in this directory were path-updated during the rework and stay
> runnable; the reports themselves are kept as historical evidence.

**Revision:** `655c5b7` on `review/fix-invisible-defects`.
**Compared with:** `bdd7728`, the preceding verification baseline.

**F1 is resolved. F2's USB layout and configuration are corrected. One new P2
documentation finding remains: the CAN example added to the generated reference
selects Manchester coding.** No additional RTL issue was found in this scoped
check of the changes.

## F3 — P2: correct the CAN configuration example

**Location:** [`tools/gen_signal_glossary.py:69`](../../tools/gen_signal_glossary.py),
published at [`wiki/reference/signal-names.md:89`](../../wiki/reference/signal-names.md).

The corrected note now says CAN uses `0x05`. In `pe_codec_mux`, that sets both
`cfg[0]` (stuffing) and `cfg[2]` (Manchester). CAN needs the symmetric stuffing
stage with the line-coding stages bypassed. The documented value therefore
changes the transmitted levels and makes RX consume Manchester half-cell inputs
instead of the CAN wire input.

A directed test presents one raw/transmitted CAN bit of 1, before any stuff bit
is owed:

| Configuration | TX | RX | RX valid | Error | Result |
|---|---|---|---|---|---|
| Documented `0x05` | 0 | 0 | 1 | 1 | Fail |
| `0x01` (default run length 5) | 1 | 1 | 1 | 0 | Pass |
| `0x51` (explicit run length 5) | 1 | 1 | 1 | 0 | Pass |

**Correction:** replace the CAN example in the generator note with `0x01` or
`0x51`, regenerate the reference, and correct copies in the review resolution
text if retained as current guidance. The RTL already handles both correct
values. The glossary drift gate passes because generator and output contain
the same incorrect example.

[Reproducer](f1-f2-recheck/can_config.v),
[fresh output](f1-f2-recheck/can-results.txt). Compilation succeeds; simulation
exits 1 for `0x05` and 0 for each control.

```bash
iverilog -g2012 -s verify_can_config -o /tmp/can-config.vvp \
  rtl/pe_line_codec.v rtl/pe_codec_mux.v \
  reviews/2026-09-23/f1-f2-recheck/can_config.v
vvp /tmp/can-config.vvp
# Use -Pverify_can_config.CFG=1 or =81 on the compile command for the controls.
```

## Verified fixes

### F1 — Ethernet minimum size and byte alignment

The verdict requires `bit_cnt == 0` and at least 50 stored bytes for EtherType
frames: 46 data/pad bytes plus four FCS bytes. Together with the 14-byte header,
that enforces the 64-byte minimum. Length frames continue to require `fcs_done`;
their payload/padding path reaches FCS on a byte boundary. Rejection restores
the starting pointer and all charged bytes.

`run-boundaries.sh` exits **0**: both undersized frames and all seven partial-byte
cases are rejected with room 2048 and pointer 0. The valid 64-byte control is
accepted with length 46, room 2002, and pointer 46.
[Fresh output](f1-f2-recheck/boundary-results.txt).

The permanent ARP acceptance test now includes padding to the minimum wire
length and expects the padded payload length. New minimum-size and alignment
mutations exercise the new verdict conditions.

### F2 — USB configuration reference

Generator and generated reference now agree with the RTL: `cfg[6:4]` is the
run length, `cfg[7]` is `ones_only`, and USB uses `0xE3`. The new `ones_only` port
also has a description. The USB zero-run probe passes. F3 concerns the separate
CAN example introduced alongside this correction.

## Fresh verification

| Check | Result |
|---|---|
| `./tb/run_all.sh --fast -j4` in a fresh archived copy | Exit 0: 26/26 RTL, 18/18 firmware, lint/elaboration, document/Canvas gates, parameter checks, I2C timing, all four mutation suites |
| `bash reviews/2026-09-22/review2/run_repros.sh --sweep` | Exit 0: all seven original probes pass; 102 Ethernet timing trials, zero failures |
| `bash reviews/2026-09-23/run-boundaries.sh` | Exit 0: all rejection assertions and the valid-frame control pass |
| Documented CAN preset probe | Exit 1 at `0x05`; exits 0 at `0x01` and `0x51` |

[Regression output](f1-f2-recheck/regression-results.txt) and
[original-probe/sweep output](f1-f2-recheck/original-probe-results.txt) preserve
the full results. An independent scoped review found no further issue in the
F1 RTL and test changes.

Only review documents, evidence, and handoff/status records were changed during
this check. Production RTL, firmware, tests, and the glossary generator remain
unchanged. Physical flow, DRC, and LVS were not run. Historical failing outputs
remain intact in the preceding verification directory.

---

## Resolution — F3 fixed

The generator note for `pe_codec_mux.cfg` now gives CAN as **`0x51`** (stuff +
explicit run 5), notes that **`0x01`** is equivalent (run nibble 0 means the
default 5), and states explicitly that `0x05` sets `cfg[2]` and is not a CAN
preset. `wiki/reference/signal-names.md` is regenerated from it, and the
drift gate is green.

Permanent coverage: `tb_pe_codec_mux` exercises `cfg=0x51` on TX (five data ones
then a complementary stuff slot) and RX (five valid ones, the stuff slot
flagged invalid, no error) alongside the existing `0x01` CAN sections. The
recheck's reproducer keeps its behavior: exit 1 at `0x05`, exit 0 at `0x01` and
`0x51` (the RTL was always correct; only the documented example was wrong).
