# VIVADO ?= vivado-2019.1.1 vivado
VIVADO ?= vitis-2020.2 vivado
# VIVADO ?= vitis-2022.1 vivado
VIVADOFLAGS ?= -nojournal 

# Configuration variable defaults
# Most of this is developement-oriented
ENV_VARS :=  
define env_var_default
	ifndef $(1)
		$1 := $2
	endif
	ENV_VARS += $1 
endef
$(eval $(call env_var_default, project			 , ara_xilinx))
$(eval $(call env_var_default, VCU128_BOARD		 , 1))
$(eval $(call env_var_default, CLK_PERIOD_NS	 , 40)) # Default to 25MHz after IBUF
$(eval $(call env_var_default, BOARD			 , vcu128))
$(eval $(call env_var_default, XILINX_PART		 , xcvu37p-fsvh2892-2L-e))
$(eval $(call env_var_default, XILINX_BOARD		 , xilinx.com:vcu128:part0:1.0))
$(eval $(call env_var_default, NR_LANES			 , 4))
$(eval $(call env_var_default, WORK_DIR			 , work_fpga_nr_lanes_$(NR_LANES)))
$(eval $(call env_var_default, BITSTREAM		 , $(WORK_DIR)/$(project).runs/impl_1/$(project).bit))
$(eval $(call env_var_default, RTL_ONLY			 , 0))
$(eval $(call env_var_default, RUNTIME_OPTIMIZED , 1))
$(eval $(call env_var_default, SYNTH_ONLY  		 , 0))
$(eval $(call env_var_default, DEBUG			 , 0))

# Dependant variables
# Select Vivado run mode
# ifeq ($(DEBUG),1)
# 	VIVADOFLAGS += -mode tcl
# else
VIVADOFLAGS += -mode batch
# endif

# Compute reducing ratio compared to the input 100MHz clock
# NOTE: this is a temporary solution that uses a counter as
#		clock divider instead of a PLL through a Xilinx clock wizard
# TODO: replace it with a PLL
CLOCK_RATIO := $$(( $(CLK_PERIOD_NS) / 10 ))

# bit := $(work-dir)/$(project).bit
# mcs := $(work-dir)/$(project).mcs

all: variables_check gen_bitstream #$(bit) #$(mcs)

# Debug
print_env:
	@echo -e $(foreach var, $(ENV_VARS), "$(var)=$($(var))\n")
	mkdir -p $(WORK_DIR)
	@echo -e $(foreach var, $(ENV_VARS), "$(var)=$($(var))\n") > $(WORK_DIR)/ENV_VARS.txt
	@echo "Chech $(WORK_DIR)/ENV_VARS.txt for environment setup"

# Check wether sourceme.sh was sourced to define variables
variables_check:
	@if [[ '$(XILINX_PART)' == "" || '$(XILINX_BOARD)' == "" || '$(CLK_PERIOD_NS)' == "" ]]; then \
		echo "ERROR: Before running make, you must source sourceme.sh"; \
		exit 1; \
	fi

bender:
	make -C ../hardware bender

# Generate mcs from bitstream
# $(mcs): $(bit)
# 	$(VIVADO) $(VIVADOFLAGS) -source scripts/write_cfgmem.tcl -tclargs $@ $^

# List of bender defines
bender_defs := --define NR_LANES=$(NR_LANES)
bender_defs += --define CLOCK_RATIO=$(CLOCK_RATIO)
# List of bender targets
bender_targets := -t ara_jtag 			# For ara_bootrom and JTAG versions of ara_system and ara_soc
bender_targets += -t cv64a6_imafdc_sv39 # Configuration of CVA6
# bender_targets += -t cva6_test			# For sram.sv in CVA6
bender_targets += -t xilinx -t fpga 	# For ara_xilinx.sv
bender_targets += -t bscane 			# For BSCANE2 in riscv-dbg submodule, this will automatically route
#										# 	 the jtag signals on the scan chain of the USB connector
scripts/add_sources.tcl: bender
	../hardware/bender script vivado $(bender_targets) $(bender_defs) > $@

gen_bitstream: print_env scripts/add_sources.tcl #$(ips)
	# Update bootrom data width
	make -C ../hardware/ clean_bootrom bootrom ARA_CONFIGURATION=$(NR_LANES)_lanes
	# Export variables and lauch synthesis script
	$(foreach env_var, $(ENV_VARS), export $(env_var)=$($(env_var)); ) \
	$(VIVADO) $(VIVADOFLAGS) -source scripts/run.tcl

# $(ips): %.xci :
# 	mkdir -p $(work-dir)
# 	@echo Generating $(@F)
# 	@cd $(ip-dir)/$(basename $(@F)) && make clean && make
# 	@cp $(ip-dir)/$(basename $(@F))/$(basename $(@F)).srcs/sources_1/ip/$(basename $(@F))/$(@F) $@

program: print_env $(BITSTREAM) 
	@echo "Target board: vcu128-0$(VCU128_BOARD)"
	@echo "Target bitstream: $(work-dir)/$(project).runs/impl_1/$(project).bit"
	$(VIVADO) $(VIVADOFLAGS) -source scripts/program.tcl -tclargs $(VCU128_BOARD) $(BITSTREAM)


clean_all: clean
	rm -rf work_fpga_nr_lanes_*

.PHONY:	clean
clean:
	rm -rf *.log *.jou *.str *.mif *.xpr .Xil $(WORK_DIR) scripts/add_sources.tcl

