// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Vincenzo Maisto <vincenzo.maisto2@unina.it>
// Description:
// Ara's FPGA based SoC, containing:
//       - ara_soc:
//          - ara
//          - SRAM scratchpad
//          - cva6/ariane
//          - jtag (BSCANE2)
//      - peripherals:
//          - uart

module ara_xilinx import axi_pkg::*; import ara_pkg::*; #(
    // Number of parallel vector lanes.
    parameter  int           unsigned NrLanes      = `NR_LANES,
    // Support for floating-point data types
    parameter  fpu_support_e          FPUSupport   = FPUSupportHalfSingleDouble,
    // AXI Interface
    parameter  int           unsigned AxiDataWidth = 32*NrLanes,
    parameter  int           unsigned AxiAddrWidth = 64,
    parameter  int           unsigned AxiUserWidth = 1,
    parameter  int           unsigned AxiIdWidth   = 4, // This must be 4 until CVA6 is updated
    // Main memory
    parameter  int           unsigned SRAMNumWords   = 2**15,
    // Dependant parameters. DO NOT CHANGE!
    localparam type                   axi_data_t   = logic [AxiDataWidth-1:0],
    localparam type                   axi_strb_t   = logic [AxiDataWidth/8-1:0],
    localparam type                   axi_addr_t   = logic [AxiAddrWidth-1:0],
    localparam type                   axi_user_t   = logic [AxiUserWidth-1:0],
    localparam type                   axi_id_t     = logic [AxiIdWidth-1:0]
  ) (
    input  logic        clk_100MHz_p,
    input  logic        clk_100MHz_n,
    input  logic        rst_i,
    // output logic [63:0] exit_o,
    // TODO: route them on VIOs
    output logic [7:0]  exit_o, // On leds[7:0]
  `ifndef TARGET_BSCANE
    // External JTAG:
    // Not using "bscane" bender target for riscv-dbg
    // Route out this ports to GPIOs
    output logic        jtag_vdd_o,
    output logic        jtag_gnd_o,
    input  logic        jtag_tck_i,
    output logic        jtag_tdo_o,
    input  logic        jtag_tdi_i,
    input  logic        jtag_tms_i,
  `endif
    // UART
    input  logic        uart0_rx_i,
    output logic        uart0_tx_o
    );

  //////////////////////
  //  Signals         //
  //////////////////////
  // Resetn
  logic        rst_n;
  // Buffered input clock
  logic        soc_clk_100MHz;
  // Divided clock
  logic        soc_clk;

  // ARA exit word
  logic [63:0] exit_o_8bits;

  // ARA -> UART
  logic        penable_ara_uart;
  logic        pwrite_ara_uart;
  logic [31:0] paddr_ara_uart;
  logic        psel_ara_uart;
  logic [31:0] pwdata_ara_uart;
  // UART -> ARA
  logic [31:0] prdata_uart_ara;
  logic        pready_uart_ara;
  logic        pslverr_uart_ara;


  //////////////////////
  //  Assignments     //
  //////////////////////

  // invert reset polarity
  assign rst_n = ~rst_i;
  // Extract low bits of ARA exit_o word
  assign exit_o = exit_o_8bits[7:0]; // Just take 8 bits for now

`ifndef TARGET_BSCANE
  // Tie to logic high or low
  assign jtag_vdd_o = 1'b1;
  assign jtag_gnd_o = 1'b0;
`endif

  //////////////////////
  //  Clock input     //
  //////////////////////

  // From ug974-vivado-ultrascale-libraries/IBUFDS
  // Clock buffer for differential clock
  // NOTE: this is not optimal though
  IBUFDS IBUFDS_inst (
    .O     ( soc_clk_100MHz  ),
    .I     ( clk_100MHz_p    ),
    .IB    ( clk_100MHz_n    )
  );

  // Clock divider
  // TODO: a clock wizard (clkwiz) would be a better choice here
  clk_div #(
    .RATIO    ( `CLOCK_RATIO )
  ) i_clk_div (
    .clk_i      ( soc_clk_100MHz ), // Clock
    .rst_ni     ( rst_n          ), // Asynchronous reset active low
    .testmode_i ( 1'b0           ), // testmode
    .en_i       ( 1'b1           ), // enable clock divider
    .clk_o      ( soc_clk        )  // divided clock out
  );

  //////////////////////
  //  Ara SoC         //
  //////////////////////

  ara_soc #(
    .NrLanes      ( NrLanes      ),
    .AxiAddrWidth ( AxiAddrWidth ),
    .AxiDataWidth ( AxiDataWidth ),
    .AxiIdWidth   ( AxiIdWidth   ),
    .AxiUserWidth ( AxiUserWidth ),
    .SRAMNumWords ( SRAMNumWords )
  ) i_ara_soc (
    .clk_i            ( soc_clk          ),
    .rst_ni           ( rst_n            ),
    .exit_o           ( exit_o_8bits     ),
    .dram_base_addr_o (                  ),
    .dram_end_addr_o  (                  ),
    .event_trigger_o  (                  ),
    .hw_cnt_en_o      (                  ),
    .scan_enable_i    ( 1'b0             ),
    .scan_data_i      ( 1'b0             ),
    .scan_data_o      (                  ),
`ifndef TARGET_BSCANE
    // JTAG
    .jtag_tck_i       ( jtag_tck_i       ),
    // TODO: add VIO here
    .jtag_trst_ni     ( 1'b1             ), // Never reset jtag...? As in occamy
    .jtag_tdo_o       ( jtag_tdo_o       ),
    .jtag_tdi_i       ( jtag_tdi_i       ),
    .jtag_tms_i       ( jtag_tms_i       ),
    .jtag_tdo_oe_o    (                  ),
    .dmactive_o       (                  ),
`endif
    // UART
    .uart_penable_o   ( penable_ara_uart ),
    .uart_pwrite_o    ( pwrite_ara_uart  ),
    .uart_paddr_o     ( paddr_ara_uart   ),
    .uart_psel_o      ( psel_ara_uart    ),
    .uart_pwdata_o    ( pwdata_ara_uart  ),
    .uart_prdata_i    ( prdata_uart_ara  ),
    .uart_pready_i    ( pready_uart_ara  ),
    .uart_pslverr_i   ( pslverr_uart_ara )
  );

  //////////////////////
  //       UART       //
  //////////////////////

  apb_uart i_apb_uart (
      .CLK     ( soc_clk             ),
      .RSTN    ( rst_n               ),
      .PSEL    ( psel_ara_uart       ),
      .PENABLE ( penable_ara_uart    ),
      .PWRITE  ( pwrite_ara_uart     ),
      .PADDR   ( paddr_ara_uart[4:2] ),
      .PWDATA  ( pwdata_ara_uart     ),
      .PRDATA  ( prdata_uart_ara     ),
      .PREADY  ( pready_uart_ara     ),
      .PSLVERR ( pslverr_uart_ara    ),
      // .INT     ( irq_sources[0]  ),
      .INT     (                     ), // Shoul be connected to PLIC
      .OUT1N   (                     ), // keep open
      .OUT2N   (                     ), // keep open
      .RTSN    (                     ), // no flow control
      .DTRN    (                     ), // no flow control
      .CTSN    ( 1'b0                ),
      .DSRN    ( 1'b0                ),
      .DCDN    ( 1'b0                ),
      .RIN     ( 1'b0                ),
      .SIN     ( uart0_rx_i          ),
      .SOUT    ( uart0_tx_o          )
  );

  //////////////////////
  //     DDR/HBM      //
  //////////////////////
  // TODO: Add DDR/HBM  

endmodule : ara_xilinx
