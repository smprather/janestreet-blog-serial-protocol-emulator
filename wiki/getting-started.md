---
title: Getting started — a hands-on track
created: 2026-09-26
updated: 2026-09-26
type: concept
tags: [architecture, verification, tooling, plan]
sources: [regress/run_firmware_tests.sh, regress/run_one_tb.sh, regress/run_all.sh, regress/sram_model.sh, regress/check_wiki_pages.sh, regress/check_wiki_links.sh, regress/test_check_wiki_pages.sh, tools/diag/check_diagrams.sh, tools/fw/peasm.py, tools/fw/peemu.py, diagrams/TOOLCHAIN.md, firmware/ws2812.pe, tb/tb_pe_soc_uart.v, wiki/STATUS.md]
confidence: high
---

# Getting started — a hands-on track

**What you'll learn here:** how to run this project, what each command actually
proves, and where every number in the rest of the wiki comes from. By the end
you will have run the firmware, run the gates, changed a protocol, and read the
waveform the chip produces.

**How to verify this page:** every command below was run in this repository,
and the "what you will see" lines are what it printed — **except where a line
says otherwise.** Writing this page caught two of my own claims being wrong
before anyone else had to find them: the SRAM model is *present* here (the
script prints two paths), and `gen_vcd_view.py` takes different flag names
than I first wrote. Both are corrected below, and both corrections are left
visible rather than tidied away, because a tutorial that silently hides its own
errors teaches the reader to trust the next one too much.
Where a step needs something this repository cannot supply, it says so and says
what happens without it. The gates that back the claims are
[[concepts/overview]]; the terms are in [[glossary]].

## Before you start

You need `bash`, `python3` (3.11+), and a POSIX shell. Everything else is
optional and each step names its own requirement.

Clone or enter the repository, and work from its root — most commands below
assume it:

```bash
cd /path/to/janestreet-blog-serial-protocol-emulator
```

---

## Step 1 — check the toolchain

The project's timing and figure claims are only meaningful on a host whose
tools match the ones the committed artefacts were made with, so the versions
are **pinned in a file the gate reads**, not written in prose:

```bash
cat diagrams/TOOLCHAIN.md
```

**What you will see** — a short table of pins:

```
plantuml    = 1.2026.8
graphviz    = 16.1.0
java        = 26.0.2
monospace   = Noto Sans Mono
sans-serif  = Noto Sans
```

**What it means.** `tools/diag/check_diagrams.sh` proves every rendered figure is
byte-identical to a fresh render of its source. That check is only sound if your
renderer produces the same bytes as the host that made the committed renders. So
compare yours:

```bash
plantuml -version | head -1
dot -V
java -version 2>&1 | head -1
```

**What you will see** on a matching host, for example:

```
PlantUML version 1.2026.8 / 149874a [2026-09-07 10:00:36 UTC]
dot - graphviz version 16.1.0 (0)
openjdk version "26.0.2" 2026-07-21
```

**What it means if yours differ.** You can read and run everything else in this
wiki. The **diagram freshness gate will report a red you cannot clear by editing
a diagram**, which is worse than no gate — so the gate treats a toolchain
difference as *inconclusive* and says so instead of failing. The pin is the
version only, not the build stamp, because the stamp changes between builds of
the same release and pinning it would produce that same uncancellable red.

For the simulator (only needed from Step 3 on):

```bash
iverilog -V | head -1
```

**What you will see:** `Icarus Verilog version 13.0 (stable)`. The project needs
11 or newer with `-g2012`.

---

## Step 2 — run the firmware

This is the quickest way to see the project's central idea work, and it needs
no simulator.

```bash
bash regress/run_firmware_tests.sh
```

**What you will see** — a table and a verdict:

```
========================================
FIRMWARE: 37   PASS: 37   FAIL: 0
all firmware tests pass
```

**What it means.** Every `.pe` program in `firmware/` was assembled and
checked. 37 of 37 passed, so the assembler and all the protocol images are
sound. This does **not** yet prove anything about the silicon — that is Step 3.

Read one act to see what a protocol looks like here:

```bash
head -30 firmware/ws2812.pe
```

**What you will see** — a comment block explaining that a WS2812 strip has *no
clock on the wire*, and that at 60 MHz one bit cell is **exactly 75 clocks** with
no remainder.

**What it means.** This is the sharpest test of the project's thesis. UART, SPI
and I2C all have a clock on the wire, so firmware running 10% fast still
produces a readable waveform. A WS2812 strip samples the line at one instant in
every cell, so if you are one clock out you are simply wrong.

---

## Step 3 — assemble a protocol yourself

Now change something and watch the artefact change.

```bash
python3 tools/fw/peasm.py firmware/ws2812.pe --listing | head -6
```

**What you will see** — address, encoded word, and the source line:

```
--- 129 words (258 bytes of instruction memory)
  0  0000  LDI A, 0x00
  1  1002  OUT PINOE, A
  2  0040  LDI A, LED_DIN
  3  1001  OUT TXPIN, A
```

**What it means.** A protocol persona is **a program**, not a block of gates.
`129 words` is the whole WS2812 driver: it fits in a 1024-word instruction
memory with room to spare, and it is 129 words because the protocol is 129
instructions long.

Now assemble it to an image, and see the one knob that matters for timing:

```bash
python3 tools/fw/peasm.py firmware/ws2812.pe -o /tmp/ws2812.hex && wc -l /tmp/ws2812.hex
python3 tools/fw/peasm.py firmware/ds18b20.pe --const OW_RST=40 | head -3
```

**What it means.** `--const NAME=VALUE` overrides a named constant — here the
DS18B20's reset delay. That flag exists because the project's mutation harness
has to *break* a fitted counted delay to prove its test can fail. The same knob
is how you would sweep a delay rather than tune one.

**Try this:** edit `firmware/ws2812.pe`, change the cell length, re-assemble,
and watch the word count move. That is the whole development loop for a persona.

---

## Step 4 — run the checks that guard the repository

The project treats a claim as real only if something can prove it wrong. These
are those somethings, and you can run each one.

```bash
bash regress/check_wiki_pages.sh
```

**What you will see:**

```
check_wiki_pages: 63 hand-written pages, 44 taxonomy tags read from wiki/SCHEMA.md
  violations found: 0 across 0 page(s)
  baseline: 0 pinned violation(s)
check_wiki_pages: OK — 0 new, 0 stale; 0 known violation(s) pinned in the baseline
```

**What it means.** Every hand-written page was checked against the five rules in
[[SCHEMA]]: frontmatter present, `type` legal, tags inside the taxonomy, at
least two outbound links, and listed in the index. `0 new, 0 stale` is the whole
point — the gate has two directions, so it also fails if a *pinned* violation
has been fixed but the pin left behind. A baseline entry that outlives its
defect is a lie, and this gate refuses to let one sit there.

Now the document-link gate:

```bash
bash regress/check_wiki_links.sh
```

**What you will see** — a count, and `OK`:

```
check_wiki_links: 72 document(s) scanned, 708 link(s) checked, 0 dead
```

**What it means.** Every link a reader might click was resolved and found. It
scans only the **live** surface (`wiki/**` minus `raw/`, plus `README.md` and
`docs/`). `reviews/` and `logs/` are excluded on purpose: a path in a review
record that was true when written is *evidence*, and rewriting it to follow a
rename would falsify the record, while flagging it would cry wolf forever.

Now the negative control — the thing that proves the gates above can fail:

```bash
bash regress/test_check_wiki_pages.sh | tail -2
```

**What you will see:** a count of cases, and `0 failed`.

**What it means.** Each case breaks something on purpose — plants an off-taxonomy
tag, a dead link in each wikilink convention, a pin that no longer bites — and
requires the gate to notice. A gate that has only ever been seen green is a
script that prints reassuring text. This suite is the evidence that ours is not.

**Make it fail, to see why that matters.** Open `regress/run_all.sh`, delete the
line that calls `regress/check_wiki_links.sh`, and re-run the control:

```bash
bash regress/test_check_wiki_pages.sh | grep check_wiki_links
```

**What you will see:** that case goes red with a message saying the gate is not
called. **Restore the file afterwards.** There is an assertion for exactly this
because the same thing happened in this repository — two gates were written,
documented, and never once executed by a full run.

Finally, the figures:

```bash
bash tools/diag/check_diagrams.sh | tail -2
```

**What you will see:** `diagrams: OK`.

**What it means.** Every one of the 34 figures was re-rendered from its `.puml`
source and compared byte for byte with the committed PNG and SVG. If a figure
had been edited without re-rendering, you would see a `STALE` line naming it.

---

## Step 5 — run a testbench, and why it may refuse

Now the silicon. A testbench needs Icarus and the SRAM behavioural model.

```bash
cat regress/sram_model.sh | head -9
```

**What you will see** — a comment explaining that the SRAM macro is a hard
macro supplied as GDS, so simulating it needs a model that lives **outside** the
repository.

**What it means.** This is a deliberate design decision. The tempting fallback
is `pe_imem`'s flop array — and a testbench that quietly ran against the
fallback would have verified **nothing about the memory**. So a missing model is
a loud failure, never a quiet substitution.

Check whether you have it:

```bash
bash regress/sram_model.sh
```

**What you will see** — the two behavioural models it resolved, one per line:

```
/home/<you>/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_1024x16_c2_bm_bist.v
/home/<you>/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v
```

**What it means.** Both files were found, so testbenches will simulate the real
SRAM macro. If yours print `sram model unavailable` instead, the PDK is not
where the script looks — it resolves the IHP PDK under `~/pdk/IHP-Open-PDK`.
In that case the firmware (Step 2) and every gate (Step 4) still work; only the
testbenches do not. Note what this script refuses to do: substitute `pe_imem`'s
flop array, because a testbench that quietly ran against the fallback would
have verified nothing about the memory.

With the model present, run one testbench in isolation:

```bash
regress/run_one_tb.sh \
  "tb_pe_soc_uart|<rtl files, space separated, as ../rtl/...>|tb_pe_soc_uart" \
  /tmp/tbwork
cat /tmp/tbwork/*.result
```

**What you will see** — in the result file, a verdict, and the measurement lines
the testbench printed: measured bit cells in nanoseconds, and `PASS`.

**What it means.** This is the step where a number in [[STATUS]] comes from. The
testbenches do not assert a datasheet number; they **measure the pin** and print
what they measured, and the wiki quotes that. The `name|rtl|top|wip` spec is
four fields because `run_all.sh` keeps a `<<wip>>` marker in the fourth; see
[[concepts/overview]] for why a wip is marked rather than hidden.

**The `$readmemh` trap.** Testbenches load firmware with paths like
`../firmware/uart_echo.hex`, which are **relative to the process working
directory**, not to the testbench file. The binary is therefore invoked from
`sim/`, and waveform dumps land in `sim/` because `$dumpfile` is likewise
relative to the process cwd. If you run `vvp` from the repository root, the
firmware will not load and you will see an empty memory rather than an error
about paths. This is the single most common confusion for a newcomer, and
`regress/run_one_tb.sh` exists so you do not have to hit it.

---

## Step 6 — read a waveform

The most convincing artefact in the project is a measured pin.

A VCD records every signal transition, but a raw VCD viewer shows you *what*
the wires did and not *why*. The project ships a renderer that draws a window of
one as a labelled timing diagram. Its real interface, from `--help`:

```bash
python3 tools/live-canvas/gen_vcd_view.py --help
```

**What you will see** — required `--vcd`, `--signals`, `--from` and `--to`,
plus optional `--clock`, `--title`, `--strobe` and others. (I first wrote this
step with the wrong flag names; the real ones are above.)

Once a testbench has run, its VCD is in `sim/` — dumps land there because
`$dumpfile` is relative to the process cwd, which the harness sets to `sim/`
deliberately. Then, following the example in the tool's own help:

```bash
python3 tools/live-canvas/gen_vcd_view.py --vcd sim/tb_pe_uart.vcd \
  --signals line,bit_en,tx_load,tx_busy,tx_ser \
  --from 250000 --to 500000 --title "UART TX: one byte, 8N1"
```

**What it will show you** — an SVG in which you can see *which edge committed
which value*, where the strobe lands, and what each column of the transfer
means. The renderer is explicit about refusing to lie: it draws the sampled
value of every signal on every clock edge it can find, so a signal that is
valid only mid-cycle is visibly so, and an edge that commits nothing is visibly
flat. That is the thing a raw VCD viewer cannot tell you, and it is where most
of the subtle timing bugs in this project were found: a sample ordered one step
early, a value valid only mid-cycle, a strobe arriving before the data it is
meant to be committing.

---

## Step 7 — the whole regression, when you have time

```bash
regress/run_all.sh --fast -j8
```

**What you will see** — a table of every testbench, then lint, then the
generated-document and documentation gates, then the mutation suites.

**What it means.** This is the full gate: every testbench, every mutation suite
(a suite that proves each testbench can *fail* when the property it claims is
broken), the formal proofs, and the documentation gates from Step 4.

**Two things to know before you run it.** First, `--fast` does **not** switch
simulator: it runs the same Icarus simulation in parallel. The name invites
the wrong assumption and the reasoning is measured in the script's header.
Second, it **mutates the RTL on purpose** — that is how mutation testing works —
so it takes the project's single-run lock and refuses to start if another run
holds it. It is also the long one. For a first pass, Steps 2 and 4 give you most
of the confidence in a fraction of the time.

---

## Where to go next

- [[concepts/overview]] — how the five layers fit together. Read this next.
- [[glossary]] — the terms of art, with one-line definitions.
- [[concepts/competition-overview]] — what the competition asks for, and the
  area and tile rules that constrain the design.
- [[concepts/spi-as-firmware]] — the thesis in one concrete protocol.
- [[concepts/protocol-ws2812]] and [[concepts/protocol-servo]] — the timing
  acts, where the waveform *is* the specification.
- [[plans/feature-brainstorm]] — **where to go next**: 33 ideas for what could
  be built on top of this, ranked, with the effort shape of each.

## If a step does not work

Two failure modes are worth recognising, and both are properties of the project
rather than accidents:

1. **A red gate you cannot clear by editing the thing it is about.** Usually a
   toolchain difference (Step 1) or a shared-run lock. Both say so explicitly —
   read the message before changing anything.
2. **A gate that passes when you expected a failure.** That is worse than a red.
   It is what the negative control in Step 4 exists to make visible, and if you
   see it, the honest response is to distrust the gate rather than to trust the
   result.
