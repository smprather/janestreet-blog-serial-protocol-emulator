# Tiny Tapeout shared-silicon run: collected specs

Fetched **2026-10-18**; updated **2026-11-10**. This is a local, source-backed
spec pack for the Tiny Tapeout shared-silicon model and the IHP SG13CMOS5L
shuttle path used by this project. Raw captures and extracted text live in
`sources/`; the full URL/sha256 manifest is `sources.json` and the
human-readable index is `SOURCES.md`.

> **2026-11-09 template move.** The `ttihp-verilog-template` **main branch now
> targets CMOS5L**; the `cmos5l` branch is retired. The captures under
> `sources/` are the 2026-10-18 `cmos5l`-branch snapshot and are kept as
> provenance. Where they disagree with the current main branch, main wins:
> a single tile is **202×155 µm**, the valid tile list includes **8×4**, and the
> competition allocation is **8×4 = 32 tiles**.

> **Scope.** Tiny Tapeout’s public spec pages (`tinytapeout.com/specs/*`) are
> still framed around the **sky130** pad macro. The IHP CMOS5L template on
> **main**, `tt-gds-action@ttihp27a`, and the IHP PDK are the authoritative
> sources for the CMOS5L flow. Where a value is sky130-only it is labelled
> below; do not silently carry it into an IHP design.

## Source key

| Key | Local source | What it covers |
|---|---|---|
| `MUX` | `sources/tt-multiplexer-INFO.md` | Mux/spine/controller, tile count, QFN pinouts |
| `IHP25A` | `sources/ttihp25a-datasheet.txt` | IHP shuttle datasheet: mux, pad frame, chip ROM |
| `GPIO` | `sources/tt-specs-gpio.txt` | 26 I/O pins, sky130 pad limits |
| `CLOCK` | `sources/tt-specs-clock.txt` | Clock/reset, insertion delay, demo-board clock |
| `ANALOG` | `sources/tt-specs-analog.txt` | Analog pins, power rails, analog switch |
| `MEM` | `sources/tt-specs-memory.txt` | Registers, latches, DFF RAM, SRAM macros |
| `FAQ` | `sources/tt-faq.txt` | Generic shuttle FAQ, tile size, default project |
| `TEMPLATE` | `sources/ttihp-template-info.txt`, `sources/ttihp-template-config.json` | IHP CMOS5L `info.yaml` / LibreLane defaults |
| `TTTOOLS` | `sources/tt-support-tools-project_info.txt`, `sources/tt-support-tools-project.txt` | `info.yaml` schema and top-port validation |
| `ACTION` | `sources/tt-gds-action-ihp-cmos5l.yml`, `sources/tt-gds-action-install-sg13cmos5l.sh` | 2026-10-18 `ihp-cmos5l`-branch action; template main now uses `@ttihp27a` |
| `PDK` | `sources/ihp-cmos5l-librelane-config.txt`, `sources/ihp-cmos5l-stdcell-config.txt` | CMOS5L stack, pins, corners, layers |
| `IHP TECH` | `sources/tt-support-tools-ihp-tech.txt` | IHP PDK args, cell prefix, power-gate macros |

## 1. Shared-silicon model

A Tiny Tapeout chip is a **shared die**: many user designs are placed as tiles
on one chip, and a **multiplexer selects exactly one active design at a time**.

- **Capacity:** up to **512 user designs** = 32 mux units × up to 16 designs each.
- **Tile:** the basic placement unit. A design can occupy **up to 16 tiles**.
- **Mux address:** 10-bit global `si_sel`; each mux unit has a 5-bit hard-coded
  address and selects the matching design from the remaining address bits.
- **Controller inputs:** `ctrl_ena`, `ctrl_sel_inc`, `ctrl_sel_rst_n`.
  Reset the 10-bit counter with `sel_rst_n` low, then pulse `sel_inc` N times
  to select design address N.
- **Active design:** `clk`, `rst_n`, `ui_in[7:0]`, `uio_in[7:0]` are driven
  from the spine through buffers; `uo_out[7:0]`, `uio_out[7:0]`,
  `uio_oe[7:0]` drive back through tristate buffers.
- **Inactive designs:** `clk`, `rst_n`, `ui_in`, `uio_in` are tied to zero;
  `uo_out`, `uio_out`, `uio_oe` are disconnected (tristate disabled).
- **`ena`:** buffered from the controller to the mux units. The template
  comment says it is “always 1 when the design is powered”, so a design may
  ignore it; the mux still uses `si_ena` to gate the active branch.
- **Power gating:** **TTIHP25A does not power-gate designs**; they are powered
  from the start. `ena` is the logical select, not a power switch. `IHP25A`

## 2. Tiles, die and allocation

| Item | Value | Source |
|---|---|---|
| Generic TT tile (TT04–TT10) | ~160 × 100 µm | `FAQ` |
| IHP CMOS5L template tile | **202 × 155 µm** | template main (2026-11-09); captures show the old 167 × 108 |
| IHP template tile choices | `1x1, 1x2, 2x2, 3x2, 4x2, 6x2, 8x2, 3x4, 4x4, 5x4, 6x4, 8x4` | template main |
| Max tiles per design | 16 | `MUX` |
| Max designs per chip | 512 (32 mux units × 16) | `MUX` |
| Competition allocation | **8×4 = 32 tiles = 1616 × 620 µm² (1.002 mm²)** | competition blog 2026-11-09 / repo `info.yaml` |
| TT notation | **WIDTH × HEIGHT**, not count | `FAQ`, `TEMPLATE` |
| Default project size | 1×1 | `FAQ` |
| Package | QFN-64, chip on breakout board | `MUX`, `IHP25A` |

The 8×4 competition allocation is now one of the IHP template’s listed tile
strings. The repo uses `tiles: "8x4"` and `DIE_AREA = [0, 0, 1616, 620]`.

## 3. Per-design digital interface

The user top module must be named `tt_um_*` and expose exactly:

| Port | Direction | Width | Meaning |
|---|---|---:|---|
| `clk` | input | 1 | user clock |
| `rst_n` | input | 1 | active-low reset |
| `ena` | input | 1 | design enabled/selected; “always 1 when powered” |
| `ui_in` | input | 8 | dedicated inputs |
| `uo_out` | output | 8 | dedicated outputs |
| `uio_in` | input | 8 | bidirectional input path |
| `uio_out` | output | 8 | bidirectional output path |
| `uio_oe` | output | 8 | 1 = drive `uio_out`; 0 = release/high-Z |
| `ua` | inout | 6 usable | analog pins, only if analog (`analog_pins`) |

- All outputs must be assigned; unused inputs should be listed to avoid warnings.
- Extra ports are rejected by `tt-support-tools` port validation.
- `clk`, `rst_n`, `ui_in[7:0]`, `uio_in[7:0]` are all bits of the same
  `pad_ui_in` bus; there is no dedicated clock tree or balanced insertion.
- `VPWR` is accepted and substituted as `VDPWR`; the validator knows
  `VGND`, `VDPWR`, and optional `VAPWR` when power ports are included.
  The IHP template `project.v` uses only the signal ports; the mux/pad frame
  supplies power. `TTTOOLS`, `TEMPLATE`

## 4. `info.yaml` v6 schema and submission fields

Required/validated by `tt-support-tools` `ProjectInfo`:

```yaml
yaml_version: 6
project:
  title: "..."
  author: "..."
  description: "..."
  language: "Verilog"
  clock_hz: 60000000          # integer
  tiles: "8x4"                # must be in the shuttle's tile-size set
  top_module: "tt_um_..."     # must start tt_um_
  source_files: ["..."]       # each source file listed separately
  analog_pins: 0              # 0..6; >0 makes the design analog
  uses_vapwr: false           # or legacy uses_3v3; requires an analog pin
  discord: ""                 # optional
  doc_link: ""                # optional
pinout:
  ui[0..7]: ""
  uo[0..7]: ""
  uio[0..7]: ""
```

- `pinout` keys are exactly `ui[0..7]`, `uo[0..7]`, `uio[0..7]`; `ua[0..5]`
  is optional/analog.
- `source_files` must exist under `src/`; wildcards are not allowed.
- `clock_hz` is an integer (Hz), not a string.
- The top module must be unique and start with `tt_um_`.
- `TEMPLATE`, `TTTOOLS`

## 5. IHP SG13G2 / CMOS5L pad frame (QFN-64)

The mux and pad frame are **chip-level**, outside the user design. The IHP
custom pad frame in the TTIHP25A datasheet uses 64 die pads plus the exposed
pad (EPAD) ground. QFN pin = die pad + 1 for pads 0–63.

| Die pads | QFN pins | Function |
|---|---|---|
| 0–2 | 1–3 | mux control: `ctrl_ena`, `ctrl_sel_inc`, `ctrl_sel_rst_n` |
| 3–7 | 4–8 | reserved |
| 8–15 | 9–16 | `uo[0..7]` |
| 16 | 17 | VDD IO |
| 17 | 18 | GND IO |
| 18–21 | 19–22 | `analog[0..3]` |
| 22 | 23 | VDD Analog |
| 23 | 24 | GND Analog |
| 24–27 | 25–28 | `analog[4..7]` |
| 28 | 29 | GND Core |
| 29 | 30 | VDD Core |
| 30 | 31 | GND IO |
| 31 | 32 | VDD IO |
| 32–39 | 33–40 | `uio[0..7]` |
| 40–47 | 41–48 | `ui[0..7]` |
| 48 | 49 | `u_rst_n` |
| 49 | 50 | `u_clk` |
| 50 | 51 | GND IO |
| 51 | 52 | VDD IO |
| 52–55 | 53–56 | `analog[8..11]` |
| 56 | 57 | GND Analog |
| 57 | 58 | VDD Analog |
| 58–61 | 59–62 | `analog[12..15]` |
| 62 | 63 | GND Core |
| 63 | 64 | VDD Core |
| SUB / EPAD | EPAD | GND |

- `u_clk` and `u_rst_n` are **not special inside the pad frame**; they are bits
  in the `pad_ui_in` bus, named for convenience. `IHP25A`, `MUX`
- The datasheet table is labelled “IHP SG13G2 custom pad frame”. The CMOS5L
  PDK ships `sg13cmos5l_io`; verify the exact CMOS5L shuttle pinout against its
  own datasheet before wiring a board.
- The design itself instantiates **no pads**. Its `ui_in`/`uo_out`/`uio_*`
  ports connect to the mux; the mux/pad frame are outside the tile allocation.

## 6. Clock, reset and electrical limits

### Clock/reset

- `clk` and `rst_n` are ordinary input bits, not a dedicated clock network.
- **sky130 pad spec:** input max 66 MHz, output max 33 MHz, insertion delay up
  to 10 ns; demo board clock 1 Hz–66.5 MHz from an RP2040. These are
  **sky130-framed**, not IHP numbers. `CLOCK`, `GPIO`
- **IHP CMOS5L template default:** `CLOCK_PERIOD: 20` ns (50 MHz), selected in
  `src/config.json`; the template says increase it for setup violations.
  `TEMPLATE`
- **This competition:** 60 MHz (16.667 ns) operating point, chosen in
  `info.yaml` and both flow configs.
- `rst_n` is active-low. The chip ROM uses `rst_n` high to address by `ui_in`
  and `rst_n` low to read sequentially on `clk` (see §8).
- **IHP-specific max clock and pad insertion delay are not published in the
  sources fetched here.** Treat 66 MHz/10 ns as sky130 numbers until the IHP
  shuttle datasheet or pad macro timing says otherwise.

### Supply / IO

- IHP CMOS5L core nominal: **1.20 V** (`VDD_PIN_VOLTAGE = 1.20`,
  `VDD_PIN = VPWR`, `GND_PIN = VGND`); stdcell/IO Liberty includes
  `typ_1p20V`, `fast_1p32V`, `slow_1p08V` corners. `PDK`
- CMOS5L IO library is `sg13cmos5l_io`, characterized with 1.2 V core /
  3.3 V IO in the corner Liberty names (`..._1p2V_3p3V_25C.lib`). `PDK`
- TT’s IHP power-gate macros are named `tt_pg_1v5_*` (1.5 V family); confirm the
  actual board/IO rail for the shuttle rather than inferring it from the name.
  `IHP TECH`
- **sky130 pad spec (not IHP):** IO 1.71–5.5 V, demo board 3.3 V, 4 mA
  source/sink, inputs not 5 V tolerant. `GPIO`
- **TTIHP25A:** designs are **not power-gated**; they are powered from the
  start. `IHP25A`

### Analog

- Generic TT: `ua[0..5]` (6 usable of 8 template pins); analog projects are
  1×2 or 2×2 tiles; an analog switch (`tt_asw_3v3` on sky130) sits between the
  design and the pads. `VDPWR` = 1.8 V digital core, `VAPWR` = 3.3 V analog
  (optional, requires an analog pin). `ANALOG`
- IHP CMOS5L: `analog_pins` is still part of the v6 schema, but the fetched
  IHP action/template does not show an analog-switch macro list; confirm
  analog availability on the actual shuttle before relying on it.

## 7. Memory options

- Registers: about **320 DFFs per tile** (≈40 bytes), less after logic.
- Latches: ≈512 bits per tile reported in examples.
- DFF RAM: available; power/ground connection is nontrivial.
- `RAM32` macro: 128 bytes (32×32 bits), 1RW, **401 × 136 µm**, fits 3×2 tiles
  at about 54% area.
- Pregenerated SRAM macros are supported; IHP CMOS5L ships
  `sg13cmos5l_sram` as a symlink to the shared SG13G2 SRAM macros
  (`RM_IHPSG13_*`, 30 fixed shapes, no compiler). `MEM`, `PDK`
- This project’s macro: `RM_IHPSG13_1P_1024x16_c2_bm_bist` (1024×16, BIST +
  bitmask), used for instruction memory and frame buffer.

## 8. Chip ROM and mux control

The chip ROM is an **8-bit × 256-byte** ROM generated by `tt-support-tools`:

| Address | Length | Encoding | Contents |
|---:|---:|---|---|
| 0 | 8 | 7-segment | shuttle name, null-padded |
| 8 | 8 | 7-segment | git commit hash |
| 32 | 96 | ASCII | chip descriptor (`shuttle=`, `repo=`, `commit=`) |
| 248 | 4 | binary | magic `"TT\xFA\xBB"` |
| 252 | 4 | binary | CRC32 of ROM contents, little-endian |

Read modes:

- `rst_n` high: drive `ui_in` with the desired address; data appears on
  `uo_out`.
- `rst_n` low: toggle `clk` to read sequentially from address 0; data on
  `uo_out`. `IHP25A`

Mux control is separate from the user design: `ctrl_sel_rst_n` resets the
10-bit counter, `ctrl_sel_inc` advances it, `ctrl_ena` enables the selected
branch. `MUX`, `IHP25A`

## 9. Hardening / submission path (IHP CMOS5L)

Current Tiny Tapeout CMOS5L action in the template's **main** branch
(checked 2026-11-10):

```yaml
uses: TinyTapeout/tt-gds-action@ttihp27a
with:
  pdk: ihp-sg13cmos5l
```

The same tag is used for the `precheck`, `gl_test` and `viewer` jobs. The
2026-10-18 captures show the older `@ihp-cmos5l` branch, which is retired for
the template; do not copy its `tools-ref`/`librelane-version` inputs.

The action:

1. checks out the template and `tt-support-tools`;
2. runs `tt_tool.py --create-user-config` with `--ihp`;
3. installs the IHP-Open-PDK for `ihp-sg13cmos5l`;
4. runs `tt_tool.py --harden --ihp`;
5. prints the linter, Yosys warnings, routing stats and cell-category summary;
6. creates `tt_submission/` and a GDS render;
7. runs precheck and gate-level test jobs. `ACTION` (captured branch)

Local hardening docs are generic and currently show older values
(`ihp-sg13g2`, LibreLane 3.0.3); the action is the current CMOS5L authority.
`tt-local-hardening`, `ACTION`

## 10. IHP SG13CMOS5L PDK facts

| Item | Value |
|---|---|
| PDK name | `ihp-sg13cmos5l` |
| Standard-cell library | `sg13cmos5l_stdcell` (84 cells, `sg13cmos5l_*`) |
| IO library | `sg13cmos5l_io` |
| Process | 130 nm CMOS, 5-metal stack **M1–M4–TopMetal1** |
| Missing layers | no Metal5, no TopMetal2 |
| Routing layers | `RT_MIN_LAYER=Metal2`, `RT_MAX_LAYER=TopMetal1` |
| PDN layers | rails Metal1; vertical Metal4; horizontal TopMetal1 |
| Core supply | 1.20 V nominal (`VPWR`/`VGND`) |
| Corners | `nom_typ_1p20V_25C`, `nom_fast_1p32V_m40C`, `nom_slow_1p08V_125C` |
| Streamout | KLayout (`PRIMARY_GDSII_STREAMOUT_TOOL=klayout`); Magic lacks CMOS5L support |
| SRAM | `sg13cmos5l_sram` → shared SG13G2 `sg13g2_sram` macros |
| PDK source pin | IHP-Open-PDK `2bbec755dc67ca3db0261c3d6163e15735d66710` |
| Flow tool | LibreLane `3.1.0.dev3` |

`PDK`, `ACTION`, `IHP TECH`

## 11. Demo board / chip control

- Chip is mounted on a breakout board; QFN-64.
- Demo board carries an RP2040, USB-C, DIP switches, 7-segment display, PMOD
  headers and a MicroPython SDK/Commander.
- RP2040 selects the active design, generates the project clock, and can
  emulate SPI RAM; newer boards use RP2350.
- Generic TT04+ docs say the RP2040 generates up to 50 MHz; the clock spec page
  says the demo board supports 1 Hz–66.5 MHz. Treat the lower 50 MHz figure as
  the conservative board limit unless the current board page says otherwise.
  `FAQ`, `CLOCK`, `PCB`

## 12. Open / must-verify for the March 2027 CMOS5L shuttle

1. ~~Exact tile size and allowed tile strings for the CMOS5L shuttle.~~
   **Resolved 2026-11-09:** 202×155 µm per tile; 8×4 is valid and is the
   competition allocation.
2. IHP-specific maximum input clock, pad insertion delay, output frequency,
   drive strength and IO supply range.
3. Whether the CMOS5L shuttle supports analog pins and which switch macro is
   used.
4. CMOS5L pad-frame pinout (the fetched datasheet table is labelled SG13G2;
   the CMOS5L PDK has its own `sg13cmos5l_io`).
5. Whether the shuttle power-gates designs (TTIHP25A does not).
6. Exact current shuttle identifier and project-count limits.

## 13. Querying

Everything is plain text under this directory:

```bash
# spec text and source snippets
rg -n "mux|tile|pad|clock|analog|VPWR|8x4" docs/tt-shared-silicon

# source manifest
python3 -m json.tool docs/tt-shared-silicon/sources.json

# a single raw capture
less docs/tt-shared-silicon/sources/tt-multiplexer-INFO.md
```

The directory is also indexed in context-mode; use `ctx_search` against the
`docs/tt-shared-silicon` label for question-style lookup.
