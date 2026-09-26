# Docs accuracy review — pass 7 (2026-09-26)

Author: protocol-worker. Rolling pass, remote tips only. Covers the five new
`wiki/concepts/` pages on `docs/diag-bus` (the pages pass 6 named as the
highest-risk unreviewed item, because D1/D2 and D3 each survived in a page), the
SPI3/CRC and UART-flow claim details pass 6 ran out of room for, and the current
state of D3 at `docs/diag-timing`.

## 1. Correction — owner: pw-diag-bus

### F1 (medium) the SPI3 page states a response rule that does not produce the
### firmware's response bytes

`wiki/concepts/protocol-spi3-crc.md:103` says the slave's response is
**"`resp = word XOR 0x7E5A`, applied byte-wise"**, and offers it as the reason
the responses are computed "rather than a played-back table". Checked against
`firmware/spi_mode3.pe`, which states the three response bytes are `0x6B`, `0x2C`,
`0xD9`:

| word | `word ^ 0x7E5A` | firmware's byte | |
| --- | --- | --- | --- |
| `0x1134` | `0x6F6E` | `0x6B` | no match |
| `0x1245` | `0x6C1F` | `0x2C` | no match |
| `0x1356` | `0x6D0C` | `0xD9` | no match |

Three for three, and not a near miss on any of them, so it is not a transcription
slip in one digit: either the constant is wrong or the rule is something else
(the page's own hedge "rather than a played-back table" is what the rule was
supposed to establish, and as written it establishes nothing). Worth fixing
because a reader who tries to reproduce the responses with the stated rule will
conclude the firmware is wrong — the same inversion the day record's stale row
produced, and the reason a derivation nobody has executed is worth checking.

## 2. D3 — closed in the docs, and one live instance left in tooling

At `origin/docs/diag-timing`: the figures and the page now carry **1.15 µs**
(`proto-ds18b20.puml`, `proto-ds18b20-timing.puml`,
`wiki/concepts/protocol-ds18b20.md:158`). The third site is fixed. The `1.22`
that remains in `tools/diag/delay_lattice.py:11` is **legitimate** — it is the
gate's own fixture, listing the quoted error it exists to catch ("quoted 69
clocks = 1.22 us (69/60 = 1.15)"), which is exactly the right way to keep the bad
value visible without asserting it.

**One live instance, outside the docs remit, for the manager rather than the
worker:** `tools/fw/peasm.py:200` still carries "# clocks (1.22 us) on the (2,13)
pair, so a slot is aimed by division". That is a comment in the **assembler**,
not in a figure or a page, and it is the same conversion error in the one file
every firmware build reads. Worth correcting wherever it belongs; flagging rather
than filing it as a docs finding, because the owner of that file is not in this
fleet.

## 3. The numbers gate has no visible negative control

`docs/diag-timing bbbb1ff` adds `tools/diag/delay_lattice.py`, a gate built
specifically to catch the class D3 belonged to — the right instinct, and the
corrections table in it is well made. But `git ls-tree` over the branch shows
**no test for it**, where the wiki-pages gate on the other branch has 13 cases.

That asymmetry is worth naming rather than as a defect but as the next thing to
ask for: the wiki-pages gate's negative control is the reason I could close it
with evidence in one turn, and a numbers gate that has only ever been seen green
is the same "a script that prints reassuring text" the other gate's header warns
about. The fixture is already there — the D3 row in its own table is a ready-made
negative case.

## 4. Verified correct

* **MIDI page**: 1 clock = 16.667 ns; a bit at 31.25 kbaud = 1920 clocks =
  32.000 µs; and the derivation `21 + 1 + 146 × 13 = 1920` checks out, with
  `146 × 13 = 1898` being the delay the page says it has to be. A clock-
  resolution probe figure (979 clocks = 16.316 µs) is quoted as a measurement,
  not derived.
* **DMX page**: 513 slots, `513 × 11 × 4.000 µs = 22.572 ms` (arithmetic exact),
  "each iteration of both loops is exactly 240 clocks, one bit" (240/60 = 4 µs),
  and — the C3 point — it names the tick as **260 clocks = 4.3333 µs** and then
  states a DMX bit as 4 µs, which is the corrected framing rather than the old
  "the rate the tick cannot express AT ALL".
* **SPI3 page, everything else**: CRC-8 poly `0x07`, init `0x00`, no reflection,
  no final XOR, matching both the firmware and the testbench's independent
  reference datapath; the three words `0x1134`, `0x1245`, `0x1356`; and the
  bit-reversals `0x3411`, `0x5421`, `0x6531`, each of which is the correct
  reversal.
* **UART page**: 260 clocks = 4.3333 µs and "a bit is two ticks", which is the
  project's half-bit arrangement (`TICKS_PER_BIT = 260` at 115 200, i.e. 8.67 µs a
  bit = 115.4 kbaud). The page also carries the `dmem[3]` counter's saturation at
  `0xFF` and the reasoning that it is not cosmetic.
* **I2C page**: the wire sequence matches the testbench's decoded expectations,
  and `13.03 µs = 76.7 kHz` is arithmetically right (1/13.03 µs = 76.7 kHz).

## 5. Not reviewed

**37 new commits on `docs/diag-bus`** (including two merges of `diag-proto` and
`diag-bus` into it) since pass 6 read `6c89c07`; the new NEC-IR figure set
(`998daa6`) and the formal-campaign wiki pages on `diag-proto` (`3dcbd32`). The
branches are now merging into each other, which raises a question for the next
pass rather than answering it: once `diag-proto`'s maps live inside `diag-bus`,
whose map is authoritative, and does a figure that restates a map claim get
checked when the map moves? That is a merge-order observation of the same class
as pass 6's MIDI/DMX finding, and it is better raised now than discovered later.
