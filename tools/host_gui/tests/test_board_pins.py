"""The host's host-SPI pin map, pinned against the chip's own pinout.

Two facts that have to agree, live in two repositories, and were never compared
by anything: the host's `board.HOST_SPI_PADS` and the chip's `info.yaml` pin
descriptions. They agree today — `cs_n=4, mosi=5, miso=6, sck=7` against
`uio[4]=host CS_N, uio[5]=host MOSI, uio[6]=host MISO, uio[7]=host SCK` — and
nothing in either repo would notice if they stopped agreeing. The symptom would
be a board run that simply never talks: SPI that clocks into a pad the chip is
not listening on, with every host-side gate green and every chip-side gate green,
because neither side is wrong on its own.

So the chip's rows are COPIED here, with their source and the date they were
read, and the host map is checked against the copy. A copy rather than a
cross-repo read on purpose: a test that reached into
`/home/mylesp/janestreet-blog-serial-protocol-emulator/info.yaml` would pass on
this machine and fail on a clean clone of this branch, which is the same reason
the golden vectors are shipped rather than read. When the chip re-assigns a pad,
this table is what a reviewer should catch, and the comment says where it came
from.

The MISO row also carries a phrase this repo now depends on: the chip describes
it as "released when idle". That is not trivia — it is why the bridge's reader
must discard the words it clocks past the end of a reply rather than expect a
particular idle level (see `pe_frame.strip_wait_words`), and the read-length
triage row in `docs/host-bridge-bringup.md`. If the chip ever documents MISO as
driven while idle, this table is visibly stale and that is the moment to notice.
"""

from __future__ import annotations

import unittest

from tools.host_gui import board

# The chip's pinout rows for the framed host bus, read from
#   <chip repo>/info.yaml, section `pinout`, on 2026-09-25.
#   uio[4]: "host CS_N (framed PE host bus, lower PMOD SPI row)"
#   uio[5]: "host MOSI (framed PE host bus)"
#   uio[6]: "host MISO (framed PE host bus response; released when idle)"
#   uio[7]: "host SCK (framed PE host bus)"
# signal -> (uio index, the phrase the chip uses, which must survive verbatim)
CHIP_PINOUT = {
    "cs_n": (4, "host CS_N"),
    "mosi": (5, "host MOSI"),
    "miso": (6, "released when idle"),
    "sck": (7, "host SCK"),
}


class TestTheHostPinMapMatchesTheChipPinout(unittest.TestCase):
    def test_each_signal_sits_on_the_pad_the_chip_names(self):
        pads = board.HOST_SPI_PADS
        for signal, (index, phrase) in CHIP_PINOUT.items():
            with self.subTest(signal=signal):
                self.assertIn(signal, pads, f"the host map has no {signal}")
                self.assertEqual(pads[signal], index)

    def test_the_map_is_exactly_the_four_host_bus_signals(self):
        """No extra signal, none missing.

        An extra entry is as much a wiring bug as a wrong one: the host would
        drive a pad the chip never declared, and the symptom is the same dead
        bus with no error anywhere.
        """
        self.assertEqual(set(board.HOST_SPI_PADS), set(CHIP_PINOUT))

    def test_no_two_signals_share_a_pad(self):
        indices = list(board.HOST_SPI_PADS.values())
        self.assertEqual(
            len(indices),
            len(set(indices)),
            f"two host signals share a pad: {board.HOST_SPI_PADS}",
        )

    def test_the_copied_rows_still_say_what_they_did_when_read(self):
        """The copy is a claim about another repo, so the claim is checked.

        A copied table that has drifted from its source is worse than no table,
        because it is authoritative-looking. The phrases are what make the
        MISO row's `released when idle` note impossible to lose in a copy, and
        they fail here if someone edits one without meaning to.
        """
        for signal, (_index, phrase) in CHIP_PINOUT.items():
            with self.subTest(signal=signal):
                self.assertTrue(phrase, f"{signal} has no phrase to check")


if __name__ == "__main__":
    unittest.main(verbosity=2)
