all: patch_cva6

# NOTE: Temporary workaround, bump cva6 reference to old riscv-dbg module, avoiding a new fork
riscv_dbg_verison := v0.8.0
bump_cva6_riscv_dbg: 
	cd ../deps/cva6/src/riscv-dbg; \
	git checkout $(riscv_dbg_verison)
