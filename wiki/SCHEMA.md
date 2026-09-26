# Wiki Schema

## Domain
Protocol-emulator ASIC competition entry: a Tiny Tapeout (IHP 130nm CMOS5L) general-purpose protocol-emulator chip (PIO/PRU-style programmable bit-bang engine). Covers competition constraints, physical-layer reality, CDR/oversampling design, clocking, signoff methodology, shared-hardware architecture, and project decisions.

## Conventions
- File names: lowercase, hyphens, no spaces (e.g., `cdr-oversampling.md`)
- Every wiki page starts with YAML frontmatter (see below)
- Use `[[wikilinks]]` to link between pages (minimum 2 outbound links per page)
- When updating a page, always bump the `updated` date
- Every new page must be added to `index.md` under the correct section
- Every action must be appended to `log.md`
- **Provenance:** the Jane Street blog post is the primary source for competition facts and supersedes the Gemini transcript wherever they differ. Transcript-only claims (board/mux speed limits, cell counts) are marked `confidence: low` or `medium` until verified against Tiny Tapeout docs.
- **A source outranks another only if the CAPTURE is faithful.** Authority of origin does not survive a lossy transcription. Learned the hard way on 2026-09-20: the 2026-09-17 ingest recorded a hand-written *summary* of the competition blog, got the tile allocation wrong (8x4 for the blog's 6x4), and that paraphrase was then used to rule a *correct* transcript claim stale. Before letting source A overrule source B, check that what you hold of A is A's text.
- **Keep the full text of any source the wiki's facts depend on**, under `raw/`, with a `sha256:` of the fetched bytes in the frontmatter. A summary is a derived work and belongs in a wiki page, not in `raw/`. See `raw/articles/janestreet-competition-blog-fulltext.md`.
- **Mark living sources as living.** The competition blog says it will be updated if the tile allocation changes. Re-fetch and diff such pages periodically rather than treating one ingest as permanent.
- Raw sources are immutable: corrections go in wiki pages, never in `raw/`. A superseding capture is a NEW file, not an edit to the old one.

## Frontmatter
```yaml
---
title: Page Title
created: YYYY-MM-DD
updated: YYYY-MM-DD
type: entity | concept | comparison | query | decision | reference | plan
tags: [from taxonomy below]
sources: [raw/articles/source-name.md]
confidence: high | medium | low
---
```

## Tag Taxonomy
- competition, constraint, area-budget, process-node
- physical-layer, gpio, protocol
- cdr, oversampling, clocking, pvt
- signoff, sta, spice
- architecture, verification
- decision
- plan
- tooling
- reference

### Extended 2026-09-25 (manager ruling)

The list above was twenty entries and the wiki had outgrown it: **23 distinct
tags were in active use across nine pages and none of them was in the
taxonomy.** That is a defect in the taxonomy, not twenty-three defects in nine
pages — the tags were descriptive, consistent and obviously useful, so they
were added rather than removed.

The same three groups as above, extended. **Every bullet below contains only
comma-separated tags, with no prose**, because `regress/check_wiki_pages.sh`
parses this section: a parenthetical left inside a bullet would be read as a
tag. Commentary goes in the paragraphs, never in the list.

Physical layer and the pin budget:

- physical-layer, gpio, protocol, pads, pinout, wrapper

Time:

- cdr, oversampling, clocking, pvt, timing

Signoff and physical implementation:

- signoff, sta, spice, floorplan

Architecture and the evidence around it:

- architecture, verification, status, observability, integration

The host bus and its tooling:

- host-controller, loader, boot, debug, gui, pico, firmware

Housekeeping:

- reference, planning

The individual protocol surfaces, kept distinct from `protocol` itself, which
is the general claim that a protocol is a program:

- ethernet, spi, usb, codec, serdes, tx, protocol-emulation

That is 43 tags: the original 20 plus these 23.

Rule: every tag on a page must appear in this taxonomy. Add new tags here
first, then use them.

**This list is now enforced.** `regress/check_wiki_pages.sh` reads the
taxonomy **out of this file** rather than hard-coding it, scoping its parse to
the `## Tag Taxonomy` section, so the taxonomy and the gate cannot disagree:
extending the taxonomy here and extending the gate are the same edit, and a
tag added to a page but not to this file is red on the next regression. That
coupling is the point — a rule nothing checks is a wish, and this project has
been bitten by that shape enough to stop writing them.

## Page Thresholds
- **Create a page** when a topic is central to the design or appears in 2+ sources
- **Add to existing page** when new info fits an existing topic
- **DON'T create a page** for passing mentions or one-off details
- **Split a page** when it exceeds ~200 lines
- **Archive a page** when fully superseded — move to `_archive/`, remove from index
- **A plan page** (`plans/`, type `plan`) is a forward-looking work plan with a definition
  of done and an ordered work list. Update it in place as steps complete; when the
  milestone lands, the durable findings move into concepts/reference/decisions and the
  plan's status line records that it is done.

## Update Policy
1. Check dates — newer sources generally supersede older ones
2. The Jane Street blog post outranks the Gemini transcript on competition facts
3. If genuinely contradictory, note both positions with dates and sources
4. Flag for review in the lint report
