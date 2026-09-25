# E1 published-byte ownership hardening screen

Fresh mapped evidence for the exact current `rtl/pe_eth_mac.v` source. The
source was SHA-256 `750d0bd591cc3c1a6e425b03e4cd471a5b398ca6cc03265c654d03daa69195d9`;
the mapped Verilog SHA-256 was
`af81045deec97cefdf5011b5a8f6025748a45a17d48fe27082f8dbc2020ec193`.
The fresh mapped Verilog is byte-identical to the earlier E1 published-byte
screen, confirming that the later source edit only changed comments.

Yosys 0.69+post reports zero problems in both `check` passes. The typical
corner area screen gives `pe_eth_mac` 1,681 cells / 23,749.6266 µm²,
`pe_soc` 3,571 / 56,816.8776 µm², and `tt_um_top` 3,888 / 62,745.4296 µm².

All three mapped OpenSTA runs include both setup and hold analysis. In
particular, the slow corner reads the slow 1.08 V / 125 °C libraries, applies
0.25 ns hold uncertainty, reports `-path_delay min`, and reports `-min` worst
slack. Worst hold slack is −0.8692 ns (slow), −0.6065 ns (typical), and
−0.4778 ns (fast). The worst setup summary is 0.00 ns; at slow this comes from
a transparent-latch time-borrow path, while the worst register-to-register
setup path is +2.2274 ns. The reports also retain the pre-existing unplaced
hold and electrical violations. This is a mapped screen, not physical or
signoff evidence.

The three-corner OpenSTA screen is a manual check, not a `run_all.sh` gate.
`regress/synth_area.sh` is also run separately from the standard regression.
Run both after relevant RTL changes and refresh these results.
