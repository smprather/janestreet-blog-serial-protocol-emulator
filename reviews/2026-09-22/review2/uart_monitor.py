"""Exercise the emulator's TX decoder with independently timed 8N1 frames."""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / 'tools' / 'fw'))
from peemu import Soc, TICKS_PER_FULL_BIT

failures = 0
for period in [520, 521, 519]:
    soc = Soc([])
    bits = [0] + [(0xA5 >> i) & 1 for i in range(8)] + [1, 1]
    for cycle in range(10 + len(bits) * period):
        soc.cycles = cycle
        level = 1 if cycle < 10 else bits[min((cycle - 10) // period, len(bits) - 1)]
        soc.reg_out = level
        soc.poll_tx()
    print(f'wire bit clocks={period}, monitor bit clocks={TICKS_PER_FULL_BIT}, '
          f'transmitted=a5, decoded={[hex(value) for value in soc.tx_bits]}')
    failures += soc.tx_bits != [0xA5]

if failures:
    raise SystemExit('FAIL: UART decoder rejected or misdecoded a valid waveform')
