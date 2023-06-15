# Copyright 2018 ETH Zurich and University of Bologna.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Author: Vincenzo Maisto <vincenzo.maisto2@unina.it>
# Description: Program bitstream

puts "Info: this script only works for the 2 VCU128s at IIS borcomputer"

# Parse args
if { $argc < 2 } {
    puts "2 arguments required:"
    puts "  Board index"
    puts "  Bitstream path"
    return -1
}

# Set serial number and TCP port
switch [lindex $argv 0] {
   "1" {
    # vcu128-01
    set occ_target_port 3231 
    set occ_target_serial 091847100576A 
    set occ_hw_device xcvu37p_0
   }
   "2" {
    # vcu128-02
    set occ_target_port 3232
    set occ_target_serial 091847100638A
    set occ_hw_device xcvu37p_0
   }
}

# Path to bistream
set bitstream [lindex $argv 1] 

# The name of the remote host at IIS is borcomputer, this is not a typo
set host bordcomputer

# Connect to hw server
open_hw_manager
connect_hw_server -url $host:$occ_target_port 
current_hw_target [get_hw_targets */xilinx_tcf/Xilinx/${occ_target_serial}]
set_property PARAM.FREQUENCY 15000000 [get_hw_targets */xilinx_tcf/Xilinx/${occ_target_serial}]
open_hw_target
current_hw_device [get_hw_devices ${occ_hw_device}]
# Debug
report_property -all [get_hw_targets]
# Search for hw probes
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices ${occ_hw_device}] 0]

# programming bitstream
puts "Programming ${bitstream}"
# set_property PROBES.FILE "${bit_stem}.ltx" [get_hw_devices ${occ_hw_device}]
# set_property FULL_PROBES.FILE "${bit_stem}.ltx" [get_hw_devices ${occ_hw_device}]
set_property PROGRAM.FILE "${bitstream}" [get_hw_devices ${occ_hw_device}]
current_hw_device [get_hw_devices  ${occ_hw_device}]
program_hw_devices [get_hw_devices ${occ_hw_device}]
refresh_hw_device [get_hw_devices ${occ_hw_device}]

puts "--------------------"
set vios [get_hw_vios -of_objects [get_hw_devices ${occ_hw_device}]]
puts "Done programming device, found [llength $vios] VIOS: "
foreach vio $vios {
    puts "- $vio : [get_hw_probes * -of_objects $vio]"
}
puts "--------------------"

proc occ_write_vio {regexp_vio regexp_probe val} {
    global occ_hw_device
    puts "\[occ_write_vio $regexp_vio $regexp_probe\]"
    set vio_sys [get_hw_vios -of_objects [get_hw_devices ${occ_hw_device}] -regexp $regexp_vio]
    set_property OUTPUT_VALUE $val [get_hw_probes -of_objects $vio_sys -regexp $regexp_probe]
    commit_hw_vio [get_hw_probes -of_objects $vio_sys -regexp $regexp_probe]
}

# Reset peripherals and CPU
# occ_write_vio "hw_vio_1" ".*rst.*" 1

close_hw_manager