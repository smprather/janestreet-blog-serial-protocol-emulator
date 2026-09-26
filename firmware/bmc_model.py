#!/usr/bin/env python3
# bmc_model.py -- the FM0/FM1 receiver MODEL, in the REPOSITORY because the two copies
# of this file in /tmp were both deleted mid-session by something that cleans
# /tmp, and a model that decides the shape of a fix cannot live where a cleanup
# can take it. Written from the wire rules and from nothing else here: it builds
# the level sequence for both polarities, lists the transitions and the interval
# sequence, and runs the receiver algorithm both as it was and as it now is.
# /tmp/fm_model.py -- the FM0/FM1 receiver MODEL, written from the WIRE RULES
# and not from the firmware. Two rules produce everything below:
#   h1 == ~h0 for every bit (every bit carries a MID transition);
#   the DATA is the level of the FIRST half; a bit boundary transitions iff two
#   adjacent bits are EQUAL.
# fm0 = 1 marks a one HIGH, fm0 = 0 (FM1) marks a one LOW.
#
# The model exists because the handoff's instruction is MODEL BOTH POLARITIES
# BEFORE EDITING: the loss is asymmetric, so the shape of the fix cannot be
# argued from one polarity.

PRE_ZEROS, PRE_ONES = 8, 8
FRAME = [0xA5, 0x3C, 0x96]
# THE BIT ORDER ON THE WIRE, AND WHY IT IS THE HIGH BIT FIRST. The frame's bits
# go out from bit 7 down to bit 0. The reason is the ISA and nothing else: the
# receiver's shift-in is `A = A + A; A = A + bit`, i.e. a doubling with the new
# bit in at the LOW end, so the FIRST bit to arrive ends up in the HIGH position.
# Assembling low-bit-first would need the arriving bit placed at weight
# 2**count, and this machine has no shift and no variable place: it would cost
# a scratch byte shared with the poll loop's elapsed-time store (dmem[14], which
# is the one byte in the map that is written and never read) and four more
# instructions on every bit. High-first costs nothing on either side and is now
# written down here, in the testbench's encoder and in its decoder, which are
# the three places a wire rule has to live.
HALF_US = 2                      # a half-interval is 2 us, whole
IDLE = 1                         # the line idles HIGH, for BOTH polarities
# THE FRAME DOES NOT START AT TICK ZERO. dmem[5] is seeded to 0 and the core
# spends ~20 us loading imem before the first poll, so the first transition
# arrives at tick ~20 and its measured interval is ~20, not 2 -- which is why
# BOTH polarities resync. Putting the frame at tick 0 in a model gives the FM1
# case a first interval of exactly 2 us, no resync, and a phase error that is
# the opposite one. The model has to sit where the machine sits.
FRAME_START_US = 20


def bits():
    """the bits IN ARRIVAL ORDER: the preamble, then the frame high bit first"""
    return [0] * PRE_ZEROS + [1] * PRE_ONES + \
           [(FRAME[i // 8] >> (7 - i % 8)) & 1 for i in range(24)]


def level(k, fm0):
    d = bits()[k // 2]
    h0 = d if fm0 else 1 - d
    return h0 if k % 2 == 0 else 1 - h0


def levels(fm0):
    return [level(k, fm0) for k in range(2 * len(bits()))]


def lev_at(fm0, us):
    """the level at microsecond `us`, the frame starting at FRAME_START_US"""
    t = us - FRAME_START_US
    if t < 0:
        return IDLE
    n = 4 * len(bits())
    return IDLE if t >= n else levels(fm0)[t // 2]


def transitions(fm0, bit_lo=0, bit_hi=None):
    """the transition TIMES (absolute ticks) over a bit range of the stream"""
    if bit_hi is None:
        bit_hi = len(bits())
    lo, hi = FRAME_START_US + 4 * bit_lo, FRAME_START_US + 4 * bit_hi
    tr, prev = [], lev_at(fm0, lo - 1)     # the level BEFORE the window, so a
    for us in range(lo, hi):               # transition on its first sample is
        lv = lev_at(fm0, us)               # not counted as one
        if lv != prev:
            tr.append((us, lv))
            prev = lv
    return tr


# ---------------------------------------------------------------- receiver ---
# dmem  4 = level at the last CHANGE        5 = tick of the last change
#       8 = INTERVAL between changes        15 = phase history, THREE states
#       12 = the bit/byte under construction  7 = bits in it   9 = byte index
#       13 = "the preamble is still running"  3 = the flag    0..2 = the frame
class Rx:
    def __init__(self, phase_states=2, idem='old'):
        self.idem = idem
        self.two_states = (phase_states == 2)
        self.d = {4: IDLE, 5: 0, 8: 0, 15: 0, 3: 0xFF, 13: 1,
                  0: 0, 1: 0, 2: 0, 7: 0, 9: 0, 12: 0}
        self.mids = self.bnds = self.resyncs = self.skipped = 0
        self.iv2 = self.iv4 = self.ivx = 0
        self.bits_emitted = []

    def poll(self, lv, us):
        d = self.d
        if lv == d[4]:
            return
        d[4] = lv
        iv = (us - d[5]) & 0xFF
        d[5] = us
        d[8] = iv
        if iv == 4:
            self.iv4 += 1
        elif iv == 2:
            self.iv2 += 1
        else:
            self.ivx += 1

        if iv == 4:                       # a two-half gap is ALWAYS mid->mid
            self.mid()
        elif iv != 2:                     # the clock is lost
            d[15] = 0 if self.two_states else 2
            self.resyncs += 1
        elif d[15] == 1:                  # previous was a boundary -> its mid
            self.mid()
        elif d[15] == 2 and not self.two_states:
            self.skipped += 1            # UNKNOWN phase: a 2 us gap says
        elif d[15] == 2:                 # nothing, and nothing is emitted
            self.mid()
        else:                             # previous was a mid -> a boundary
            d[15] = 1
            self.bnds += 1

    def mid(self):
        d = self.d
        d[15] = 0
        self.mids += 1
        bit = 1 - d[4]                    # the level of the FIRST half
        if d[13]:                         # the preamble: the flag is not known
            self.bits_emitted.append(('pre', bit))
        else:                             # the payload: FM1 inverts
            if d[3] == 1:
                bit = 1 - bit
            self.bits_emitted.append(('pay', bit))
        d[12] = ((d[12] << 1) | bit) & 0xFF
        d[7] += 1
        if d[7] == 8:
            d[7] = 0
            if d[13]:                     # THIS byte is the preamble's, and it
                # is the polarity: eight ONES as levels = FM0, 0x00 = FM1
                if self.idem == 'trace':
                    print("      byte_done: the preamble's byte assembled as "
                          "0x%02x -> %s" % (d[12], 'FM0' if d[12] == 0xFF
                                             else 'FM1' if d[12] == 0 else 'NOT LOCKED'))
                if d[12] == 0xFF:
                    d[3] = 0
                elif d[12] == 0x00:
                    d[3] = 1
                else:
                    d[3] = 0xFF           # declared: not this protocol
                d[13] = 0
                d[12] = 0
                # d[9] STAYS 0: the preamble was ONE received byte, so the
                # payload's first byte lands in slot 0. The old code advanced
                # it to 1, which is what put A5 in dmem[1] and the third byte
                # ON TOP OF THE FLAG in dmem[3].
            else:
                d[0 + d[9]] = d[12]
                d[12] = 0
                d[9] += 1

    def run(self, fm0, until_us):
        for us in range(1, until_us + 1):
            self.poll(lev_at(fm0, us), us)
        return self


def show(fm0):
    tr = transitions(fm0)
    ivs = [tr[i][0] - tr[i-1][0] for i in range(1, len(tr))]
    print("  %s: %2d transitions over the WHOLE stream, first at t=%d us, "
          "%2d intervals (%d x 2us, %d x 4us)"
          % ('FM0' if fm0 else 'FM1', len(tr), tr[0][0], len(ivs),
             ivs.count(2), ivs.count(4)))
    return ivs


def emitted(fm0, idem, pre_first=0, pre_ones=8):
    rx = Rx(phase_states=2 if idem == 'old' else 3,
            idem=idem).run(fm0, FRAME_START_US + 4 * len(bits()) + 8)
    pre = ''.join(str(b) for k, b in rx.bits_emitted if k == 'pre')
    pay = ''.join(str(b) for k, b in rx.bits_emitted if k == 'pay')
    print("  emitted: %d mids, %d boundaries, %d resyncs, %d skipped, "
          "%d x 2us, %d x 4us, %d other"
          % (rx.mids, rx.bnds, rx.resyncs, rx.skipped, rx.iv2, rx.iv4, rx.ivx))
    print("    preamble bits emitted: %2d  %s" % (len(pre), pre))
    print("    payload  bits emitted: %2d  %s" % (len(pay), pay))
    print("    bytes %02x %02x %02x   flag dmem[3] = %s"
          % (rx.d[0], rx.d[1], rx.d[2],
             'FM0' if rx.d[3] == 0 else 'FM1' if rx.d[3] == 1 else 'NO LOCK'))
    return rx


frame_bits = ''.join(str(b) for b in bits()[16:])
print("THE FRAME IN ARRIVAL ORDER: %s   (A5 3C 96, high bit first)" % frame_bits)
print("the preamble is %d zeros then %d ones; the frame starts at tick %d"
      % (PRE_ZEROS, PRE_ONES, FRAME_START_US))
print()
print("THE INTERVAL SEQUENCE, WHICH IS THE ONLY TIMING INFORMATION ON THE WIRE:")
a, b = show(1), show(0)
print("  whole stream, one for one: %s   <- the frame-start transition is"
      % (a == b))
print("  UNDONE: FM0 has 2us of extra run-up that FM1 does not, so over the")
print("  WHOLE stream the sequences differ in length. Over the PAYLOAD alone")
pa = [t[0] - t[0] for t in transitions(1, 16, 40)]
pb = [t[0] - t[0] for t in transitions(0, 16, 40)]
iv_a = [transitions(1, 16, 40)[i][0] - transitions(1, 16, 40)[i-1][0]
        for i in range(1, len(pa))]
iv_b = [transitions(0, 16, 40)[i][0] - transitions(0, 16, 40)[i-1][0]
        for i in range(1, len(pb))]
print("  they are equal interval for interval: %s (%d intervals, %d x 2us, %d x 4us)"
      % (iv_a == iv_b, len(iv_a), iv_a.count(2), iv_a.count(4)))
print()
print("THE ALGORITHM AS IT STANDS (the resync clears the history bit):")
for f in (1, 0):
    print(" %s" % ('FM0' if f else 'FM1'))
    emitted(f, 'old')
print()
print("THE PROPOSED ALGORITHM (the resync says UNKNOWN, and only the")
print("unambiguous 4 us gap may emit):")
for f in (1, 0):
        print(" %s" % ('FM0' if f else 'FM1'))
        emitted(f, 'trace')

# ---- the numbers the testbench's encoder self-check asserts -------------
print()
print("THE DERIVED NUMBERS for the testbench's self-check, MSB first:")
pa, pb = transitions(1, 16, 40), transitions(0, 16, 40)
iva = [pa[i][0] - pa[i-1][0] for i in range(1, len(pa))]
ivb = [pb[i][0] - pb[i-1][0] for i in range(1, len(pb))]
print("  payload only: %d intervals, %d of 2us, %d of 4us, and the two "
      "polarities are interval for interval identical: %s"
      % (len(iva), iva.count(2), iva.count(4), iva == ivb))
f = bits()[16:]
eq = sum(1 for i in range(len(f) - 1) if f[i] == f[i+1])
print("  a bit boundary transitions iff two adjacent bits are EQUAL: "
      "%d of the 23 adjacent pairs in the payload are equal" % eq)
print("  (so %d boundary transitions inside the payload, and %d mids)" %
      (eq, len(f)))
wa, wb = show(1), show(0)
print("  whole stream: %d + %d intervals, %d x 2us and %d x 4us"
      % (len(wa), len(wb), wa.count(2) + wb.count(2), wa.count(4) + wb.count(4)))
for f in (1, 0):
    tr = transitions(f)
    first4 = [(tr[i][0] - FRAME_START_US, tr[i - 1][0] - FRAME_START_US)
              for i in range(1, len(tr)) if tr[i][0] - tr[i - 1][0] == 4]
    print("  %s: the FIRST 4us gap ends at t=%d us of the frame, and it comes "
          "after t=%d us -- %d such gaps in the whole stream"
          % ('FM0' if f else 'FM1', first4[0][0], first4[0][1], len(first4)))
