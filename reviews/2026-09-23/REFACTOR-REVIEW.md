# Refactor review — 2026-09-23

**Reviewed:** `6de2a6ab4c1cdf9a014c21075231197fe1fbf3a4` on `main`.
**Baseline:** `2cc0f03e5eb1de9886254bee36496e5ef4a9dae0`, immediately before the
layout refactor, with the earlier F1/F2/F3 fixes already closed.

## Result

**No new functional defect found.** The source comparisons and fresh regression
support the commit's functional no-op claim. The previous review's failure
cases still pass after the moves. No RTL, firmware, production tool, or
regression-harness changes were needed during this review.

This review checked the refactor itself and reran the earlier adversarial
probes. It is not a proof that every possible protocol input is correct.

## What changed and what was checked

| Change | Review result |
|---|---|
| `pe_uart_soc` → `pe_soc`, including four SoC TB names | Intended module/instance/test-label renames only; all module bodies match after normalizing these names. Wrapper, test harnesses and manifests resolve the new name. |
| `pe_line_codec.v` → `pe_nrzi.v`, `pe_manch.v`, `pe_bitstuff.v` | All three module bodies preserved. Shared comments were redistributed and the obsolete Verilator filename suppression removed. No compilation directives were lost. |
| SRAM shell moved under `rtl/vendor/` | Ports and `(* blackbox *)` attribute preserved. Both submission metadata and flow staging include the relocated shell. |
| Eleven shell harnesses moved from `tb/` to `regress/` | Source lists, firmware-tool invocations, mutation targets, and nested harness calls use the new paths. Full regression and interruption probes pass. |
| Python moved to `tools/{fw,gen,checks}/` | Repository-root calculations and I2C assembler/emulator imports updated. All seven generators and both checkers also work when launched from a temporary directory outside the repository. |
| Flow config, SDC and PDN Tcl renamed to `pe_soc.*` | Staging resolves the intended files; staged Verilog bytes match the originals and both configured designs compile. No physical flow was run. |
| Generated references and diagrams refreshed | All generated-document gates pass. The signal glossary now covers project RTL at the top of `rtl/`; the vendor shell's ports no longer appear in that generated page. |

### Source preservation

[Comparison output](refactor/equivalence.txt),
[reproducible checker](refactor/compare_refactor.py).

- **15 → 15 RTL modules** and **26 → 26 testbench modules**, with no changed
  token streams after the explicit SoC/TB renames and diagnostic path change.
  The RTL count includes the vendor shell. Strings are retained; comments and
  insignificant whitespace are ignored.
- File-level directives and attributes also match per renamed file, including
  the SRAM blackbox attribute and all testbench timescales.
- `peasm.py` and `peemu.py` have identical executable Python ASTs after removing
  docstrings. All four committed firmware `.hex` images are byte-identical.
- Manual comparison of all eleven shell harnesses found the expected path/name
  substitutions, `tools/fw` import roots, and individual codec synthesis source
  lists. The generator changes likewise resolve the new paths and labels.

These checks establish source preservation under the stated normalization;
they are not formal sequential equivalence checking or physical signoff.

## Fresh execution evidence

The checkout was clean at the start. The full regression ran in a fresh
`git archive HEAD` copy under `/tmp`; the review probes use temporary build
outputs, and the mutation interruption probe uses its own archived copy.

| Check | Result | Evidence |
|---|---|---|
| `./regress/run_all.sh --fast -j4` | Exit 0; **26/26 RTL**, **18/18 firmware**; 14 Verilator tops, 11 Yosys elaborations; parameter guards, documentation gates, Canvas viewer, I2C timing, all four mutation suites pass | [Full output](refactor/regression.txt) |
| `bash reviews/2026-09-22/review2/run_repros.sh --sweep` | Exit 0; seven original probes pass; **102 asynchronous Ethernet trials, 0 failures** | [Full output](refactor/probes.txt) |
| `bash reviews/2026-09-23/run-boundaries.sh` | Exit 0; valid 46-byte EtherType payload accepted; 0/45-byte payload runts and all 1–7 trailing partial-bit cases rejected with buffer room restored to 2,048 and pointer 0 | [Full output](refactor/boundaries.txt) |
| Relocated generators/checkers launched from `/tmp` | Seven generator `--check` commands and both checkers exit 0 | [Full output](refactor/layout.txt) |
| Submission source manifest | All six `info.yaml` paths resolve; `tt_um_protocol_emulator` compiles | [Checker and command](refactor/check_layout.py) |
| Actual Python staging block extracted from `flow/run_librelane.sh` | Both configs stage successfully into `/tmp`, including renamed constraints, PDN Tcl and SoC macro collateral; SERDES (1 source) and SoC (5 sources) compile from staged files | [Full output](refactor/layout.txt) |

The interruption probe terminates each of the I2C, SPI and frame-buffer mutation
harnesses with status 143 and reports `changed=[]`. This verifies the tested
interruption points; it is not an exhaustive test of all possible signals or
interruption timings. The probe runner's additional DDR NBA experiment is a
temporary diagnostic variant; the checked-in RTL passes independently.

The previous CAN documentation fix is retained: the glossary specifies `0x51`
(`0x01` equivalent), and the permanent `tb_pe_codec_mux` TX/RX cases pass in the
fresh regression. Earlier finding details remain in
[the fix verification](FIX-VERIFICATION.md) and
[the F1/F2 recheck and F3 resolution](F1-F2-RECHECK.md).

## Scope and handoff

- Old public file paths and the `pe_uart_soc` module name have intentionally
  changed. External scripts or HDL instantiations must adopt the new layout;
  compatibility aliases were not part of this refactor.
- The current executable references inspected in RTL, harnesses, tools, flow
  configs and submission metadata use the new layout. Historical review prose
  retains its original paths and carries a layout note; its maintained runners
  passed on the new layout.
- The source-staging check executes only the launcher's Python copy block.
  Docker, LibreLane, physical flow, DRC and LVS were not invoked, following the
  standing user instruction. Prior physical results were not revalidated.
- Two delegated reviewers hit a usage limit before delivering final reviews.
  The remaining source and tool checks were completed locally; this report
  does not claim a completed independent second review.
- Updated `HANDOFF.md` and `wiki/STATUS.md` to point here and identify the fresh
  verification revision. Corrected the stale statement that the review branch
  equals `main`: `review/fix-invisible-defects` remains at `2cc0f03`.

**Next:** resume the ordered integration/loader/I2C transaction backlog in
`wiki/STATUS.md`. No open refactor finding needs to precede that work.

To repeat the source and layout checks from the repository root:

```bash
python3 reviews/2026-09-23/refactor/compare_refactor.py
python3 reviews/2026-09-23/refactor/check_layout.py
```

The first compares the current checkout against `2cc0f03`. The second requires
the normal local simulation tools and PDK, and uses temporary output directories.
The archived `.txt` files describe the reviewed `6de2a6a` checkout.

## Documentation follow-up — retired signoff target corrected

After this review, the user identified stale README prose claiming signoff at
66 MHz. That documentation issue was missed in the review. Both checked-in
flow configs already specify `CLOCK_PERIOD: 16.667` (60 MHz), and ADR-005's
2026-09-22 amendment retires the 66 MHz target.

Corrected the README's current target and reproduction instructions, labelled
the old SERDES result as historical, and synchronized the matching metadata
comment, clock notes, status and handoff guidance. Historical measurements
retain their original frequencies; the handoff points to the recorded 60 MHz
SoC result. This correction changes documentation/comments only. The source
preservation and simulation results above still describe the reviewed code;
no new physical verification was performed.

## Documentation follow-up — SoC naming corrected

The user also identified the README's obsolete "Software-UART SoC" label.
Changed it to "Programmable protocol SoC" to match `pe_soc` and its UART,
SPI and I2C firmware use. Updated the nearby status and memory descriptions:
the pin matrix and frame buffer are implemented, and `wiki/STATUS.md` owns the
current integration backlog. README source references and whitespace checks
pass; this follow-up changes documentation only.
