set DEBUG true
set EXT_JTAG false
if {$argc > 0 && ![lindex $argv 0]} { set DEBUG false }
if {$argc > 1 && [lindex $argv 1]} { set EXT_JTAG true }


puts "XILINX_PART=$::env(XILINX_PART)"
puts "XILINX_BOARD=$::env(XILINX_BOARD)"
puts "WORK_DIR=$::env(WORK_DIR)"
puts "BOARD=$::env(BOARD)"
puts "RTL_ONLY=$::env(RTL_ONLY)"
puts "RUNTIME_OPTIMIZED=$::env(RUNTIME_OPTIMIZED)"
puts "DEBUG=$DEBUG"
puts "EXT_JTAG=${EXT_JTAG}"

set BOARD $::env(BOARD)
if {$::env(BOARD) eq "vcu128"} {
    set part xcvu37p
} elseif {$::env(BOARD) eq "genesysii"} {
    set part genesysii
} else {
      puts "ERROR: Board $::env(BOARD) not supported"
      exit 1
}

set project ara_xilinx
set work_dir $::env(WORK_DIR)

# Cleanup
exec rm -rfv ${work_dir}/*

create_project ${project} ${work_dir} -force -part $::env(XILINX_PART)
set_property board_part $::env(XILINX_BOARD) [current_project]
# set number of threads to 8 (maximum, unfortunately)
set_param general.maxThreads 8

# Update SRAM IP from Xilinx
set_property XPM_LIBRARIES XPM_MEMORY [current_project]

# Import sources
source scripts/add_sources.tcl

# Set top level
set_property top ${project} [current_fileset]

# System Verilog headers
set headers {
    "../hardware/deps/axi/include/axi/assign.svh"
    "../hardware/deps/axi/include/axi/typedef.svh"
    "../hardware/deps/common_cells/include/common_cells/registers.svh"
    "src/ara_config.svh"
    }
    # "../hardware/src/register_typedef.svh" 
    
set part_header "src/$part.svh"        
read_verilog -sv $part_header
read_verilog -sv $headers

set file_objs [get_files -of_objects [get_filesets sources_1] $headers]
set_property -dict { file_type {Verilog Header} is_global_include 1} -objects $file_objs

set file_objs [get_files -of_objects [get_filesets sources_1] [list "*$part_header"]]
set_property -dict { file_type {Verilog Header} is_global_include 1} -objects $file_objs

update_compile_order -fileset sources_1

# Add board constraint file
add_files -fileset constrs_1 -norecurse "constraints/$BOARD.xdc"
set_property used_in_synthesis false [get_files "$BOARD.xdc"]

# Add project constraint file
add_files -fileset constrs_1 -norecurse "constraints/$project.xdc"
set_property used_in_synthesis false [get_files "$project.xdc"]

# Conditionally add jtag constraint file
if { $EXT_JTAG } {
    add_files -fileset constrs_1 -norecurse "constraints/occamy_vcu128_impl_ext_jtag.xdc"
    set_property used_in_synthesis false [get_files "occamy_vcu128_impl_ext_jtag.xdc"]
}

# Cleanup reports
exec mkdir -p  ${work_dir}/reports_synth_1/
exec mkdir -p  ${work_dir}/reports_impl_1/
exec rm    -rf ${work_dir}/reports_synth_1/*
exec rm    -rf ${work_dir}/reports_impl_1/*

# Stop here for RTL developement
if { $::env(RTL_ONLY) == "1" } {
    # Fast rtl compilation
    synth_design -rtl -name rtl_1
    report_drc -checks "LUTLP-1" -file ${work_dir}/reports_synth_1/$project.rtl.drc
    puts "RTL_ONLY=1, stop here for RTL developement"
    exit
}

if { $::env(DEBUG) == "1" } {
    set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
    set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true [get_runs synth_1]

    # The "-verbose" switch does not seem to work for message limit override
    # WARNING: [Synth 8-1921] elaboration system task error violates IEEE 1800 syntax 
    set_msg_config -id "Synth 8-1921" -limit 10000 
    # WARNING: [Synth 8-693] zero replication count - replication ignored
    set_msg_config -id "Synth 8-693"  -limit 10000 
    # WARNING: [Synth 8-7129] Port '...' in module shift_reg__parameterized0 is either unconnected or has no load
    set_msg_config -id "Synth 8-7129" -limit 10000 
    # WARNING: [Synth 8-3332] Sequential element ('...') is unused and will be removed from module '...'.
    set_msg_config -id "Synth 8-3332" -limit 10000 
    # WARNING: [Synth 8-3917] design '...' has port '...' driven by constant 0
    set_msg_config -id "Synth 8-3917" -limit 10000 
    # WARNING: [Synth 8-4446] all outputs are unconnected for this instance and logic may be removed 
    set_msg_config -id "Synth 8-4446" -limit 10000 
    # WARNING: [Synth 8-2898] ignoring assertion 
    set_msg_config -id "Synth 8-2898" -limit 10000 
    # INFO: [Synth 8-3333] propagating constant 0 across sequential element
    set_msg_config -id "Synth 8-3333" -limit 10000 
    # INFO: [Synth 8-5844] Detected registers with asynchronous reset at DSP/BRAM block boundary. Consider using synchronous reset for optimal packing 
    set_msg_config -id "Synth 8-5844" -limit 10000 
    # INFO: [Synth 8-6157] synthesizing module '...'
    set_msg_config -id "Synth 8-6157" -limit 10000 
} else {
    set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
}

launch_runs synth_1 -verbose
wait_on_run synth_1
open_run synth_1

check_timing -verbose                                                   -file ${work_dir}/reports_synth_1/$project.check_timing.rpt
report_timing -max_paths 100 -nworst 100 -delay_type max -sort_by slack -file ${work_dir}/reports_synth_1/$project.timing_WORST_100.rpt
report_timing -nworst 1 -delay_type max -sort_by group                  -file ${work_dir}/reports_synth_1/$project.timing.rpt
report_utilization -hierarchical  -hierarchical_percentages             -file ${work_dir}/reports_synth_1/$project.utilization.rpt
report_cdc                                                              -file ${work_dir}/reports_synth_1/$project.cdc.rpt
report_clock_interaction                                                -file ${work_dir}/reports_synth_1/$project.clock_interaction.rpt

if {$::env(SYNTH_ONLY) eq 1} {
    puts "SYNTH_ONLY=1, stop here for synthesis developement"
    start_gui
} else {
    # set for RuntimeOptimized implementation
    if {$::env(RUNTIME_OPTIMIZED) eq 1} {
        set_property "steps.place_design.args.directive" "RuntimeOptimized" [get_runs impl_1]
        set_property "steps.route_design.args.directive" "RuntimeOptimized" [get_runs impl_1]
    }

    launch_runs impl_1 -to_step write_bitstream -jobs 8 -verbose
    wait_on_run impl_1
    open_run impl_1

    # output Verilog netlist + SDC for timing simulation
    # write_verilog -force -mode funcsim ${work_dir}/${project}_funcsim.v
    # write_verilog -force -mode timesim ${work_dir}/${project}_timesim.v
    # write_sdf     -force ${work_dir}/${project}_timesim.sdf

    # reports
    check_timing -verbose                                                     -file ${work_dir}/reports_impl_1/${project}.check_timing.rpt
    report_timing -max_paths 100 -nworst 100 -delay_type max -sort_by slack   -file ${work_dir}/reports_impl_1/${project}.timing_WORST_100.rpt
    report_timing -nworst 1 -delay_type max -sort_by group                    -file ${work_dir}/reports_impl_1/${project}.timing.rpt
    report_utilization -hierarchical -hierarchical_percentages                -file ${work_dir}/reports_impl_1/${project}.utilization.rpt
}
