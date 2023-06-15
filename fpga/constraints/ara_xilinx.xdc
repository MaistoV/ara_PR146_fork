# NOTE: clock period is set in scripts/run.tcl
# TODO: is this redundant?
# create_clock -period 13.334 -name clk_100MHz_p [get_ports clk_100MHz_p]
# create_generated_clock -name clk_soc -source [get_pins $MIG_CLK_SRC] -divide_by 4 [get_pins i_sys_clk_div/i_clk_bypass_mux/i_BUFGMUX/O]

set_false_path -from [get_ports rst_i] -to [all_registers]

#######################
# Placement Overrides #
#######################

# Accept suboptimal BUFG-BUFG cascades
#set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets i_sys_clk_div/i_clk_mux/clk0_i] # from https://github.com/pulp-platform/cheshire/blob/fpga/vcu128/target/xilinx/constraints/cheshire.xdc
# set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk_100MHz_p]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets rst_i]

# Set design-specific constraints:
#    set_input_delay
#    set_output_delay
#    set_false_path
#    set_multicycle_path

########################################################
# From hardware/deps/cva6/fpga/scripts/ariane.tcl
########################################################

# create_clock -period 100.000 -name tck -waveform {0.000 50.000} [get_ports tck]
# set_input_jitter tck 1.000

# # minimize routing delay
# set_input_delay  -clock tck -clock_fall 5 [get_ports tdi    ]
# set_input_delay  -clock tck -clock_fall 5 [get_ports tms    ]
# set_output_delay -clock tck             5 [get_ports tdo    ]
# set_false_path   -from                    [get_ports trst_n ]


# set_max_delay -datapath_only -from [get_pins i_dmi_jtag/i_dmi_cdc/i_cdc_resp/i_src/data_src_q_reg*/C] -to [get_pins i_dmi_jtag/i_dmi_cdc/i_cdc_resp/i_dst/data_dst_q_reg*/D] 20.000
# set_max_delay -datapath_only -from [get_pins i_dmi_jtag/i_dmi_cdc/i_cdc_resp/i_src/req_src_q_reg/C] -to [get_pins i_dmi_jtag/i_dmi_cdc/i_cdc_resp/i_dst/req_dst_q_reg/D] 20.000
# set_max_delay -datapath_only -from [get_pins i_dmi_jtag/i_dmi_cdc/i_cdc_req/i_dst/ack_dst_q_reg/C] -to [get_pins i_dmi_jtag/i_dmi_cdc/i_cdc_req/i_src/ack_src_q_reg/D] 20.000

# # set multicycle path on reset, on the FPGA we do not care about the reset anyway
# set_multicycle_path -from [get_pins i_rstgen_main/i_rstgen_bypass/synch_regs_q_reg[3]/C] 4
# set_multicycle_path -from [get_pins i_rstgen_main/i_rstgen_bypass/synch_regs_q_reg[3]/C] 3  -hold


########################################################
# From snitch/hw/system/occamy/fpga/occamy_vcu128_impl_ext_jtag.xdc
########################################################

# 5 MHz max JTAG
# create_clock -period 200.000 -name jtag_tck_i [get_ports jtag_tck_i]
# # set_property CLOCK_DEDICATED_ROUTE FALSE [get_pins jtag_tck_i_IBUF_inst/O]
# set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets jtag_tck_i_IBUF_inst/O]
# set_property CLOCK_BUFFER_TYPE NONE [get_nets -of [get_pins jtag_tck_i_IBUF_inst/O]]
# set_input_jitter jtag_tck_i 1.000

# # JTAG clock is asynchronous with every other clocks.
# set_clock_groups -asynchronous -group [get_clocks jtag_tck_i]

# # Minimize routing delay
# set_input_delay -clock jtag_tck_i -clock_fall 5.000 [get_ports jtag_tdi_i]
# set_input_delay -clock jtag_tck_i -clock_fall 5.000 [get_ports jtag_tms_i]
# set_output_delay -clock jtag_tck_i 5.000 [get_ports jtag_tdo_o]

# set_max_delay -to [get_ports jtag_tdo_o] 20.000
# set_max_delay -from [get_ports jtag_tms_i] 20.000
# set_max_delay -from [get_ports jtag_tdi_i] 20.000

