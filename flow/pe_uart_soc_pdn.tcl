# pe_uart_soc_pdn.tcl — PDN config for the full SoC, with the SRAM macro's
# Metal4 supplies connected.
#
# WHY THIS FILE EXISTS.
#
# LibreLane's stock PDN config (scripts/openroad/common/pdn_cfg.tcl) builds the
# stdcell grid on TopMetal1/TopMetal2 with Metal1 rails, and defines a macro
# grid that connects TopMetal1 <-> TopMetal2 only:
#
#     define_pdn_grid -macro -default -name macro -halo "10 10"
#     add_pdn_connect -grid macro -layers "$PDN_VERTICAL_LAYER $PDN_HORIZONTAL_LAYER"
#
# That assumes a macro whose supply pins are reachable on the top two metals.
# THIS macro is not one of those. The IHP RM_IHPSG13_1P_1024x16's supplies
# (VDD!, VSS!, VDDARRAY!) are brought out on **Metal4**, as vertical stripes
# running the full height of the macro -- measured from the placed DEF:
#
#     VSS! spans Metal4, x = 9.88..226.92, full height y = 0..336.46
#     VDD! spans Metal4, x = 4.26..232.54, full height or 0..38.825 (core taps)
#
# so the macro's own supply geometry sits three to four layers BELOW the grid
# that is supposed to feed it. `PDN_MACRO_CONNECTIONS` makes OpenROAD *connect*
# the pins logically (that part works -- VDD!/VSS!/VDDARRAY! all land on
# VPWR/VGND), but connecting a pin is not the same as building a physical path
# to it. There is no Metal4 geometry on VPWR at all, so `check_power_grid`
# reports the macro's Metal4 straps as ~50 unconnected shapes (PSM-0038), and
# the router -- which is free to use Metal4 for signal -- shorts into them.
#
# THE FIX: extend the macro grid DOWN to Metal4. Add a Metal4 stripe set over
# the macro's halo and connect Metal1 rails -> Metal4 -> TopMetal1, so the
# macro's stripes have a real path up to the grid.
#
# This is the same structure the stdcell grid already uses (rails on Metal1,
# a `add_pdn_connect -layers "$PDN_RAIL_LAYER $PDN_VERTICAL_LAYER"`), just
# stopped at the wrong layer for this macro.
#
# HOW IT IS WIRED IN: set PDN_CFG to this file in the flow config. LibreLane
# only substitutes its default when PDN_CFG is None (steps/openroad.py:1479).

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd

        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }

    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd

        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary


if { $::env(PDN_MULTILAYER) == 1 } {

    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_HORIZONTAL_LAYER) \
        -width $::env(PDN_HWIDTH) \
        -pitch $::env(PDN_HPITCH) \
        -offset $::env(PDN_HOFFSET) \
        -spacing $::env(PDN_HSPACING) \
        -starts_with POWER \
        {*}$arg_list

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
} else {

    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list
}

# Adds the standard cell rails if enabled.
if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
}


# Adds the core ring if enabled.
if { $::env(PDN_CORE_RING) == 1 } {
    if { $::env(PDN_MULTILAYER) == 1 } {
        set arg_list [list]
        append_if_flag arg_list PDN_CORE_RING_ALLOW_OUT_OF_DIE -allow_out_of_die
        append_if_flag arg_list PDN_CORE_RING_CONNECT_TO_PADS -connect_to_pads
        append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

        set pdn_core_vertical_layer $::env(PDN_VERTICAL_LAYER)
        set pdn_core_horizontal_layer $::env(PDN_HORIZONTAL_LAYER)

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            set pdn_core_vertical_layer $::env(PDN_CORE_VERTICAL_LAYER)
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            set pdn_core_horizontal_layer $::env(PDN_CORE_HORIZONTAL_LAYER)
        }

        add_pdn_ring \
            -grid stdcell_grid \
            -layers "$pdn_core_vertical_layer $pdn_core_horizontal_layer" \
            -widths "$::env(PDN_CORE_RING_VWIDTH) $::env(PDN_CORE_RING_HWIDTH)" \
            -spacings "$::env(PDN_CORE_RING_VSPACING) $::env(PDN_CORE_RING_HSPACING)" \
            -core_offset "$::env(PDN_CORE_RING_VOFFSET) $::env(PDN_CORE_RING_HOFFSET)" \
            {*}$arg_list

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_HORIZONTAL_LAYER) $::env(PDN_VERTICAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] && [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_CORE_HORIZONTAL_LAYER)"
        }

    } else {
        throw APPLICATION "PDN_CORE_RING cannot be used when PDN_MULTILAYER is set to false."
    }
}

# ---------------------------------------------------------------------------
# The macro grid -- THIS IS THE PART THAT DIFFERS FROM THE STOCK CONFIG.
# ---------------------------------------------------------------------------
#
# Stock:
#     define_pdn_grid -macro -default -name macro -starts_with POWER \
#         -halo "$PDN_HORIZONTAL_HALO $PDN_VERTICAL_HALO"
#     add_pdn_connect -grid macro -layers "$PDN_VERTICAL_LAYER $PDN_HORIZONTAL_LAYER"
#
# Here we additionally stripe the macro in the layer its supplies come out on
# (Metal4) and connect that up to the vertical layer.
#
# The stripes are given the SAME pitch/offset as the top-metal grid so their
# Metal4 legs land on the macro's own stripes rather than between them: the
# macro's VSS! stripes sit on a 11.24 um pitch and VDD! on 11.24 um as well
# (measured, x = 9.88, 21.12, 32.36 ... for VSS! and 4.26, 15.5, 26.74 ... for
# VDD!). A denser pitch costs area and a sparser one misses.
define_pdn_grid \
    -macro \
    -default \
    -name macro \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

# Vertical stripes on the macro's supply layer, so the macro's own Metal4
# geometry is met by grid geometry on the same layer.
add_pdn_stripe \
    -grid macro \
    -layer Metal4 \
    -width 1.2 \
    -pitch 11.24 \
    -offset 4.26 \
    -starts_with POWER

# The ladder up: Metal4 -> TopMetal1 (vertical) -> TopMetal2 (horizontal).
add_pdn_connect \
    -grid macro \
    -layers "Metal4 $::env(PDN_VERTICAL_LAYER)"

add_pdn_connect \
    -grid macro \
    -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
