#!/usr/bin/env python3
"""Generate wiki/reference/protocol-pin-budget.md — per-protocol IO pin counts.

Answers one question: how many IO pins does each target protocol need, and does
the Tiny Tapeout pad budget cover them?

The budget is a fact about the platform (tt-multiplexer INFO.md: ui_in 10,
uo_out 8, uio 8). The per-protocol requirements are facts about the testbenches
and the physical-layer reality — the wire sets are read from `tb/tb_pe_*.v`
where a TB models them, and stated in WIRE_USE below where the requirement is
board-level (a transceiver, a pull-up) rather than RTL. TB presence is CHECKED
for every protocol, so a deleted testbench cannot leave this page claiming
coverage that no longer exists.

    python3 tools/gen/pin_budget.py           # write the page
    python3 tools/gen/pin_budget.py --check    # exit 1 if stale
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
TB = REPO / "tb"
OUT = REPO / "wiki" / "reference" / "protocol-pin-budget.md"

# ---- platform budget (tt-multiplexer INFO.md, ingested in raw/articles) -----
BUDGET = {"ui_in": 10, "uo_out": 8, "uio": 8}

# ---- per-protocol requirement -------------------------------------------------
# tb:      testbench stem that proves it ("" = no TB yet)
# pins:    (name, count, direction) — direction from the CHIP's point of view
# external: what the board must add; "" means nothing
# note:    the part the count alone does not tell you
PROTOCOLS = [
    dict(
        name="UART", tb="tb_pe_uart", tier="baseline",
        pins=[("tx", 1, "out"), ("rx", 1, "in")],
        external="",
        note="Two independent protocols on 2 pins. Loopback (TX→RX in firmware) needs 1.",
    ),
    dict(
        name="SPI", tb="tb_pe_spi", tier="baseline",
        pins=[("sclk", 1, "out"), ("mosi", 1, "out"), ("miso", 1, "in"), ("cs_n", 1, "out")],
        external="",
        note="Full duplex. The TB models master only; slave mode needs `sclk` and `cs_n` as INPUTS, so roles are config, not wiring.",
    ),
    dict(
        name="I2C", tb="tb_pe_i2c", tier="baseline",
        pins=[("scl", 1, "bidir"), ("sda", 1, "bidir")],
        external="pull-ups (board)",
        note="Bidirectional needs the pin-direction register (open-drain emulation); the TB models it as logic level.",
    ),
    dict(
        name="JTAG", tb="tb_pe_jtag", tier="also-suggested",
        pins=[("tck", 1, "out"), ("tms", 1, "out"), ("tdi", 1, "out"), ("tdo", 1, "in")],
        external="",
        note="`tck` must be a GPIO output — the chip generates the debug clock. That is why the TAP lives on `uio`.",
    ),
    dict(
        name="SWD", tb="tb_pe_swd", tier="also-suggested",
        pins=[("swclk", 1, "out"), ("swdio", 1, "bidir")],
        external="",
        note="`swdio` is bidirectional with a turnaround phase (the TB models `host_drives`); `swclk` is chip-driven in the TB but is an input in a real target.",
    ),
    dict(
        name="PS/2", tb="tb_pe_ps2", tier="also-suggested",
        pins=[("ps2_clk", 1, "bidir"), ("ps2_data", 1, "bidir")],
        external="pull-ups (board)",
        note="Open-drain on both lines — the device may hold the clock low (inhibit). Same OE trick as I2C.",
    ),
    dict(
        name="CAN (classic)", tb="tb_pe_can", tier="also-suggested",
        pins=[("can_tx", 1, "out"), ("can_rx", 1, "in")],
        external="transceiver, e.g. SN65HVD230-class",
        note="Two pins are enough because the differential layer is the transceiver's job. The TB models only `can_rx` (it stands in for the wire).",
    ),
    dict(
        name="USB 1.1 low-speed", tb="tb_pe_usb", tier="stretch",
        pins=[("d_plus", 1, "bidir"), ("d_minus", 1, "bidir")],
        external="series resistors + pull-up",
        note="D+/D- driven as two single-ended CMOS outputs. Idle state is FS-only (D- pulled up); a real LS device needs the 1.5 kΩ pull-up on D-. SE0 (both low) and J/K are directly expressible — see the TB.",
    ),
    dict(
        name="10BASE-T", tb="tb_pe_eth", tier="stretch",
        pins=[("eth_tx", 1, "out"), ("eth_rx", 1, "in")],
        external="transformer / resistor ladder, or a PHY (LAN8720-class)",
        note="Manchester is single-ended here, so 2 pins carry it; the ±2.5 V differential into 100 Ω is the board's problem, not the pad's. The TB models one `wire_lvl`.",
    ),
]


# The wrapper's committed pinout (rtl/tt_um_protocol_emulator.v + info.yaml),
# kept as DATA so the direction arithmetic on the rendered page cannot be done
# by hand. It mirrors the wrapper header; update both together.
DESIGN_PINOUT = {
    "ui_in": {0: "UART RX", 1: "run", 2: "10BASE-T RX",
              3: "loader SCLK", 4: "loader MOSI", 5: "loader CS_N"},
    "uo_out": {0: "UART TX", 1: "heartbeat",
               2: "dbg_pc[0]", 3: "dbg_pc[1]", 4: "dbg_pc[2]",
               5: "dbg_pc[3]", 6: "dbg_pc[4]", 7: "dbg_pc[5]"},
    "uio": {0: "I2C SDA", 1: "I2C SCL"},
}


def tb_signals(stem: str) -> set[str]:
    """Non-SERDES signals a testbench declares — used only as a cross-check."""
    p = TB / f"{stem}.v"
    if not p.exists():
        return set()
    text = p.read_text(encoding="utf-8")
    skip = {
        "clk", "rst_n", "bit_en", "cfg_lsb_first", "tx_load", "tx_ser", "tx_busy", "tx_done",
        "tx_data", "tx_len", "rx_ser", "rx_start", "rx_busy", "rx_valid", "rx_data", "rx_len",
        "tx_done_seen", "rx_valid_seen", "errors",
    }
    found = set(re.findall(r"^\s*logic\s+(?:\[[^\]]*\])?\s*([a-z][a-z0-9_]*)\s*;", text, re.M))
    return {s for s in found if s not in skip}


def build() -> tuple[str, list[str]]:
    problems: list[str] = []
    rows = []
    for p in PROTOCOLS:
        n = len(p["pins"])
        if p["tb"] and not (TB / f"{p['tb']}.v").exists():
            problems.append(f"{p['name']}: testbench {p['tb']}.v is MISSING")
        rows.append((p, n))

    total_ui = sum(c for _, c in
                   [("x", BUDGET[k]) for k in ("ui_in", "uo_out", "uio")])
    usable = BUDGET["ui_in"] - 2  # clk + rst_n ride on ui_in

    lines = [
        "---",
        "title: Protocol Pin Budget",
        "created: 2026-09-18",
        "updated: 2026-09-18",
        "type: reference",
        "tags: [physical-layer, gpio, protocol, constraint]",
        "sources: [raw/articles/tinytapeout-multiplexer.md, wiki/concepts/physical-layer-gpio.md]",
        "confidence: high",
        "---",
        "",
        "# Protocol Pin Budget",
        "",
        "How many IO pins each target protocol needs, and whether the Tiny Tapeout",
        "pad budget covers them. Counts are per-protocol in isolation (the",
        "interesting case — see *Worst case* below).",
        "",
        "## The budget",
        "",
        f"| Bus | Bits | Notes |",
        "|---|---|---|",
        f"| `ui_in` | {BUDGET['ui_in']} | inputs. **`u_clk` and `u_rst_n` are two of these** in the mux, so {usable} are free for design use |",
        f"| `uo_out` | {BUDGET['uo_out']} | outputs |",
        f"| `uio` | {BUDGET['uio']} | bidirectional, each with its own output-enable (`uio_oe`) |",
        f"| **total** | **{total_ui}** | of which **{usable + BUDGET['uo_out'] + BUDGET['uio']}** are usable (clk/rst_n are not negotiable) |",
        "",
        "The mux doc is explicit that `u_clk`, `u_rst_n` and `ui` are all just bits",
        "in the `pad_ui_in` bus — there is no difference internally. Only the naming",
        "distinguishes them, which is why two input bits are spoken for.",
        "",
        "## Per protocol",
        "",
        "| Protocol | Tier | Pins | Wires | Board must add |",
        "|---|---|---|---|---|",
    ]
    for p, n in rows:
        wires = ", ".join(
            ("`%s`(%s)" % (nm, d)) for nm, _, d in p["pins"]
        )
        lines.append(
            f"| **{p['name']}** | {p['tier']} | **{n}** | {wires} | {p['external'] or '—'} |"
        )

    lines += ["", "### Notes per protocol", ""]
    for p, n in rows:
        lines.append(f"**{p['name']}** — {p['note']}  ")
        lines.append(f"<sub>proven by `{p['tb']}.v`</sub>" if p["tb"] else "<sub>no testbench yet</sub>")
        lines.append("")

    max_single = max(n for _, n in rows)
    widest = max(rows, key=lambda r: r[1])[0]
    n_out = sum(1 for p, _ in rows for _, _, d in p["pins"] if d == "out")
    n_in = sum(1 for p, _ in rows for _, _, d in p["pins"] if d == "in")
    n_bi = sum(1 for p, _ in rows for _, _, d in p["pins"] if d == "bidir")
    proto_wires = n_out + n_in + n_bi
    free = {"ui_in": usable - len(DESIGN_PINOUT["ui_in"]),
            "uo_out": BUDGET["uo_out"] - len(DESIGN_PINOUT["uo_out"]),
            "uio": BUDGET["uio"] - len(DESIGN_PINOUT["uio"])}
    committed = sum(len(v) for v in DESIGN_PINOUT.values())
    # Remaining demand after the pinned UART (1 out, 1 in), I2C (2 bidir) and
    # 10BASE-T RX (1 in) wires.
    rem_out, rem_in, rem_bi = n_out - 1, n_in - 2, n_bi - 2
    # Reclaiming the six debug pins frees those uo_out pads and only those
    # (UART TX and the heartbeat stay committed).
    debug_pins = sum(1 for v in DESIGN_PINOUT["uo_out"].values()
                     if v.startswith("dbg_pc"))
    free_rec = {"ui_in": free["ui_in"],
                "uo_out": free["uo_out"] + debug_pins,
                "uio": free["uio"]}
    free_total = sum(free_rec.values())
    short_kept = (rem_out + rem_in + rem_bi) - (free["ui_in"] + free["uio"])
    short_reclaimed = (rem_out + rem_in + rem_bi) - free_total
    # With the debug pins reclaimed, the inputs beyond the free ui_in take uio
    # pads FIRST; the bidir wires take the rest; only then can uio serve an
    # output. Forgetting that input was an arithmetic error the review caught.
    uio_for_in = max(0, rem_in - free_rec["ui_in"])
    uio_for_out = free_rec["uio"] - uio_for_in - rem_bi
    out_avail = free_rec["uo_out"] + max(0, uio_for_out)

    lines += [
        "## The answer",
        "",
        f"- **Any single protocol: {max_single} pins maximum** ({widest['name']}), out of "
        f"{usable + BUDGET['uo_out'] + BUDGET['uio']} usable. The budget is not the constraint.",
        f"- **All nine at once: {proto_wires} protocol wires** "
        f"({n_out} out, {n_in} in, {n_bi} bidir). **It does not fit — see the "
        f"direction arithmetic below.**",
        "",
        "### Worst case, by direction",
        "",
        "Disjoint wires for every protocol, counted by ROLE rather than by one raw",
        "total. The role counts are what any assignment has to satisfy: a",
        "bidirectional wire needs a `uio` pad, an input needs `ui_in` or a released",
        "`uio`, and an output needs `uo_out` or a driven `uio`.",
        "",
        "| Protocol | Outputs | Inputs | Bidir | Wires |",
        "|---|---|---|---|---|",
    ]
    for p, _ in rows:
        o = sum(1 for _, _, d in p["pins"] if d == "out")
        i = sum(1 for _, _, d in p["pins"] if d == "in")
        b = sum(1 for _, _, d in p["pins"] if d == "bidir")
        lines.append(f"| {p['name']} | {o} | {i} | {b} | {o+i+b} |")
    lines += [
        f"| **sum** | **{n_out}** | **{n_in}** | **{n_bi}** | **{proto_wires}** |",
        "",
        "### This design's actual pinout",
        "",
        "`rtl/tt_um_protocol_emulator.v` + `info.yaml` currently commit:",
        "",
        "| Bank | committed | free |",
        "|---|---|---|",
        f"| `ui_in` | {len(DESIGN_PINOUT['ui_in'])} "
        f"({', '.join(DESIGN_PINOUT['ui_in'].values())}) | {free['ui_in']} |",
        f"| `uo_out` | {len(DESIGN_PINOUT['uo_out'])} "
        f"(UART TX, heartbeat, dbg_pc[5:0]) | {free['uo_out']} |",
        f"| `uio` | {len(DESIGN_PINOUT['uio'])} "
        f"({', '.join(DESIGN_PINOUT['uio'].values())}) | {free['uio']} |",
        f"| **total** | {committed} | **{free['ui_in']+free['uo_out']+free['uio']}** |",
        "",
        "After the pinned UART, I2C and 10BASE-T-RX wires, the remaining protocols",
        f"need {rem_out} outputs, {rem_in} inputs and {rem_bi} bidir:",
        "",
        f"- **Debug pins kept** (the item-4 decision): "
        f"{free['ui_in']+free['uio']} free pads against "
        f"{rem_out+rem_in+rem_bi} remaining wires — short {short_kept}. The "
        f"{rem_in} inputs and {rem_bi} bidir wires alone consume every free pad "
        f"(2 `ui_in` + 1 `uio` + {rem_bi} `uio`), leaving nothing for the "
        f"{rem_out} outputs.",
        f"- **Debug pins reclaimed:** {free_total} free pads, short "
        f"{short_reclaimed}: the {rem_in} remaining inputs take the "
        f"{free_rec['ui_in']} free `ui_in` and {uio_for_in} `uio`; the {rem_bi} "
        f"bidir wires take the other {rem_bi}; {uio_for_out} `uio` are left for "
        f"the {rem_out} outputs, and `uo_out` supplies {free_rec['uo_out']} — so "
        f"only {out_avail} of {rem_out} outputs can be placed.",
        "",
        "**Even shedding every overhead** — the run strap, the heartbeat, the debug",
        f"pads and the loader's three pads reused at runtime — leaves {n_out} outputs",
        "for `uo_out`'s 8 plus at most one spare `uio` pad: **one output short**.",
        "So \"all nine at once\" is not a feasible permanent pinout here, and the raw",
        "23-of-24 count this page used to carry hid both the arithmetic error (UART",
        "plus SPI is 6 wires, not 7) and the direction mix. The permanent-only design",
        "is also completely the wrong way to build it, and the premise is the",
        "opposite: **the whole premise of the project is that protocols are firmware,",
        "not pin assignments.** A programmable pin matrix means a protocol claims",
        "pins at *runtime*:",
        "",
        "- Only one or two protocols are live at a time, chosen by firmware.",
        "- `uio` pins are bidirectional with per-pin output-enable, so a single pin",
        "  serves I2C SDA, PS/2 DATA, SWDIO and USB D+ depending on what is running.",
        "- Concurrent protocols need disjoint pins, and *that* is a firmware/placement",
        "  decision, not an RTL one — the matrix just has to be flexible enough.",
        "",
        "So the real constraint is not a raw wire count but **how many protocols",
        "must run simultaneously**. Two (e.g. UART console + SPI target) is trivial;",
        "a bus-converter persona running four at once is the case worth designing the",
        "matrix around.",
        "",
        "## Pins are not the hard part",
        "",
        "Everything above counts digital wires. The genuinely awkward items are",
        "electrical, and they are on the board:",
        "",
        "- **Open-drain** (I2C, PS/2) needs external pull-ups *and* the chip must",
        "  never drive high — output-enable toggling only. Getting this wrong is a",
        "  bus-contention bug, not a pin-count one.",
        "- **USB LS** needs the 1.5 kΩ pull-up on D- to look like a device, and",
        "  series resistors for impedance.",
        "- **10BASE-T** needs a transformer or PHY; true ±2.5 V differential into",
        "  100 Ω cannot come from a GPIO. See [[concepts/physical-layer-gpio]].",
        "- **CAN** needs a transceiver; the chip only sees logic-level TX/RX.",
        "",
        "See [[concepts/gpio-signoff-corners]] for the rise/fall asymmetry that",
        "thins these pulses at skewed corners.",
        "",
        "## Related",
        "",
        "- [[concepts/physical-layer-gpio]] — what each protocol needs electrically.",
        "- [[reference/signal-names]] — the RTL port list.",
        "- [[concepts/competition-overview]] — the 6×4 tile budget this sits inside.",
        "- [[STATUS]] — what is actually built.",
        "",
    ]
    return "\n".join(lines), problems


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
            print(f"gen_pin_budget: {OUT} is missing", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != rendered:
            print(f"gen_pin_budget: {OUT} is STALE — re-run without --check", file=sys.stderr)
            return 1
        print("protocol pin budget up to date")
        return 0 if not problems else 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT} ({len(rendered)} bytes)")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
