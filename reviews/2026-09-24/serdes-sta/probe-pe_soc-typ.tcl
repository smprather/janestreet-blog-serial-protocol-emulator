read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib
read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_1024x16_c2_bm_bist_typ_1p20V_25C.lib
read_verilog ./mapped-pe_soc.v
link_design pe_soc
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
puts "===== PROBE max-to-pads"
report_checks -path_delay max -to [get_ports {pin_out* uo_out* uio_out*}] -group_path_count 3 -format full_clock_expanded -digits 4
puts "===== PROBE min-to-pads"
report_checks -path_delay min -to [get_ports {pin_out* uo_out* uio_out*}] -group_path_count 3 -format full_clock_expanded -digits 4
puts "===== PROBE max-through-half_phase"
report_checks -path_delay max -through [get_nets *half_phase*] -group_path_count 3 -format full_clock_expanded -digits 4
puts "===== PROBE min-through-half_phase"
report_checks -path_delay min -through [get_nets *half_phase*] -group_path_count 3 -format full_clock_expanded -digits 4
puts "===== PROBE max-through-win_regs"
report_checks -path_delay max -through [get_nets *win_regs*] -group_path_count 3 -format full_clock_expanded -digits 4
puts "===== PROBE min-through-win_regs"
report_checks -path_delay min -through [get_nets *win_regs*] -group_path_count 3 -format full_clock_expanded -digits 4
puts "===== PROBE max-through-serdes_tx_bit_en"
report_checks -path_delay max -through [get_nets *serdes_tx_bit_en*] -group_path_count 3 -format full_clock_expanded -digits 4
puts "===== PROBE min-through-serdes_rx_bit_en"
report_checks -path_delay min -through [get_nets *serdes_rx_bit_en*] -group_path_count 3 -format full_clock_expanded -digits 4
exit
