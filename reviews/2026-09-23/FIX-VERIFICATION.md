# Second-review fix verification — 2026-09-23

**Latest recheck:** [F1-F2-RECHECK.md](F1-F2-RECHECK.md) verifies `655c5b7`.
F1 and the USB configuration reference pass; the recheck's one P2 (F3, the CAN
example added to the reference) is fixed — the reference now says CAN `0x51`
(`0x01` equivalent). The text below preserves the preceding pass.

**Revision checked:** `bdd7728`, branch `review/fix-invisible-defects`.
**Changes examined:** fixes after the reviewed `628e309` baseline.

All seven original reproductions now pass. The fixes resolve the reported DRU
sampling race, buffer underflow, USB zero-run stuffing, restart, memory fallback,
UART monitor, and mutation-interruption symptoms. **Two follow-ups remain:**
Ethernet structure validation is incomplete, and the generated codec register
reference still describes the old configuration layout.

## Findings requiring follow-up

### F1 — P2: reject undersized and partial-byte EtherType frames

**Location:** [`rtl/pe_eth_mac.v:534–535`](../../rtl/pe_eth_mac.v).

The new verdict requires `hdr_done` and at least four stored bytes for a type
frame. That prevents the original subtraction underflow, but does not require a
minimum-size Ethernet frame or `bit_cnt == 0` at its end. A matching CRC can still
cause an invalid frame to be presented to a consumer as valid.

Independent raw Manchester stimuli through the DRU/MAC/CRC chain produced:

| Wire frame, excluding preamble/SFD | Observed result |
|---|---|
| Valid 14-byte header + 46-byte payload + FCS | Accepted, length 46, room 2002, pointer 46 |
| Header + FCS only (18 bytes) | Incorrectly accepted, length 0 |
| Header + 45-byte payload + FCS (63 bytes) | Incorrectly accepted, length 45, consumes 45 buffer bytes |
| Header + 46-byte payload + 1–7 extra bits + recomputed FCS | All seven incorrectly accepted, `bit_cnt=1..7`, length 46 |

All malformed stimuli reach CRC residue `debb20e3`. The project's
[Ethernet scope](../../wiki/concepts/ethernet-scope.md) specifies a 64-byte minimum
legal frame. These cases demonstrate incomplete structure validation; the
original pointer/free-space underflow did not recur.

**Correction criterion:** validate the minimum frame length and complete-byte
alignment before asserting `frame_valid`; rejected cases must preserve the
pre-frame buffer allocation. Keep the valid 64-byte control passing.

Reproducer: [mac_boundaries.v](mac_boundaries.v).
Fresh result: [boundary-results.txt](boundary-results.txt), **nine failed rejection
assertions, exit 1**, with a passing valid-frame control.

### F2 — P2: update the generated codec configuration reference

**Location:** [`tools/gen_signal_glossary.py:69`](../../tools/gen_signal_glossary.py),
published at [`wiki/reference/signal-names.md:89`](../../wiki/reference/signal-names.md).

The public reference still assigns `cfg[7:4]` to `run_cfg`. The fixed RTL instead
uses `cfg[6:4]` for the run length and `cfg[7]` for `ones_only`. Following the old
description to enable stuffing/NRZI with a six-bit run produces `0x63`, which
still selects symmetric stuffing and corrupts USB zero runs. The intended USB
configuration is now **`0xE3`**. Hardware behavior in that configuration passes.

The glossary gate remains green because both its handwritten NOTES entry and its
generated output contain the same obsolete description. Regenerating the page
without correcting NOTES will preserve the error.

**Correction criterion:** update the generator's configuration note and the new
`ones_only` port description, regenerate the reference, and state the USB
configuration explicitly. The needed hardware change is already implemented.

## Status of the original findings

| ID | Verification result |
|---|---|
| R2-1 | Fixed in the checked simulations: no sample mismatches in the directed frame; all 12,144 folds and expected CRC; asynchronous phase/frequency/filter sweep **102/102**. |
| R2-2 | Original 14-byte valid-residue runt is rejected; room stays 2048 and pointer stays 0; next valid frame passes. Broader structure checks remain open as F1. |
| R2-3 | Fixed with USB config `0xE3`. Original zero-run probe and independent USB/CAN wire model pass. Configuration documentation remains open as F2. |
| R2-4 | One-clock stop resumes with A=`55`, PC=1, and fetched instruction `0055`. |
| R2-5 | Macro and fallback outputs both hold `11`/`0011` across a write with changing read address. Both word and byte lane are gated in the fallback. |
| R2-6 | `A5` decodes correctly at 519/520/521 clocks per bit. Additional valid/invalid stop and consecutive-frame checks passed. |
| R2-7 | I2C/SPI/fbuf SIGTERM probes exit 143 with `changed=[]`; original source and image snapshots are restored. Additional SIGINT checks for these three also restored source bytes. |

## Fresh verification evidence

- `./tb/run_all.sh --fast -j4` in a fresh `git archive` copy: **exit 0**,
  **26/26 RTL**, **18/18 firmware**, lint/elaboration, parameter guards, generated
  document/Canvas checks, I2C timing, and all four mutation suites pass.
  [Complete output](regression-results.txt).
- `bash reviews/2026-09-22/review2/run_repros.sh --sweep`: **exit 0**, seven original
  probes pass and the Ethernet sweep reports **102 trials, 0 failures**.
  [Complete output](original-probe-results.txt).
- Independent USB/CAN model: **524 streams, 4,822 wire cells, zero errors**.
  Covers all 256 single-byte values for each protocol, USB SYNC, long zero/one
  runs, and mixed stuffing boundaries; checks TX, inserted-bit indications, RX,
  and NRZI. [Model](codec_model.v), [output](codec-results.txt).
- Additional UART checks: **27 passed**, using `00`, `FF`, `96`, `A5`, valid and
  invalid stop bits, and consecutive frames at 519/520/521 clocks per bit.
- The new Ethernet rejection checks compile and run, then exit **1** on F1.
  This is a behavioral failure, not a compilation failure.

Run the remaining failing checks from the repository root:

```bash
bash reviews/2026-09-23/run-boundaries.sh
```

Run the independent codec model:

```bash
iverilog -g2012 -s codec_model -o /tmp/fixcheck-codec.vvp \
  rtl/pe_line_codec.v rtl/pe_codec_mux.v reviews/2026-09-23/codec_model.v
vvp /tmp/fixcheck-codec.vvp
```

## Scope, artifacts, and next action

This check reviewed the fixes and adjacent failure boundaries. It did not repeat
the entire project audit or run physical flow, DRC, or LVS. The DRU results are
functional simulation evidence, not physical latch timing signoff. The interruption
conclusion above is scoped to the three harnesses in R2-7; an additional Ethernet
harness SIGINT attempt reached its baseline only and timed out waiting for its
`timeout`-managed child, so it supplies no mutation-restoration verdict.

No production RTL, firmware, test harness, or generator was edited. This check
adds the report, evidence, and boundary reproducers and updates the handoff/status
record. Earlier review logs were copied to `.txt` and their links corrected:
the global `*.log` ignore rule had excluded the promised evidence from commits.
The new evidence files use `.txt` so they can be retained in the repository.

**Next action:** resolve F1 and F2, add F1 to the permanent MAC tests, and rerun
the relevant checks before resuming Ethernet SoC integration.

---

## Resolution — F1 and F2 fixed

Both follow-ups are fixed; `run-boundaries.sh` now exits 0 and the standard
regression is green.

### F1 — minimum size and byte alignment enforced

The verdict now also requires `bit_cnt == 0` (the frame ended on a byte
boundary) and, for a type frame, `pay_cnt >= MIN_TYPE_PAY` = 46 data/pad + 4
stored FCS = the 64-byte 802.3 minimum. The CRC residue is still necessary but
is no longer sufficient:

| Stimulus | Result |
|---|---|
| Valid 64-byte type frame (14 + 46 + FCS) | accepted, length 46, room 2002, pointer 46 |
| Header + FCS only (18 bytes) | **rejected**, room 2048, pointer 0 |
| Header + 45 data + FCS (63 bytes) | **rejected**, room 2048, pointer 0 |
| Full-size type frame + 1..7 extra bits + recomputed FCS | **all rejected**, room 2048, pointer 0 |

Permanent coverage: `tb_pe_eth_mac` frames 12–15 (the 18-byte runt, the
63-byte runt, and +1/+7 partial-byte cases), and frame 2 (the ARP acceptance
test) is now a conformant 64-byte frame, since the receiver cannot distinguish
pad from data in a type frame. New mutations `no-type-min-size` and
`no-byte-align` in `tb/mutate_eth_mac_tb.sh` (13 detected, 0 survived).

### F2 — the codec configuration reference is current

`tools/gen_signal_glossary.py` now documents `cfg[6:4]` as the run length,
`cfg[7]` as `ones_only`, and the USB configuration byte as `0xE3`, and it
describes the new `ones_only` port. `wiki/reference/signal-names.md` is
regenerated; the drift gate is green.
