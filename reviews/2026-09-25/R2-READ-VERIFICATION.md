# R2 read-path verification package (host contract, NOT chip-confirmed)

This is the **R2 acceptance spec** for the chip side, handed over by the
gui-worker so the protocol worker can wire `tb_pe_host.v` (and the R2 RTL in
`pe_ctrl.v` / `pe_soc.v` / `pe_imem.v` / `pe_cpu.v`) against exact golden
values instead of re-deriving the contract.

- **`R2-READ-VERIFICATION.json`** — the vectors. Every step carries the exact
  framed request bytes (`request_hex`), the request payload words, the response
  bytes (`response_hex`), the response payload words, the status code, and the
  model's fault bits after the step.
- Regenerate / drift-check:
  `python3 -m tools.host_gui.r2_vectors --write` and `--check`.
  The checked-in JSON must match a fresh build (a test enforces this), so the
  artifact can never silently disagree with the host model.

## Status: NOT chip-confirmed

Every vector carries `"chip_confirmed": false`. These are the **agreed
expectations** the chip read path must satisfy, derived from the host's
`FakePE` model — they are the gate, not evidence that the RTL passes it. The
R2 read path is chip-side work under the chip manager's dispatch; when it lands,
the same vectors are driven against real RTL and `chip_confirmed` flips only
with that run as evidence.

## Manager RULINGs encoded (2026-09-25)

1. **An out-of-range READ answers `RANGE` (3) _and_ latches sticky
   `FAULT_RANGE` (0x4).** `CLEAR_FAULT` with mask `0x4` clears it. See the
   `read_range_fault_lifecycle` vector: `bad_read_answers_range` →
   `status_shows_sticky_fault` (faults=`0x0004`) → `clear_fault_clears_the_bit`
   (faults=`0x0000`).
2. **READ payload is low-word-first, ascending**, matching LOAD's stream:
   `READ_IMEM(1, 2)` returns `status, 0x1001, 0x4002` in that order;
   `READ_DMEM(0, 4)` returns `status, 0x0A0B, 0x0C0D` (bytes packed
   big-endian per word).

## Wire contract the frames assume

- 16-bit words, MSB-first on the wire, `CS_N` low for a frame; sync `16'hA55A`;
  header `{version[3:0]=1, opcode[7:0], target[3:0]=0}`; sequence; 16-bit
  payload length; CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`, no
  reflection, no final XOR) over all preceding words.
- Responses set bit 7 of the opcode, echo the sequence and target, and carry the
  status as the first payload word: `0=OK, 1=BUSY, 2=BAD_FRAME, 3=RANGE,
  4=FAULT, 5=UNSUPPORTED, 6=NOT_READY`.
- Memory sizes: IMEM 1024 words, DMEM 16 bytes. Past-the-end reads are `RANGE`,
  never wrapped (the `range_never_wraps` vector: `READ_IMEM(1023,1)` reads the
  last word; `READ_IMEM(1023,2)` and `READ_DMEM(15,2)` are `RANGE`).

## The obligations, in vector form

| Vector | Obligation the chip must satisfy |
|---|---|
| `read_imem_bounded` | `READ_IMEM` returns the requested `address..address+count` words, ascending. |
| `read_dmem_bounded` | `READ_DMEM` returns the requested byte range packed big-endian per word. |
| `dump_core_header` | `DUMP_CORE` while stopped equals the `STATUS` register header. |
| `read_cpu_non_halting` | `READ_CPU` answers while `run=1` and exposes full-width `pc/a/x/y/insn` (R2 removes the 8-bit `dbg_pc`/`dbg_a` truncation). |
| `full_width_debug_regs` | The same full-width `READ_CPU` header, pinned word for word (the anti-truncation vector). |
| `read_while_running_rejected` | `READ_IMEM`/`READ_DMEM`/`DUMP_CORE` answer `NOT_READY` (6) while `run=1` (chip-side rejection, not just the Pico). |
| `range_never_wraps` | Past-the-end reads are `RANGE` (3), never wrapped. |
| `read_range_fault_lifecycle` | A bad read latches sticky `FAULT_RANGE`; `STATUS` shows it; `CLEAR_FAULT` clears it. |

## How to consume it in a Verilog testbench

Each `steps[].request_hex` is a full frame in hex; feed its bytes to the PE
SPI slave (or capture the Pico's `host_spi_transfer` input) and assert the
returned bytes equal `response_hex` — or assert the decoded
`response_payload_words` word for word. `model_faults` is the expected sticky
fault register after the step, which is how the lifecycle vector pins the
latch/clear behaviour. `opcode_name` gives the plan opcode (e.g. `OP_READ_IMEM`
= `0x13`).

Related records: `HOST-GUI-R2-PREP.md` (the host-side prep this package is
exported from), `wiki/plans/host-controller-gui.md` Tasks 3-5, and
`reviews/2026-09-24/HOST-CONTROLLER-PLAN-REVIEW.md` rows P16/P17.
