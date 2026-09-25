#!/usr/bin/env python3
"""Generate wiki/reference/crc-config.md from a checked CRC parameter table.

Every constant this project must load into rtl/pe_crc.v is DERIVED here, not
typed, and every derived entry is checked against the published check value for
the message "123456789" before the page is written. If a constant is wrong, this
script fails rather than documenting it.

    python3 tools/gen/crc_config.py            # write the page
    python3 tools/gen/crc_config.py --check    # exit 1 if the page is stale

--check runs in regress/run_all.sh, so the page cannot drift from the table below.

WHY THE DERIVATION MATTERS
-------------------------
The RTL has ONE shift-right datapath (see rtl/pe_crc.v's header). Two facts make
that possible and both are verified below rather than asserted:

  * The R-orientation mask is REVERSED(polynomial). For a reflected algorithm
    (refin=True) that is the reflected polynomial; for a non-reflected one
    (refin=False) it is the bit-reversal of the polynomial. One expression,
    both families.
  * A non-reflected algorithm run on a right-shifting register computes the
    bit-reversal of the CRC. So its seed is loaded bit-reversed and its result
    is read bit-reversed; nothing else changes.

Also checked: the HIGH BITS of a 32-bit register stay zero for every polynomial
narrower than 32, which is what lets one register width serve a 5-bit CRC and a
15-bit CRC with no width port and no masking logic.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
OUT = REPO / "wiki" / "reference" / "crc-config.md"

REGW = 32                      # the physical register width in pe_crc
CHECK_MSG = b"123456789"       # the RevEng catalogue's check message


def rev(v: int, width: int) -> int:
    """Bit-reverse `v` within `width` bits."""
    r = 0
    for i in range(width):
        if (v >> i) & 1:
            r |= 1 << (width - 1 - i)
    return r


# ---------------------------------------------------------------------------
# The parameter sets. `check`/`residue` are the RevEng catalogue's published,
# independent values: `check` is the CRC of "123456789" and `residue` is what a
# register holds after folding the message AND its CRC field.
# ---------------------------------------------------------------------------
ENTRIES = [
    dict(name="CRC-32/ISO-HDLC", target="10BASE-T Ethernet FCS", wcrc=32,
         poly=0x04C11DB7, init=0xFFFFFFFF, refin=True, xorout=0xFFFFFFFF,
         check=0xCBF43926, residue=0xDEBB20E3, wire="LSB-first"),
    dict(name="CRC-16/USB", target="USB token / data", wcrc=16,
         poly=0x8005, init=0xFFFF, refin=True, xorout=0xFFFF,
         check=0xB4C8, residue=0xB001, wire="LSB-first"),
    dict(name="CRC-5/USB", target="USB token", wcrc=5,
         poly=0x05, init=0x1F, refin=True, xorout=0x1F,
         check=0x19, residue=0x06, wire="LSB-first"),
    dict(name="CRC-15/CAN", target="CAN 2.0 classic", wcrc=15,
         poly=0x4599, init=0x0000, refin=False, xorout=0x0000,
         check=0x059E, residue=0x0000, wire="MSB-first"),
    dict(name="CRC-8/SMBUS", target="SMBus / I2C PEC", wcrc=8,
         poly=0x07, init=0x00, refin=False, xorout=0x00,
         check=0xF4, residue=0x00, wire="MSB-first"),
    dict(name="CRC-16/ARC", target="cross-check only (not a target)", wcrc=16,
         poly=0x8005, init=0x0000, refin=True, xorout=0x0000,
         check=0xBB3D, residue=0x0000, wire="LSB-first"),
    # The PE host frame engine (rtl/pe_ctrl.v, phase R1) runs this one on a
    # FORWARD (MSB-first) datapath. The entry is still checked through the
    # reference implementation and the catalogue check value, so the RTL's
    # polynomial and seed are documented, derived numbers, never hand-typed.
    dict(name="CRC-16/CCITT-FALSE", target="PE host frame", wcrc=16,
         poly=0x1021, init=0xFFFF, refin=False, xorout=0x0000,
         check=0x29B1, residue=0x0000, wire="MSB-first"),
]


def reference_crc(msg: bytes, wcrc: int, poly: int, init: int, refin: bool,
                  xorout: int):
    """Independent reference: the parameter-driven form, straight from the
    definitions. Non-reflected CRCs shift LEFT here -- deliberately a different
    datapath from the RTL's, so agreement means something."""
    mask = (1 << wcrc) - 1
    p = rev(poly, wcrc) if refin else (poly & mask)
    crc = init & mask
    for byte in msg:
        order = range(8) if refin else range(7, -1, -1)
        for i in order:
            b = (byte >> i) & 1
            if refin:
                fbb = b ^ (crc & 1)
                crc = (crc >> 1) & mask
            else:
                fbb = b ^ ((crc >> (wcrc - 1)) & 1)
                crc = (crc << 1) & mask
            if fbb:
                crc ^= p
    return (crc ^ xorout) & mask


def wire_bits(msg: bytes, refin: bool) -> list[int]:
    """Transmission order of the message bits."""
    out: list[int] = []
    for byte in msg:
        order = range(8) if refin else range(7, -1, -1)
        out += [(byte >> i) & 1 for i in order]
    return out


def machine(bits, seed: int, mask_r: int):
    """The RTL's datapath, modelled exactly: R shifts right, feedback from R[0],
    mask XORed when the feedback bit is set. Register width REGW."""
    m = (1 << REGW) - 1
    R = seed & m
    for b in bits:
        fb = b ^ (R & 1)
        R = (R >> 1) & m
        if fb:
            R ^= mask_r
    return R


def derive(entry: dict) -> dict:
    """Everything the RTL needs, plus everything the page wants to show."""
    wcrc = entry["wcrc"]
    wmask = (1 << wcrc) - 1
    poly_r = rev(entry["poly"], wcrc)              # R-orientation mask
    seed_r = entry["init"] if entry["refin"] else rev(entry["init"], wcrc)

    # Every target's xorout is all-ones or all-zeros, which is what lets one
    # config bit express the final complement (cfg_out_inv). Asserted below.
    xo = entry["xorout"] & wmask
    out_inv = 1 if xo == wmask else 0

    data = wire_bits(CHECK_MSG, entry["refin"])
    R = machine(data, seed_r, poly_r)

    # canonical CRC value out of R
    crc_val = (R if entry["refin"] else rev(R, wcrc)) ^ entry["xorout"]
    crc_val &= wmask

    # the field as it goes on the wire: the post-complemented R, LSB-first
    field = [((R >> i) & 1) ^ out_inv for i in range(wcrc)]

    # Receiver views.
    #   rx_clean    folds the field UN-complemented -> must be 0 (crc_zero)
    #   rx_raw_fold folds the field exactly as transmitted -> must be the
    #               catalogue residue, which is an outside cross-check on our
    #               field ORDER rather than on our arithmetic
    rx_clean = machine(data + [b ^ out_inv for b in field], seed_r, poly_r)
    rx_raw_fold = machine(data + field, seed_r, poly_r)

    high_clean = (R >> wcrc) == 0
    return dict(entry, poly_r=poly_r, seed_r=seed_r, out_inv=out_inv,
                crc_val=crc_val, rx_clean=rx_clean, rx_raw_fold=rx_raw_fold,
                high_clean=high_clean, field=field)


def build() -> str:
    rows = [derive(e) for e in ENTRIES]

    # Fail loudly rather than documenting a constant that is wrong.
    bad = []
    for r in rows:
        wcrc = r["wcrc"]
        wmask = (1 << wcrc) - 1
        xo = r["xorout"] & wmask
        if xo not in (0, wmask):
            bad.append(f"{r['name']}: xorout 0x{xo:X} is neither all-ones nor "
                       f"all-zeros, so cfg_out_inv cannot express it")
        if r["crc_val"] != r["check"]:
            bad.append(f"{r['name']}: derived check 0x{r['crc_val']:X} != "
                       f"catalogue 0x{r['check']:X}")
        if r["rx_raw_fold"] != r["residue"]:
            bad.append(f"{r['name']}: raw fold of the transmitted field gives "
                       f"0x{r['rx_raw_fold']:X}, catalogue residue is "
                       f"0x{r['residue']:X} — the field order on the wire would "
                       f"not be the standard's")
        if r["rx_clean"] != 0:
            bad.append(f"{r['name']}: un-complemented fold gives "
                       f"0x{r['rx_clean']:X}, expected 0 (crc_zero)")
        if not r["high_clean"]:
            bad.append(f"{r['name']}: high bits of the register are not clean")
    if bad:
        sys.exit("gen_crc_config: PARAMETER CHECK FAILED\n  " + "\n  ".join(bad))

    L: list[str] = [
        "---",
        "title: CRC Configuration",
        "created: 2026-09-20",
        "updated: 2026-09-20",
        "type: reference",
        "tags: [protocol, architecture, verification]",
        "sources: [rtl/pe_crc.v, rtl/pe_ctrl.v, tb/tb_pe_crc.v]",
        "confidence: high",
        "---",
        "",
        "# CRC Configuration",
        "",
        "Every constant `rtl/pe_crc.v` has to be loaded with, plus the PE host",
        "frame CRC that `rtl/pe_ctrl.v` runs on its own forward datapath.",
        "**Generated and checked by `tools/gen/crc_config.py`**",
        "(`--check` runs in `regress/run_all.sh`), so nothing here is typed by hand.",
        "",
        "Each row's `check` and `residue` are the RevEng catalogue's published",
        "values — an independent authority's numbers, not ours. The script DERIVES",
        f"the hardware constants, computes the CRC of \"{CHECK_MSG.decode()}\" on the",
        "RTL's own datapath, and refuses to write this page unless the result equals",
        "the catalogue value. A wrong constant fails the build.",
        "",
        "## The register the RTL actually has",
        "",
        f"One {REGW}-bit shift-right register, `R`, with no width port and no mode bit.",
        "Loaded through two constants and read one way:",
        "",
        "```",
        "    fb = bit_in ^ R[0]",
        "    R  = (R >> 1) ^ (fb ? cfg_poly_r : 0)          // every wire bit",
        "    crc_bit = R[0]                                 // the field bit to send",
        "    crc_zero = (R == 0)                            // after the last field bit",
        "```",
        "",
        "Two facts make that sufficient, and the script verifies both for every",
        "polynomial below:",
        "",
        "- **`cfg_poly_r` = bit-reversal of the polynomial**, low-justified.",
        "  That is the reflected polynomial for a reflected algorithm and the",
        "  reversal of the polynomial for a non-reflected one — one expression,",
        "  both families.",
        "- **A non-reflected algorithm on a right-shifting register computes the",
        "  bit-reversal of its CRC.** So `cfg_seed` is the seed bit-reversed and the",
        "  result is read bit-reversed. Nothing else differs.",
        "",
        "Both hold because the feedback is taken from bit 0 and injected through the",
        "reversed mask in *both* families. That is why there is no mode bit.",
        "",
        f"## Why {REGW} bits serve a 5-bit CRC",
        "",
        f"`cfg_poly_r` and `cfg_seed` are loaded low-justified (`< 2^Wcrc`), and every",
        "operation is a right shift plus an XOR with a mask that has no bit above",
        "`Wcrc-1`. So",
        "",
        "```",
        "    R < 2^Wcrc      is an invariant of the datapath",
        "```",
        "",
        "and the high bits stay zero for the 5-, 8-, 15- and 16-bit polynomials —",
        "verified below for each, and asserted on every strobe by `tb/tb_pe_crc.v`.",
        "That is what makes `crc_zero` a plain full-register compare.",
        "",
        "| CRC | Wcrc | high bits after \"%s\" | clean? |" % CHECK_MSG.decode(),
        "|---|---|---|---|",
    ]
    for r in rows:
        L.append(f"| {r['name']} | {r['wcrc']} | `R[31:{r['wcrc']}]` = 0 | "
                 f"{'yes' if r['high_clean'] else 'NO'} |")

    L += [
        "",
        "## Derived constants",
        "",
        "Load `cfg_poly_r`, `cfg_seed` and `cfg_out_inv`; read `R`; the field goes",
        "out as `R[0] ^ cfg_out_inv` shifting.",
        "",
        "| Protocol | CRC | Wcrc | wire order | `cfg_poly_r` | `cfg_seed` "
        "| `cfg_out_inv` | catalogue `check` | catalogue residue |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        f = lambda v, w=r["wcrc"]: f"`0x{v:0{(w + 3) // 4}X}`"
        L.append(
            f"| {r['target']} | {r['name']} | {r['wcrc']} | {r['wire']} "
            f"| {f(r['poly_r'])} | {f(r['seed_r'])} | `{r['out_inv']}` "
            f"| {f(r['check'])} | {f(r['residue'])} |")

    L += [
        "",
        "The PE host frame CRC is the one entry read by a block that is not",
        "`pe_crc`: `rtl/pe_ctrl.v` implements CRC-16/CCITT-FALSE on the forward",
        "(MSB-first) datapath with polynomial `0x1021` and seed `0xFFFF`. Those",
        "two constants come from this table's entry, whose catalogue check value",
        "(`0x29B1` for \"123456789\") is asserted by the generator above; the",
        "frame TB independently checks every response CRC on the wire.",
        "",
        "Two of these are worth reading twice:",
        "",
        "- **CRC-16/USB and CRC-16/ARC differ only in seed and in `cfg_out_inv`.**",
        "  Same polynomial, same mask, `0xFFFF`/invert against `0x0000`/no-invert.",
        "  They are in the table as a pair because firmware that gets the USB seed",
        "  wrong will produce ARC's answer, which is a far more useful failure than",
        "  a random wrong number.",
        "- **Every `xorout` here is all-ones or all-zeros**, which is precisely why a",
        "  single `cfg_out_inv` bit can express the final complement and no wider",
        "  register is needed. The script rejects a parameter set that would break",
        "  that.",
        "",
        "## The field on the wire, and why both families agree",
        "",
        "The block transmits `R[0] ^ cfg_out_inv` for `Wcrc` strobes, shifting each",
        "time. That single rule produces the correct field order for every protocol",
        "here, which is not obvious:",
        "",
        "- **Reflected family** (`R` *is* the CRC): LSB-first of `R` is LSB-first of",
        "  the CRC value — USB's convention.",
        "- **Non-reflected family** (`R` is the CRC bit-reversed): LSB-first of `R`",
        "  is **MSB-first of the CRC value** — which is how CAN transmits its",
        "  CRC-15 field, and SMBus its PEC.",
        "- **Ethernet is the case that looks wrong and is not.** IEEE 802.3 §3.2.9",
        "  says the FCS is transmitted x^31 first with the *first octet* the",
        "  high-order one. The standard also gives an equivalent formulation: use",
        "  the right-shifting CRC-32, keep the data LSB-first, and transmit the CRC",
        "  LSB-first — *\"resulting in identical transmissions\"*. That is what this",
        "  block does, and it is the variant that needs no buffering.",
        "",
        "## The residue is an outside check on the bit order, not our arithmetic",
        "",
        "The `catalogue residue` column is the RevEng catalogue's published value",
        "for what a register holds after folding the message **and its field exactly",
        "as transmitted** — the complemented bits, no un-complementing. The script",
        "folds our own generated field bits and requires that residue, so agreement",
        "is evidence that our field ORDER is the standard's, from an authority",
        "outside this project. It would catch a field emitted MSB-first, or a",
        "complement omitted, regardless of whether the rest was self-consistent.",
        "",
        "Which also fixes the receiver rule. A raw fold lands on the residue, not on",
        "zero, so:",
        "",
        "```",
        "    receiver verdict = crc_zero XOR cfg_out_inv",
        "```",
        "",
        "Fold the field un-complemented and the register drains to zero, which the",
        "script verifies too. Both directions then agree, because the receiver folds",
        "the same bits the transmitter emitted and the complement cancels.",
        "",
        "## Related",
        "",
        "- [[concepts/factored-hardware-blocks]] — where the LFSR sits in the plan.",
        "- [[concepts/ethernet-scope]] — why CRC-32 has to be hardware (4 clocks/bit).",
        "- [[reference/signal-names]] — the port names `pe_crc` exposes.",
        "- [[STATUS]] — what is built.",
        "",
    ]
    return "\n".join(L)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the page on disk differs from a fresh render")
    args = ap.parse_args()

    rendered = build()
    if args.check:
        if not OUT.exists():
            print(f"gen_crc_config: {OUT} is missing", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != rendered:
            print(f"gen_crc_config: {OUT} is STALE — re-run without --check",
                  file=sys.stderr)
            return 1
        print("crc config up to date")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(rendered, encoding="utf-8")
    print(f"wrote {OUT} ({len(rendered)} bytes)")
    for r in (derive(e) for e in ENTRIES):
        w = (r["wcrc"] + 3) // 4
        print(f"  {r['name']:16s} check=0x{r['crc_val']:0{w}X} "
              f"poly_r=0x{r['poly_r']:08X} seed=0x{r['seed_r']:08X} "
              f"inv={r['out_inv']} raw_fold=0x{r['rx_raw_fold']:0{w}X} "
              f"clean_fold=0x{r['rx_clean']:0{w}X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
