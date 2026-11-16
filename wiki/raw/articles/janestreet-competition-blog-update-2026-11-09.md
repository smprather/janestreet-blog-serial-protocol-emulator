---
source_url: https://blog.janestreet.com/protocol-emulator-asic-competition/
ingested: 2026-11-10
sha256: 3e9ae6ad0a23d4b2c8bdcc6c8c03a710603f4a615e58edbd0de3f15bb314629e
capture: changed sections verbatim (2026-11-09 update, rules, area, FAQ, timeline)
supersedes: raw/articles/janestreet-competition-blog-fulltext.md for the tile allocation, template branch, and FAQ; the original capture remains the source for the rest
---

# Jane Street competition blog — 2026-11-09 update

> **DO NOT CHANGE THE TEXT BELOW THIS BLOCK.** This is a verbatim capture of the
> changed sections of a primary source, fetched 2026-11-10. The `sha256` above is
> of the full HTML bytes fetched that day. `wiki/SCHEMA.md` rules raw sources
> immutable: corrections go in wiki pages, never here; a later change is a NEW
> capture file, not an edit. The original full text remains at
> [[raw/articles/janestreet-competition-blog-fulltext]] and is superseded only on
> the points captured here.

---

**Update November 9th:** 8x4 tiles are now confirmed for the March 2027 shuttle, and the
Tiny Tapeout Verilog template targets CMOS5L on its main branch. We’ve updated the rules below and added
an [FAQ](#faq) with answers to the most common questions we’ve been getting.

## The rules

- **Process:** We’re targeting IHP’s 130nm CMOS5L process through our friends at [Tiny Tapeout](https://www.tinytapeout.com/). Start with the [Tiny Tapeout IHP Verilog template](https://github.com/TinyTapeout/ttihp-verilog-template), which takes you from
  RTL to GDS. Its main branch now targets CMOS5L, so you no longer need the `cmos5l` branch. Set the tile size in `info.yaml` to 8x4.
- **Area:** The maximum area is 8x4 tiles per design. This is confirmed for the March 2027
  shuttle, and Tiny Tapeout says the tile sizes are final.
- **Open source:** Your submission should be open source so others can use and build on it.
  Unlike the reverse-engineering puzzle, there’s no need to keep your work hidden until
  the deadline, so feel free to build in public!
- **Teams:** This is a much bigger project than the puzzle, so we strongly recommend
  working in teams. If you’re looking for teammates or want to chat with other entrants,
  the [Tiny Tapeout Discord](https://discord.gg/rMmn8kXJng) has a competitions channel.
- **Deadline:** Submit your design by **January 18th, 2027**.
- **Prize:** We’ll pay to tape out the most novel designs on a Tiny Tapeout shuttle.
  We’re targeting the **March 2027 CMOS5L shuttle**, subject to the foundry schedule.
  Winners will receive their chip on a [Tiny Tapeout demo board](https://tinytapeout.com/specs/pcb-etr/) after fabrication, so you can test your
  design in silicon.

We’re aiming to announce the selected designs in early February and currently plan to tape
out around four designs. After the deadline, we’ll work with winners on small
non-functional fixes, like re-hardening for a newer flow.

## How much fits?

An 8x4 allocation is 32 tiles. At approximately 202um × 155um per tile, that’s about 1.0
mm² of nominal tile area. As a rough estimate, budget for about 1K logic cells per tile.
You may need to get creative to fit the functionality you want.

For instruction memory, SRAM can be more area-efficient than flip-flops. Tiny Tapeout has [examples of SRAM](https://www.tinytapeout.com/chips/ttihp0p2/tt_um_urish_sram_test) running on this process node you can reference, and Ken Pettit has written a [walkthrough](https://kdp1965.github.io/ihp-um-janestreet-prism/ihp_sram_macro.html) on
adding an IHP SRAM macro to a CMOS5L tile.

Run synthesis early, check the mapped cell area, and leave room for clock-tree buffers
and routing. Then run the full place-and-route flow and check timing. A design that looks
small enough after synthesis can still be difficult to route or too slow at your chosen
clock frequency.

## FAQ

### Entering

**Who can enter, and how big can teams be?**  
Students and professionals are both welcome. You can enter on your own or as a team
(though we recommend teams), and there’s no limit on team size. Each team submits one entry.

**Did my sign-up go through?**  
The form doesn’t send a confirmation email. If you submitted it, you’re on the list, and
there’s nothing else you need to do to register. The sign-up is just so we can send
updates.

**Can you review my architecture before I submit?**  
To keep things fair we can’t review individual designs before the deadline, but feel free
to email us specific questions.

**Can the board ship to my country?**  
Tiny Tapeout ships worldwide. If you’re unsure about your country, email us and we’ll check
with them.

### Design

**Will I need to re-harden if the template changes?**  
Tiny Tapeout isn’t planning any changes to 8x4 (like pin positions, the power grid or the
floorplan) that would mean re-hardening.

**Can I use SRAM macros?**  
Yes, you can use the IHP SRAM macros, including more than one, as long as everything fits
in your tiles and passes the Tiny Tapeout precheck. Ken’s [walkthrough](https://kdp1965.github.io/ihp-um-janestreet-prism/ihp_sram_macro.html) covers the RTL, LibreLane config, Metal4 power and sign-off, and uses two of them.

**What pins are available?**  
24 digital pins: 8 inputs, 8 outputs and 8 bidirectional, plus clock and reset. There are
no analog pads, but analog or mixed-signal circuits inside your design (like a PLL) are
fine as long as they pass precheck.

**How fast can the I/O go?**  
Tiny Tapeout estimates about 10 ns round trip through the pads and mux, and a max output
frequency of around 66 MHz. There’s no CMOS5L silicon back yet, so these aren’t measured
numbers.

**What clock frequency should I target?**  
There’s no target. Pick one that closes timing after place-and-route and meets the
protocols you want to support. The RP2350 on the demo board generates the clock, and Tiny
Tapeout has confirmed 60 MHz is OK.

**Can I use external parts on the board?**  
Yes. The chip only has digital pins (3.3V I/O on the demo board), so things like pull-ups,
transceivers or level shifting go on a Pmod. Tiny Tapeout’s [Pmods](https://tinytapeout.com/specs/pcb-etr/) and [recommended pinouts](https://tinytapeout.com/specs/pinouts/) are good examples of what’s possible.
Please document anything your design needs.

**Does it have to be a CPU?**  
No. A CPU-style design is the most common approach, but an eFPGA, multiple engines sharing
a pipeline, or something else entirely is fine, as long as the chip can be reprogrammed
after fabrication to support new protocols. Whatever you build, include the software side:
an assembler or toolchain (or bitstream flow) and example programs for the protocols you
support.

**Which protocols, and how fast?**  
Start with UART, SPI and I2C. Stretch goals are low-speed USB and 10 Mbit Ethernet. There
are no fixed speed requirements, and standard settings (common UART baud rates, SPI modes
0-3, I2C at 100 and 400 kHz) are a good target. Running protocols concurrently, or
supporting both controller and target roles, is a plus but not required. For USB and
Ethernet, the more of the protocol work (line coding, CRC, clock recovery) your chip does
itself, the better.

**How does the program get loaded?**  
That’s part of your design. The microcontroller on the demo board is the natural host, but
any documented host works.

**What about reset?**  
Unlike an FPGA, flops don’t start at 0, so your design needs to use the reset signal
(`rst_n`) to get into a known state. On the demo board it’s triggered by a button or from
software. When your design is deselected it’s powered down and loses its state, so plan to
reload the program after it’s selected again. Tiny Tapeout has more on [moving from FPGA to ASIC](https://tinytapeout.com/hdl/fpga_vs_asic/).

### Submission and judging

**What do I submit?**  
A link to your public repository with your RTL, tests and a passing GDS/precheck from the
Tiny Tapeout flow. Please also include documentation of your architecture and instruction
set, your assembler or toolchain with example programs, and a write-up of your
verification approach. A video or demo isn’t required, but we’ll look at it if you have
one.

**What sign-off do I need?**  
A clean run through the Tiny Tapeout flow and precheck. You’re not expected to run extra
sign-off on top of that. We strongly recommend gate-level simulation to catch design (and
occasionally tool) errors. If something slips past precheck, Tiny Tapeout will reach out
and work out a fix with you.

**Can I use my own GDS flow?**  
Please stick to the Tiny Tapeout flow, since that’s how the winning designs get onto the
shuttle. If your design is big enough to hit GitHub Actions’ 6-hour limit, you can [run the flow locally](https://tinytapeout.com/guides/local-hardening/) and submit using Tiny
Tapeout’s custom GDS action instead. It still needs to pass precheck. The [analog template](https://github.com/TinyTapeout/ttihp-analog-template) shows how it’s set up.

**Can I use my own verification tools?**  
Yes, use whatever tools you like, just describe them in your write-up. If some of your
tests also run on open-source tools (like the cocotb tests in the template), that helps us
run them ourselves, but it isn’t required.

**Can I use AI tools?**  
Yes. Please describe how you used them in your write-up.

**Does my repo need to be public now?**  
No. You can develop privately and make the repo public when you submit, or build in public
if you prefer.

**How will entries be judged?**  
There’s no fixed weighting. Flexibility is the main thing: can the chip be reprogrammed to
support protocols it wasn’t designed for? Beyond that, we’ll look at which protocols you
demonstrate, anything unique your architecture makes possible, and how you designed and
verified it. A design with fewer protocols but a strong architecture and verification
approach can definitely be competitive. We’ll also weigh your write-up heavily, how easy it
is to read, and how clearly it explains any new techniques or flows you introduce.

### Timeline and prizes

- Submissions close January 18th, 2027.
- We’re aiming to announce the selected designs in early February, ahead of the March 2027
  CMOS5L shuttle.
- We’re currently planning to tape out around four designs. Winners will receive their
  chip on the Tiny Tapeout demo board.
- After the deadline, small non-functional fixes like re-hardening for a newer flow are
  fine, and we’ll work with the winners on those.
