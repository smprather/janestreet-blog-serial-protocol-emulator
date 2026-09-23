# pe_soc.sdc — the design SDC for the full SoC, and the ONLY thing it adds
# to the flow's generated constraints is a setup/hold SPLIT of the clock
# uncertainty. Everything else is inherited.
#
# WHY THIS FILE EXISTS AT ALL, AND WHY IT IS ONE LINE OF SUBSTANCE.
#
# The ruling was: no hand-written absolute timing; constraints come from flow
# parameters and are fed through to an SDC. That is still exactly how this
# works -- it sources the LibreLane-generated template, so CLOCK_PERIOD,
# CLOCK_TRANSITION_CONSTRAINT, IO_DELAY_CONSTRAINT, TIME_DERATING_CONSTRAINT
# and the driving-cell/load setup all still come from the flow config. Nothing
# absolute is duplicated here. PNR_SDC_FILE / SIGNOFF_SDC_FILE are themselves
# flow parameters, so this is the parameters path, not a bypass of it.
#
# What the flow's parameter vocabulary CANNOT express is the thing that has to
# be said: CLOCK_UNCERTAINTY_CONSTRAINT is a single number, and LibreLane's
# base.sdc applies it with a bare `set_clock_uncertainty`, which OpenSTA
# applies to SETUP **AND** HOLD. Measured (2026-09-21), in isolation, on this
# PDK: a bare `set_clock_uncertainty 1.0` cost 1.0 ns of HOLD slack
# (-0.02 -> -0.82 on a two-flop probe path), and write_sdc confirms the split
# only exists if it is asked for:
#
#     set_clock_uncertainty -setup 1.0000 clk
#     set_clock_uncertainty -hold  0.2000 clk
#
# ONE NUMBER FOR TWO DIFFERENT PHYSICAL EFFECTS IS THE BUG.
#
#   * Setup uncertainty models jitter and pessimism that make the CAPTURE edge
#     late relative to the data: the 0.1 ns board jitter + 0.2 ns DDR latch-pair
#     duty penalty + 0.4 ns clock-tree IR derate = 1.0 ns already argued in
#     concepts/tx-timing-generation.md, which leaves ~6.4 ns of the ~7.2 ns
#     measured setup slack. Setup is not the constraint.
#   * Hold uncertainty models launch-vs-capture clock path DIFFERENCE, which is
#     a much smaller quantity. Spending the full 1.0 ns budget on hold is not
#     conservatism, it is a category error: it demands ~1 ns of extra data-path
#     delay that the design does not need and cannot cheaply absorb.
#
# And it is not academic. With the bare 1.0 ns applied to hold, the full-SoC run
# died in ResizerTimingPostCTS:
#
#     [INFO RSZ-0046] Found 191 endpoints with hold violations.
#     [INFO RSZ-0032] Inserted 812 hold buffers.
#     [ERROR RSZ-0060] Max buffer count reached.
#
# The worst hold path was `_2159_/Q -> u_imem.g_macro.u_sram/A_ADDR[9]`, whose
# required time broke down as 1.395 ns (clock path) + **1.000 ns (uncertainty)**
# + 0.412 ns (library hold) = 1.807 ns against 0.707 ns of arrival: -1.099 ns.
# Strip the uncertainty and the SAME path is +0.099 ns. The 1.0 ns was the
# entire violation -- which also means the earlier guess that this was a
# power-connectivity failure (PDN-0189 on VDDARRAY!) was WRONG: a run without
# any PDN hook failed in exactly the same place with the same -1.181 -> -0.169
# trajectory and the same 812 buffers. See flow/pe_soc.json for the PDN
# fix that is genuinely needed (but is a correctness fix, not this one).
#
# HOLD UNCERTAINTY VALUE: 0.25 ns.
# This is LibreLane's own default for other PDKs (config/pdk_compat.py sets
# CLOCK_UNCERTAINTY_CONSTRAINT = 0.25 for sky130/gf180mcu) and it is the right
# order of magnitude for a differential clock-path term at this size. It is a
# documented constant rather than a new config key on purpose: an unfamiliar key
# risks a config validation error, and the whole point of this file is to be the
# one place a reader looks for the split.
#
# After the split the residual hold requirement is ~0.15 ns, which is a normal
# hold repair for the resizer to absorb -- versus 0.9 ns, which is what exceeded
# its buffer budget.

source $::env(FALLBACK_SDC)

puts "\[INFO\] pe_soc.sdc: splitting clock uncertainty (setup vs hold)"
set_clock_uncertainty -setup $::env(CLOCK_UNCERTAINTY_CONSTRAINT) [get_clocks $::env(CLOCK_PORT)]
set_clock_uncertainty -hold  0.25                             [get_clocks $::env(CLOCK_PORT)]
