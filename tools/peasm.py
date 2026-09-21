#!/usr/bin/env python3
"""Assembler for pe_cpu (rtl/pe_cpu.v). One pass, 16 opcodes, no linking.

    python3 tools/peasm.py firmware/uart_echo.pe                 # -> .hex on stdout
    python3 tools/peasm.py firmware/uart_echo.pe -o firmware/uart_echo.hex
    python3 tools/peasm.py firmware/uart_echo.pe --listing       # addr + bytes + src
    python3 tools/peasm.py firmware/uart_echo.pe --rtl-init      # imem initialiser

The ISA is deliberately tiny, so this is deliberately small: a table of
mnemonics, an immediate encoder, and a two-pass label resolver. If the assembler
needs a feature the ISA does not have, that is a sign the ISA is wrong.

Syntax
    label:                    a label on its own line
    MNEMONIC operands         ; comment
    ; full-line comment

Labels are resolved in a second pass, so forward references are fine.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# opcode nibble, operand kind
#   'none'  no operand
#   'imm8'  raw 8-bit immediate
#   'imm4'  raw 4-bit immediate (io port)
#   'addr8' 8-bit code address (label or literal)
#   'sel2'  MOV selector
#   'alu'   ALU sub-op + imm8
MNEMONICS: dict[str, tuple[int, str]] = {
    "LDI":  (0x0, "imm8"),
    "OUT":  (0x1, "out_port"),
    "IN":   (0x2, "in_port"),
    "MOV":  (0x3, "mov_sel"),
    "JMP":  (0x4, "addr8"),
    "JZ":   (0x5, "addr8"),
    "JNZ":  (0x6, "addr8"),
    "ADD":  (0x7, "alu"),
    "SUB":  (0x7, "alu"),
    "AND":  (0x7, "alu"),
    "OR":   (0x7, "alu"),
    "INCX": (0x8, "none"),
    "DECX": (0x9, "none"),
    "SHR":  (0xA, "none"),
    "LDS":  (0xB, "none"),
    "STS":  (0xC, "none"),
    "LDM":  (0xD, "ldm_arg"),
    "STM":  (0xE, "stm_arg"),
    "NOP":  (0xF, "none"),
}

ALU_SUB = {"ADD": 0, "SUB": 1, "AND": 2, "OR": 3}

# Symbolic IO port names -> port number. The firmware writes IN A, RXSTAT
# rather than IN A, 3; the map lives here so it matches the RTL's memory map.
PORTS: dict[str, int] = {
    "PIN": 0x0,      # input pin level
    "TXPIN": 0x1,    # output pin level
    "TIMER": 0x5,    # free-running tick counter
    "STATUS": 0x7,   # bit0 = a tick happened (cleared by the read)
}

MOV_SEL = {
    "A,Y": 0, "A<-Y": 0, "AY": 0,
    "Y,A": 1, "Y<-A": 1, "YA": 1,
    "X,A": 2, "X<-A": 2, "XA": 2,
    "A,X": 3, "A<-X": 3, "AX": 3,
}

# A few constants the firmware leans on; resolved like ports.
CONSTS: dict[str, int] = {
    "RX_VALID": 0x1, "RX_BUSY": 0x2,
    "RX_START": 0x1, "RX_CLR": 0x2,
    "LSB_FIRST": 0x1,
    "TRUE": 1, "FALSE": 0,
}


# Target sizing. These are the pe_uart_soc defaults and they are what makes
# the range checks below meaningful: every field in this ISA is narrower than
# the immediate that can be written into it, so without a check the assembler
# silently truncates and emits a program that runs wrong.
#
# The four that actually bite:
#   * the program counter is 8-bit but instruction memory is IMEM_WORDS deep,
#     so word 128 aliases onto word 0 at run time;
#   * a jump target is encoded in 8 bits and truncated to the memory's address
#     width, so `JMP 200` lands somewhere unrelated;
#   * LDM's bit 7 is a DESTINATION SELECTOR (A vs X), so `LDM A, 128` assembles
#     as `LDM X, 0`;
#   * data addresses wider than DMEM_BYTES wrap into occupied slots.
# Target sizing. IMEM_WORDS moved 128 -> 1024 with the SRAM swap
# (decisions/adr-004-program-counter-width.md); the jump-target field
# widened with it, because an 8-bit target cannot name word 1023.
IMEM_WORDS = 1024
DMEM_BYTES = 16
IO_PORTS = 16
# Jump targets are encoded in the operand's low bits. The PC is
# clog2(IMEM_WORDS) wide (min 8), so the field is that many bits.
PCW = max(8, (IMEM_WORDS - 1).bit_length())


class AsmError(Exception):
    pass


def check_range(value: int, limit: int, what: str, tok: str) -> int:
    """Reject a field that does not fit its hardware. `limit` is exclusive."""
    if not 0 <= value < limit:
        raise AsmError(
            f"{what} {tok} = {value} is out of range (0..{limit - 1}); "
            f"the field is truncated in hardware, so this would assemble "
            f"clean and run wrong")
    return value


def strip_a(tok: str, what: str) -> str:
    """Drop a leading 'A,' from an operand. LDI A, 5 / OUT A, 1 / LDS A read
    better than the bare forms, and the destination is always A for these
    mnemonics -- the register name is documentation, not information."""
    t = tok.strip()
    if "," in t:
        head, _, tail = t.partition(",")
        if head.strip().upper() == "A":
            return tail.strip()
        raise AsmError(f"{what} takes a single A destination (got {tok!r})")
    return t


def parse_imm(tok: str, table: dict[str, int] | None = None) -> int:
    tok = tok.strip()
    if table and tok.upper() in table:
        return table[tok.upper()]
    if tok.upper() in PORTS:
        return PORTS[tok.upper()]
    try:
        if tok.lower().startswith("0x"):
            return int(tok, 16)
        if tok.startswith("%"):
            return int(tok, 2)
        return int(tok, 10)
    except ValueError as exc:
        raise AsmError(f"cannot parse immediate {tok!r}") from exc


def assemble(src: str) -> tuple[list[int], list[tuple[int, str, str]]]:
    """Returns (words, listing). Listing rows are (addr, hex, source-text)."""
    lines = src.splitlines()
    labels: dict[str, int] = {}

    # ---- pass 1: addresses + labels ------------------------------------
    items: list[tuple[int, str, str]] = []   # (addr, mnemonic, operands)
    addr = 0
    for lineno, raw in enumerate(lines, 1):
        line = raw.split(";")[0].strip()
        if not line:
            continue
        while ":" in line:
            label, _, rest = line.partition(":")
            label = label.strip()
            if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", label):
                break
            if label in labels:
                raise AsmError(f"line {lineno}: duplicate label {label!r}")
            labels[label] = addr
            line = rest.strip()
            if not line:
                break
        if not line:
            continue
        parts = line.split(None, 1)
        mnem = parts[0].upper()
        ops = parts[1].strip() if len(parts) > 1 else ""
        if mnem not in MNEMONICS:
            raise AsmError(f"line {lineno}: unknown mnemonic {mnem!r}")
        items.append((addr, mnem, ops))
        addr += 1

    # ---- pass 2: encode -------------------------------------------------
    words: list[int] = []
    listing: list[tuple[int, str, str]] = []
    for a, mnem, ops in items:
        opcode, kind = MNEMONICS[mnem]
        arg = 0
        try:
            if kind == "none":
                # Ops that implicitly act on A accept "SHR A" as documentation
                # ("SHR" alone is equivalent); anything else is an error.
                leftover = ops.strip().upper().replace(" ", "")
                ok = {"", "A"}
                if mnem == "LDS":
                    ok |= {"A,[X]", "[X]", "A"}
                if mnem == "STS":
                    ok |= {"[X],A", "[X]", "A"}
                if leftover not in ok:
                    raise AsmError(f"{mnem} takes no operands (got {ops!r})")
            elif kind == "imm8":
                arg = parse_imm(strip_a(ops, mnem), CONSTS) & 0xFF
            elif kind == "out_port" or kind == "in_port":
                # forms: "OUT TXPIN, A" / "IN A, PIN" / "OUT TXPIN" / "IN PIN"
                toks = [t.strip() for t in ops.split(",")]
                if len(toks) == 2:
                    if toks[0].upper() == "A":
                        port_tok = toks[1]
                    elif toks[1].upper() == "A":
                        port_tok = toks[0]
                    else:
                        raise AsmError(f"{mnem} needs A as one operand (got {ops!r})")
                elif len(toks) == 1:
                    port_tok = toks[0]
                else:
                    raise AsmError(f"{mnem} form is '{mnem} A, PORT' (got {ops!r})")
                arg = check_range(parse_imm(port_tok, CONSTS), IO_PORTS,
                                  "IO port", port_tok)
            elif kind == "mov_sel":
                key = re.sub(r"\s+", "", ops).upper()
                if key not in MOV_SEL:
                    raise AsmError(f"MOV selector {ops!r} is not one of "
                                   f"{sorted(set(MOV_SEL))}")
                arg = MOV_SEL[key]
            elif kind == "addr8":
                tok = ops.strip()
                if tok in labels:
                    arg = labels[tok]
                else:
                    arg = parse_imm(tok, CONSTS)
                # The jump target is encoded in the operand field, which is as
                # wide as the PC (PCW bits, min 8). A target past the end of
                # instruction memory is not "high memory" -- it is a different
                # instruction, because the PC only has PCW bits.
                check_range(arg, IMEM_WORDS, "jump target", tok)
                # ...and it must also fit the FIELD. At IMEM_WORDS=1024 both are
                # 10 bits so they agree, but a depth that is not a power of two
                # would make clog2(IMEM_WORDS) > bits needed, and the wider of
                # the two is the real limit. Fail loudly rather than truncate.
                check_range(arg, 1 << PCW, "jump target field", tok)
            elif kind == "alu":
                # forms: "AND A, 1" / "AND 1" / "ADD A, A" (register form is
                # not in the ISA -- the assembler rejects it explicitly rather
                # than silently encoding nonsense)
                key = re.sub(r"\s+", "", strip_a(ops, mnem)).upper()
                if not key:
                    raise AsmError(f"{mnem} needs an immediate or X")
                # Only X is addressable as the ALU's second operand (arg[9]).
                # Y is not, deliberately: one register is enough for the
                # timer-delta idiom, and Y stays free as the snapshot.
                if key == "X":
                    arg = (ALU_SUB[mnem] << 10) | (1 << 9)
                elif re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", key):
                    raise AsmError(
                        f"{mnem} second operand must be an immediate or X "
                        f"(got {key!r}); register-register is not in this ISA")
                else:
                    arg = (ALU_SUB[mnem] << 10) | (parse_imm(key, CONSTS) & 0xFF)
            elif kind == "ldm_arg":
                # LDM A, addr8  -> loads A
                # LDM X, addr8  -> loads X (arg[7]=1; only 4 address bits used)
                toks = [t.strip() for t in ops.split(",")]
                dest = "A"
                imm = None
                if len(toks) == 2:
                    dest, imm = toks[0].upper(), toks[1]
                elif len(toks) == 1:
                    imm = toks[0]
                else:
                    raise AsmError(f"LDM form is 'LDM A|X, addr8' (got {ops!r})")
                v = parse_imm(imm, CONSTS)
                if dest not in ("A", "X"):
                    raise AsmError(f"LDM destination must be A or X (got {dest!r})")
                # Bit 7 of the operand selects X as the destination, so an
                # address of 128 or more is not addressable at all -- it would
                # re-encode `LDM A` as `LDM X`. DMEM_BYTES is the real limit
                # and it is far below 128 anyway.
                check_range(v, DMEM_BYTES, "data address", imm)
                arg = (1 << 7) | (v & 0x0F) if dest == "X" else v & 0xFF
            elif kind == "stm_arg":
                # STM addr8, A
                toks = [t.strip() for t in ops.split(",")]
                if len(toks) == 2 and toks[1].upper() == "A":
                    imm = toks[0]
                elif len(toks) == 1:
                    imm = toks[0]
                else:
                    raise AsmError(f"STM form is 'STM addr8, A' (got {ops!r})")
                arg = check_range(parse_imm(imm, CONSTS), DMEM_BYTES,
                                  "data address", imm)
        except AsmError as exc:
            raise AsmError(f"addr {a:3d} ({mnem} {ops}): {exc}") from exc

        word = (opcode << 12) | (arg & 0x0FFF)
        words.append(word)
        listing.append((a, f"{word:04X}", f"{mnem} {ops}".strip()))

    if len(words) > IMEM_WORDS:
        raise AsmError(
            f"program is {len(words)} words and instruction memory holds "
            f"{IMEM_WORDS}; the program counter aliases word {IMEM_WORDS} "
            f"onto word 0, so the overflow does not fail loudly at run time. "
            f"See wiki/plans/through-i2c.md Blocker 3 for the SRAM swap.")
    return words, listing


def rtl_init(words: list[int], width: int = 128) -> str:
    """A Verilog initialiser for the SoC's instruction memory."""
    padded = words + [0xF000] * (width - len(words))     # NOP fill
    body = ", ".join(f"16'h{w:04X}" for w in padded[:width])
    return f"  initial $readmemh_unused;\n  // {len(words)} words used of {width}\n  {body}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=None)
    ap.add_argument("--listing", action="store_true")
    ap.add_argument("--rtl-init", action="store_true",
                    help="emit a Verilog register init instead of hex")
    ap.add_argument("--vh", action="store_true",
                    help="emit a Verilog $readmemh include file (one word per line)")
    args = ap.parse_args()

    try:
        words, listing = assemble(args.source.read_text(encoding="utf-8"))
    except AsmError as exc:
        print(f"peasm: {exc}", file=sys.stderr)
        return 1

    if args.listing:
        for a, hx, txt in listing:
            print(f"{a:3d}  {hx}  {txt}")
        print(f"--- {len(words)} words "
              f"({len(words) * 2} bytes of instruction memory)", file=sys.stderr)

    if args.rtl_init:
        out = rtl_init(words)
    elif args.vh:
        out = "\n".join(f"{w:04x}" for w in words)
    else:
        out = "\n".join(f"{w:04x}" for w in words)

    if args.out:
        args.out.write_text(out + "\n", encoding="utf-8")
        print(f"wrote {args.out} ({len(words)} words)", file=sys.stderr)
    elif not args.listing:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
