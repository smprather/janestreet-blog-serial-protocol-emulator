---
title: No-reset flops in the CMOS5L pe_soc netlist
created: 2026-10-19
updated: 2026-10-19
type: reference
tags: [reference, signoff, verification, architecture]
sources: [flow/pe_soc.json, regress/synth_area.sh, wiki/reference/block-diagram.md]
confidence: high
---

# No-reset flops in the CMOS5L `pe_soc` netlist

> **What this answers:** how many mapped flops have their reset pin tied off
> because synthesis identified the reset as unused. This is a netlist fact,
> not a claim that those flops are safe in arbitrary power-on states.

## Result

The **CMOS5L `pe_soc` synthesis netlist** from
`RUN_2026-10-18_20-27-03`, stage `06-yosys-synthesis/pe_soc.nl.v`, contains
**1,116 flop cells** (`sg13cmos5l_dfrbpq_1`):

| `RESET_B` connection | flop cells | share |
|---|---:|---:|
| tied high (reset identified as unused) | **805** | **72.13%** |
| connected to `rst_n` | 311 | 27.87% |
| other reset logic | 0 | 0% |
| **total** | **1,116** | **100%** |

Two latches are in the same netlist and are **not counted as flops**: one
`sg13cmos5l_dlhq_1` has no `RESET_B` pin, and one `sg13cmos5l_dllrq_1` has
`RESET_B` tied high. Including all sequential cells gives 806 of 1,118
no-reset (72.09%), but the flop-only answer is **805 / 1,116 = 72.13%**.

## What "no reset" means here

The `sg13cmos5l_stdcell` library has **no plain non-reset DFF**: its flop cells
are `dfrbp`/`sdfrbp` families, all with a reset pin. After the synthesis
`opt_dff` pass identifies a flop whose reset value is not needed, the flop is
still mapped to `sg13cmos5l_dfrbpq_1`, with `RESET_B` driven by a
`sg13cmos5l_tiehi` cell. So "not needing reset" is a **tied-off reset pin**,
not a different cell type. It does not by itself save area, and it does not
prove the flop's power-on value is irrelevant — it says the design's reset
network does not drive that flop.

## Method

1. Run the SoC through the CMOS5L flow: `flow/run_librelane.sh
   flow/pe_soc.json` (or use an existing run's stage 06 netlist).
2. Parse the mapped netlist for `sg13cmos5l_*dfr*` instances, read each
   `RESET_B` net, and resolve whether that net is driven by
   `sg13cmos5l_tiehi` (constant 1), `sg13cmos5l_tielo` (constant 0), or an
   `assign` constant.
3. Classify `RESET_B` as `tied high`, `rst_n`, or other logic.

The exact parser used for the result above:

```python
import re, sys, collections

t = open(sys.argv[1], errors="replace").read()
const = {}
for m in re.finditer(r"sg13cmos5l_tiehi\s+\S+\s*\(\s*\.L_HI\s*\(\s*([^)]*?)\s*\)", t):
    const[m.group(1)] = "1"
for m in re.finditer(r"sg13cmos5l_tielo\s+\S+\s*\(\s*\.L_LO\s*\(\s*([^)]*?)\s*\)", t):
    const[m.group(1)] = "0"
for m in re.finditer(r"assign\s+(\S+)\s*=\s*(1'h1|1'b1|1'h0|1'b0)\s*;", t):
    const[m.group(1)] = {"1'h1": "1", "1'b1": "1", "1'h0": "0", "1'b0": "0"}[m.group(2)]

flops = re.findall(r"\b(sg13cmos5l_(?:s?dfr\w*))\s+(\S+)\s*\((.*?)\);", t, re.S)
cls = collections.Counter()
for _typ, _name, body in flops:
    m = re.search(r"\.RESET_B\s*\(\s*([^)]*?)\s*\)", body)
    if not m:
        cls["no RESET_B"] += 1
        continue
    net = m.group(1)
    if net in const:
        cls["tied " + const[net]] += 1
    elif net == "rst_n":
        cls["rst_n"] += 1
    else:
        cls["other logic"] += 1

print("flop cells", len(flops))
print(cls)
print("no-reset pct", 100 * cls["tied 1"] / len(flops))
```

Run it on the flow netlist, for example:

```bash
python3 /tmp/no_reset_flops.py \
  ~/asic-runs/pe_soc/runs/RUN_2026-10-18_20-27-03/06-yosys-synthesis/pe_soc.nl.v
```

## Scope and caveats

- This is the **`pe_soc` core** (the flow config excludes `pe_ctrl` and the TT
  wrapper). The `tt_um_top` adds `pe_ctrl`; its reset mix has not been measured
  in this flow. Do not quote 72.13% as the whole-deliverable figure without
  repeating the analysis on a `tt_um_top` netlist.
- The netlist is post-synthesis, **pre-CTS**; CTS/hold-repair buffers do not
  change these flop reset classifications, but a later run can.
- It includes the uncommitted RTL state in this tree on 2026-10-18. A fresh
  synthesis from a clean commit is the reproducible baseline.
- The historical SG13G2 mapped netlists in `reviews/2026-09-25/` show **0%**
  tie-high because their synthesis recipe did not run the same `opt_dff`
  tie-off. The two percentages are not comparable.
- This is a synthesis identification, not a formal proof that reset is
  unnecessary. If you want to remove reset from a flop for area or reset-tree
  reasons, prove the reset value is unobservable or re-establish it from the
  protocol state first.

## Related

- [[concepts/pdk-toolchain]] — the CMOS5L flow and netlist location.
- [[reference/block-diagram]] — the block inventory and cell counts.
- [[STATUS]] — the current signoff state and open area items.
