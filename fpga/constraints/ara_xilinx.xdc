################################
# Primary and generated clocks #
################################
# Input 100Mhz differential clock
set DIFF_CLK 10.0
# From UG903/Primary Clocks Examples
# "With differential buffer driving the PLL. In such a scenario, the primary clock must
# only be created on the positive input of the differential buffer"
# From https://support.xilinx.com/s/article/57109?language=en_US
create_clock -period $DIFF_CLK -name diff_clk_100MHz_p [get_ports clk_100MHz_p]

# Post differential buffer
set SOC_CLK $DIFF_CLK
create_clock -period $SOC_CLK -name soc_clk_100MHz [get_nets soc_clk_100MHz]
# create_generated_clock -name soc_clk_100MHz -source [get_ports diff_clk_100MHz_p] -combinational [get_nets soc_clk_100MHz] 
# create_generated_clock -name soc_clk_100MHz -source [get_ports diff_clk_100MHz_p] -divide_by 1 [get_nets soc_clk_100MHz_BUFG]

# Divided clock (i_clk_int_div)
# TODO: this ratio should be parameterized
create_generated_clock -name soc_clk -source [get_pins -of [get_clocks soc_clk_100MHz]] -divide_by 4 [get_pins i_clk_int_div/i_clk_mux/i_BUFGMUX/O]
# These ports still get no clock
# i_clk_int_div/i_clk_mux/clk0_i 
# i_clk_int_div/i_clk_mux/clk1_i 

# JTAG Clock
set JTAG_CLK 100.0
set JTAG_JIT 1.000
create_clock -period $JTAG_CLK -name clk_jtag [get_pins i_ara_soc/i_dmi_jtag/i_dmi_jtag_tap/tck_o]
set_input_jitter clk_jtag $JTAG_JIT

##############
# Fase paths #
##############
# Declare async reset paths as non timing-constrained
set_false_path -from [get_ports rst_i] -to [all_registers]

##############
# I/O Delays #
##############

# Constrain inputs
set_input_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports uart0_rx_i]
set_input_delay -clock soc_clk [expr 0.50 * $SOC_CLK] [get_ports rst_i     ]

# Constrain outputs
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[0]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[1]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[2]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[3]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[4]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[5]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[6]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports exit_o[7]]
set_output_delay -clock soc_clk [expr 0.10 * $SOC_CLK] [get_ports uart0_tx_o]

#######################
# Placement Overrides #
#######################

# Accept suboptimal placement
# set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets rst_i]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets rst_i]