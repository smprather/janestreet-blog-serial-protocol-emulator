# Submission readiness — judge-eye audit (2026-09-25)

**Auditor:** `gui-worker`. **Scope:** how a competition judge (or a judge
reading the repo cold, with no context) finds and trusts this entry. This is
the host branch's view; chip-repo documentation issues are listed for the
manager rather than fixed here.

**Method:** followed the path a judge actually walks — land on `README.md`,
skim the status claim, follow the "what exists / quick start" links, then the
demo walkthrough, and check every number against the artifacts that back it.

---

## Scorecard

| Area | Score | Note |
|---|---|---|
| Entry point (README) | **B** | Clear pitch, Tiny Tapeout framing, honest "what exists" list — but the top status block **predates** the landed 10BASE-T TX path and the R1/R2 host bus (fixed below). |
| Licensing | **A** | MIT, present at the root with a copyright line. |
| Submittability metadata | **A** | `info.yaml` and `rtl/tt_um_protocol_emulator.v` present and self-describing. |
| Reproducibility | **A** | `regress/run_all.sh` one-command regression; host side has `tools/host_gui/run_host_tests.sh` (exit 0, ten checks). |
| Demo story | **A−** | `docs/demo-walkthrough.md` gives a judge the four protocol acts with a per-claim proven/simulated/pending table and a no-board fallback. One stale number (fixed below). |
| Honesty of claims | **A** | Proven vs simulated vs pending is explicit everywhere; the R2 read path is marked chip-confirmed-in-simulation with the hardware run explicitly not claimed. |
| Cross-references | **B−** | A few bare filenames in the walkthrough (`uart_echo.pe`, `main.py`, `R2-READ-PATH-REVIEW.md`) are ambiguous without their directory; the R2 review lives in the **chip** repo, not this one. |
| Wiki as entry point | **B+** | `wiki/index.md` is a clear catalog; `wiki/STATUS.md` carries the live work list. Both a little stale relative to the host work (managed by the chip side). |
| Host-controller story | **A−** | Bridge is MicroPython-verified (five deployment blockers found and fixed), the R2 read contract is 18/18 chip-confirmed, liveness surfaces in the GUI — all recorded, none overclaimed. |

**Overall: strong submission.** The demo is real, the claims are honest, and
the one thing a judge cannot yet see (a physical board run) is the one thing
the docs say is not done. The gaps below are polish, not substance.

---

## Issues found (and what I did about them)

### Fixed in this repo (host-owned)

1. **README status block was stale** — it claimed the core "runs UART, SPI mode
   0, and a complete I2C write/read transaction ... integrates 10BASE-T receive
   hardware", which understates the landed work (10BASE-T **TX** and the
   framed host bus R1/R2 are now on the chip). Corrected to name the full
   current set without overclaiming, pointing at the host controller section
   and the demo walkthrough.
2. **Demo walkthrough regression line was stale** — it quoted "10 mutation
   suites"; the chip record now says 12. Corrected to 12 and kept the
   `run_all` reference.
3. **Ambiguous bare filenames in the walkthrough** — `uart_echo.pe` → the
   `firmware/` path; `main.py` → the bridge module; `R2-READ-PATH-REVIEW.md` →
   annotated as living in the chip repo, so a judge does not hunt for it here.

### Reported to the manager (chip-repo doc issues — not mine to edit)

4. **`wiki/index.md` is dated 2026-09-23** ("Last updated") and its "31 pages"
   count does not reflect the new host docs or the R2 review. The chip STATUS
   and index are the chip manager's to keep current.
5. **The R2 read-path review lives only in the chip repo**
   (`reviews/2026-09-25/R2-READ-PATH-REVIEW.md`). The host package cites it
   across a repo boundary; a judge starting from *this* repo cannot click
   through to it. Suggest a one-line pointer in the chip `wiki/STATUS.md` or
   `HANDOFF.md` to the host package (`reviews/2026-09-25/R2-READ-PATH-REVIEW`
   mirrored or linked) — but that is a chip-repo edit for the manager.

---

## What a judge should be able to verify in under five minutes

```bash
./regress/run_all.sh --fast          # chip: 34/34 RTL, 26/26 firmware, exit 0
tools/host_gui/run_host_tests.sh     # host: 233 tests + lint + fuzz + acceptance, exit 0
python3 tools/fw/peemu.py firmware/uart_echo.hex --send "41 42"   # firmware, ~2 s
python3 tools/host_bridge/acceptance.py --fake   # end-to-end, no hardware, exit 0
```

Each is one command with a stated pass/fail. These were re-run verbatim on a
fresh clone of the GitHub remote in `docs/cold-clone-audit.md`. The demo
walkthrough (`docs/demo-walkthrough.md`) is the narrative that ties them
together, and its no-board fallback means a judge without a dev board still
sees the whole story.

---

## Assessment

The entry is judge-ready in substance: a working firmware-protocol chip, an
open one-command regression, a real (if hardware-gated) host controller, and
documentation that is unusually careful about what is proven versus pending.
The two doc-staleness issues I own are fixed in this commit; the two chip-repo
doc issues are reported above for the manager. Nothing found here undermines a
claim — the walkthrough's proven/simulated/pending table held up under audit.
