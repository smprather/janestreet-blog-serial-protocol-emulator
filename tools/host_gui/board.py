"""Board-level constants fixed by the W2-2 R0 decisions.

Source: reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md, section 4 (R0) and
the manager's W2-2 rulings:

  * the plan's pad mapping WINS: host SPI is ``uio[4]=CS_N``, ``uio[5]=MOSI``,
    ``uio[6]=MISO``, ``uio[7]=SCK`` (TT pinout "lower PMOD SPI row");
  * the A1 raw echo on ``uio[4]`` is superseded -- that pad is CS_N; its
    semantics now live in the framed LOAD response (per-word commit log and the
    final-word echo; an aborted word is never echoed);
  * the 5 MHz figure is the host guard rate, not the computed RTL limit; the
    bridge protocol carries the negotiated cap (``hello.sclk_hz_max``) and no
    caller may exceed it.
"""

from __future__ import annotations

# uio indices on the chip for the host SPI, per the TT pinout convention.
HOST_SPI_PADS: dict[str, int] = {"cs_n": 4, "mosi": 5, "miso": 6, "sck": 7}

# Host-enforced first-pass SCLK cap (plan Global Constraints). The loader's
# computed 60/6 = 10 MHz write ceiling is deliberately not offered as the
# readback path has its own, lower, mode-0 limit (see the review's rate table).
SCLK_GUARD_HZ = 5_000_000

# The locked PE operating point (ADR-005).
PE_CLOCK_HZ = 60_000_000
