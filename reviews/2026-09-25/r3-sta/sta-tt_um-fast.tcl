# ---------------------------------------------------------------------------
# R3 debug-control screen: tt_um / fast / ZERO-ASSUMPTION
# # ZERO-ASSUMPTION screening constraints: 0 ns min input/output delay. Under this
# variant every negative min slack on an input or output path is a property of the
# ZERO assumption, not of the design -- see the -board sibling.
# Slow is also the hold corner. The clock-uncertainty SPLIT (setup 1.0, hold 0.25)
# is the flow's own (flow/pe_soc.sdc): LibreLane's base.sdc applies one number to
# BOTH, which costs 1.0 ns of hold slack for jitter that is a capture-edge
# concern only.
# ---------------------------------------------------------------------------
read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_fast_1p32V_m40C.lib
read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_1024x16_c2_bm_bist_fast_1p32V_m55C.lib
read_verilog ./sta-tt_um.v
link_design tt_um_protocol_emulator
create_clock -name clk -period 16.667 -waveform {0 8.3335} [get_ports clk]
set_clock_uncertainty -setup 1.0 [get_clocks clk]
set_clock_uncertainty -hold 0.25 [get_clocks clk]
# Pre-layout screening assumptions, not board or routed signoff constraints.
set_input_delay -clock clk -max 3.3334 [get_ports {rst_n host_* run pin_in*}]
set_input_delay -clock clk -min 0.0 [get_ports {rst_n host_* run pin_in*}]
set_input_transition 0.1 [get_ports {rst_n host_* run pin_in*}]
set_output_delay -clock clk -max 3.3334 [all_outputs]
set_output_delay -clock clk -min 0.0 [all_outputs]
set_load 0.02 [all_outputs]
check_setup -verbose
report_checks -path_delay max -group_path_count 5 -format full_clock_expanded -digits 4
report_checks -path_delay min -group_path_count 5 -format full_clock_expanded -digits 4
report_check_types -max_slew -max_capacitance -max_fanout -violators
report_worst_slack -max
report_worst_slack -min
# ---- negative-min-slack inventory (this variant's constraints) -------------
# Worst min paths per endpoint (up to 4 per endpoint), slack <= 0, summary format.
# Parsed by analyze_hold.py to attribute the negatives to classes.
puts "===== NEGATIVE-MIN INVENTORY (slack <= 0)"
report_checks -path_delay min -slack_max 0 -group_path_count 1000 -endpoint_path_count 4 -format summary -digits 4
exit
