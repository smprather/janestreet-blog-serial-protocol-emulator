#!/usr/bin/env python3
"""Generate wiki/reference/block-diagram.md — a checked RTL block inventory.

Answers one question: what is this chip, and what is actually in it?

WHY THIS IS GENERATED. The hand-drawn ASCII diagram it replaces had drifted in
three ways at once: it still said "the pin matrix does not exist yet" (it landed
2026-09-22, 111 cells, with a TB), it described pe_soc's memory as
"flop memory" (the SRAM macro swap landed 2026-09-20), and it omitted pe_dru and
pe_crc from the built list in one place while listing them in another. A diagram
is the most-read and least-checked artifact in a repo, which is exactly the
combination that rots.

So the BUILT set is derived from the filesystem and from synth_area.sh: a block
appears as built only if its RTL exists, it is mapped in tools/synth_area.sh, and
it has a testbench listed in tb/. An orphan (built, tested, instantiated nowhere)
is marked as such rather than quietly drawn as a signal path -- see STATUS gotcha
14, "hardware nothing exercises is hardware you have not tested".

    python3 tools/gen/block_diagram.py           # write the page
    python3 tools/gen/block_diagram.py --check    # exit 1 if stale
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
RTL = REPO / "rtl"
TB = REPO / "tb"
REGRESS = REPO / "regress"
OUT = REPO / "wiki" / "reference" / "block-diagram.md"

# ---- the blocks, and what is true about each ---------------------------------
#
# source_file: where the module actually lives (one module per file).
# instantiated_in: the RTL file that instantiates it, or None if orphaned.
# tb: the testbench that covers it. The three line-codec modules share the
#   tb_pe_line_codec.v suite, so this field is NOT always "tb_<name>.v" and
#   must be stated explicitly.
BLOCKS = [
    dict(
        name="pe_cpu",
        source_file="pe_cpu.v",
        role="the ISA: 16 opcodes, A/Y/X, 8-bit datapath",
        instantiated_in="pe_soc.v",
        tb="tb_pe_cpu.v",
    ),
    dict(
        name="pe_imem",
        source_file="pe_imem.v",
        role="instruction memory; SRAM macro by default",
        instantiated_in="pe_soc.v",
        tb="tb_pe_imem.v",
        # synth_area maps the macro and flop variants separately, so the SoC's
        # actual configuration is what should be shown. Without this the label
        # silently loses its cell count -- caught by rendering the diagram and
        # looking at it, not by the structural check.
        cells_key="pe_imem_macro",
    ),
    dict(
        name="pe_eth_mac",
        source_file="pe_eth_mac.v",
        role="10BASE-T receive: SFD lock, byte assembly, FCS, store-and-forward",
        # Ties four blocks into one signal path: DRU -> manch -> CRC -> fbuf.
        # Instantiated in pe_soc as of 2026-09-23, with the frame window on the
        # SoC's IO space and firmware/eth_rx.pe as its first consumer.
        instantiated_in="pe_soc.v",
        tb="tb_pe_eth_mac.v",
    ),
    dict(
        name="pe_fbuf",
        source_file="pe_fbuf.v",
        role="frame buffer: 2 KB behind a byte interface, same macro as pe_imem",
        # Instantiated in pe_soc as of 2026-09-23: the receive chain's
        # store-and-forward port is its writer and BUFBYTE its reader.
        instantiated_in="pe_soc.v",
        tb="tb_pe_fbuf.v",
        # Same reason as pe_imem above: synth_area maps macro and flop builds
        # separately, so the label must name the configuration that ships. 48
        # cells is glue only -- the macro's area is in its LEF, not in gates.
        cells_key="pe_fbuf_macro",
    ),
    dict(
        name="pe_ctrl",
        source_file="pe_ctrl.v",
        role="passive SPI load path: host clocks words into imem",
        instantiated_in="tt_um_protocol_emulator.v",
        tb="tb_pe_ctrl.v",
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
        instantiated_in="pe_soc.v",
        tb="tb_pe_dru.v",
    ),
    dict(
        name="pe_crc",
        source_file="pe_crc.v",
        role="CRC/LFSR generator, 8/16/32-bit, catalogue-checked",
        instantiated_in="pe_soc.v",
        tb="tb_pe_crc.v",
    ),
    dict(
        name="pe_pinmux",
        source_file="pe_pinmux.v",
        role="per-pin direction, open-drain, read-back (the I2C gate)",
        # Was an orphan until 2026-09-23, when the matrix went inside the SoC
        # (decisions/adr-006-pin-matrix). Note this field is HAND-MAINTAINED and
        # the --check gate compares the page against this table, NOT against the
        # RTL -- so the table going stale is exactly the failure this field can
        # have. Verify with: grep -n "^  pe_pinmux #" rtl/*.v
        instantiated_in="pe_soc.v",
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
        source_file="pe_nrzi.v",
        role="NRZI encode/decode",
        instantiated_in="pe_codec_mux.v",
        tb="tb_pe_codec_mux.v",
    ),
    dict(
        name="pe_manch",
        source_file="pe_manch.v",
        role="Manchester encode/decode",
        instantiated_in="pe_codec_mux.v",
        tb="tb_pe_codec_mux.v",
    ),
    dict(
        name="pe_bitstuff",
        source_file="pe_bitstuff.v",
        role="bit stuffing (CAN/USB style)",
        instantiated_in="pe_codec_mux.v",
        tb="tb_pe_codec_mux.v",
    ),
]

# ---- planned, not built -------------------------------------------------------
PLANNED = [
    ("pe_serdes into the SoC", "the SERDES is routed and TB-proven but no SoC instance drives it"),
]
# Removed as BUILT: "pe_pinmux into the SoC" and "I2C 1 us tick divider"
# (2026-09-23, adr-006-pin-matrix), and "frame buffer (2nd SRAM)" -- that is
# rtl/pe_fbuf.v, the 1024x16 macro at 2 KB per ADR-003. A "planned" table is a
# claim about the design like any other, so it is maintained with the same
# intent as the orphan table: an entry that has shipped is a stale claim.
# divider" (plan step 5, decisions/adr-006-pin-matrix). A "planned" table is a
# claim about the design like any other, so it is maintained with the same
# intent as the orphan table -- an entry that has shipped is a stale claim, not
# a leftover.


def check_instantiated(blocks: list[dict], problems: list[str]) -> None:
    """Verify each block's instantiated_in claim against the RTL, so the
    diagram cannot claim a signal path that does not exist.

    BOTH DIRECTIONS, and the reverse one is the subtle half. Checking only that
    a CLAIMED parent names the block catches a path that was removed; it cannot
    catch a block that GREW a path and is still drawn as an orphan. That is what
    happened to `pe_pinmux` on 2026-09-23: it was instantiated inside
    `pe_soc`, the diagram still said "instantiated nowhere", and `--check`
    passed because it compared the page against this table rather than the table
    against the RTL. An orphan claim is as much a factual claim as a parent
    claim, so it is verified the same way.
    """
    # Every RTL file, for the reverse check.
    sources = {p.name: p.read_text(encoding="utf-8")
               for p in sorted(RTL.glob("*.v"))}

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
        # An instantiation is `<name> #(` (parameterised) or `<name> <inst> (`
        # (not). Match those, not a bare mention -- comments and this file's own
        # name appear all over the RTL and a bare `\\bname\\b` search is what
        # made the first version of this check unable to see a real instance.
        inst_re = re.compile(rf"^\s*{re.escape(b['name'])}\s*(#\s*\(|\w+\s*\()", re.M)
        parents = sorted(n for n, src in sources.items()
                         if n != b["source_file"] and inst_re.search(src))

        if b["instantiated_in"]:
            parent = RTL / b["instantiated_in"]
            if not parent.is_file():
                problems.append(f"{b['name']}: parent {b['instantiated_in']} missing")
                continue
            if b["instantiated_in"] not in parents:
                problems.append(
                    f"{b['name']}: diagram says it is instantiated in "
                    f"{b['instantiated_in']}, but that file has no instantiation "
                    f"of it (found: {parents or 'none'})"
                )
        else:
            if parents:
                problems.append(
                    f"{b['name']}: diagram says INSTANTIATED NOWHERE, but it is "
                    f"instantiated in {parents}"
                )


def check_tb(blocks: list[dict], problems: list[str]) -> None:
    """A block with no TB in run_all.sh is not verified. Flag it."""
    run_all = (REGRESS / "run_all.sh").read_text(encoding="utf-8")
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
        "> **Generated** by `tools/gen/block_diagram.py`. The built/orphan split is",
        "> checked against `rtl/` and `regress/run_all.sh` on every regression, so a block",
        "> cannot be listed as integrated unless something instantiates it.",
        "",
        "The project-wide plan and progress views are the editable PlantUML source",
        "files `diagrams/project-plan.puml` and `diagrams/project-progress.puml`.",
        "Update the progress view when implementation or verification status changes,",
        "and the plan view when an architecture or scope decision changes.",
        "",
        "## What is in the chip today",
        "",
        "Two implementation styles coexist on purpose. The firmware core",
        "bit-bangs pins; the SERDES is a word engine. [[plans/through-i2c]] explains",
        "why control flow is per-bit for I2C (ACK, arbitration, clock stretch) and",
        "per-word for UART/SPI/CAN/USB.",
        "",
        "### Built, verified — and wired to nothing",
        "",
        "These blocks pass their own testbenches but no SoC instance drives them:",
        "",
    ]

    for b in orphan:
        L.append(f"- `{b['name']}` — {b['role']}")

    L += [
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
        "There are two memories in the ADRs, and both are in the RTL now:",
        "",
        "- **Instruction memory — BUILT.** `pe_imem` instantiates the PDK's",
        "  `RM_IHPSG13_1P_1024x16_c2_bm_bist` by default (`FLOP=0`). This is the",
        "  SRAM that carries the design's critical path (`A_CLK` -> `A_DOUT`,",
        "  7.635 ns in context at the slow corner), and it is the reason the SoC",
        "  needed its own STA run at all — see [[reference/sram-budget]].",
        "- **Frame buffer — BUILT.** `pe_fbuf` holds 2 KB behind a byte interface",
        "  on the same `RM_IHPSG13_1P_1024x16_c2_bm_bist` part as the instruction",
        "  memory (ADR-003), and the 10BASE-T receive chain is its writer as of",
        "  2026-09-23. The `FLOP=1` path is the register-array fallback.",
        "",
        "The `FLOP=1` path in `pe_imem` synthesises a register array instead of the",
        "macro (60,806 cells vs 12). It exists for tests and area experiments and is",
        "mapped separately by `synth_area.sh`; it is **not** what the SoC uses.",
        "",
        "## Refreshing the cell counts",
        "",
        "Counts come from `regress/synth_area.sh` (mapped, typ corner). To refresh:",
        "",
        "```bash",
        "./regress/synth_area.sh | awk 'NF>=3 && $2 ~ /^[0-9]+$/ {print $1, $2}' \\",
        "  > wiki/reference/.block-diagram-cells",
        "python3 tools/gen/block_diagram.py",
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
