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

THE SPI CONTRACT, read off the code rather than assumed. Mode 0 (pe_ctrl is a
mode-0, MSB-first, 16-bit-word slave), CS-framed, and - the correction that
matters - the pad map is the WRAPPER's framed host bus, not the SoC's own
SPI-master map:

    uio[4] = host CS_N      uio[5] = host MOSI
    uio[6] = host MISO      uio[7] = host SCK
    uo_out[1] = IRQ_N      ui_in[1] = run

MISO is valid only while miso_oe is asserted - uio[6] is RELEASED when idle,
which is the R2 wait-word contract, and the host strips up to 15 leading 0xFFFF
words with strip_wait_words.

An earlier draft of this file carried SCLK=0, MOSI=1, CS=2, MISO=3 from
tb_pe_soc_spi3.v:78. That map is the UART/SPI row used when pe_soc is the SPI
MASTER - the firmware's own path - and it is wrong here in two ways at once: it
is the opposite direction of traffic, and pe_ctrl does not live in pe_soc.v at
all (pe_soc.v:224 says so outright: "the host bus (pe_ctrl, outside this
block)"). pe_ctrl is instantiated in rtl/tt_um_protocol_emulator.v. Building the
14-file pe_soc list would produce a chip with no pe_ctrl in it, and a smoke test
against it would pass on a part that cannot answer a single frame.

So a VvpTTAdapter testbench must instantiate tt_um_protocol_emulator, NOT bare
pe_soc. The protocol worker caught this before it wrote code against the wrong
map - it was given the contract spelled out and the authority to reject it, and
it did, rather than silently picking one. That is the behaviour worth having.

Framing (pe_frame.py): HEADER_WORDS=4 (sync, header, sequence, length),
payload, TRAILER_WORDS=1 (CRC-16/CCITT-FALSE, poly 0x1021, init 0xFFFF, no
reflection, no final XOR), MAX_PAYLOAD_WORDS=0xFFFF, MAX_WAIT_WORDS=15. The
bridge path: encode_frame -> host_spi_transfer(raw, read_words) ->
strip_wait_words -> decode_frame, with read_words = 6 + data + MAX_WAIT_WORDS
(main.py:328-354).

WHY A TESTBENCH BUILD COMES FIRST. Every existing tb_pe_soc_*.v is self-contained
and free-runs, and tb_pe_soc_spi3.v hardcodes ONE specific transaction shape in
a bit-level slave model against the SoC-as-master pad map. A VvpTTAdapter needs
a testbench that (a) builds tt_um_protocol_emulator so pe_ctrl is present, and
(b) takes its SPI traffic from outside rather than generating it. That bite is in
flight in the chip lane now (tb/tb_pe_soc_extspi.v).
