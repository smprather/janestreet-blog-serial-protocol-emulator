# ---------------------------------------------------------------------------
# VARIANT: BOARD-ASSUMPTION screening constraints.
#
# SCREENING ASSUMPTION, NOT A SPEC. A same-board source-synchronous launch is
# assumed to arrive at the pad no earlier than 1.0 ns after its reference
# clock edge, and an external receiver's hold window is assumed to start no
# earlier than 1.0 ns after the edge. Budget floor (screening estimates, not
# characterised): driver/level-shifter launch skew ~0.1-0.2 ns + 5-10 cm FR-4
# microstrip at ~6.7 ns/m (0.33-0.67 ns) + header/connector ~0.1-0.3 ns +
# pad-ring input ~0.1-0.2 ns >= 1.0 ns. Max delays stay at the recorded
# 3.3334 ns screening value. Every MET claim in this report is scoped to this
# 1.0 ns assumption -- see
# reviews/2026-09-24/HOLD-SCREEN-ATTRIBUTION.md.
# ---------------------------------------------------------------------------
read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib
read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_1024x16_c2_bm_bist_typ_1p20V_25C.lib
read_verilog ./sta-tt_um.v
link_design tt_um_protocol_emulator
create_clock -name clk -period 16.667 -waveform {0 8.3335} [get_ports clk]
set_clock_uncertainty -setup 1.0 [get_clocks clk]
set_clock_uncertainty -hold 0.25 [get_clocks clk]
# Pre-layout screening assumptions, not board or routed signoff constraints.
set_input_delay -clock clk -max 3.3334 [get_ports {rst_n ena ui_in* uio_in*}]
set_input_delay -clock clk -min 1.0 [get_ports {rst_n ena ui_in* uio_in*}]
set_input_transition 0.1 [get_ports {rst_n ena ui_in* uio_in*}]
set_output_delay -clock clk -max 3.3334 [all_outputs]
set_output_delay -clock clk -min 1.0 [all_outputs]
set_load 0.02 [all_outputs]
check_setup -verbose
report_checks -path_delay max -group_path_count 5 -format full_clock_expanded -digits 4
report_checks -path_delay min -group_path_count 5 -format full_clock_expanded -digits 4
report_check_types -max_slew -max_capacitance -max_fanout -violators
report_worst_slack -max
report_worst_slack -min
# ---- negative-min-slack inventory (this variant's constraints) -------------
# Worst min paths per endpoint (up to 4 per endpoint), all with slack <= 0,
# in summary format. Parsed by analyze_hold.py to attribute the negatives to
# classes; the endpoint cap is OpenSTA's, so "every endpoint whose worst min
# path is negative" is covered, with secondary paths shown where they exist.
puts "===== NEGATIVE-MIN INVENTORY (slack <= 0)"
report_checks -path_delay min -slack_max 0 -group_path_count 1000 -endpoint_path_count 4 -format summary -digits 4
exit
