read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_fast_1p32V_m40C.lib
read_verilog /tmp/pe-ctrl-hardening-check/mapped.v
link_design pe_ctrl
create_clock -name clk -period 16.667 -waveform {0 8.3335} [get_ports clk]
set_clock_uncertainty -setup 1.0 [get_clocks clk]
set_clock_uncertainty -hold 0.25 [get_clocks clk]
set_false_path -from [get_ports {spi_sclk spi_mosi spi_cs_n}]
set_input_delay -clock clk -max 3.3334 [get_ports {run rst_n}]
set_input_delay -clock clk -min 0.0 [get_ports {run rst_n}]
set_input_transition 0.1 [get_ports {run rst_n}]
set_output_delay -clock clk -max 3.3334 [all_outputs]
set_output_delay -clock clk -min 0.0 [all_outputs]
set_load 0.02 [all_outputs]
check_setup -verbose
report_checks -path_delay max -group_path_count 5 -format full_clock_expanded -digits 4
report_checks -path_delay min -group_path_count 5 -format full_clock_expanded -digits 4
report_check_types -max_slew -max_capacitance -max_fanout -violators
report_worst_slack -max
report_worst_slack -min
exit
