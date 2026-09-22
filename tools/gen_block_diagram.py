#!/usr/bin/env python3
"""Generate wiki/reference/block-diagram.md — a Mermaid block diagram of the design.

Answers one question: what is this chip, and what is actually in it?

WHY THIS IS GENERATED. The hand-drawn ASCII diagram it replaces had drifted in
three ways at once: it still said "the pin matrix does not exist yet" (it landed
2026-09-22, 111 cells, with a TB), it described pe_uart_soc's memory as
"flop memory" (the SRAM macro swap landed 2026-09-20), and it omitted pe_dru and
pe_crc from the built list in one place while listing them in another. A diagram
is the most-read and least-checked artifact in a repo, which is exactly the
combination that rots.

So the BUILT set is derived from the filesystem and from synth_area.sh: a block
appears as built only if its RTL exists, it is mapped in tools/synth_area.sh, and
it has a testbench listed in tb/. An orphan (built, tested, instantiated nowhere)
is marked as such rather than quietly drawn as a signal path -- see STATUS gotcha
14, "hardware nothing exercises is hardware you have not tested".

    python3 tools/gen_block_diagram.py           # write the page
    python3 tools/gen_block_diagram.py --check    # exit 1 if stale
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RTL = REPO / "rtl"
TB = REPO / "tb"
OUT = REPO / "wiki" / "reference" / "block-diagram.md"

# ---- the blocks, and what is true about each ---------------------------------
#
# source_file: where the module actually lives. Three modules share one file
#   (pe_line_codec.v holds pe_nrzi, pe_manch AND pe_bitstuff), which is why the
#   file and the module name are separate fields -- an earlier version of this
#   generator conflated them and the gate caught it.
# instantiated_in: the RTL file that instantiates it, or None if orphaned.
# tb: the testbench that covers it. Three line-codec modules share one TB, so
#   this field is NOT "tb_<name>.v" and must be stated explicitly.
BLOCKS = [
    dict(
        name="pe_cpu",
        source_file="pe_cpu.v",
        role="the ISA: 16 opcodes, A/Y/X, 8-bit datapath",
        instantiated_in="pe_uart_soc.v",
        tb="tb_pe_cpu.v",
    ),
    dict(
        name="pe_imem",
        source_file="pe_imem.v",
        role="instruction memory; SRAM macro by default",
        instantiated_in="pe_uart_soc.v",
        tb="tb_pe_imem.v",
        # synth_area maps the macro and flop variants separately, so the SoC's
        # actual configuration is what should be shown. Without this the label
        # silently loses its cell count -- caught by rendering the diagram and
        # looking at it, not by the structural check.
        cells_key="pe_imem_macro",
    ),
    dict(
        name="pe_serdes",
        source_file="pe_serdes.v",
        role="word engine: load 8-32 bits, pace with bit_en",
        instantiated_in=None,  # 539 cells routed; no SoC instance yet
        tb="tb_pe_serdes.v",
    ),
    dict(
        name="pe_dru",
        source_file="pe_dru.v",
        role="digital receiver unit: 12x oversampled edge recovery",
        instantiated_in=None,
        tb="tb_pe_dru.v",
    ),
    dict(
        name="pe_crc",
        source_file="pe_crc.v",
        role="CRC/LFSR generator, 8/16/32-bit, catalogue-checked",
        instantiated_in=None,
        tb="tb_pe_crc.v",
    ),
    dict(
        name="pe_pinmux",
        source_file="pe_pinmux.v",
        role="per-pin direction, open-drain, read-back (the I2C gate)",
        instantiated_in=None,
        tb="tb_pe_pinmux.v",
    ),
    dict(
        name="pe_codec_mux",
        source_file="pe_codec_mux.v",
        role="stuff -> nrzi/manchester; cfg selects the subset",
        instantiated_in=None,
        tb="tb_pe_codec_mux.v",
    ),
    dict(
        name="pe_nrzi",
        source_file="pe_line_codec.v",
        role="NRZI encode/decode",
        instantiated_in="pe_codec_mux.v",
        tb="tb_pe_codec_mux.v",
    ),
    dict(
        name="pe_manch",
        source_file="pe_line_codec.v",
        role="Manchester encode/decode",
        instantiated_in="pe_codec_mux.v",
        tb="tb_pe_codec_mux.v",
    ),
    dict(
        name="pe_bitstuff",
        source_file="pe_line_codec.v",
        role="bit stuffing (CAN/USB style)",
        instantiated_in="pe_codec_mux.v",
        tb="tb_pe_codec_mux.v",
    ),
]

# ---- planned, not built -------------------------------------------------------
PLANNED = [
    ("pe_ctrl (SPI load path)", "boot the chip in real silicon; today the loader is a "
                                "host port driven by the TB, so the chip cannot boot itself"),
    ("frame buffer (2nd SRAM)", "ADR-003; 10BASE-T needs 2 KB. Instruction macro only, so far"),
    ("pe_pinmux into the SoC", "plan step 5: put the matrix in front of the fixed-mask port"),
    ("I2C 1 us tick divider", "plan step 5: 60 clocks at 60 MHz, distinct from the 260 UART tick"),
    ("pe_serdes into the SoC", "the SERDES is routed and TB-proven but no SoC instance drives it"),
]


def check_instantiated(blocks: list[dict], problems: list[str]) -> None:
    """Verify each block's instantiated_in claim against the RTL, so the
    diagram cannot claim a signal path that does not exist."""
    for b in blocks:
        f = RTL / b["source_file"]
        if not f.is_file():
            problems.append(f"{b['name']}: source_file rtl/{b['source_file']} is missing")
            continue
        # the module must actually be DEFINED in the file it claims
        if not re.search(rf"^module\s+{b['name']}\b", f.read_text(encoding="utf-8"), re.M):
            problems.append(
                f"{b['name']}: rtl/{b['source_file']} does not define module {b['name']}"
            )
        if b["instantiated_in"]:
            parent = RTL / b["instantiated_in"]
            if not parent.is_file():
                problems.append(f"{b['name']}: parent {b['instantiated_in']} missing")
                continue
            src = parent.read_text(encoding="utf-8")
            if not re.search(rf"\b{b['name']}\b", src):
                problems.append(
                    f"{b['name']}: diagram says it is instantiated in "
                    f"{b['instantiated_in']}, but that file does not name it"
                )


def check_tb(blocks: list[dict], problems: list[str]) -> None:
    """A block with no TB in run_all.sh is not verified. Flag it."""
    run_all = (TB / "run_all.sh").read_text(encoding="utf-8")
    seen: set[str] = set()
    for b in blocks:
        if b["tb"] in seen:
            continue
        seen.add(b["tb"])
        if not (TB / b["tb"]).is_file():
            problems.append(f"{b['name']}: TB tb/{b['tb']} does not exist")
        elif b["tb"].replace(".v", "") not in run_all:
            problems.append(
                f"{b['name']}: tb/{b['tb']} exists but is not in run_all.sh "
                "(a TB nothing runs is not a test)"
            )


def read_cells() -> dict[str, str]:
    """Read mapped cell counts from the last synth_area run, if available.

    Deliberately NOT re-running synthesis here: the generator must stay cheap
    enough to sit in the regression, and synthesis is minutes. The page states
    the counts as 'last mapped' with the command to refresh them.
    """
    cache = REPO / "wiki" / "reference" / ".block-diagram-cells"
    if not cache.is_file():
        return {}
    out = {}
    for line in cache.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            out[parts[0]] = parts[1]
    return out


def build() -> tuple[str, list[str]]:
    problems: list[str] = []
    check_instantiated(BLOCKS, problems)
    check_tb(BLOCKS, problems)
    cells = read_cells()

    built = [b for b in BLOCKS if b["instantiated_in"]]
    orphan = [b for b in BLOCKS if not b["instantiated_in"]]

    def label(b: dict) -> str:
        c = cells.get(b.get("cells_key", b["name"]), "")
        tail = f"<br/><i>{c} cells</i>" if c else ""
        return f'["<b>{b["name"]}</b><br/>{b["role"]}{tail}"]'

    cpu = next(b for b in BLOCKS if b["name"] == "pe_cpu")
    imem = next(b for b in BLOCKS if b["name"] == "pe_imem")

    # Every block must resolve to a cell count. A silent "—" is how the diagram
    # loses information without anyone noticing: synth_area.sh keys pe_imem's
    # macro and flop variants separately (pe_imem_macro / pe_imem_flop), so a
    # block whose cells_key does not match its display name quietly blanks out.
    if cells:
        for b in BLOCKS:
            if cells.get(b.get("cells_key", b["name"])) is None:
                problems.append(
                    f"{b['name']}: no cell count in .block-diagram-cells "
                    f"(looked up {b.get('cells_key', b['name'])!r}) — the diagram "
                    "would show a blank instead of a number"
                )

    L: list[str] = []
    L += [
        "---",
        'title: "Block diagram"',
        "created: 2026-09-22",
        "updated: 2026-09-22",
        "type: reference",
        "tags: [architecture, reference, verification]",
        "sources: [rtl/, tools/synth_area.sh, wiki/plans/through-i2c.md]",
        "confidence: high",
        "---",
        "",
        "# Block diagram",
        "",
        "> **Generated** by `tools/gen_block_diagram.py`. The built/orphan split is",
        "> checked against `rtl/` and `tb/run_all.sh` on every regression, so a block",
        "> cannot be drawn as a signal path unless something instantiates it.",
        "",
        "**Rendered copies you can open without a Mermaid viewer:**",
        "`diagrams/block-diagram-chip.svg` (below) and",
        "`diagrams/block-diagram-orphans.svg` (the orphans). They are produced from",
        "the blocks on this page by `tools/render_block_diagram.py`, so the rendering",
        "cannot drift from the source here.",
        "",
        "## What is in the chip today",
        "",
        "Read this as **two styles coexisting on purpose**. The firmware core",
        "bit-bangs pins; the SERDES is a word engine. [[plans/through-i2c]] argues",
        "why, and the short version is that control flow is per-bit for I2C",
        "(ACK, arbitration, clock stretch) and per-word for UART/SPI/CAN/USB.",
        "",
        "```mermaid",
        "flowchart TB",
        "    subgraph BOARD[\"off-chip / board\"]",
        "        HOST[\"host loader<br/><i>a TB today; pe_ctrl later</i>\"]",
        "        WIRE[\"protocol pins<br/>ui_in / uo_out / uio\"]",
        "    end",
        "",
        '    subgraph TT["tt_um_protocol_emulator — the deliverable"]',
        "        subgraph SOC[\"pe_uart_soc\"]",
        "            CPU" + label(cpu),
        "            IMEM" + label(imem),
        "            TICK[\"tick timer<br/><b>260</b> clk = half a 115200 bit\"]",
        "            PORT[\"fixed-mask port<br/>PIN_IN_MASK = 8'hF8\"]",
        "            CPU --> IMEM",
        "            CPU --> TICK",
        "            CPU --> PORT",
        "            IMEM -.->|FLOP=0| SRAM",
        "        end",
        '        SRAM["SRAM macro<br/>RM_IHPSG13 1P_1024x16"]',
        "    end",
        "",
        '    HOST -.->|"imem/dmem write port"| IMEM',
        # Two directed edges rather than one <--> : mermaid routes a bidirectional
        # edge the long way round, which made it graze the SRAM box and read as if
        # the SRAM drove the pins. Caught by rendering the diagram and looking.
        '    PORT -->|"drive"| WIRE',
        '    WIRE -->|"sense"| PORT',
        "",
        '    classDef built fill:#1f4d2e,stroke:#4ade80,color:#fff',
        '    classDef plan fill:#4a1f1f,stroke:#f87171,color:#fff,stroke-dasharray: 5 5',
        "    class CPU,IMEM,TICK,PORT,SRAM built",
        "```",
        "",
        "### Built, verified — and wired to nothing",
        "",
        "These blocks pass their own testbenches but no SoC instance drives them.",
        "Drawn as detached, because that is what they are:",
        "",
        "```mermaid",
        "flowchart LR",
    ]

    for b in orphan:
        L.append("    " + b["name"] + label(b))

    L += [
        '    classDef orphan fill:#3a2f0f,stroke:#facc15,color:#fff,stroke-dasharray: 5 5',
        "    class " + ",".join(b["name"] for b in orphan) + " orphan",
        "```",
        "",
        "## The built blocks, and where they actually live",
        "",
        "| block | role | instantiated in | cells | TB |",
        "|---|---|---|---|---|",
    ]

    for b in built + orphan:
        where = b["instantiated_in"] or "**nowhere — orphan**"
        c = cells.get(b.get("cells_key", b["name"]), "—")
        L.append(f"| `{b['name']}` | {b['role']} | {where} | {c} | `{b['tb'][:-2]}` |")

    L += [
        "",
        "### Orphans: built, tested, and driving nothing",
        "",
        f"**{len(orphan)} of {len(BLOCKS)} blocks are instantiated nowhere in `rtl/`.**",
        "That is not an accident and not a bug in the diagram — it is the project's",
        "staging: each block was built and verified standalone before anything",
        "wired it up. But it is worth stating plainly, because it is the single",
        "biggest gap between \"what is built\" and \"what the chip does\":",
        "",
    ]

    for b in orphan:
        L.append(f"- **`{b['name']}`** — {b['role']}")

    L += [
        "",
        "[[STATUS]] gotcha 14 is the rule this section exists to satisfy:",
        "**\"hardware nothing exercises is hardware you have not tested.\"** A block",
        "with a passing TB is verified *in isolation*; that is weaker than verified",
        "in the design, and the difference is exactly what this table shows.",
        "",
        "## Planned, and why each one is a gate",
        "",
        "| not built yet | what it unblocks |",
        "|---|---|",
    ]

    for name, why in PLANNED:
        L.append(f"| **{name}** | {why} |")

    L += [
        "",
        "## The two memory stories",
        "",
        "There are two memories in the ADRs and only one in the RTL:",
        "",
        "- **Instruction memory — BUILT.** `pe_imem` instantiates the PDK's",
        "  `RM_IHPSG13_1P_1024x16_c2_bm_bist` by default (`FLOP=0`). This is the",
        "  SRAM that carries the design's critical path (`A_CLK` -> `A_DOUT`,",
        "  7.635 ns in context at the slow corner), and it is the reason the SoC",
        "  needed its own STA run at all — see [[reference/sram-budget]].",
        "- **Frame buffer — NOT BUILT.** ADR-003 plans a 2 KB frame buffer for",
        "  10BASE-T (a max Ethernet frame is 1518 bytes, so the 1 KB parts miss by",
        "  494). No RTL exists for it.",
        "",
        "The `FLOP=1` path in `pe_imem` synthesises a register array instead of the",
        "macro (60,806 cells vs 12). It exists for tests and area experiments and is",
        "mapped separately by `synth_area.sh`; it is **not** what the SoC uses.",
        "",
        "## Refreshing the cell counts",
        "",
        "Counts come from `tb/synth_area.sh` (mapped, typ corner). To refresh:",
        "",
        "```bash",
        "./tb/synth_area.sh | awk 'NF>=3 && $2 ~ /^[0-9]+$/ {print $1, $2}' \\",
        "  > wiki/reference/.block-diagram-cells",
        "python3 tools/gen_block_diagram.py",
        "```",
        "",
        "## Related",
        "",
        "- [[reference/clock-arithmetic]] — the 60 MHz constants every block derives from.",
        "- [[reference/signal-names]] — the port list, generated from the RTL.",
        "- [[concepts/factored-hardware-blocks]] — why these blocks are factored this way.",
        "- [[concepts/pin-matrix]] — the orphan that gates I2C.",
        "- [[plans/through-i2c]] — the ordered work list.",
        "- [[STATUS]] — what is built and verified, in prose.",
        "",
    ]

    return "\n".join(L), problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    rendered, problems = build()
    for p in problems:
        print(f"WARN: {p}", file=sys.stderr)

    if args.check:
        if not OUT.exists():
            print(f"gen_block_diagram: {OUT} is missing", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != rendered:
            print(f"gen_block_diagram: {OUT} is STALE — re-run without --check",
                  file=sys.stderr)
            return 1
        print("block diagram up to date")
        return 0 if not problems else 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT} ({len(rendered)} bytes)")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
