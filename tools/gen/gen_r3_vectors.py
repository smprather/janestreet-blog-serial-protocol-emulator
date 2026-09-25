#!/usr/bin/env python3
"""gen_r3_vectors.py — turn the gui-worker's R3 golden package into the include
file the chip-side conformance testbench replays.

WHY A GENERATOR AND NOT A HAND-WRITTEN INCLUDE. The R2 conformance include
(`tb/r2-vectors/R2_CONFORMANCE_RUN.vh`) was written by hand from the manifest,
which means a regenerated package and a regenerated include could drift apart
with nothing noticing. Icarus cannot read JSON, so the per-vector preloads and
the per-step file names have to be emitted as Verilog — this script is the only
thing that decides what they say, and `--check` re-derives the file and fails
if the checked-in one differs. The manifest is the single source of truth; the
generated `.hex` package is never edited here.

IT ALSO VALIDATES THE PACKAGE, because a conformance harness that trusts its
input proves nothing. Every request frame is re-CRC'd (CRC-16/CCITT-FALSE over
every word but the last) and its length field is checked against the framing
rule for its opcode, and every response frame's length field is checked against
its byte count. The vector with a deliberately corrupt CRC therefore has its
corruption CONFIRMED rather than assumed — the point of the vector is that the
chip answers BAD_FRAME to those exact bytes.

Usage:
  python3 tools/gen/gen_r3_vectors.py            # write the include
  python3 tools/gen/gen_r3_vectors.py --check    # fail if it would change
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
VEC_DIR = REPO / "tb" / "r3-vectors"
MANIFEST = VEC_DIR / "manifest.json"
OUT = VEC_DIR / "R3_CONFORMANCE_RUN.vh"

# The request payload length each opcode's framing rule demands (pe_ctrl.v,
# S_LEN). -1 means the opcode has no length check of its own. Only the ops the
# R3 package actually uses matter, but the whole table is here so a future
# vector cannot slip past the check by using an op nobody listed.
OP_LEN = {
    0x10: -1,  # LOAD: bounded by the word count, not a fixed length
    0x11: 0,  # PING
    0x12: 0,  # READ_CPU
    0x13: 2,  # READ_IMEM (address, count)
    0x14: 2,  # READ_DMEM (byte address, byte count)
    0x15: 0,  # DUMP_CORE
    0x16: 1,  # CLEAR_FAULT (the mask)
    0x20: 1,  # TARGET
    0x21: 0,  # DEBUG_STEP
    0x22: 1,  # DEBUG_BP_SET (the address)
    0x23: 0,  # DEBUG_BP_CLR
    0x24: 0,  # DEBUG_STATUS
}

# pe_ctrl's sticky fault bits. R3 adds NO fault class; the R1 lifecycle is
# unchanged, which is why a malformed frame still latches one.
FAULT_CRC = 0x0002
FAULT_PROTOCOL = 0x0008

# The opcodes that can make the core execute an instruction. A vector that
# expects one of these to SUCCEED must not be model-frozen (see the freeze note
# in the emitted task); a refused one is fine, because no pulse is emitted.
STEP_OPS = {0x21}
STATUS_OK = 0


def crc16_ccitt_false(crc: int, byte: int) -> int:
    c = crc ^ (byte << 8)
    for _ in range(8):
        c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def crc_words(words: list[int]) -> int:
    """The CRC a frame carries: CCITT-FALSE over EVERY word but the last, the
    sync word included (pe_ctrl accumulates from S_SYNC)."""
    crc = 0xFFFF
    for w in words:
        crc = crc16_ccitt_false(crc16_ccitt_false(crc, (w >> 8) & 0xFF), w & 0xFF)
    return crc


def read_words(path: pathlib.Path) -> list[int]:
    data = [int(tok, 16) for tok in path.read_text().split()]
    if len(data) % 2:
        raise SystemExit(f"{path.name}: odd byte count {len(data)}")
    return [(data[i] << 8) | data[i + 1] for i in range(0, len(data), 2)]


def expected_faults(req: list[int], model_faults: int, step: str) -> int:
    """The sticky fault register after this step, derived from the golden bytes.

    The host's model has no sticky fault register, so `model_faults` is 0 on
    every step; the chip's R1 lifecycle is unchanged by R3, so a frame that
    fails its CRC latches FAULT_CRC and a frame whose length field contradicts
    its opcode latches FAULT_PROTOCOL. "No side effect" in the R3 contract
    means no step, no arming and no debug-register change — not "no fault",
    which is a pre-existing R1 behaviour this phase does not touch.
    """
    faults = model_faults
    if req[0] != 0xA55A:
        raise SystemExit(f"{step}: request does not start with the A55A sync")
    if crc_words(req[:-1]) != req[-1]:
        faults |= FAULT_CRC
    else:
        # The frame header is {version[15:12], opcode[11:4], target[3:0]}
        # (pe_ctrl S_HEADER), so the opcode is bits 11:4 -- NOT the high byte.
        if (req[1] >> 12) != 1 or (req[1] & 0x80):
            faults |= FAULT_PROTOCOL
        opcode = (req[1] >> 4) & 0xFF
        want = OP_LEN.get(opcode, -1)
        if want >= 0 and req[3] != want:
            faults |= FAULT_PROTOCOL
    return faults


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--check",
        action="store_true",
        help="fail if the generated include differs from the checked-in one (no write)",
    )
    args = ap.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    images = manifest["model_images"]
    vectors = manifest["vectors"]
    if len(vectors) != 14:
        raise SystemExit(f"expected the 14 contract vectors, got {len(vectors)}")

    out: list[str] = []
    w = out.append
    w("// R3_CONFORMANCE_RUN — generated from the gui-worker golden package")
    w(
        f"// ({MANIFEST.relative_to(REPO)}, {len(vectors)} vectors / "
        f"{sum(len(v['steps']) for v in vectors)} steps) by"
    )
    w("// tools/gen/gen_r3_vectors.py. DO NOT EDIT: `--check` re-derives it.")
    w("//")
    w("// Every request and response below is the HOST's own bytes, replayed")
    w("// through $readmemh and compared word for word, CRC included. Nothing")
    w("// here re-derives an expected response: the package IS the acceptance")
    w("// spec, and a step only says PASS when the chip's bytes match it.")
    w("//")
    w("// WHAT IS PRELOADED, AND WHY IT IS NOT A WEAKENING. The package's")
    w("// load_procedure says to preload each vector's model_images[] state and")
    w("// debug context; those pre-states are the host MODEL's snapshots, and")
    w("// several are not host-reachable at all (a core stopped on a breakpoint")
    w("// with a=0 has not executed the two LDI instructions that precede it).")
    w("// So the pre-state is driven onto the DUT's own registers, and what is")
    w("// asserted is the RESPONSE: the framing, the status, the payload layout,")
    w("// the byte order, the CRC and the state encoding. The logic that")
    w("// ESTABLISHES those states is a different harness's job — tb_pe_ctrl_r3")
    w("// (directed, written RED-first) with its 7-mutant gate, plus the S1-S4")
    w("// formal claims. Neither harness lets the other off the hook.")
    w("task automatic r3_run_all;")
    w("  begin")
    w('    $readmemh("../tb/r3-vectors/imem.hex", r3_imem_img);')
    w('    $readmemh("../tb/r3-vectors/dmem.hex", r3_dmem_img);')
    w("  end")

    total_steps = 0
    for idx, vec in enumerate(vectors, start=1):
        img = images[vec["model_image_id"]]
        st, dbg = img["state"], img["debug"]
        steps = vec["steps"]
        total_steps += len(steps)
        name = f"r3_v{idx:02d}"

        # A FREE-RUNNING core (run=1) cannot hold one pc for the ~1000 clocks a
        # frame takes, and worse, a vector that RELEASES the hold (BP_CLR) or
        # lands one steps past a release will race on: the chip answers with
        # wherever the core actually got to, while the golden models the instant
        # after the op. So the freeze covers the WHOLE vector whenever the strap
        # is high and nothing in the vector is expected to execute -- which is
        # not the same condition as "the pre-state is free-running" (v10 starts
        # held and is released mid-vector, and still needs it).
        runs_free = bool(st["run"])
        executes = any(s["opcode"] in STEP_OPS and s["status"] == 0 for s in steps)
        needs_freeze = runs_free and not executes
        if needs_freeze and any(s["opcode"] in STEP_OPS for s in steps):
            # A refused step emits no pulse, so a freeze cannot swallow it, but
            # say so rather than rely on it silently.
            refused_only = all(s["status"] != 0 for s in steps if s["opcode"] in STEP_OPS)
            if not refused_only:
                raise SystemExit(
                    f"{vec['name']}: strap high and a step is expected to "
                    f"execute - the model freeze would swallow it"
                )

        w(f"  // ---- {vec['name']} ({vec['obligation']}) ----")
        w(f"  begin : {name}")
        w(f'    r3_vector_begin("{vec["name"]}");')
        w(
            f"    // image {img['id']}: pc={st['pc']} run={st['run']} "
            f"bp_addr={dbg['bp_addr']} bp_en={int(dbg['bp_en'])} "
            f"bp_hit={int(dbg['bp_hit'])} hold={int(dbg['debug_hold'])}"
        )
        # The imem/dmem image: the package's sparse map over its own fill.
        for addr in sorted(img["imem"]["sparse"], key=int):
            w(f"    r3_imem[{addr}] = 16'h{img['imem']['sparse'][addr]:04x};")
        fill = img["imem"]["fill"]
        if fill:
            w(f"    // imem fill {fill:#04x} is the array's reset value")
        for addr in sorted(img["dmem"]["sparse"], key=int):
            w(f"    r3_dmem[{addr}] = 8'h{img['dmem']['sparse'][addr]:02x};")
        # A fault latched by an earlier vector would leak into this one, and
        # faults is a STICKY DUT register, so the only host-reachable way back
        # to the image's faults=0 is a real CLEAR_FAULT frame (R2's pattern).
        w("    r3_clear_faults();")
        w(
            f"    r3_preload_regs(10'd{st['pc']}, 8'h{st['a']:02x}, "
            f"8'h{st['x']:02x}, 8'h{st['y']:02x},"
        )
        w(
            f"                10'd{dbg['bp_addr']}, 1'b{int(dbg['bp_en'])}, "
            f"1'b{int(dbg['bp_hit'])}, 1'b{int(dbg['debug_hold'])});"
        )
        w(f"    r3_run_strap = 1'b{int(st['run'])};")
        if needs_freeze:
            w(
                f"    r3_freeze_arm(10'd{st['pc']}, 8'h{st['a']:02x}, "
                f"8'h{st['x']:02x}, 8'h{st['y']:02x});"
            )
        for sidx, step in enumerate(steps):
            req = read_words(VEC_DIR / step["request_file"])
            rsp = read_words(VEC_DIR / step["response_file"])
            # --- package self-checks (a conformance harness that trusts its
            # --- input proves nothing) ---
            if len(req) * 2 != step["request_bytes"]:
                raise SystemExit(
                    f"{step['name']}: request byte count disagrees with the manifest"
                )
            if len(rsp) * 2 != step["response_bytes"]:
                raise SystemExit(
                    f"{step['name']}: response byte count disagrees with the manifest"
                )
            if rsp[0] != 0xA55A:
                raise SystemExit(f"{step['name']}: response has no A55A sync")
            if rsp[3] != len(rsp) - 5:
                raise SystemExit(
                    f"{step['name']}: response length field "
                    f"{rsp[3]} but {len(rsp) - 5} payload words"
                )
            if rsp[4] != step["status"]:
                raise SystemExit(
                    f"{step['name']}: response status "
                    f"{rsp[4]} but the manifest says {step['status']}"
                )
            faults = expected_faults(req, step.get("model_faults", 0), step["name"])
            bad = (
                " (CRC is deliberately corrupt: FAULT_CRC expected)"
                if faults & FAULT_CRC
                else ""
            )
            w(
                f"    // step {sidx}: opcode 0x{step['opcode']:02x} "
                f"{step['opcode_name']}, expected faults 0x{faults:04x}{bad}"
            )
            w(f"    begin : {name}_s{sidx}")
            w(f'      $readmemh("../tb/r3-vectors/{step["request_file"]}", r2_req_mem);')
            w(f'      $readmemh("../tb/r3-vectors/{step["response_file"]}", r2_rsp_mem);')
            w(
                # BYTE counts, not word counts. The transport's signature is
                # (req_bytes, rsp_bytes): it sends with `i < req_bytes; i += 2`
                # and reads `rsp_bytes / 2`. Emitting len(req) here sent THREE
                # of the six words of a DEBUG_BP_SET frame and then switched to
                # reading, so the chip sat waiting for the rest of the payload
                # and answered nothing at all -- which is what this harness
                # reported, and what the PROVEN R2 transport reported too when
                # fed the same generated include. One word-vs-byte slip, and it
                # looked exactly like a chip that rejects the host's frames.
                f'      r3_step({2 * len(req)}, {2 * len(rsp)}, "{step["name"]}", '
                f"16'h{faults:04x});"
            )
            w("    end")
        if needs_freeze:
            w("    r3_freeze_disarm();")
        w("    r3_vector_end();")
        w("  end")

    w("endtask")

    text = "\n".join(out) + "\n"
    if args.check:
        if not OUT.exists():
            print(f"{OUT} is missing; run without --check", file=sys.stderr)
            return 1
        if OUT.read_text() != text:
            print(f"{OUT} is stale; run without --check", file=sys.stderr)
            return 1
        print(f"r3 conformance include: up to date ({total_steps} steps)")
        return 0
    OUT.write_text(text)
    print(
        f"wrote {OUT.relative_to(REPO)}: {len(vectors)} vectors, "
        f"{total_steps} steps, package CRC/length checks passed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
