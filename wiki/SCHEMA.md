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
- Raw sources are immutable: corrections go in wiki pages, never in `raw/`.

## Frontmatter
```yaml
---
title: Page Title
created: YYYY-MM-DD
updated: YYYY-MM-DD
type: entity | concept | comparison | query | decision
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

Rule: every tag on a page must appear in this taxonomy. Add new tags here first, then use them.

## Page Thresholds
- **Create a page** when a topic is central to the design or appears in 2+ sources
- **Add to existing page** when new info fits an existing topic
- **DON'T create a page** for passing mentions or one-off details
- **Split a page** when it exceeds ~200 lines
- **Archive a page** when fully superseded — move to `_archive/`, remove from index

## Update Policy
1. Check dates — newer sources generally supersede older ones
2. The Jane Street blog post outranks the Gemini transcript on competition facts
3. If genuinely contradictory, note both positions with dates and sources
4. Flag for review in the lint report
