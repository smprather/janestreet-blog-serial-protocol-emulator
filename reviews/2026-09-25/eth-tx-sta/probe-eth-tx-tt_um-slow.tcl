# ---------------------------------------------------------------------------
# PROBE: the 10BASE-T TX frame path's own timing classes, slow corner.
#
# The flat screen (sta-*.txt) cannot attribute a path to the engine: yosys's
# flatten erases the engine's net names, so everything becomes an anonymous
# _NNNN_ wire. This probe therefore reads the HIERARCHICAL mapped netlist
# (synth-hier-*.ys: identical flow, no `flatten`) and asks for paths THROUGH
# the named nets, which is how the Task-4 closeout screened the SERDES's new
# classes (probe-*-slow.tcl in reviews/2026-09-24/serdes-sta/).
#
# The five classes the plan asks about, one probe each:
#   * frame FSM + counters   through *u_eth_tx*state* / *pre_cnt* / *ifg_cnt*
#   * staging FIFO read path through *fifo_head* / *fifo_after* / *fifo_mem*
#   * FCS / CRC path         through *crc_state* / *crc_bit*
#   * the shared TX owner mux through *eth_tx_owner* / *tx_path*
#   * the pad mux             TO uo_out[2] (the G6 pad) and through *uo_out[2]*
#
# ZERO-ASSUMPTION constraints, matching sta-*-slow.tcl so the numbers are
# comparable with the flat screen. Slow is also the hold corner.
#
# Mapped pre-layout screen only: no placement, routing, DRC or LVS.
# ---------------------------------------------------------------------------
set design tt_um_protocol_emulator
set netlist ./sta-hier-tt_um.v
read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_slow_1p08V_125C.lib
read_liberty /home/mylesp/pdk/IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_1024x16_c2_bm_bist_slow_1p08V_125C.lib
read_verilog $netlist
link_design $design
create_clock -name clk -period 16.667 -waveform {0 8.3335} [get_ports clk]
set_clock_uncertainty -setup 1.0 [get_clocks clk]
set_clock_uncertainty -hold 0.25 [get_clocks clk]
if { [llength [get_ports uio_in*]] } {
  set_input_delay -clock clk -max 3.3334 [get_ports {rst_n ena ui_in* uio_in*}]
  set_input_delay -clock clk -min 0.0 [get_ports {rst_n ena ui_in* uio_in*}]
  set_input_transition 0.1 [get_ports {rst_n ena ui_in* uio_in*}]
} else {
  set_input_delay -clock clk -max 3.3334 [get_ports {rst_n host_* run pin_in*}]
  set_input_delay -clock clk -min 0.0 [get_ports {rst_n host_* run pin_in*}]
  set_input_transition 0.1 [get_ports {rst_n host_* run pin_in*}]
}
set_output_delay -clock clk -max 3.3334 [all_outputs]
set_output_delay -clock clk -min 0.0 [all_outputs]
set_load 0.02 [all_outputs]

proc probe {label pattern} {
  set nets [get_nets -quiet $pattern]
  if { [llength $nets] == 0 } {
    puts "===== PROBE $label: no net matches $pattern (skipped)"
    return
  }
  puts "===== PROBE max $label ($pattern, [llength $nets] nets)"
  report_checks -path_delay max -through $nets -group_path_count 2 -format full_clock_expanded -digits 4
  puts "===== PROBE min $label"
  report_checks -path_delay min -through $nets -group_path_count 2 -format full_clock_expanded -digits 4
}

# 1. the frame FSM and its counters
probe "frame-fsm"      *u_eth_tx*state*
probe "preamble-cnt"   *u_eth_tx*pre_cnt*
probe "ifg-cnt"        *u_eth_tx*ifg_cnt*
# 2. the staging FIFO read path
probe "fifo-read"      *u_eth_tx*fifo_head*
probe "fifo-mem"       *u_eth_tx*fifo_mem*
# 3. the FCS / CRC path
probe "crc-state"      *u_tx_crc*crc_state*
probe "crc-bit"        *u_tx_crc*crc_bit*
# 4. the shared TX owner mux
probe "owner-mux"      *eth_tx_owner*
probe "tx-path"        *u_eth_tx*tx_path*
# 5. the G6 pad mux: report TO the reclaimed pad itself
if { [llength [get_ports -quiet uo_out[2]]] } {
  puts "===== PROBE max to the G6 pad uo_out[2]"
  report_checks -path_delay max -to [get_ports uo_out[2]] -group_path_count 3 -format full_clock_expanded -digits 4
  puts "===== PROBE min to the G6 pad uo_out[2]"
  report_checks -path_delay min -to [get_ports uo_out[2]] -group_path_count 3 -format full_clock_expanded -digits 4
} else {
  puts "===== PROBE G6 pad: this design has no uo_out[2] port (pe_soc screen)"
  probe "pad-mux-net"  *pin_out_bus[7]*
}
exit
