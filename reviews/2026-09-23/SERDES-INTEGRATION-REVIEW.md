# Serdes + codec integration plan — review findings and resolutions

Review of `wiki/plans/serdes-integration.md` (2026-09-23, plan-only). Seven
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

**Resolution (superseded in part by findings 6-7).** Two strobes:
`serdes_bit_en` (per logical bit) and
`codec_bit_en` (per codec cell; twice per bit for Manchester TX), with
`serdes.tx_ser` held across both halves (`rtl/pe_manch.v`:
`tx_wire = half_phase ? tx_raw : ~tx_raw`). Manchester **RX** does not use the
divider: `pe_dru` supplies a per-bit `bit_en` plus `rx_first`/`rx_second`,
exactly as the signed-off eth chain wires it (`half_phase = 0`). The plan's
earlier "`dru.bit_en` half-cell cadence" claim was wrong and is corrected.

**Corrected by findings 6-7** (loopback follow-up): the claim that `pe_manch`
TX "needs a strobe per half-cell" is false -- its TX is purely combinational.
The codec strobe is per encoded cell, `half_phase` is the 2x half-cell level,
and both blocks' shared enables are split.

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

## 6. The codec's single `bit_en` clocks both directions, and Manchester TX consumes no strobe

**Finding.** The first amendment said `codec_bit_en` runs at twice the bit rate
for Manchester TX with `half_phase` toggling. RTL: `pe_manch`'s TX is purely
combinational (`tx_wire = bypass ? tx_raw : (half_phase ? tx_raw : ~tx_raw)`,
`rtl/pe_manch.v`); only `rx_err` is registered on `bit_en`. `pe_codec_mux`
wires its one `bit_en` to `pe_bitstuff`, `pe_nrzi` AND `pe_manch`, and each of
those advances both directions from it: `pe_bitstuff`'s single `always_ff`
updates `tx_run`/`tx_pend` and `rx_run`/`rx_err`; `pe_nrzi` updates `tx_level`
and `rx_level` in one block. A doubled strobe would advance all of that twice
per bit; a per-decoded-cell DRU strobe on the same port would collide with the
TX cadence in the concurrent loopback.

**Resolution.** The codec's `bit_en` is redefined as one pulse per **encoded
cell** -- a payload cell or an inserted stuff cell, never a half-cell. The
Manchester second half is the independent `half_phase` **level** (2x toggle,
not a strobe). Two `pe_codec_mux` instances, one per direction, carry the TX
and RX encoded-cell cadences separately (`u_tx_codec`/`u_rx_codec`);
`tx_stuffed` and `rx_bit_valid` are exported to gate the serdes enables. The
alternative internal split (`tx_bit_en`/`rx_bit_en` inside one instance, each
stage's `always_ff` split) is documented as smaller but more invasive. See
finding 7 for the serdes half of the handshake and the directed stuffed
loopback/mutation requirements.

## 7. `pe_serdes`'s single `bit_en` cannot carry the two payload-only sequences

**Finding.** `pe_serdes` has one `bit_en` port that clocks both the TX
`always_ff` (`bit_en && tx_busy`) and the RX `always_ff` (`bit_en && rx_busy`)
(`rtl/pe_serdes.v`). With stuffing enabled the handshake is: TX holds across
each `tx_stuffed` cell (`serdes.tx_bit_en = tx_codec_cell_en && !tx_stuffed`,
current-cycle -- `tx_stuffed` is the combinational output of the registered
`tx_pend`, high for the whole stuff `bit_en` cycle; the unit reference is
`tb_pe_codec_mux.tx_step_comb`, which pulses the strobe on the stuff slot
while `tx_stuffed` is high and checks the following payload resumes the
correct bit). RX skips each received stuff cell
(`serdes.rx_bit_en = rx_codec_cell_en && rx_bit_valid`, where `rx_bit_valid`
is `pe_bitstuff.rx_raw_valid`, combinational from the RX run state). The two
sequences can differ (independent words, decode latency), so one `bit_en`
cannot serve both; the first amendment's "per logical bit" strobe was
underspecified and would have consumed a payload bit on every stuff cell.

**Resolution.** Split `pe_serdes.bit_en` into `tx_bit_en` and `rx_bit_en`, each
wired to its own payload-only gate. The split is mechanical (two enable
networks already exist; no new state; area unchanged in expectation) with
source cost: module header/ports, `tb_pe_serdes` (both enables; a directed
case where they differ), the new `regress/mutate_serdes_tb.sh`, and the
generated signal page. Two direction-specific `pe_serdes` instances are the
documented alternative (double the 539 cells for no functional gain); one
shared enable with lockstep-only scope is rejected for the concurrent loopback.
The integration TB must run a **stuffed Manchester loopback** (`cfg = 0x05` or
`0x07`) and check both holds/skips end to end; the SoC mutation harness must
detect removal of either gate, a doubled codec cell enable, and the strobe
cross-wire.

No RTL was changed by this review; no physical flow, DRC or LVS was run. The
plan remains plan-only, awaiting the open scope decisions.
