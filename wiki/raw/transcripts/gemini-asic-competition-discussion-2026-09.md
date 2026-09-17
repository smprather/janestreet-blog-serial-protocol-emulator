---
source_url: https://gemini.google.com/app/010c372abf820796
ingested: 2026-09-16
sha256: 73a7932179ebc5839b29a4c426a9c8df85697e42a27c19d4737b5d8a11d922b6
---

# **Jane Street ASIC Competition Details**

[https://gemini.google.com/app/010c372abf820796](https://gemini.google.com/app/010c372abf820796)

*User prompt: check out https://blog.janestreet.com/protocol-emulator-asic-competition/*

Response: Jane Street has announced a brand new open-source hardware design challenge: the **Protocol Emulator ASIC Competition**.

Unlike their previous reverse-engineering puzzle, this time participants are tasked with designing a chip from scratch—and Jane Street will pay to fabricate the winning designs and mount them onto development boards.

### **Key Details of the Challenge**

> * **The Goal:** Design an open-source, general-purpose **protocol emulator ASIC**—essentially a tiny CPU with an instruction set optimized for reading pins, writing pins, counting cycles, and achieving the precise timing required to bit-bang protocols like UART, SPI, and I2C in firmware rather than fixed logic.  
> * **Inspiration:** Similar to the PIO state machines found on the Raspberry Pi RP2040 or the PRU cores on TI Sitara chips, but with a focus on flexibility and reprogrammability.  
> * **Protocols:**  
  * *Required baseline:* UART, SPI, I2C.  
  * *Stretch goals:* Low-speed USB, 10Mbit Ethernet, JTAG, SWD, PS/2, and CAN bus.  
> * **Target Process & Manufacturing:** The project uses Tiny Tapeout targeting **IHP's 130nm CMOS5L process**.  
> * **Area & Constraints:** Initially budgeted at a **6x4 tile allocation** (\~0.7 mm² nominal tile area, roughly 1K logic cells per tile), with potential scaling up to 8x4 tiles.  
> * **Timeline:** Submissions are due by **January 18th, 2027**, with tapeout targeted for the March 2027 shuttle.  
> * **Prizes:** Winning teams will receive physical, fabricated chips mounted on dev boards back from the foundry to test in real silicon.

Jane Street is encouraging participants to build in public, form teams, and explore creative verification techniques (including formal methods, random constrained tests, and AI-assisted verification).

---

*User prompt: first, i assume these are all full cmos swing protocols since only a gpio will be available as far as i know.*

Response: Yes, that assumption is correct.

Because Tiny Tapeout routes the digital tiles through standard digital I/O cells, you are interfacing with **CMOS push-pull digital GPIOs** operating at standard logic levels (typically 3.3V I/O domain provided by the Tiny Tapeout breakout board, driven by 1.2V core logic internally).

That physical layer reality shapes how you handle different target protocols in your design:

### **1\. Directly Supported Protocols (Native CMOS Swing)**

Protocols that naturally use push-pull or open-drain single-ended CMOS levels work directly out of the box:

> * **UART, SPI, JTAG, SWD:** Direct digital CMOS input/output.  
> * **I2C:** Implemented by toggling your pin direction register (switching the GPIO between Drive Low and High-Z / Input) to simulate open-drain lines with external pull-up resistors.  
> * **PS/2 & CAN (Controller Level):** PS/2 works directly (open-drain). For CAN, your chip acts as the protocol controller issuing standard digital logic levels (CAN-TX / CAN-RX), requiring an external physical-layer transceiver (like a SN65HVD230) on the dev board to map those signals to differential *V*DIFF​ levels.

### **2\. The Stretch Goals (Low-Speed USB & 10Mbit Ethernet)**

Since you won't have specialized high-speed differential PHYs or multi-level analog drivers on the tile, reaching these stretch goals requires clever physical-layer workarounds:

> * **Low-Speed USB (USB 1.1 \- 1.5 Mbps):**  
  * Low-Speed USB uses 3.3V signal levels, which match the I/O rail.  
  * While USB is technically differential (*D*\+ and *D*−), USB 1.1 receivers infer single-ended states (SE0 is both lines pulled low to signal End of Packet).  
  * You can drive USB 1.1 Low-Speed directly across two standard GPIO pins (using series resistors for impedance matching) by treating *D*\+ and *D*− as two separate single-ended CMOS outputs driven in complementary/single-ended configurations.  
> * **10Mbit Ethernet (10BASE-T):**  
  * True 10BASE-T uses differential Manchester encoding with peak-to-peak voltages around ±2.5V into a 100Ω load.  
  * Without an integrated analog PHY, you cannot generate true 10BASE-T differential signals directly from the pin. To bridge this, you would drive digital Manchester-encoded signals out of GPIO pins into an external circuit (such as a simple resistor ladder network/transformer or an external Ethernet PHY like an ENC28J60/LAN8720) on the dev board.

### **Architectural Takeaway**

Since the hardware layer is restricted to standard GPIO state changes (Output High, Output Low, Input High-Z), **the core challenge of the competition isn't physical-layer synthesis—it's timing precision and state machine flexibility.**

Your programmable core needs to be able to manipulate pin states, sample input lines, and adjust bit timings with cycle-accurate microcode, leaving the specialized voltage or differential conversions to simple passive networks or external transceivers on the breakout board.

---

*User prompt: is 8x oversample enough to capture 10Mbit ethernet? or is a digital DLL required?*

Response: **8× oversampling is more than sufficient** to receive and decode 10Mbit/s Ethernet (10BASE-T). You **do not** need a digital DLL or analog CDR (Clock and Data Recovery) circuit on chip.

### **Why 8× Oversampling Works**

10BASE-T runs at a nominal bit rate of 10 Mbps using **Manchester encoding**:

> * Data transitions occur in the **middle** of every bit period (100 ns). A 0 is a high-to-low transition; a 1 is a low-to-high transition.  
> * Setup transitions *may* occur at bit boundaries (every 100 ns) if consecutive identical bits are transmitted.  
> * Thus, the shortest pulse width in 10BASE-T is **50 ns** (half a bit period).

At an 8× oversampling rate relative to the 10 Mbps data rate:

> * Sampling Clock Frequency: **80 MHz**  
> * Sample Resolution: **12.5 ns** per sample  
> * A half-bit period (50 ns) yields **\~4 sample clock cycles**.  
> * A full-bit period (100 ns) yields **\~8 sample clock cycles**.

With 12.5 ns resolution, you have plenty of margin to accurately identify edge transitions, filter out high-frequency noise/glitches, and lock onto the Manchester phase—even accounting for minor clock drift between transmitter and receiver.

### **How to Implement It in Digital Logic (No DLL Required)**

Instead of a phase-locked loop (PLL) or delay-locked loop (DLL) adjusting clock phase dynamically, you build a purely synchronous **Digital Data Recovery Unit (DRU)** in standard verilog RTL:

> 1. **Synchronize Input:** Run the single-ended Manchester signal into a standard 2-flip-flop synchronizer clocked at 80 MHz to prevent metastability.  
> 2. **Edge Detector & Counter:**  
   * Maintain a small sample counter (e.g., 0 to 7).  
   * Reset/align the counter whenever a mid-bit transition is detected.  
> 3. **Preamble Locking:**  
   * 10BASE-T packets begin with a 56-bit preamble of alternating 1s and 0s (10101010...), ending in the Start Frame Delimiter (10101011).  
   * Use this sequence to align your internal sample window directly to the middle of the 50 ns half-bit cells.  
> 4. **Manchester Decoding:**  
   * Once locked, sample the line state \~2 clock ticks (25 ns) after a mid-bit edge to reliably decode the bit polarity (0 vs 1).  
   * Ignore edges occurring at boundary intervals (\~8 clock ticks from mid-bit).

### **Trade-offs & Implementation Tips**

| Approach | Logic Area (Tiles) | Complexity | Latency | Clock Requirement |
| :---- | :---- | :---- | :---- | :---- |
| **8× Digital Oversampling** | Extremely Low (\~50-100 logic cells) | Simple State Machine | 1-2 sample ticks (12.5-25 ns) | Requires clean 80 MHz system/sampling clock |
| **Digital DLL / Multi-phase CDR** | High (Delay lines, phase selection) | Complex routing & timing constraints | Extremely low | Works with lower clock frequency (e.g., 10 MHz multiphase) |

### **Practical Advice for Tiny Tapeout (IHP 130nm)**

> * **Clocking:** If your tile can accept an 80 MHz clock from the Tiny Tapeout breakout board (or generate it via an internal multiplier if available), 8× oversampling is by far the most robust, area-efficient approach.  
> * **4× Alternative:** If fitting an 80 MHz clock tree in your tile allocation is tight, **4× oversampling (40 MHz clock)** is actually the absolute practical minimum used by many FPGA designs (yielding \~2 samples per 50 ns pulse). However, **8× (80 MHz)** gives you vastly superior jitter tolerance and immunity to board-level trace distortion.

---

*User prompt: that target node can easily do 80MHz, especially for shallow path niche circuits, right?*

Response: Yes, from a purely silicon perspective, a standard 130nm CMOS node easily reaches 80 MHz—and much higher—for low-logic-depth paths operating at 1.2V core supply. Standard gate delays in 130nm raw silicon are typically under 30–50 ps for basic logic, meaning a shallow 2–4 gate logic depth path can comfortably run past 200–300 MHz in isolated silicon.

However, in the context of this specific challenge, there are a few practical constraints in the Tiny Tapeout ecosystem you'll need to design around to achieve a reliable 80 MHz clock:

### **1\. Board & Multiplexer Clock Routing Limits**

In Tiny Tapeout, your 6x4 tile area isn't directly connected to dedicated chip pads. Instead, your tile signals pass through an on-chip multiplexer tree and out to the demo board's RP2040 (or FPGA controller) and PCB trace environment.

> * **Tiny Tapeout Top Speeds:** Tiny Tapeout shuttles generally list nominal target system frequencies around **50 MHz** across the shared mux and board routing.  
> * **To Hit 80 MHz safely:** If the external global clock driven into the Tiny Tapeout carrier board caps out around 50–60 MHz due to board trace capacitance or multiplexer path delay, driving the full chip externally at 80 MHz might hit a bottleneck outside your tile layout.

### **2\. Standard Cell Selection & Drive Strengths**

Because the IHP 130nm open-source PDK (sg13g2 / CMOS5L) relies on OpenLane/OpenROAD synthesis, your critical path logic will need careful tuning:

> * Ensure your oversampling sync chain uses high-drive standard cells (e.g., \_2 or \_4 drive strength buffers/registers) to prevent local wire-capacitance slowdowns.  
> * Keep the data path between the input synchronizer, edge detector, and sampling counter tight—ideally under **4 to 6 levels of logic**.

### **3\. Alternative Solution: Multi-Phase Sampling at Lower Frequency**

If board-level clocking limits force your tile system clock down to **40 MHz or 50 MHz**, you can bypass the need for an 80 MHz global clock entirely by utilizing dual-edge sampling:

> * Sampling on both the **rising and falling edges** of a **40 MHz clock** gives you the exact same **12.5 ns temporal resolution** (8× oversampling of 10 Mbps) without requiring the global clock tree or multiplexer network to toggle at 80 MHz.

### **Summary**

Silicon-wise, 80 MHz is trivial for a shallow line-sampling state machine in IHP 130nm. The main challenge will be ensuring the Tiny Tapeout I/O multiplexer and PCB interface can deliver an 80 MHz clock cleanly into your tile, making dual-edge 40 MHz clocking a great design fallback.

---

*User prompt: i see. could we build a "loose and dirty" clock doubler just good enough to get the job done?*

Response: Building a "loose and dirty" internal clock doubler inside your tile is definitely possible in standard digital logic, but doing so on an ASIC requires carefully weighing the trade-offs of cell delay variation across process, voltage, and temperature (PVT).

Here is how you can implement one, how it works, and the safer alternative.

### **The "Dirty" Combinational Doubler (XOR Delay Line)**

The classic way to double a clock without a PLL or DLL in pure standard-cell RTL is an **XOR edge-detector circuit**.

            `+---------------+`  
`CLK In ---->|               |`  
            `|     XOR       |-----> Doubled CLK Out (80 MHz)`  
   `+------->|               |`  
   `|        +---------------+`  
   `|`  
   `|   +----------+  +----------+  +----------+`  
   `+---| Delay 1  |--| Delay 2  |--| Delay 3  |--- ... (Inverting Chain)`  
       `+----------+  +----------+  +----------+`

#### **How it works:**

> 1. Drive your incoming base clock (e.g., **40 MHz**) directly into one input of a 2-input XOR gate.  
> 2. Pass the same clock through a delay line consisting of an **odd number of inverters** (or buffer chains) into the second input of the XOR gate.  
> 3. Every time the base clock toggles (rising *or* falling edge), the two inputs to the XOR gate momentarily differ in state for the duration of the delay line, creating a high pulse on the output.

This turns a **40 MHz input clock** into an **80 MHz clock train** (producing two short high pulses per 40 MHz cycle).

### **The Engineering Challenges on 130nm ASIC**

While this circuit works easily in FPGAs (where LUT/routing delays are relatively predictable), on a 130nm ASIC tile, it introduces three significant risks:

#### **1\. Duty Cycle Asymmetry**

> * The high pulse width of your generated 80 MHz clock is determined **entirely by the physical delay of your inverter chain** (≈*N*×*t*pd​).  
> * If your delay chain is 6.25 ns long, you get a 50% duty cycle at 80 MHz.  
> * However, if process variation or temperature changes shrink that delay to 3 ns, your clock line will only pulse high for 3 ns and sit low for 9.5 ns. Flip-flops downstream may violate minimum pulse width requirements.

#### **2\. PVT Sensitivity (Process, Voltage, Temperature)**

> * Standard cell logic delays on IHP 130nm (sg13g2) will vary considerably between standard corner cases (**SS** / slow-slow vs. **FF** / fast-fast) and operating temperature (0∘C vs. 85∘C).  
> * A delay chain sized correctly for nominal conditions might become too short to clock registers reliably at high temperatures or low voltages.

#### **3\. OpenLane / OpenROAD STA Tooling Issues**

> * Automated ASIC synthesis (Yosys) and static timing analysis (OpenROAD / OpenSTA) generally treat combinational loops or delay-line clock gates as unconstrained clock domains.  
> * You will need custom SDC (Synopsys Design Constraints) rules (create\_generated\_clock) to prevent the tool from trying to optimize away your inverter chain during synthesis or failing setup/hold checks on generated clock trees.

### **A Cleaner Alternative: Standard Dual-Edge Triggering**

If your goal is simply to achieve **8× oversampling of 10 Mbps (12.5 ns resolution)** from a **40 MHz external clock**, you can achieve the exact same functional result without generating an unstable internal 80 MHz clock tree.

Instead of doubling the clock signal, sample the incoming Ethernet signal on **both edges** of the clean 40 MHz clock:

`// Dual-Edge Sampling Engine (No Clock Doubler Needed)`  
`always @(posedge clk_40mhz) begin`  
    `sample_pos <= rx_pin_sync;`  
`end`

`always @(negedge clk_40mhz) begin`  
    `sample_neg <= rx_pin_sync;`  
`end`

> * **Zero PVT Risk:** Relies entirely on the stable external clock's 50% duty cycle.  
> * **STA Friendly:** OpenROAD can easily perform static timing checks on both rising and falling edges of clk\_40mhz.  
> * **Area Efficient:** Saves you from tuning hand-crafted inverter chains and manual buffer trees in your layout.

If you *really* want an internal 80 MHz pulse train for a single-edge state machine, the XOR delay line is fun and doable—just make sure to instantiate raw PDK primitives (sg13g2\_inv\_1 or similar) with (\* keep \*) attributes so Yosys doesn't optimize the delay chain out\!

---

*User prompt: are custom cells allowed if needed?*

Response: Yes, custom layout cells are allowed, but with specific workflow constraints.

Because the competition uses **Tiny Tapeout** (via OpenLane/LibreLane for IHP 130nm sg13g2), you are not strictly limited to standard Verilog synthesis. You can submit custom GDSII layouts—including hand-crafted logic cells, macro blocks, or analog/custom transistor-level circuits—provided your design meets all platform rules.

### **Requirements & Constraints**

> 1. **Standard Cell Grid & Pitch Alignment:** Any custom cell or macro block placed inside your tile must match the **site height, cell row alignment, and pin pitch** of the IHP sg13g2 standard cell library so the OpenROAD router can pass power rails (VDD/VSS) and signal routes over or around it.  
> 2. **Clean DRC & LVS Sign-off:** Your custom GDSII must pass full **Design Rule Checking (DRC)** and **Layout Versus Schematic (LVS)** verification against the open IHP PDK decks (via KLayout / Magic / Netgen).  
> 3. **LEF & LIB Generation (for Hard Macros):** If you want Yosys and OpenROAD to treat your custom block as a black-box during place-and-route:  
   * **LEF File:** Defines the physical bounding box, pin locations, and metal blockage layers.  
   * **LIB File:** Characterizes the timing and electrical pin properties of your custom cell (or manual timing constraints if uncharacterized).  
> 4. **Tile Boundary & Area Limits:** Custom cells must stay strictly within your allotted tile footprint (6x4 or 8x4 tiles) and must not overlap the predefined Tiny Tapeout tile boundary frame or power ring.

### **Best Practice for This Competition**

If you plan to design custom cells—such as a manual delay element for a clock doubler, custom high-speed registers, or an area-optimized memory bitcell—it is generally best to **hard-code the macro layout in KLayout**, export its GDS/LEF, and instantiate it as a black-box module in your top-level Verilog before running the OpenLane automated ASIC flow.

---

*User prompt: full custom, i know i could tweak a nice clock doubler to work across corners. maybe without custom, but definitely with.*

Response: Full custom layout in the IHP 130nm PDK (sg13g2) gives you direct control over transistor sizing, allowing you to build a robust, PVT-compensated delay circuit that automated standard-cell synthesis won't yield.

If you decide to hand-craft a clock doubler at the GDSII level, here is how you can stabilize the pulse width across process corners, voltage droop, and temperature swings.

### **1\. Transistor-Sized Symmetrical Delay Line**

Standard library inverters prioritize rapid switching transitions, making their propagation delay heavily dependent on output load capacitance. In full custom layout, you can tune the channel geometries directly:

                  `+--- VDD`  
                  `|`  
             `+----+----+`  
             `|  pMOS   |  W/L tuned for long t_phl / t_plh`  
             `+----+----+`  
                  `|`  
     `IN  ----+----+---- OUT`  
                  `|`  
             `+----+----+`  
             `|  nMOS   |  W/L tuned for long t_phl / t_plh`  
             `+----+----+`  
                  `|`  
                  `+--- VSS`

> * **Long-Channel Devices (*L*\>*L*min​):** Increasing *L* beyond the 130nm minimum (e.g., *L*\=0.3*μ*m−0.5*μ*m) increases gate channel resistance cleanly without adding massive parasitic routing capacitance.  
> * **Balanced Mobility Ratios (*Wp*​/*Wn*​):** Equalize the rising and falling propagation delays (*tPLH*​≈*tPHL*​) by matching the effective drive strength of the pMOS and nMOS networks under worst-case corner combinations.  
> * **Explicit MIM / MOS Capacitors:** Instead of relying on random interconnect parasitic capacitance, place explicit internal loading capacitors (using gate capacitance or metal-finger structures) between delay stages to damp out high-frequency noise and corner jitter.

### **2\. PVT Stabilization Architecture: Self-Biased / Current-Starved Delay Line**

A pure static CMOS inverter chain will still shift delay by up to ∼2× between the **FF / 1.32V/−40∘C** fast corner and the **SS / 1.08V/125∘C** slow corner.

To make the clock doubler bulletproof across all corners, use a **current-starved delay inverter chain**:

                  `+--- VDD`  
                  `|`  
             `+----+----+`  
             `|  pMOS   |  <--- Constant Bias Voltage (V_bp)`  
             `+----+----+`  
                  `|`  
             `+----+----+`  
             `|  pMOS   |  <--- Signal Switching Transistor`  
     `IN -----+----+----+`  
             `|  nMOS   |  <--- Signal Switching Transistor`  
             `+----+----+`  
                  `|`  
             `+----+----+`  
             `|  nMOS   |  <--- Constant Bias Voltage (V_bn)`  
             `+----+----+`  
                  `|`  
                  `+--- VSS`

#### **How it stabilizes the pulse:**

> 1. **Current Sinking/Sourcing Limit:** The top and bottom bias transistors limit the maximum current *I*ON​ available to charge/discharge the output node during a transition, making Δ*t*≈(*C*out​⋅Δ*V*)/*I*bias​.  
> 2. **Simple Bias Generator:** You can instantiate a basic bandgap-referenced or threshold-tracking bias generator inside your macro. As *VDD* rises or temperature drops (which would normally speed up standard CMOS logic), the bias circuit limits *I*bias​, keeping the generated clock pulse width virtually flat across the entire operating window.

### **3\. Symmetric XOR Combining**

To ensure the rising-edge doubler pulse and falling-edge doubler pulse are identical, pass both the original clock and the delayed clock through a fully symmetric, pass-transistor or transmission-gate **XOR cell** (rather than a standard static CMOS XOR gate, which often has unbalanced pin-to-pin delays between input *A* and input *B*).

### **Integration into the OpenLane Flow**

To integrate your custom GDS macro into your Tiny Tapeout tile cleanly:

> 1. **Draw & Sign-Off:** Layout the macro in KLayout using the sg13g2 DRC/LVS decks.  
> 2. **Generate LEF:** Export a LEF file defining pins (CLK\_IN, CLK\_OUT, VDD, VSS) and layer blockages.  
> 3. **Black-Box Characterization:** Assign nominal timing arcs in a .lib file, or set a set\_dont\_touch and explicit create\_generated\_clock constraint in OpenROAD/SDC so the automated tools do not attempt to optimize or re-route internal nodes of your macro.

---

*User prompt: actually, good point. we could just use regular cells, but build a super beefy power grid just in that area. i bet that would be enough to stay clean. should be able to easily hit VDD-5%. might have to rechar cells at that corner. but might not be needed at all. just have to try and see.*

Response: That is a very practical, low-risk strategy. Sticking to standard cells while hardening the local power delivery network (PDN) lets you keep the entire automated synthesis and timing sign-off flow intact while avoiding hand-crafted DRC/LVS headaches.

### **Why Local PDN Reinforcement Works**

In digital ASICs, local clock-edge jitter and dynamic delay shifts in delay lines are often caused by **dynamic IR drop**—the temporary voltage dip right at the switching edge when multiple gates pull current simultaneously.

By building a dense, high-metal power grid around your delay line:

> * **Decoupling & Low Impedance:** You dramatically lower the local loop inductance and resistance, keeping local *VDD*​ locked tight to nominal even during sharp switching transients.  
> * **Minimal Voltage Sag:** Preventing local *VDD*​ from dropping by more than 2–3% eliminates the largest source of transient delay skew across adjacent gates.

### **Implementation Tips for the Standard-Cell Approach**

> 1. **Local Decoupling Capacitor (Decap) Plentifulness:** Surround the inverter chain and XOR gate with high-density standard decap cells (sg13g2\_decap\_\*). Placing decaps directly adjacent to the delay line provides immediate charge storage during fast transitions.  
> 2. **Metal Layer Strapping:** Route local power/ground straps on the highest available thin/thick metal layers in IHP 130nm (e.g., Metal 4 / Metal 5\) directly above the block, dropping dense via stacks down to Metal 1 power rails.  
> 3. **OpenROAD / Yosys Optimization Guards:**  
   * Apply (\* keep \= "true" \*) or set\_dont\_touch on the delay chain logic to stop Yosys/OpenROAD from collapsing the inverter chain or swapping out cell drive strengths during sizing passes.  
   * Manually space the inverter cells apart across multiple standard-cell rows if routing congestion or thermal dissipation becomes a localized issue.  
> 4. **Corner Verification:** Before re-characterizing libraries, simply run standard Static Timing Analysis (STA) in OpenROAD at the slow/low-voltage corner (e.g., *VDD*​−10%, high temperature). If the setup/hold paths for the rest of your 80 MHz logic still close cleanly with the resulting pulse width at that worst-case corner, you won't need to tweak library .lib files at all.

It's definitely worth running through the standard OpenLane flow first to see where nominal layout and a beefed-up power mesh land you\!

---

*User prompt: ah actually, no new char needed. just need to reduce the STA IR derates.*

Response: That's a much cleaner shortcut. By manually dialing back the conservative dynamic IR drop derating factors in static timing analysis (STA), you can reflect your hardened local power grid directly in the timing engine without touching cell characterization .lib files.

### **How to Adjust Derates in OpenROAD / OpenSTA**

OpenROAD uses **OCV (Operating Condition Variation)** derates to simulate timing degradation caused by voltage sags and process variation. By default, it applies a global percentage penalty to cell delays across the chip.

To apply tighter, less conservative derates to your power-hardened clock doubler logic:

#### **1\. Target the Specific Instances in your SDC / TCL Script**

Rather than dropping derate penalties globally across the entire design (which could lead to false timing passes on unshielded logic), isolate the delay chain and XOR gates:

`# Lower the late/early OCV voltage derates for the hardened delay line block`  
`# Default flow might use ~5-10% derate; drop it to 1-2% for this specific path`  
`set_timing_derate -early 0.98 [get_cells {clk_doubler_inst/*}]`  
`set_timing_derate -late  1.02 [get_cells {clk_doubler_inst/*}]`

#### **2\. Configure Clock Re-convergence Pessimism Removal (CRPR)**

Because the clock doubler uses a common input clock split through two combinational paths into an XOR gate, make sure CRPR is enabled in OpenSTA:

`set_parameter crpr_enabled true`

This ensures the timing analyzer doesn't add artificial pessimism by assuming the rising edge of the source clock hits the direct path at the "fast" corner while hitting the delay path at the "slow" corner within the exact same clock pulse.

### **Verification Strategy**

> 1. **Run Standard Flow:** Run synthesis and place-and-route with default OpenLane derates to see baseline STA results.  
> 2. **Apply Tightened Derates:** Apply the targeted set\_timing\_derate constraints in your post-route STA script.  
> 3. **Verify Min/Max Pulse Widths:** Inspect the setup/hold checks on downstream registers clocked by the generated 80 MHz signal to confirm that even under the tightest timing checks, the high/low pulse duration meets the minimum pulse-width requirement (worst\_slack \> 0\) of the sg13g2 flip-flop cells.

This approach gives you realistic STA sign-off confidence while keeping your ASIC build script clean and reproducible.

---

*User prompt: i'm just assuming 4x oversample is not enough.*

Response: That assumption is valid—especially when dealing with real-world transmission lines and variable cable lengths.

While 4× oversampling (40 MHz sampling clock for 10 Mbps) is theoretically the absolute Nyquist-adjacent limit for Manchester-encoded data (yielding 2 samples per 50 ns half-bit cell), relying on it introduces significant operational risks:

### **Why 4× Oversampling Falls Short in Practice**

> 1. **Jitter & Phase Margins:** In a ideal system, a 4× clock gives you samples at 0 ns, 25 ns, 50 ns, and 75 ns relative to a 100 ns bit window. However, transmit phase jitter, board-level impedance mismatches, and trace capacitance distort edge rise/fall times. If a transition shifts by even **±10–12 ns**, a 4× sampler can easily miscategorize a edge transition or sample during a voltage slew region, leading to bit errors.  
> 2. **Clock Drift Between Transmitter & Receiver:** IEEE 802.3 allows for a ±100 ppm clock tolerance on 10BASE-T. Over a maximum length Ethernet packet (1518 bytes ≈12,144 bits), a slight frequency offset between the sender's clock and your local 40 MHz clock will cause sample-point phase drift. 8× oversampling provides enough phase resolution (12.5 ns) to continuously track and correct for this drift during the 56-bit preamble; 4× oversampling (25 ns resolution) leaves almost zero margin for adjustment once locked.  
> 3. **Preamble Acquisition Speed:** With 8× oversampling, your digital logic can lock onto the preamble sequence (10101010...) within 2 to 3 bit periods because it can pinpoint the zero-crossing edge within a 12.5 ns window. With 4× oversampling, phase lock takes longer and is prone to false locks if the initial edge aligns poorly with your sample clock.

### **Comparison: 4× vs. 8× Oversampling**

| Metric | 4× Oversampling (40 MHz) | 8× Oversampling (80 MHz) |
| :---- | :---- | :---- |
| **Sample Interval** | 25 ns | 12.5 ns |
| **Samples per 50 ns Half-Bit** | 2 samples | 4 samples |
| **Max Tolerable Jitter** | ∼±6.25 ns | ∼±18.75 ns |
| **Digital Filtering / Glitch Rejection** | Minimal (1 sample noise spike corrupts cell) | Strong (Can require 2+ consecutive matching samples) |
| **Preamble Lock Margin** | Low | High |

### **The Verdict**

Pushing for 8× oversampling—whether via an external 80 MHz board clock, dual-edge 40 MHz sampling, or your hardened internal clock doubler—is the right engineering call if you want 10Mbit Ethernet to be a reliable stretch goal rather than a brittle test bench hack.

---

*User prompt: i designed a USB2.0 CDR. we used 8x oversample.*

Response: That is a great proof point for why you intuitively reached for 8× oversampling here—and it proves your intuition on 10Mbit Ethernet is completely spot on.

If an 8× oversampling CDR architecture can cleanly recover a 480 Mbps USB 2.0 High-Speed NRZI stream (sampling at \~3.84 GHz or via multi-phase clocking), scaling that exact same architectural pattern down to 10 Mbps Manchester-encoded Ethernet at 80 MHz is straightforward:

> * **No Bit-Stuffing / NRZI Complexity:** Unlike USB 2.0, where long runs of identical bits require bit-stuffing rules and phase drift tracking over non-transitioning windows, Manchester encoding guarantees a transition *every single bit period* (100 ns).  
> * **Phase Locking is Far Easier:** In USB 2.0 High-Speed, managing edge jitter across non-return-to-zero (NRZ) data takes sophisticated phase-selection multiplexers or elastic FIFOs. For 10BASE-T Ethernet, an 8× oversampling state machine simply needs to lock onto the guaranteed mid-bit edge during the 56-bit preamble and use a basic 3-bit phase counter to center its sampling strobe.  
> * **Overkill Margin:** Since you've already built an 8× CDR for 480 Mbps, doing 8× at 10 Mbps on an IHP 130nm ASIC will feel almost luxurious in terms of timing slack and digital phase margin.

With your 80 MHz clock doubler (backed by your hardened local power mesh and decaps), your 8× oversampling data recovery block will easily handle 10BASE-T line jitter and drift without sweating corner variations.

---

*User prompt: yes, it was multi-phases from PLL which is why we called it a "phase picker" circuit.*

Response: That makes perfect sense—the multiphase PLL \+ digital phase picker is classic high-speed CDR design\!

Instead of running an actual multi-gigahertz clock tree, generating 8 evenly spaced phases from a lower-frequency PLL clock and using a phase picker (or dynamic phase-selection MUX) to track the data transitions is the standard, battle-tested way to do high-speed 8× oversampling without frying your power budget.

Coming from that background, here is how translating that mindset to this 130nm ASIC competition stack shapes up:

### **Multiphase Phase Picker vs. Simple Oversampling Clock**

| Feature | High-Speed USB 2.0 Approach | 10BASE-T on 130nm ASIC |
| :---- | :---- | :---- |
| **Architecture** | Multiphase PLL \+ Phase Picker | Single 80 MHz Clock (or Dual-Edge 40 MHz) \+ Counter |
| **Clock Tree** | 8 phase lines routed across logic | Single clock tree line |
| **Phase Resolution** | Set by PLL delay stage matching | Fixed at 80MHz1​\=12.5 ns |
| **Edge Tracking** | Phase accumulator selects best phase MUX input | 3-bit modulo counter re-syncs on Manchester edges |
| **Hardware Overhead** | High (Analog/Digital PLL \+ Matched Phase Routing) | Extremely Low (\~50-100 logic cells) |

### **Why standard oversampling is so much simpler here**

In your USB 2.0 design, you *had* to use multiphase sampling because running a single-phase clock at 8×480 MHz=3.84 GHz on standard digital logic was impossible or power-prohibitive.

For 10BASE-T on this Tiny Tapeout node, 8×10 MHz=80 MHz. Because 80 MHz is low enough to clock the digital logic directly (especially with your hardened local power grid and delay-doubled/external clock), you don't even need the multiphase PLL or phase-selection MUX\!

Your "phase picker" essentially simplifies down to a **3-bit ring counter / phase register**:

> 1. Incoming GPIO bit transitions force the 3-bit counter to re-align to phase 0\.  
> 2. The counter increments every 12.5 ns clock cycle.  
> 3. You strobe/sample the data pin on phase count 4 (center of the 50 ns half-bit window).

It’s the exact same conceptual CDR pipeline—tracking phase step offsets to strobe in the middle of the eye diagram—just collapsed down into pure synchronous digital RTL.

---

*User prompt: most timing signoff corners do not include FS and SF corners. but we'll need those for the GPIO to model how much the bit width is crushed by unequal rise/fall times, right?*

Response: Exactly right. Standard timing signoff for pure internal digital logic usually focuses on **SS** (slow-slow / setup) and **FF** (fast-fast / hold) because internal standard-cell gates generally track symmetrically.

However, for **I/O cell timing signoff**, **FS (Fast N / Slow P)** and **SF (Slow N / Fast P)** corners are critical.

When driving or receiving signals through a GPIO pad—especially when bit-banging or running a low-margin protocol like 10BASE-T or USB—unequal pull-up vs. pull-down drive strengths directly cause **duty-cycle distortion (DCD)** and pulse-width shrinkage.

### **Why FS / SF Corners Crush Bit Widths**

In an I/O buffer (which uses large output pMOS and nMOS transistors), the rise time (*tr*​) and fall time (*tf*​), as well as propagation delays (*tpLH*​ vs. *tpHL*​), depend heavily on transistor mobilities:

> * **FS Corner (Fast N, Slow P):** The nMOS pulls down rapidly, but the pMOS pulls up slowly.  
  * High-going transitions are delayed (*tpLH*​ is long).  
  * Low-going transitions happen quickly (*tpHL*​ is short).  
  * **Result:** A high pulse (e.g., a 50 ns half-bit pulse in 10BASE-T) gets **narrowed/crushed**, while a low pulse gets stretched.  
> * **SF Corner (Slow N, Fast P):** The pMOS pulls up rapidly, but the nMOS pulls down slowly.  
  * High pulses get stretched; low pulses get **narrowed/crushed**.

If your GPIO has a 5 ns imbalance between *tpLH*​ and *tpHL*​, a 50 ns pulse enters your core (or leaves the pin) as a 45 ns pulse. Combined with trace capacitance on the Tiny Tapeout breakout board, that skew eats into your 8× oversampling window.

### **Do You Need FS / SF Corners for this IHP 130nm ASIC?**

It depends on whether you are analyzing **internal logic** or the **pad ring**:

> 1. **Internal Tile Logic:** Standard digital synthesis and timing tools (OpenROAD / OpenSTA) for the IHP sg13g2 PDK typically ignore FS/SF for internal standard cells because internal logic paths are dominated by overall cell delay variations (covered by SS/FF \+ OCV derates).  
> 2. **GPIO Pad Boundary (Tiny Tapeout Top Level):** If you simulate the physical I/O pads driving external loads:  
   * **SPICE Level:** If you run SPICE / NGSPICE simulations of the GPIO pad driver driving board capacitance (∼15–30 pF), you **must** include the sg13g2 FS and SF corner models. This will reveal the worst-case pulse-width distortion (*tPLH*​−*tPHL*​) under skewed process corners.  
   * **STA Level:** In OpenROAD SDC, this imbalance is typically modeled by adding a **board/pad pin skew constraint** (set\_clock\_latency / set\_input\_delay / set\_output\_delay with explicit \-rise and \-fall offsets) rather than running full FS/SF corner runs inside the tile synthesis script.

### **Impact on Your 8× Oversampling CDR**

Because you're using an **8× oversampling CDR (12.5 ns sample resolution)**, your receiver state machine is inherently resilient to GPIO pulse-width distortion:

> * A 50 ns half-bit cell nominal width \= 4 sample ticks.  
> * If FS/SF corner distortion shrinks the pulse down to **37.5 ns \~ 40 ns**, your 8× oversampler still captures **3 valid sample ticks** inside the pulse.  
> * As long as your edge detector re-synchronizes the sample phase counter on *every* transition (both rising and falling edges), the CDR dynamically absorbs the DCD without losing bit lock\!

---

*User prompt: we might have to simulate the gpios with spice and use the bit thinning as uncertainty in STA SDC.*

Response: That is the absolute gold standard approach for sign-off on custom/niche I/O paths.

Running transistor-level SPICE (or ngspice) simulations across the full **FF, SS, FS, and SF** corner matrix—loaded with realistic board parasitics—gives you the exact, un-varnished duty-cycle distortion (DCD) metrics. Once you extract that worst-case pulse-width shrinkage (Δ*t*skew​\=∣*tpLH*​−*tpHL*​∣), you can feed it cleanly into OpenROAD / OpenSTA without needing complex multi-corner I/O library files.

### **1\. Extracting Skew from SPICE**

In your SPICE deck for the IHP sg13g2 GPIO buffer:

> 1. Drive a 10 Mbps Manchester pulse train into the input pin model.  
> 2. Load the output pin with the target PCB load model (typically 15 pF−30 pF line capacitance \+ pin inductance).  
> 3. Measure propagation delay differences across corners:  
>    Δ*t*rise\_fall\_skew​\=max∣*tpLH*​(corner)−*tpHL*​(corner)∣  
> 4. Measure input-stage threshold skews for incoming signals (where the receiver CMOS inverter threshold shifts away from *VDD*​/2).

### **2\. Injecting "Bit Thinning" into OpenROAD SDC**

Once you have your maximum SPICE-measured pulse distortion (say, Δ*t*\=4.2 ns due to FS/SF pad imbalance), translate that into SDC constraints for the timing engine:

#### **Option A: Asymmetric Input/Output Delays**

Explicitly model the rise vs. fall arrival difference on the pad:

`# Specify different max delays for rising vs. falling edges to represent bit thinning`  
`set_input_delay -clock clk_80mhz -max -rise 5.0 [get_ports rx_gpio]`  
`set_input_delay -clock clk_80mhz -max -fall 9.2 [get_ports rx_gpio] ;# +4.2ns skew penalty`

`set_input_delay -clock clk_80mhz -min -rise 2.0 [get_ports rx_gpio]`  
`set_input_delay -clock clk_80mhz -min -fall 2.0 [get_ports rx_gpio]`

#### **Option B: Clock / Port Uncertainty (Jitter Budgeting)**

If your CDR samples relative to an internal 80 MHz clock, treat the GPIO bit-thinning as external setup/hold uncertainty directly on the port:

`# Add SPICE-derived GPIO DCD directly as input uncertainty`  
`set_input_transition -rise 1.5 [get_ports rx_gpio]`  
`set_input_transition -fall 3.2 [get_ports rx_gpio]`

`# Guardband the setup/hold checks by the extra SPICE bit-thinning value`  
`set_port_fanout_number 4 [get_ports rx_gpio]`  
`set_clock_uncertainty -setup 4.2 [get_clocks clk_80mhz]`

### **3\. Closing the Loop with the 8× CDR Budget**

With an 80 MHz sampling clock:

> * **Nominal sample tick:** 12.5 ns  
> * **Nominal 10BASE-T half-bit pulse:** 50 ns (4.0 sample ticks)  
> * **After SPICE-modeled bit-thinning (∼4.2 ns):** Effective pulse width \=45.8 ns (3.66 sample ticks)

Because your 8× CDR state machine strobes near the center of the pulse (tick 2 or 3 of the 4-tick window) and re-synchronizes counter phase on *both* rising and falling edges, a 4.2 ns GPIO bit-thinning uncertainty leaves over **8 ns of clean timing margin** inside your sampling window.

This gives you a fully closed, mathematically sound sign-off path from SPICE transistor corners all the way up to OpenROAD STA.

---

*User prompt: for the logic portion (pre/post phy), are there functional blocks that can be factored out of the protocol list (8b/10b, etc)?*

Response: When evaluating the target list (UART, SPI, I2C, JTAG, SWD, PS/2, CAN, Low-Speed USB, and 10Mbit Ethernet), you can factor out several distinct hardware blocks from the core execution engine.

Instead of burning tile area on fixed protocol engines, the ideal microarchitecture places **shared, parameterized hardware primitives** right between your programmable core and the physical pin registers.

### **Core Functional Blocks to Factor Out**

#### **1\. Clock & Data Recovery (CDR) / Oversampling Engine**

> * **Shared Protocols:** 10BASE-T (Manchester), Low-Speed USB (NRZI with edge phase), UART (start-bit baud tracking), PS/2.  
> * **Primitive:** A configurable 8×/16× oversampling state machine with an edge-triggered phase alignment counter.  
> * **Factored Logic:** Instead of software polling pins at 80 MHz, this hardware block handles edge detection, majority-vote noise filtering (e.g., 3-sample debounce), and outputs a clean, phase-aligned **Data Strobe / Bit Clock** signal to the core.

#### **2\. Synchronous Shift Registers & Bit Framing (Serializer/Deserializer)**

> * **Shared Protocols:** SPI, I2C, JTAG, SWD, PS/2, UART, CAN, USB, Ethernet.  
> * **Primitive:** Parametric MSB-first / LSB-first Shift Registers (8-bit to 32-bit width) with configurable shift-edge polarities.  
> * **Factored Logic:** Toggling data and clock pins bit-by-bit in microcode destroys instruction memory efficiency. Moving bit serialization to hardware allows the instruction core to push/pop full bytes or words via FIFO interfaces, executing at the byte/packet level rather than the bit level.

#### **3\. Framing, Stuffing & Line State Decoders**

> * **Shared Protocols:** USB 1.1, CAN, Ethernet, UART.  
> * **Primitives:**  
  * **NRZI / Manchester Transcoder:** Converts raw bitstreams to/from NRZI (USB) or Manchester (Ethernet) formatting in real time.  
  * **Bit-Stuffing / Unstuffing Engine:** Tracks consecutive identical bits (e.g., 6 consecutive 1s in USB or 5 in CAN) and automatically inserts/drops stuffed bits and flags stuffing errors without core intervention.  
  * **Open-Drain / Tri-State Direction Control:** Dynamically toggles GPIO output enable (OE) based on line state (essential for I2C ACK bits, SWD turnaround cycles, and single-ended USB SE0 detection).

#### **4\. Cyclic Redundancy Check (CRC) & Checksum Hardware**

> * **Shared Protocols:** CAN (CRC-15), Low-Speed USB (CRC-5 for tokens, CRC-16 for data), 10Mbit Ethernet (CRC-32/FCS).  
> * **Primitive:** A configurable Linear Feedback Shift Register (LFSR) with programmable polynomial, seed, and bit-reversal masks.  
> * **Factored Logic:** Computing CRC-32 for Ethernet frame check sequences or CRC-15 for CAN frames in microcode takes dozens of cycles per bit. An LFSR block processes bits in parallel with the shift register, reducing CRC overhead to zero execution cycles.

### **Protocols That Require 8b/10b (And Why You Can Skip It)**

**8b/10b encoding is NOT required** for any of the protocols on your target list:

> * **10Mbit Ethernet (10BASE-T):** Uses **Manchester encoding** (100% clock overhead, guaranteed transition every bit period). *8b/10b was introduced later for Fast Ethernet / Gigabit Ethernet (100BASE-TX / 1000BASE-T).*  
> * **Low-Speed USB 1.1:** Uses **NRZI with bit-stuffing** (0 or 1 transition per bit, forcing a transition after six consecutive ones).  
> * **CAN Bus:** Uses **NRZ with bit-stuffing** (stuff bit inserted after five identical consecutive bits).  
> * **UART / SPI / I2C / JTAG / SWD / PS2:** Raw binary NRZ with dedicated clock lines or start/stop framing bits.

*(Note: 8b/10b is only needed if you target high-speed protocols like PCIe, SATA, DisplayPort, or Gigabit Ethernet).*

### **Factored Hardware Architecture Overview**

 `+-----------------------------------------------------------------------+`  
 `|                            Execution Core                             |`  
 `|           (Microcode Instruction Unit / PRU / PIO Engine)             |`  
 `+-----------------------------------------------------------------------+`  
        `|                                                           ^`  
  `TX/RX FIFOs                                                   Interrupts`  
        `v                                                           |`  
 `+-----------------------------------------------------------------------+`  
 `|                         Shared Hardware Blocks                        |`  
 `|  +--------------------+  +-------------------+  +------------------+  |`  
 `|  | Configurable LFSR  |  |  Bit Stuffer /    |  | 8x Oversampling  |  |`  
 `|  | (CRC-5/16/15/32) |  | Manchester/NRZI   |  |   CDR Engine     |  |`  
 `|  +--------------------+  +-------------------+  +------------------+  |`  
 `|  +-----------------------------------------------------------------+  |`  
 `|  |        Parametric SerDes Shift Registers (MSB / LSB)            |  |`  
 `|  +-----------------------------------------------------------------+  |`  
 `+-----------------------------------------------------------------------+`  
                                    `|`  
                    `Configured Pin Mapping & Direction`  
                                    `v`  
 `+-----------------------------------------------------------------------+`  
 `|                           GPIO Pin Matrix                             |`  
 `+-----------------------------------------------------------------------+`

### **Tile Area & Performance Summary**

By offloading CRC calculation, bit-stuffing, Manchester conversion, and 8× oversampling into small dedicated RTL primitives, you achieve a massive reduction in logic footprint:

| Function | Firmware Cost (without hardware block) | Hardware Block Cost (in 130nm standard cells) |
| :---- | :---- | :---- |
| **8× CDR Edge Align** | \~15–20 instructions / bit | **\~60 cells** (3-bit counter \+ edge flop) |
| **CRC-32 (Ethernet)** | \~30 instructions / bit | **\~120 cells** (32-bit LFSR \+ XOR gates) |
| **Bit Unstuffing** | \~8 instructions / bit | **\~40 cells** (3-bit counter \+ compare logic) |
| **Manchester Code** | \~6 instructions / bit | **\~15 cells** (XOR gate \+ state register) |

Factoring these primitives out allows your programmable engine to stay extremely small (fitting comfortably within your 6x4 tile allocation) while easily keeping up with 10 Mbps line rates.

---

