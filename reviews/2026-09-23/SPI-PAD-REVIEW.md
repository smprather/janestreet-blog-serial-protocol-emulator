# SPI pad exposure review — 2026-09-23

## Scope

Reviewed the wrapper change that exposes the SPI firmware's MOSI and CS_N
outputs on uio[2] and uio[3], together with the pad-level test, pin metadata,
pin-budget update, and current hardening evidence.

## Findings

No blocking RTL or pin-mapping findings.

The mapping is internally consistent:

| Signal | SoC port bit | TT pad |
|---|---:|---|
| UART TX / SPI SCLK | 0 out | uo_out[0] |
| UART RX / SPI MISO | 3 in | ui_in[0] |
| SPI MOSI | 1 out | uio[2] |
| SPI CS_N | 2 out | uio[3] |
| I2C SDA / SCL | 4 / 5 bidirectional | uio[0] / uio[1] |

The two new outputs use the pin matrix's independent output enables. The
remaining uio[7:4] pads stay released. SCLK/MISO alias the UART pads because
the UART and SPI firmware personas do not run at the same time. The passive
SPI loader remains on ui_in[3:5].

## Verification

- tb_tt_um_protocol_emulator completes a real loader phase, then runs eight
  SPI frames using the TT pads. The modeled slave captures 0x5B on MOSI,
  returns the expected receive sequence through MISO, and checks eight clocks
  per CS_N frame.
- Four wrapper mutations were detected: wrong MOSI source, disabled MOSI OE,
  wrong CS_N source, and disabled CS_N OE.
- ./regress/run_all.sh --fast -j8: 29/29 RTL testbenches, 20/20 firmware
  tests, parameter guards and lint clean; all seven mutation suites passed.
- ./regress/synth_area.sh completed without synthesis errors. The current
  mapped counts are 3,298 cells for pe_soc and 3,613 for tt_um_top.

The wrapper changes are combinational pad aliases and add no sequential timing
path, so no new STA run was needed. The existing core signoff remains at
60 MHz. No physical flow, DRC, or LVS was run.

## Documentation updates

info.yaml and the generated pin budget identify uo_out[0] as the shared
UART TX / SPI SCLK pad. wiki/STATUS.md now uses the current programmable-SoC
label and synthesis totals. The SPI pad plan is in wiki/plans/spi-pads.md.

The project architecture and progress maps are maintained as text in
diagrams/project-plan.puml and diagrams/project-progress.puml. The plan map
includes the committed baseline and stretch goals, with optional protocol
targets separated. The progress map marks integrated/verified blocks green,
standalone verified blocks amber, and incomplete work red.

## Remaining work

The next software candidate is a pe_ctrl readback path. The passive loader
has no MISO today. The SERDES and codec mux are built and verified in isolation
but are not integrated into pe_soc; Ethernet transmit and board-level
acceptance remain open.
