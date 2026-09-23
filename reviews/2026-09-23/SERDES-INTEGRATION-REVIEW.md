# Serdes + codec integration plan — review findings and resolutions

Review of `wiki/plans/serdes-integration.md` (2026-09-23, plan-only). Five
findings; each resolution is source-grounded against the RTL and the plan was
amended in place.

## 1. `0xF` window encoding lost data bit 7

**Finding.** `A[7]=1` selected INDEX while `A[7]=0` wrote data, so a data byte
with bit 7 set was indistinguishable from an index write — `REG[..].bit7`
could never be written.

**Resolution.** The window now has a **latched `phase` bit**: writes in INDEX
phase set the pointer; writes in DATA phase store all 8 bits and auto-increment;
**any read returns `REG[INDEX]`, auto-increments, and re-arms INDEX phase**, so
the next write is always an index write after a read or reset. Explicit
firmware sequences (write word, read word) are in the plan. No data bit is
sacrificed and the read/index behaviour is fully defined.

## 2. One 8-bit `LEN` register cannot hold both lengths

**Finding.** `LEN` was "5+5 packed" in one byte (10 bits), and `pe_serdes`'s
`LENW = $clog2(MAXLEN+1) = 6` means 32 was not encodable either.

**Resolution.** Separate `TXLEN` and `RXLEN` window indexes, each a six-bit
`1..32` encoding (0 invalid), matching `LENW = 6`; the map was renumbered. The
serdes has independent TX and RX sides and can run both at once, so a shared
length is not an option. A 5-bit `0 => 32` encoding is the documented
alternative, but not both fields in one register.

## 3. One shared `bit_en` cannot serve serdes and Manchester codec

**Finding.** The serdes advances once per logical bit; `pe_manch` TX needs a
strobe per **half-cell** with `half_phase` toggling.

**Resolution.** Two strobes: `serdes_bit_en` (per logical bit) and
`codec_bit_en` (per codec cell; twice per bit for Manchester TX), with
`serdes.tx_ser` held across both halves (`rtl/pe_manch.v`:
`tx_wire = half_phase ? tx_raw : ~tx_raw`). Manchester **RX** does not use the
divider: `pe_dru` supplies a per-bit `bit_en` plus `rx_first`/`rx_second`,
exactly as the signed-off eth chain wires it (`half_phase = 0`). The plan's
earlier "`dru.bit_en` half-cell cadence" claim was wrong and is corrected.

## 4. Overlay insertion point vs the open-drain gate

**Finding.** The plan muxed on the post-matrix `pin_out` wire;
`pe_pinmux` derives `pad_oe[i] = reg_oe[i] && (!reg_od[i] || !reg_out[i])`, so
the OD gate would still key on the un-overridden register level.

**Resolution.** The overlay is applied to the matrix's **level input, before
the OD gate** (`eff_out[i] = overlay_en[i] ? tx_wire : reg_out[i]` feeds both
`pin_out` and the OD term), so open-drain personas work. The v1 alternative of
restricting the engine to push-pull pins is rejected as a firmware footgun.
OE/OD remain firmware-owned.

## 5. `pe_eth_mac` / `pe_fbuf` cannot be a TX frame source

**Finding.** `pe_eth_mac` is receive-only and `pe_fbuf` is the RX store, so the
plan's "10BASE-T TX check driven from them" was not implementable.

**Resolution.** The first consumer is split: (a) a **wire-loopback milestone**
(engine TX -> wire model -> DRU/codec/serdes RX) that needs no frame layer and
is what this plan delivers; (b) a **separate 10BASE-T TX frame block/plan**
needing preamble/SFD generation, FCS generation (`pe_crc` is committed to the
RX path, so TX needs a time-shared or duplicated LFSR), IFG/backoff timing and
a frame source.

No RTL was changed by this review; no physical flow, DRC or LVS was run. The
plan remains plan-only, awaiting the open scope decisions.
