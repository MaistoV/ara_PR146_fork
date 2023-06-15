#!/bin/bash

# vcu128
if [ -z "${BOARD}" ]; then
    export BOARD="vcu128"
fi

echo -n "Configuring for "
if [ "$BOARD" = "genesysii" ]; then
  echo "Genesys II"
  export XILINX_PART="xc7k325tffg900-2"
  export XILINX_BOARD="digilentinc.com:genesys2:part0:1.1"
  export CLK_PERIOD_NS="13.334" # 75 MHz
fi

if [ "$BOARD" = "vcu128" ]; then
  echo -n "VCU128"
  export XILINX_PART="xcvu37p-fsvh2892-2L-e"
  export XILINX_BOARD="xilinx.com:vcu128:part0:1.0"
  export CLK_PERIOD_NS="40" # 25 MHz
fi
export VCU128_BOARD=1
# export VCU128_BOARD=2
echo "-$VCU128_BOARD"

export NR_LANES=2
# export NR_LANES=4
# export NR_LANES=8
# export NR_LANES=16

export DEBUG=1
#export DEBUG=0

export RTL_ONLY=0
export SYNTH_ONLY=0

echo "RTL_ONLY=$RTL_ONLY"
echo "SYNTH_ONLY=$SYNTH_ONLY"
echo "DEBUG=$DEBUG"
echo "NR_LANES=$NR_LANES"
echo "Now run: make NR_LANES=[2|4|8|16]"
