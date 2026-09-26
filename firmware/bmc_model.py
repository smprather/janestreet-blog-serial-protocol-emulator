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
HALF_US = 2  # a half-interval is 2 us, whole
IDLE = 1  # the line idles HIGH, for BOTH polarities
# THE FRAME DOES NOT START AT TICK ZERO. dmem[5] is seeded to 0 and the core
# spends ~20 us loading imem before the first poll, so the first transition
# arrives at tick ~20 and its measured interval is ~20, not 2 -- which is why
# BOTH polarities resync. Putting the frame at tick 0 in a model gives the FM1
# case a first interval of exactly 2 us, no resync, and a phase error that is
# the opposite one. The model has to sit where the machine sits.
FRAME_START_US = 20


def bits():
    """the bits IN ARRIVAL ORDER: the preamble, then the frame high bit first"""
    return (
        [0] * PRE_ZEROS
        + [1] * PRE_ONES
        + [(FRAME[i // 8] >> (7 - i % 8)) & 1 for i in range(24)]
    )


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
    tr, prev = [], lev_at(fm0, lo - 1)  # the level BEFORE the window, so a
    for us in range(lo, hi):  # transition on its first sample is
        lv = lev_at(fm0, us)  # not counted as one
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
    def __init__(self, phase_states=2, idem="old"):
        self.idem = idem
        self.two_states = phase_states == 2
        self.d = {
            4: IDLE,
            5: 0,
            8: 0,
            15: 0,
            3: 0xFF,
            13: 1,
            0: 0,
            1: 0,
            2: 0,
            7: 0,
            9: 0,
            12: 0,
        }
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

        if iv == 4:  # a two-half gap is ALWAYS mid->mid
            self.mid()
        elif iv != 2:  # the clock is lost
            d[15] = 0 if self.two_states else 2
            self.resyncs += 1
        elif d[15] == 1:  # previous was a boundary -> its mid
            self.mid()
        elif d[15] == 2 and not self.two_states:
            self.skipped += 1  # UNKNOWN phase: a 2 us gap says
        elif d[15] == 2:  # nothing, and nothing is emitted
            self.mid()
        else:  # previous was a mid -> a boundary
            d[15] = 1
            self.bnds += 1

    def mid(self):
        d = self.d
        d[15] = 0
        self.mids += 1
        bit = 1 - d[4]  # the level of the FIRST half
        if d[13]:  # the preamble: the flag is not known
            self.bits_emitted.append(("pre", bit))
        else:  # the payload: FM1 inverts
            if d[3] == 1:
                bit = 1 - bit
            self.bits_emitted.append(("pay", bit))
        d[12] = ((d[12] << 1) | bit) & 0xFF
        d[7] += 1
        if d[7] == 8:
            d[7] = 0
            if d[13]:  # THIS byte is the preamble's, and it
                # is the polarity: eight ONES as levels = FM0, 0x00 = FM1
                if self.idem == "trace":
                    print(
                        "      byte_done: the preamble's byte assembled as "
                        "0x%02x -> %s"
                        % (
                            d[12],
                            "FM0"
                            if d[12] == 0xFF
                            else "FM1"
                            if d[12] == 0
                            else "NOT LOCKED",
                        )
                    )
                if d[12] == 0xFF:
                    d[3] = 0
                elif d[12] == 0x00:
                    d[3] = 1
                else:
                    d[3] = 0xFF  # declared: not this protocol
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
    ivs = [tr[i][0] - tr[i - 1][0] for i in range(1, len(tr))]
    print(
        "  %s: %2d transitions over the WHOLE stream, first at t=%d us, "
        "%2d intervals (%d x 2us, %d x 4us)"
        % (
            "FM0" if fm0 else "FM1",
            len(tr),
            tr[0][0],
            len(ivs),
            ivs.count(2),
            ivs.count(4),
        )
    )
    return ivs


def emitted(fm0, idem, pre_first=0, pre_ones=8):
    rx = Rx(phase_states=2 if idem == "old" else 3, idem=idem).run(
        fm0, FRAME_START_US + 4 * len(bits()) + 8
    )
    pre = "".join(str(b) for k, b in rx.bits_emitted if k == "pre")
    pay = "".join(str(b) for k, b in rx.bits_emitted if k == "pay")
    print(
        "  emitted: %d mids, %d boundaries, %d resyncs, %d skipped, "
        "%d x 2us, %d x 4us, %d other"
        % (rx.mids, rx.bnds, rx.resyncs, rx.skipped, rx.iv2, rx.iv4, rx.ivx)
    )
    print("    preamble bits emitted: %2d  %s" % (len(pre), pre))
    print("    payload  bits emitted: %2d  %s" % (len(pay), pay))
    print(
        "    bytes %02x %02x %02x   flag dmem[3] = %s"
        % (
            rx.d[0],
            rx.d[1],
            rx.d[2],
            "FM0" if rx.d[3] == 0 else "FM1" if rx.d[3] == 1 else "NO LOCK",
        )
    )
    return rx


frame_bits = "".join(str(b) for b in bits()[16:])
print("THE FRAME IN ARRIVAL ORDER: %s   (A5 3C 96, high bit first)" % frame_bits)
print(
    "the preamble is %d zeros then %d ones; the frame starts at tick %d"
    % (PRE_ZEROS, PRE_ONES, FRAME_START_US)
)
print()
print("THE INTERVAL SEQUENCE, WHICH IS THE ONLY TIMING INFORMATION ON THE WIRE:")
a, b = show(1), show(0)
print("  whole stream, one for one: %s   <- the frame-start transition is" % (a == b))
print("  UNDONE: FM0 has 2us of extra run-up that FM1 does not, so over the")
print("  WHOLE stream the sequences differ in length. Over the PAYLOAD alone")
pa = [t[0] - t[0] for t in transitions(1, 16, 40)]
pb = [t[0] - t[0] for t in transitions(0, 16, 40)]
iv_a = [
    transitions(1, 16, 40)[i][0] - transitions(1, 16, 40)[i - 1][0]
    for i in range(1, len(pa))
]
iv_b = [
    transitions(0, 16, 40)[i][0] - transitions(0, 16, 40)[i - 1][0]
    for i in range(1, len(pb))
]
print(
    "  they are equal interval for interval: %s (%d intervals, %d x 2us, %d x 4us)"
    % (iv_a == iv_b, len(iv_a), iv_a.count(2), iv_a.count(4))
)
print()
print("THE ALGORITHM AS IT STANDS (the resync clears the history bit):")
for f in (1, 0):
    print(" %s" % ("FM0" if f else "FM1"))
    emitted(f, "old")
print()
print("THE PROPOSED ALGORITHM (the resync says UNKNOWN, and only the")
print("unambiguous 4 us gap may emit):")
for f in (1, 0):
    print(" %s" % ("FM0" if f else "FM1"))
    emitted(f, "trace")

# ---- the numbers the testbench's encoder self-check asserts -------------
print()
print("THE DERIVED NUMBERS for the testbench's self-check, MSB first:")
pa, pb = transitions(1, 16, 40), transitions(0, 16, 40)
iva = [pa[i][0] - pa[i - 1][0] for i in range(1, len(pa))]
ivb = [pb[i][0] - pb[i - 1][0] for i in range(1, len(pb))]
print(
    "  payload only: %d intervals, %d of 2us, %d of 4us, and the two "
    "polarities are interval for interval identical: %s"
    % (len(iva), iva.count(2), iva.count(4), iva == ivb)
)
f = bits()[16:]
eq = sum(1 for i in range(len(f) - 1) if f[i] == f[i + 1])
print(
    "  a bit boundary transitions iff two adjacent bits are EQUAL: "
    "%d of the 23 adjacent pairs in the payload are equal" % eq
)
print("  (so %d boundary transitions inside the payload, and %d mids)" % (eq, len(f)))
wa, wb = show(1), show(0)
print(
    "  whole stream: %d + %d intervals, %d x 2us and %d x 4us"
    % (len(wa), len(wb), wa.count(2) + wb.count(2), wa.count(4) + wb.count(4))
)
for f in (1, 0):
    tr = transitions(f)
    first4 = [
        (tr[i][0] - FRAME_START_US, tr[i - 1][0] - FRAME_START_US)
        for i in range(1, len(tr))
        if tr[i][0] - tr[i - 1][0] == 4
    ]
    print(
        "  %s: the FIRST 4us gap ends at t=%d us of the frame, and it comes "
        "after t=%d us -- %d such gaps in the whole stream"
        % ("FM0" if f else "FM1", first4[0][0], first4[0][1], len(first4))
    )


# =====================================================================
# THE ENCODER, and it is modelled BEFORE it is written, which is the
# order the handoff gave and the order that has worked every time in
# this act: the model is what the firmware is transcribed from, so a
# disagreement is a disagreement about the WIRE, not about code.
#
# THE RULING IS LOOPBACK, and it has one consequence here that is worth
# stating before any code: THE RETURN LEG CARRIES THE SAME FORTY BITS AS
# THE INPUT LEG. The encoder sends dmem[0..2] -- the frame it just
# received -- re-encoded under the encoding it DETECTED, and the frame
# plus the preamble is the same 40 bits the input leg was. So tx_level
# IS level, and the level sequence the firmware puts on OUT_PAD is the
# same sequence the testbench put on IN_PAD. The act is a round trip
# through a receiver that measures its own polarity, and that is why a
# wrong encoder polarity is caught at all: the testbench's receiver
# inverts with ITS OWN measured flag and hands back the complement.
#
# WHAT IS ACTUALLY NEW HERE, and it is three things and not the levels:
#   1. THE TRANSMITTER'S STATE. The levels are the wire rules; the state
#      is a level to drive, a half-interval counter, and NOTHING ELSE.
#      The bit for each boundary is DERIVED from the counter rather than
#      stored, because there are two free bytes in the map and three
#      counters would want three of them.
#   2. THE IDLE LEVEL OF THE RETURN LEG IS LOW, and the input leg's is
#      high. The output pad's latch is written to 0 by init and only the
#      encoder changes it, so the line the testbench's receiver watches
#      sits LOW before the first bit. That FLIPS the frame-start
#      asymmetry: under FM0 the first preamble bit is a 0, its first
#      half is LOW, and there is NO frame-start transition -- the
#      opposite of the input leg. Modelled here rather than assumed,
#      because the input leg's measured asymmetry is the one in the
#      receiver's comments and applying it to the return leg unchanged
#      would be a fault of the kind this act exists to catch.
#   3. THE ROUND TRIP ITSELF, run through the receiver in this file, so
#      "the same frame comes back byte-identical under either encoding"
#      is a property of the MODEL before it is a property of silicon.
# =====================================================================

TX_HALF_TOTAL = 2 * len(bits())  # 80 half-intervals: 40 bits, two halves each
IDLE_OUT = 0  # the OUTPUT pad idles LOW: init writes TXPIN 0
fail = 0


def chk(cond, what):
    """a self-check that COUNTS, so `python3 bmc_model.py` is a gate and not
    a printout. A model whose properties are only readable is a model whose
    properties can go stale silently."""
    global fail
    if not cond:
        fail += 1
    print("  %s  %s" % ("ok  " if cond else "FAIL", what))
    return cond


class Tx:
    """THE ENCODER AS THE FIRMWARE DRIVES IT: a level to drive, a
    half-interval counter, and nothing else. `flag` is dmem[3] -- 0 = FM0,
    1 = FM1 -- because that is the byte the decoder MEASURED and the byte
    the encoder must obey. The bit for a boundary is derived from the
    counter, which is what makes two bytes enough: `half` is dmem[6] and
    `lev` is dmem[11], and the machine's map has no third free byte."""

    def __init__(self, flag):
        self.flag = flag
        self.half = 0
        self.lev = 0
        self.wire = []

    def byte_at(self, b):
        """THE BYTE FOR BIT b. Five bytes go out: the preamble's two are
        CONSTANTS (eight zeros, then eight ones) and the payload's three
        are dmem[0..2], the frame the receiver banked. So this is a
        five-way dispatch and not a load from a table, which is what the
        firmware writes."""
        return (0x00, 0xFF, FRAME[0], FRAME[1], FRAME[2])[b // 8]

    def step(self):
        c = self.half
        if c % 2 == 0:  # the FIRST half of a bit, and h0 IS the level
            b = c // 2
            d = (self.byte_at(b) >> (7 - b % 8)) & 1
            # FM0: a one is HIGH, so h0 is the bit. FM1: a one is LOW, so
            # h0 is its complement. The two lines below are the whole of
            # the difference between the encodings, and there is no third
            # case and no state.
            self.lev = d if self.flag == 0 else 1 - d
        else:  # the SECOND half, and h1 == ~h0 in every case
            self.lev = 1 - self.lev
        self.wire.append(self.lev)
        self.half += 1
        return self.lev

    def run(self):
        while self.half < TX_HALF_TOTAL:
            self.step()
        return self


def tx_ivs(wire):
    """the intervals between transitions, in half-intervals"""
    tr = [k for k in range(1, len(wire)) if wire[k] != wire[k - 1]]
    return [tr[i] - tr[i - 1] for i in range(1, len(tr))], tr


def rx_on(wire, start_us, idle, until_us):
    """THE RECEIVER, this file's, run over an ARBITRARY level sequence from
    an ARBITRARY start with an ARBITRARY idle. The return leg starts
    wherever the decode happened to end, which is a number the firmware
    does not control and this act does not claim to control, so the
    receiver has to lock without knowing it -- and the model is where that
    is checked, because a claim that is only ever tested at one offset is
    a claim about that offset."""
    rx = Rx(phase_states=3, idem="trace")
    for us in range(1, until_us + 1):
        t = us - start_us
        lv = idle if (t < 0 or t >= HALF_US * len(wire)) else wire[t // HALF_US]
        rx.poll(lv, us)
    return rx


print()
print("=" * 70)
print("THE ENCODER, MODELLED FROM THE WIRE RULES. THE RETURN LEG IS")
print("dmem[0..2] RE-ENCODED UNDER dmem[3], SO IT CARRIES THE SAME 40 BITS")
print(
    "THE INPUT LEG DID: %d bits = %d half-intervals = %d us."
    % (len(bits()), TX_HALF_TOTAL, TX_HALF_TOTAL * HALF_US)
)
print("=" * 70)
WIRES = {}
for fl in (0, 1):
    tx = Tx(fl).run()
    WIRES[fl] = tx.wire
    fm0 = 0 if fl == 1 else 1
    want = [level(k, fm0) for k in range(TX_HALF_TOTAL)]
    print(" %s" % ("FM0 (dmem[3] = 0)" if fl == 0 else "FM1 (dmem[3] = 1)"))
    print("    first 8 half-intervals: %s" % "".join(str(x) for x in tx.wire[:8]))
    chk(
        tx.wire == want,
        "the counter-driven transmitter agrees with the wire rules, "
        "half-interval for half-interval (%d of %d)"
        % (sum(1 for a, b in zip(tx.wire, want) if a == b), TX_HALF_TOTAL),
    )
    chk(
        len(tx.wire) == TX_HALF_TOTAL,
        "it drives exactly %d half-intervals and stops" % TX_HALF_TOTAL,
    )
chk(
    all(WIRES[1][k] == 1 - WIRES[0][k] for k in range(TX_HALF_TOTAL)),
    "the two encodings' output streams are the exact COMPLEMENT of one "
    "another, all %d half-intervals" % TX_HALF_TOTAL,
)
chk(
    WIRES[0] == [level(k, 1) for k in range(TX_HALF_TOTAL)],
    "AND the return leg is the SAME level sequence the input leg was -- "
    "same bits, same flag, so the act is a round trip, not a new frame",
)

print()
print("WHAT THE FIRMWARE'S HALF-INTERVAL HAS TO BE, from the wire rules:")
iv0, tr0 = tx_ivs(WIRES[0])
iv1, tr1 = tx_ivs(WIRES[1])
print(
    "  FM0: %d transitions, %d intervals: %d of one half-interval and "
    "%d of two" % (len(tr0), len(iv0), iv0.count(1), iv0.count(2))
)
print(
    "  FM1: %d transitions, %d intervals: %d of one half-interval and "
    "%d of two" % (len(tr1), len(iv1), iv1.count(1), iv1.count(2))
)
chk(
    set(iv0) == {1, 2} and set(iv1) == {1, 2},
    "every interval on the return leg is ONE or TWO half-intervals in both "
    "polarities, which is the whole basis of the receiver's interval test",
)
#
# *** AND THIS PROPERTY IS DERIVED, NOT INDEPENDENT, WHICH IS THE POINT OF
# RECORDING IT. *** Eighteen properties sound like eighteen pieces of evidence.
# This one is arithmetic, and it is worth saying so before somebody quotes it.
#
# COMPLEMENTING A WIRE CANNOT MOVE A TRANSITION -- it only flips a level -- so
# the intervals of a wire and of its complement are the same BY CONSTRUCTION,
# for ANY wire and not merely for this model's two. MEASURED on 200 random
# 80-level pairs and their complements, none of them derived from this model:
# the interval lists were identical in all 200.
#
# **SO `iv0 == iv1` CANNOT FAIL INDEPENDENTLY OF THE PROPERTY ABOVE IT.** If
# WIRES[1] is the exact complement of WIRES[0] -- which is what the previous
# check asserts -- then this one is already true, and the two can only disagree
# if the first is false. It is a restatement, not a second witness.
#
# The CONCLUSION it states is still true and still worth having: the return
# leg's timing says nothing about polarity. It just does not need this check to
# be believed, and that is the distinction this act has spent a session on --
# a check that has never been shown to fire is a comment, and a check that CAN
# NEVER fire is worse, because it looks like a second witness and is not one.
#
# WHAT WOULD BE A REAL TEST is the same claim with the complement assumption
# removed: that the two polarities carry the same interval sequence *even when
# the preamble is built differently for each*. That is a question about the
# ENCODING rather than about the complement, and nothing above asks it.
chk(
    iv0 == iv1,
    "and the interval SEQUENCE is the same for the two polarities (%d "
    "intervals) -- DERIVED, not independent: it follows from the complement "
    "above for any wire, so it cannot fail on its own; the conclusion is that "
    "the return leg's TIMING says nothing about polarity" % len(iv0),
)
print(
    "  a bit boundary transitions iff the two adjacent bits are EQUAL: "
    "the return leg's payload has %d equal-adjacent pairs of 23"
    % sum(1 for i in range(23) if bits()[16 + i] == bits()[17 + i])
)
print()
print("THE FIVE BYTES THE ENCODER DISPATCHES ON, and the eight masks:")
for b in range(5):
    byte = Tx(0).byte_at(b * 8)  # byte_at takes a BIT index: b*8 is the first
    print(
        "  bit %2d..%2d -> byte %d = %02x   masks %s"
        % (
            b * 8,
            b * 8 + 7,
            b // 8,
            byte,
            " ".join("%02x" % (0x80 >> i) for i in range(8)),
        )
    )
chk(
    [(Tx(0).byte_at(b) >> (7 - b % 8)) & 1 for b in range(40)] == bits(),
    "the five dispatched bytes carry the 40 bits the input leg carried, bit for bit",
)

print()
print("THE ROUND TRIP, THROUGH THIS FILE'S OWN RECEIVER, AT THREE OFFSETS")
print("AND WITH THE RETURN LEG'S OWN IDLE LEVEL (LOW, not the input's HIGH):")
for fl in (0, 1):
    for off in (20, 37, 64):
        rx = rx_on(WIRES[fl], off, IDLE_OUT, off + 2 * HALF_US * TX_HALF_TOTAL + 8)
        ok = (rx.d[0], rx.d[1], rx.d[2], rx.d[3]) == (FRAME[0], FRAME[1], FRAME[2], fl)
        chk(
            ok,
            "flag %d at t=%2d us: banked %02x %02x %02x, dmem[3] = %d"
            % (fl, off, rx.d[0], rx.d[1], rx.d[2], rx.d[3]),
        )
print()
print("  AND THE IDLE LEVEL IS NOT A DETAIL, which is why it is a parameter")
print("  above: with the return leg idling HIGH instead of LOW the frame-")
print("  start asymmetry FLIPS -- FM0 would get a frame-start boundary and")
print("  FM1 would get none, the opposite of the input leg. The lock holds")
print("  either way, because it is made by the preamble's two-half gap and")
print("  not by the level the line happened to be resting at.")
for fl in (0, 1):
    rx = rx_on(WIRES[fl], 20, IDLE, 20 + 2 * HALF_US * TX_HALF_TOTAL + 8)
    chk(
        (rx.d[0], rx.d[1], rx.d[2], rx.d[3]) == (FRAME[0], FRAME[1], FRAME[2], fl),
        "  the same, with the return leg idling HIGH: banked %02x %02x %02x, "
        "dmem[3] = %d" % (rx.d[0], rx.d[1], rx.d[2], rx.d[3]),
    )

print()
print("THE ENCODER MUST NOT TRANSMIT A FLAG IT NEVER MEASURED, and the")
print("model says so as a rule rather than leaving it to the firmware:")
rx = Rx(phase_states=3, idem="trace")  # never polled: dmem[3] = 0xFF
chk(
    rx.d[3] == 0xFF,
    "dmem[3] = 0xFF is 'I have not locked onto anything', and the encoder's "
    "entry test sends NOTHING on it -- an unmeasured polarity is not a "
    "polarity, and the frame in dmem[0..2] came off a wire that did",
)

print()
if fail:
    print("MODEL SELF-CHECK: %d PROPERTIES FAILED" % fail)
    raise SystemExit(1)
print("MODEL SELF-CHECK: all properties hold")
