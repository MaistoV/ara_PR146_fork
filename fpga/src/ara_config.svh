// Description: Set global defines for CVA6 and ARA
// Author: Vincenzo Maisto vincenzo.maisto2@unina.it

//=============================================================================
// CVA6 Configurations
//=============================================================================
`define ARIANE_DATA_WIDTH 64
// write-through cache
`define WT_DCACHE 1

`define RVV_ARIANE 1

//=============================================================================
// Ara Configurations
//=============================================================================
// `define NR_LANES 4 (done with bender)
`define VLEN (1024 * `NR_LANES)

