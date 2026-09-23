---
title: CRC Configuration
created: 2026-09-20
updated: 2026-09-20
type: reference
tags: [protocol, architecture, verification]
sources: [rtl/pe_crc.v, tb/tb_pe_crc.v]
confidence: high
---

# CRC Configuration

Every constant `rtl/pe_crc.v` has to be loaded with, for every CRC this
project targets. **Generated and checked by `tools/gen/crc_config.py`**
(`--check` runs in `regress/run_all.sh`), so nothing here is typed by hand.

Each row's `check` and `residue` are the RevEng catalogue's published
values — an independent authority's numbers, not ours. The script DERIVES
the hardware constants, computes the CRC of "123456789" on the
RTL's own datapath, and refuses to write this page unless the result equals
the catalogue value. A wrong constant fails the build.

## The register the RTL actually has

One 32-bit shift-right register, `R`, with no width port and no mode bit.
Loaded through two constants and read one way:

```
    fb = bit_in ^ R[0]
    R  = (R >> 1) ^ (fb ? cfg_poly_r : 0)          // every wire bit
    crc_bit = R[0]                                 // the field bit to send
    crc_zero = (R == 0)                            // after the last field bit
```

Two facts make that sufficient, and the script verifies both for every
polynomial below:

- **`cfg_poly_r` = bit-reversal of the polynomial**, low-justified.
  That is the reflected polynomial for a reflected algorithm and the
  reversal of the polynomial for a non-reflected one — one expression,
  both families.
- **A non-reflected algorithm on a right-shifting register computes the
  bit-reversal of its CRC.** So `cfg_seed` is the seed bit-reversed and the
  result is read bit-reversed. Nothing else differs.

Both hold because the feedback is taken from bit 0 and injected through the
reversed mask in *both* families. That is why there is no mode bit.

## Why 32 bits serve a 5-bit CRC

`cfg_poly_r` and `cfg_seed` are loaded low-justified (`< 2^Wcrc`), and every
operation is a right shift plus an XOR with a mask that has no bit above
`Wcrc-1`. So

```
    R < 2^Wcrc      is an invariant of the datapath
```

and the high bits stay zero for the 5-, 8-, 15- and 16-bit polynomials —
verified below for each, and asserted on every strobe by `tb/tb_pe_crc.v`.
That is what makes `crc_zero` a plain full-register compare.

| CRC | Wcrc | high bits after "123456789" | clean? |
|---|---|---|---|
| CRC-32/ISO-HDLC | 32 | `R[31:32]` = 0 | yes |
| CRC-16/USB | 16 | `R[31:16]` = 0 | yes |
| CRC-5/USB | 5 | `R[31:5]` = 0 | yes |
| CRC-15/CAN | 15 | `R[31:15]` = 0 | yes |
| CRC-8/SMBUS | 8 | `R[31:8]` = 0 | yes |
| CRC-16/ARC | 16 | `R[31:16]` = 0 | yes |

## Derived constants

Load `cfg_poly_r`, `cfg_seed` and `cfg_out_inv`; read `R`; the field goes
out as `R[0] ^ cfg_out_inv` shifting.

| Protocol | CRC | Wcrc | wire order | `cfg_poly_r` | `cfg_seed` | `cfg_out_inv` | catalogue `check` | catalogue residue |
|---|---|---|---|---|---|---|---|---|
| 10BASE-T Ethernet FCS | CRC-32/ISO-HDLC | 32 | LSB-first | `0xEDB88320` | `0xFFFFFFFF` | `1` | `0xCBF43926` | `0xDEBB20E3` |
| USB token / data | CRC-16/USB | 16 | LSB-first | `0xA001` | `0xFFFF` | `1` | `0xB4C8` | `0xB001` |
| USB token | CRC-5/USB | 5 | LSB-first | `0x14` | `0x1F` | `1` | `0x19` | `0x06` |
| CAN 2.0 classic | CRC-15/CAN | 15 | MSB-first | `0x4CD1` | `0x0000` | `0` | `0x059E` | `0x0000` |
| SMBus / I2C PEC | CRC-8/SMBUS | 8 | MSB-first | `0xE0` | `0x00` | `0` | `0xF4` | `0x00` |
| cross-check only (not a target) | CRC-16/ARC | 16 | LSB-first | `0xA001` | `0x0000` | `0` | `0xBB3D` | `0x0000` |

Two of these are worth reading twice:

- **CRC-16/USB and CRC-16/ARC differ only in seed and in `cfg_out_inv`.**
  Same polynomial, same mask, `0xFFFF`/invert against `0x0000`/no-invert.
  They are in the table as a pair because firmware that gets the USB seed
  wrong will produce ARC's answer, which is a far more useful failure than
  a random wrong number.
- **Every `xorout` here is all-ones or all-zeros**, which is precisely why a
  single `cfg_out_inv` bit can express the final complement and no wider
  register is needed. The script rejects a parameter set that would break
  that.

## The field on the wire, and why both families agree

The block transmits `R[0] ^ cfg_out_inv` for `Wcrc` strobes, shifting each
time. That single rule produces the correct field order for every protocol
here, which is not obvious:

- **Reflected family** (`R` *is* the CRC): LSB-first of `R` is LSB-first of
  the CRC value — USB's convention.
- **Non-reflected family** (`R` is the CRC bit-reversed): LSB-first of `R`
  is **MSB-first of the CRC value** — which is how CAN transmits its
  CRC-15 field, and SMBus its PEC.
- **Ethernet is the case that looks wrong and is not.** IEEE 802.3 §3.2.9
  says the FCS is transmitted x^31 first with the *first octet* the
  high-order one. The standard also gives an equivalent formulation: use
  the right-shifting CRC-32, keep the data LSB-first, and transmit the CRC
  LSB-first — *"resulting in identical transmissions"*. That is what this
  block does, and it is the variant that needs no buffering.

## The residue is an outside check on the bit order, not our arithmetic

The `catalogue residue` column is the RevEng catalogue's published value
for what a register holds after folding the message **and its field exactly
as transmitted** — the complemented bits, no un-complementing. The script
folds our own generated field bits and requires that residue, so agreement
is evidence that our field ORDER is the standard's, from an authority
outside this project. It would catch a field emitted MSB-first, or a
complement omitted, regardless of whether the rest was self-consistent.

Which also fixes the receiver rule. A raw fold lands on the residue, not on
zero, so:

```
    receiver verdict = crc_zero XOR cfg_out_inv
```

Fold the field un-complemented and the register drains to zero, which the
script verifies too. Both directions then agree, because the receiver folds
the same bits the transmitter emitted and the complement cancels.

## Related

- [[concepts/factored-hardware-blocks]] — where the LFSR sits in the plan.
- [[concepts/ethernet-scope]] — why CRC-32 has to be hardware (4 clocks/bit).
- [[reference/signal-names]] — the port names `pe_crc` exposes.
- [[STATUS]] — what is built.
