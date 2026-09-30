# VvpTTAdapter design — shrinking v1.0 item 11 without hardware

This records the design of the simulation path to open item 11 (the
hardware-gated Pico acceptance run) BEFORE the code exists, so a lost session
costs a re-read and not a re-derivation. Nothing here claims the work is done.

WHY NOT AN RP2040 EMULATOR. The Pico runs ONE MicroPython file (main.py) as a
USB-serial adapter; it is not the thing being simulated. The boundary that
matters is the 6-method TTAdapter HAL, and everything above it is already
exercised: TestHostOverRealBridge (tools/host_bridge/tests/test_host_integration.py)
drives the REAL main.py bridge over LoopbackPort against FakeTTAdapter(FakePE())
through a full connect -> load -> start -> stop -> dump round trip. 25 of 26
golden steps are already chip_confirmed in SIMULATION. An RP2040 emulator would
re-derive what a 60-line fake already provides, at large cost, and Renode-class
USB support is weakest exactly at the step (enumeration) we most want to trust.

THE ONE OBJECT TO REPLACE. VvpTTAdapter implements the same six methods as
FakeTTAdapter - reset, set_run, configure_host_spi, host_spi_transfer, irq_n,
set_clock - backed by a vvp process running the REAL pe_soc/pe_ctrl. Because the
existing integration test is parameterised on exactly that adapter, turning it
into a real-chip test is a one-line change in setUp. That is the blast radius,
and it is why the seam was chosen: the contract is already exercised on both
sides of it.

WHAT IT DOES AND DOES NOT CLOSE. It exercises the real pe_frame codec against
the real pe_ctrl and pe_soc, the B1 wait-word fix, IRQ_N, run-gating, liveness,
and every golden step - end to end through the unmodified real bridge. It does
NOT cover USB enumeration, real SPI timing and setup, board power and clock
configuration, or MicroPython itself. Those four remain genuinely
hardware-only. So this SHRINKS item 11 from "trust the whole stack" to "trust
these four things", which is the difference between an acceptance run and a coin
flip. It does not close item 11 and must never be reported as if it did.

THE SPI CONTRACT, read off the code rather than assumed. Mode 0 (spi_xfer.pe is
a mode-0 master), CS-framed. Pad map on the ui_in/uo_out buses: SCLK_BIT=0,
MOSI_BIT=1, CS_BIT=2, MISO_BIT=3 (identical to tb_pe_soc_spi3.v:78). MISO is
valid only while miso_oe is asserted - the pad must be modelled, because the
R2 bounded read can be preceded by up to 15 leading 0xFFFF wait words that the
host strips with strip_wait_words. Framing (pe_frame.py): HEADER_WORDS=4 (sync,
header, sequence, length), payload, TRAILER_WORDS=1 (CRC-16/CCITT-FALSE, poly
0x1021, init 0xFFFF, no reflection, no final XOR), MAX_PAYLOAD_WORDS=0xFFFF,
MAX_WAIT_WORDS=15. The bridge path: encode_frame -> host_spi_transfer(raw,
read_words) -> strip_wait_words -> decode_frame, with read_words = 6 + data +
MAX_WAIT_WORDS (main.py:328-354).

WHY A TESTBENCH BUILD COMES FIRST. Every existing tb_pe_soc_*.v is self-contained
and free-runs, and tb_pe_soc_spi3.v hardcodes ONE specific transaction shape in
a bit-level slave model. A VvpTTAdapter needs a testbench whose SPI traffic is
externally supplied rather than self-generated, so that bite is the prerequisite
and is in flight in the chip lane now (tb/tb_pe_soc_extspi.v).
