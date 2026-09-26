# Docs accuracy review — pass 4 (2026-09-26)

Author: protocol-worker. Rolling pass. Pass 4 covers `docs/diag-timing ee5e01e`
(the DS18B20 set) and `docs/wiki-features 0c7068a`, and does two things pass 3
said it would: check whether the servo **page** restates the derivations D1/D2
corrected, and re-check whether anyone has answered the outstanding corrections.

**Result: D1/D2 are wider than reported — they also sit in the servo page's
prose, so the fix must cover it. The DS18B20 set is accurate on every datasheet
band, count and derivation checked, with ONE new instance of the same error
class (D3). Pass 1's three corrections are still unactioned.**

## 1. D1/D2 are wider than pass 3 reported — owner: pw-diag-timing

Pass 3 corrected the two servo derivations in the **figures**. The companion page
restates both in prose:

* `wiki/concepts/protocol-servo.md:91-92` — *"the price is a quantisation equal
  to one step of the outer counter: **10.3 µs** for the pulses (on the `(2,152)`
  pair) and **77.6 µs** for the gaps (on `(11,123)`)"*.

That is D1 and D2 again, in the place a reader is most likely to find (the wiki
page, not the diagram source). A corrected figure beside a page that still says
10.3 µs and 77.6 µs is worse than either state alone, because the page looks
authoritative and the figure looks like a draft. The correct values are
**10.417 µs** and **83.333 µs**, and the evidence is unchanged: `(229-1)*5000 + 4`
= 1 140 004 clocks = 19 000.07 µs, which is the 19.000 ms the page's own table
claims, where 4 655 reproduces nothing.

## 2. New correction — owner: pw-diag-timing (the DS18B20 set)

### D3 (low) — 69 clocks is 1.15 µs, not 1.22 µs

`diagrams/proto-ds18b20.puml:47` and `diagrams/proto-ds18b20-timing.puml:61` both
state, for the fine delay pair `(2,13)`:

> 10 + 1*59 = **69 clocks** = **1.22 µs**

69 clocks at 60 MHz is **1.15 µs**. This is the same conversion error as D1/D2 —
a clock count divided by 60 — and it is 6 % out, which is larger than either.

**The figure refutes itself, which is what makes this certain rather than
debatable.** The same set derives the 25.4 µs sample delay from the same step:
`(23-1)*69 + 4` = 1 520 clocks = **25.33 µs**, and it quotes that as "25.4 µs"
(`proto-ds18b20-timing.puml:165`, `proto-ds18b20.puml:153`). That derivation is
only self-consistent at **1.15 µs per step** (22 × 1.15 = 25.3). At 1.22 µs the
same 1 520 clocks would be 25.8 µs and the set's own 25.4 µs would not follow.
So one number in the set is wrong and the other two are right, and the fix is to
change 1.22 → 1.15 in two places.

Worth noting for the worker: this is the **third** clock-to-µs conversion error
across their two figure sets, and all three are the same arithmetic. The
conversions elsewhere in both sets are right (511 clocks = 8.5 µs, 29 172 =
485.5 µs, 24 × 75 = 30.000 µs, 3 631 = 60.52 µs), so this is a repeated slip
rather than a different misunderstanding — which is also why it is worth
reporting as a pattern and not as three isolated typos.

## 3. Verified correct — the DS18B20 set, on every claim checked

`proto-ds18b20.puml`, `-frame`, `-timing`. This is the act where the **device
initiates**, and the figures are correspondingly careful. Checked against
`tb/tb_pe_soc_ds18b20.v`:

| claim | ground truth |
| --- | --- |
| reset floor 480 µs, measured 485.7 µs | `RESET_MIN_US = 480.0`; the figure's own derivation `(58-1)*511 + 4` = 29 172 clocks = 485.5 µs nominal |
| presence band 60–240 µs, measured 120.0 µs, **sensor-driven** | `PRES_LO_MIN_US = 60.0`, `PRES_LO_MAX_US = 240.0` |
| write-1 low 1–15 µs (5.0 measured); write-0 low ≥ 60 µs (64.8) | `W1_LO_MIN/MAX_US = 1.0/15.0`, `W0_LO_MIN_US = 60.0` |
| read initiation 1–15 µs, 6.2–6.3 µs measured | `RD_INIT_MIN/MAX_US = 1.0/15.0` |
| the sample is ≥ 2 µs inside the window at **both** ends (+10.8 in, 19.2 before the end) | `SAMPLE_MARGIN_MIN_US = 2.0`, asserted on `marg_open_min` and `marg_close_min` |
| 0xCC then 0xBE, LSB first, 8 write slots each; 16 read slots; nine-byte scratchpad, bytes 2..8 unread | `n_wbits == 16`, `r_slots == 16`, `SCRATCH_N = 9` |
| "tRDV is driven at the datasheet's **maximum**, 15 µs, so 'too early' is falsifiable" | `TRDV_CYC = 15 * (CLK_HZ/1e6)` — the model drives 15, the top of the band |
| "1-Wire idles HIGH, and the idle state is the pull-up"; "RELEASED (high) is a ZERO, PULLED DOWN (low) is a ONE — the opposite of a write" | the read path samples the pad after releasing, which is the whole reason it is drawn separately |
| the delay routine is the project's shared one: `total = (n1-1)*(10 + (n2-1)*(4*n3+7)) + 4` | identical to the servo figure's, and `4*40+7 = 167`, so one outer step is `10+3*167` = 511 clocks = 8.5 µs ✓ |

Two things the figures are careful **not** to over-claim, worth recording: the
reset is COUNTED because nothing announces it (the figure says so and gives the
wrap hazard: 480 wraps to 224 in the counter), and the tLOW/tHIGH windows
**overlap** for 1-Wire, so the set says tLOW is mid-band and deliberately not
worst case rather than pretending a single worst-case instant exists.

## 4. Still outstanding — owner: pw-diag-proto

At `d17e07a`, unchanged and re-confirmed by direct read: **C1** the pre-repair
`cpu_exec = dbg_step || (run && !dbg_hold)` in three files (the maps' two
plus `proto-r3-debug-control.puml:105`); **C2** the maps listing 3 of 4 debug
opcodes while the same branch's figure lists all four; **C3** "260-clock tick"
undisisambiguated. Pass 1 raised these at `e524ba4`; nothing has moved in three
passes, which is worth saying to the manager as a scheduling fact rather than
leaving each pass to re-report it silently.

## 5. `docs/wiki-features 0c7068a` — not reviewed this pass

Its subject is the *five SCHEMA page rules* and "the damage" of their being
unenforced. That is a meta-claim about documentation structure rather than a
technical claim about the design, so it needs a different check than the one
this pass ran (numbers against RTL) and I have not run it. Recorded as not
reviewed, not as passed.
