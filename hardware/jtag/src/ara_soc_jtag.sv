// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
// Author: Vincenzo Maisto <vincenzo.maisto2@unina.it>
// Description:
// Ara's SoC, containing Ariane, Ara, a L2 cache and a JTAG debug module

module ara_soc import axi_pkg::*; import ara_pkg::*; import dm::*; #(
    // RVV Parameters
    parameter  int           unsigned NrLanes      = 0,                          // Number of parallel vector lanes.
    // Support for floating-point data types
    parameter  fpu_support_e          FPUSupport   = FPUSupportHalfSingleDouble,
    // External support for vfrec7, vfrsqrt7
    parameter  fpext_support_e        FPExtSupport = FPExtSupportEnable,
    // Support for fixed-point data types
    parameter  fixpt_support_e        FixPtSupport = FixedPointEnable,
    // AXI Interface
    parameter  int           unsigned AxiDataWidth = 32*NrLanes,
    parameter  int           unsigned AxiAddrWidth = 64,
    parameter  int           unsigned AxiUserWidth = 1,
    parameter  int           unsigned AxiIdWidth   = 4, // This must be 4 to pass it down to cva6, whose interface is bounded by ariane_axi_pkg.sv
    // AXI Resp Delay [ps] for gate-level simulation
    parameter  int           unsigned AxiRespDelay = 200,
    // Main memory
    parameter  int           unsigned L2NumWords   = 2**20,
    // Dependant parameters. DO NOT CHANGE!
    localparam type                   axi_data_t   = logic [AxiDataWidth-1:0],
    localparam type                   axi_strb_t   = logic [AxiDataWidth/8-1:0],
    localparam type                   axi_addr_t   = logic [AxiAddrWidth-1:0],
    localparam type                   axi_user_t   = logic [AxiUserWidth-1:0],
    localparam type                   axi_id_t     = logic [AxiIdWidth-1:0]
  ) (
    input  logic        clk_i,
    input  logic        rst_ni,
    // CSRs
    output logic [63:0] exit_o,
    output logic [63:0] dram_base_addr_o,
    output logic [63:0] dram_end_addr_o,
    output logic [63:0] event_trigger_o,
    output logic [63:0] hw_cnt_en_o,
    // JTAG
    input  logic        jtag_tck_i,
    input  logic        jtag_trst_ni,
    output logic        jtag_tdo_o,
    input  logic        jtag_tdi_i,
    input  logic        jtag_tms_i,
    output logic        jtag_tdo_oe_o,
    output logic        dmactive_o,
    // Scan chain
    input  logic        scan_enable_i,
    input  logic        scan_data_i,
    output logic        scan_data_o,
    // UART APB interface
    output logic        uart_penable_o,
    output logic        uart_pwrite_o,
    output logic [31:0] uart_paddr_o,
    output logic        uart_psel_o,
    output logic [31:0] uart_pwdata_o,
    input  logic [31:0] uart_prdata_i,
    input  logic        uart_pready_i,
    input  logic        uart_pslverr_i
  );

  `include "axi/assign.svh"
  `include "axi/typedef.svh"
  `include "common_cells/registers.svh"

  //////////////////////////////////////
  // AXI components interconnection
  //
  //           _________                      master_wide_axi  __________ periph_wide_axi                 periph_narrow_axi
  //  ARA --->|         \                                     |          |--------------> axi_dw_converter -------------> axi2apb  ------------------------> out
  //          | axi_mux |---> ara_system -------------------->|          |--------------> axi_dw_converter -------------> axi_to_axi_lite -----------------> ctrl_registers
  //  CVA6 -->|_________/                                     | axi_xbar |--------------> axi_dw_converter -------------> axi_to_mem ----------------------> dm_top
  //                                                          |          |----------------------------------------------> axi_to_mem ----------------------> bootrom
  //  dm_top --> axi_from_mem ---------> axi_dw_converter --->|__________|----------------------------------------------> atop_filter ------> axi_to_mem --> L2$
  //                          dm_narrow                                   periph_wide_axi
  //
  //////////////////////////////////////

  //////////////////////
  //  Memory Regions  //
  //////////////////////

  // Actually masters, but slaves on the crossbar, including Debug module
  // NOTE: What does the word "actually" mean...?
  typedef enum int unsigned {
    DM_master     = 0,
    AraAriane     = 1, // Muxed in ara_system
    NrAXIMasters  = 2
  } axi_masters_e;

  typedef enum int unsigned {
    L2MEM       = 0,
    UART        = 1,
    CTRL        = 2,
    DM_slave    = 3,
    BOOTROM     = 4,
    NrAXISlaves = 5
  } axi_slaves_e;

  // Memory Map
  localparam logic [63:0] DMLength   = 64'h40000; // From Cheshire
  // localparam logic [63:0] DMLength   = 64'h1000;  // From Ariane
  // localparam logic [63:0] DMLength   = 64'h1000;  // From Occamy
  // 1GByte of DDR (split between two chips on Genesys2)
  localparam logic [63:0] DRAMLength = 64'h40000000; // TODO: update for VCU128
  localparam logic [63:0] UARTLength = 64'h1000;
  localparam logic [63:0] CTRLLength = 64'h1000;
  localparam logic [63:0] BOOTLength = 64'h10000;

  typedef enum logic [63:0] {
    DMBase   = 64'h0000_0000,
    BOOTBase = 64'h0005_0000,
    DRAMBase = 64'h8000_0000, // L2 cache
    UARTBase = 64'hC000_0000,
    CTRLBase = 64'hD000_0000
  } soc_bus_start_e;

  ///////////
  //  AXI  //
  ///////////

  // Ariane's AXI port data width
  localparam AxiNarrowDataWidth = 64;
  localparam AxiNarrowStrbWidth = AxiNarrowDataWidth / 8;
  // Ara's AXI port data width
  localparam AxiWideDataWidth   = AxiDataWidth;
  localparam AXiWideStrbWidth   = AxiWideDataWidth / 8;

  // ID width should decrease at every xbar step from masters to slaves
  // https://github.com/pulp-platform/axi/blob/master/doc/axi_xbar.md
  // AxiIdWidthMstPorts = AxiIdWidthSlvPorts + $clog_2(NoSlvPorts)
  localparam AxiCoreIdWidth   = AxiIdWidth; // This must be 4 to pass it down to cva6, whose interface is bounded by ariane_axi_pkg.sv
  localparam AxiSysIdWidth    = AxiCoreIdWidth + 1;
  localparam AxiSocIdWidth    = AxiSysIdWidth;
  localparam AxiPeriphIdWidth = AxiSocIdWidth + $clog2(NrAXIMasters);

  // Internal types
  typedef logic [AxiNarrowDataWidth-1 : 0] axi_narrow_data_t;
  typedef logic [AxiNarrowStrbWidth-1 : 0] axi_narrow_strb_t;
  typedef logic [AxiPeriphIdWidth-1   : 0] axi_periph_id_t;
  typedef logic [AxiSocIdWidth-1      : 0] axi_soc_id_t;
  typedef logic [AxiSocIdWidth-1      : 0] axi_sys_id_t;
  typedef logic [AxiCoreIdWidth-1     : 0] axi_core_id_t;

  // AXI Typedefs
  // In-AraSystem types
  `AXI_TYPEDEF_ALL      ( ara_axi            , axi_addr_t  , axi_core_id_t     , axi_data_t        , axi_strb_t        , axi_user_t  )
  `AXI_TYPEDEF_ALL      ( ariane_axi         , axi_addr_t  , axi_core_id_t     , axi_narrow_data_t , axi_narrow_strb_t , axi_user_t  )
  // In-Soc types
  `AXI_TYPEDEF_ALL      ( master_wide        , axi_addr_t  , axi_sys_id_t      , axi_data_t        , axi_strb_t        , axi_user_t  )
  `AXI_TYPEDEF_ALL      ( dm_narrow_axi      , axi_addr_t  , axi_sys_id_t      , axi_narrow_data_t , axi_narrow_strb_t , axi_user_t  )
  `AXI_TYPEDEF_ALL      ( periph_wide        , axi_addr_t  , axi_periph_id_t   , axi_data_t        , axi_strb_t        , axi_user_t  )
  `AXI_TYPEDEF_ALL      ( periph_narrow      , axi_addr_t  , axi_periph_id_t   , axi_narrow_data_t , axi_narrow_strb_t , axi_user_t  )
  `AXI_LITE_TYPEDEF_ALL ( periph_narrow_lite , axi_addr_t  , axi_narrow_data_t , axi_narrow_strb_t )

  // AXI master bus
  master_wide_req_t  [NrAXIMasters-1:0] master_wide_axi_req;
  master_wide_resp_t [NrAXIMasters-1:0] master_wide_axi_resp;
  // master_wide_req_t  master_wide_axi_req_spill;
  // master_wide_resp_t master_wide_axi_resp_spill;
  // master_wide_resp_t master_wide_axi_resp_spill_delayed;
  // DM master narrow
  dm_narrow_axi_req_t   dm_narrow_axi_req;
  dm_narrow_axi_resp_t  dm_narrow_axi_resp;
  
  // AXI slave bus
  // Wide bus
  periph_wide_req_t    [NrAXISlaves-1:0] periph_wide_axi_req;
  periph_wide_resp_t   [NrAXISlaves-1:0] periph_wide_axi_resp;
  // Narrow bus
  periph_narrow_req_t  [NrAXISlaves-1:0] periph_narrow_axi_req;
  periph_narrow_resp_t [NrAXISlaves-1:0] periph_narrow_axi_resp;

  ////////////////
  //  Crossbar  //
  ////////////////

  localparam axi_pkg::xbar_cfg_t XBarCfg = '{
    NoSlvPorts        : NrAXIMasters,  
    NoMstPorts        : NrAXISlaves,
    MaxMstTrans       : 4,
    MaxSlvTrans       : 4,
    FallThrough       : 1'b0,
    LatencyMode       : axi_pkg::CUT_MST_PORTS,
    AxiIdWidthSlvPorts: AxiSocIdWidth,
    AxiIdUsedSlvPorts : AxiSocIdWidth,
    UniqueIds         : 1'b0,
    AxiAddrWidth      : AxiAddrWidth,
    AxiDataWidth      : AxiWideDataWidth,
    NoAddrRules       : NrAXISlaves,
    default           : '0
  };

  axi_pkg::xbar_rule_64_t [NrAXISlaves-1:0] routing_rules;
  assign routing_rules = '{
    '{ idx: DM_slave , start_addr: DMBase    , end_addr: DMBase   + DMLength   },
    '{ idx: BOOTROM  , start_addr: BOOTBase  , end_addr: BOOTBase + BOOTLength },
    '{ idx: CTRL     , start_addr: CTRLBase  , end_addr: CTRLBase + CTRLLength },
    '{ idx: UART     , start_addr: UARTBase  , end_addr: UARTBase + UARTLength },
    '{ idx: L2MEM    , start_addr: DRAMBase  , end_addr: DRAMBase + DRAMLength }
  };

  axi_xbar #(
    .Cfg          ( XBarCfg                 ),
    .slv_aw_chan_t( master_wide_aw_chan_t   ),
    .mst_aw_chan_t( periph_wide_aw_chan_t   ),
    .w_chan_t     ( master_wide_w_chan_t    ),
    .slv_b_chan_t ( master_wide_b_chan_t    ),
    .mst_b_chan_t ( periph_wide_b_chan_t    ),
    .slv_ar_chan_t( master_wide_ar_chan_t   ),
    .mst_ar_chan_t( periph_wide_ar_chan_t   ),
    .slv_r_chan_t ( master_wide_r_chan_t    ),
    .mst_r_chan_t ( periph_wide_r_chan_t    ),
    .slv_req_t    ( master_wide_req_t       ),
    .slv_resp_t   ( master_wide_resp_t      ),
    .mst_req_t    ( periph_wide_req_t       ),
    .mst_resp_t   ( periph_wide_resp_t      ),
    .rule_t       ( axi_pkg::xbar_rule_64_t )
  ) i_soc_xbar (
    .clk_i                ( clk_i                ),
    .rst_ni               ( rst_ni               ),
    .test_i               ( 1'b0                 ),
    .slv_ports_req_i      ( master_wide_axi_req  ),
    .slv_ports_resp_o     ( master_wide_axi_resp ),
    .mst_ports_req_o      ( periph_wide_axi_req  ),
    .mst_ports_resp_i     ( periph_wide_axi_resp ),
    .addr_map_i           ( routing_rules        ),
    .en_default_mst_port_i( '0                   ),
    .default_mst_port_i   ( '0                   )
  );

  //////////////
  // Boot ROM //
  //////////////

  // Boot Rom signals definition
  typedef logic [AxiAddrWidth-1     : 0] bootrom_addr_t;
  typedef logic [AxiWideDataWidth-1 : 0] bootrom_data_t;

  logic          bootrom_req;
  bootrom_addr_t bootrom_addr;
  bootrom_data_t bootrom_rdata;
  logic          bootrom_rvalid;

  axi_to_mem #(
    .AddrWidth  ( AxiAddrWidth         ),
    .DataWidth  ( AxiWideDataWidth     ),
    .IdWidth    ( AxiPeriphIdWidth     ),
    .NumBanks   ( 1                    ),
    .axi_req_t  ( periph_wide_req_t    ),
    .axi_resp_t ( periph_wide_resp_t   )
  ) i_axi_to_mem_bootrom (
    .clk_i       ( clk_i                         ),
    .rst_ni      ( rst_ni                        ),
    .axi_req_i   ( periph_wide_axi_req [BOOTROM] ),
    .axi_resp_o  ( periph_wide_axi_resp[BOOTROM] ),
    .mem_req_o   ( bootrom_req                   ),
    .mem_gnt_i   ( bootrom_req                   ),
    .mem_we_o    (                               ), // Unused
    .mem_addr_o  ( bootrom_addr                  ),
    .mem_strb_o  (                               ), // Unused
    .mem_wdata_o (                               ), // Unused
    .mem_rdata_i ( bootrom_rdata                 ),
    .mem_rvalid_i( bootrom_rvalid                ),
    .mem_atop_o  (                               ), // Unused
    .busy_o      (                               )  // Unused
  );

  // One-cycle latency
  `FF(bootrom_rvalid, bootrom_req, 1'b0);

  ara_bootrom i_bootrom (
    .clk_i  ( clk_i         ),
    .req_i  ( bootrom_req   ),
    .addr_i ( bootrom_addr  ),
    .rdata_o( bootrom_rdata )
  );

  //////////
  //  L2  //
  //////////

  // The L2 memory does not support atomics

  periph_wide_req_t  l2mem_wide_axi_req_wo_atomics;
  periph_wide_resp_t l2mem_wide_axi_resp_wo_atomics;
  axi_atop_filter #(
    .AxiIdWidth     (AxiPeriphIdWidth  ),
    .AxiMaxWriteTxns(4              ),
    .axi_req_t          (periph_wide_req_t ),
    .axi_resp_t         (periph_wide_resp_t)
  ) i_l2mem_atop_filter (
    .clk_i     (clk_i                         ),
    .rst_ni    (rst_ni                        ),
    .slv_req_i (periph_wide_axi_req[L2MEM]    ),
    .slv_resp_o(periph_wide_axi_resp[L2MEM]   ),
    .mst_req_o (l2mem_wide_axi_req_wo_atomics ),
    .mst_resp_i(l2mem_wide_axi_resp_wo_atomics)
  );

  logic                             l2_req;
  logic                             l2_we;
  logic [AxiAddrWidth-1       : 0]  l2_addr;
  logic [AxiWideDataWidth/8-1 : 0]  l2_be;
  logic [AxiWideDataWidth-1   : 0]  l2_wdata;
  logic [AxiWideDataWidth-1   : 0]  l2_rdata;
  logic                             l2_rvalid;

  axi_to_mem #(
    .AddrWidth  ( AxiAddrWidth       ),
    .DataWidth  ( AxiWideDataWidth   ),
    .IdWidth    ( AxiPeriphIdWidth   ),
    .NumBanks   ( 1                  ),
    .axi_req_t  ( periph_wide_req_t  ),
    .axi_resp_t ( periph_wide_resp_t )
  ) i_axi_to_mem_l2 (
    .clk_i       (clk_i                         ),
    .rst_ni      (rst_ni                        ),
    .axi_req_i   (l2mem_wide_axi_req_wo_atomics ),
    .axi_resp_o  (l2mem_wide_axi_resp_wo_atomics),
    .mem_req_o   (l2_req                        ),
    .mem_gnt_i   (l2_req                        ), // Always available
    .mem_we_o    (l2_we                         ),
    .mem_addr_o  (l2_addr                       ),
    .mem_strb_o  (l2_be                         ),
    .mem_wdata_o (l2_wdata                      ),
    .mem_rdata_i (l2_rdata                      ),
    .mem_rvalid_i(l2_rvalid                     ),
    .mem_atop_o  (/* Unused */                  ),
    .busy_o      (/* Unused */                  )
  );

`ifndef SPYGLASS
  tc_sram #(
    .NumWords (L2NumWords  ),
    .NumPorts (1           ),
    .DataWidth(AxiWideDataWidth),
    .SimInit("random")
  ) i_dram (
    .clk_i  (clk_i                                                                      ),
    .rst_ni (rst_ni                                                                     ),
    .req_i  (l2_req                                                                     ),
    .we_i   (l2_we                                                                      ),
    .addr_i (l2_addr[$clog2(L2NumWords)-1+$clog2(AxiWideDataWidth/8):$clog2(AxiWideDataWidth/8)]),
    .wdata_i(l2_wdata                                                                   ),
    .be_i   (l2_be                                                                      ),
    .rdata_o(l2_rdata                                                                   )
  );
`else
  assign l2_rdata = '0;
`endif

  // One-cycle latency
  `FF(l2_rvalid, l2_req, 1'b0);

  ////////////
  //  UART  //
  ////////////

  axi2apb_64_32 #(
    .AXI4_ADDRESS_WIDTH(AxiAddrWidth      ),
    .AXI4_RDATA_WIDTH  (AxiNarrowDataWidth),
    .AXI4_WDATA_WIDTH  (AxiNarrowDataWidth),
    .AXI4_ID_WIDTH     (AxiPeriphIdWidth     ),
    .AXI4_USER_WIDTH   (AxiUserWidth      ),
    .BUFF_DEPTH_SLAVE  (2                 ),
    .APB_ADDR_WIDTH    (32                )
  ) i_axi2apb_64_32_uart (
    .ACLK      (clk_i                                ),
    .ARESETn   (rst_ni                               ),
    .test_en_i (1'b0                                 ),
    .AWID_i    (periph_narrow_axi_req[UART].aw.id    ),
    .AWADDR_i  (periph_narrow_axi_req[UART].aw.addr  ),
    .AWLEN_i   (periph_narrow_axi_req[UART].aw.len   ),
    .AWSIZE_i  (periph_narrow_axi_req[UART].aw.size  ),
    .AWBURST_i (periph_narrow_axi_req[UART].aw.burst ),
    .AWLOCK_i  (periph_narrow_axi_req[UART].aw.lock  ),
    .AWCACHE_i (periph_narrow_axi_req[UART].aw.cache ),
    .AWPROT_i  (periph_narrow_axi_req[UART].aw.prot  ),
    .AWREGION_i(periph_narrow_axi_req[UART].aw.region),
    .AWUSER_i  (periph_narrow_axi_req[UART].aw.user  ),
    .AWQOS_i   (periph_narrow_axi_req[UART].aw.qos   ),
    .AWVALID_i (periph_narrow_axi_req[UART].aw_valid ),
    .AWREADY_o (periph_narrow_axi_resp[UART].aw_ready),
    .WDATA_i   (periph_narrow_axi_req[UART].w.data   ),
    .WSTRB_i   (periph_narrow_axi_req[UART].w.strb   ),
    .WLAST_i   (periph_narrow_axi_req[UART].w.last   ),
    .WUSER_i   (periph_narrow_axi_req[UART].w.user   ),
    .WVALID_i  (periph_narrow_axi_req[UART].w_valid  ),
    .WREADY_o  (periph_narrow_axi_resp[UART].w_ready ),
    .BID_o     (periph_narrow_axi_resp[UART].b.id    ),
    .BRESP_o   (periph_narrow_axi_resp[UART].b.resp  ),
    .BVALID_o  (periph_narrow_axi_resp[UART].b_valid ),
    .BUSER_o   (periph_narrow_axi_resp[UART].b.user  ),
    .BREADY_i  (periph_narrow_axi_req[UART].b_ready  ),
    .ARID_i    (periph_narrow_axi_req[UART].ar.id    ),
    .ARADDR_i  (periph_narrow_axi_req[UART].ar.addr  ),
    .ARLEN_i   (periph_narrow_axi_req[UART].ar.len   ),
    .ARSIZE_i  (periph_narrow_axi_req[UART].ar.size  ),
    .ARBURST_i (periph_narrow_axi_req[UART].ar.burst ),
    .ARLOCK_i  (periph_narrow_axi_req[UART].ar.lock  ),
    .ARCACHE_i (periph_narrow_axi_req[UART].ar.cache ),
    .ARPROT_i  (periph_narrow_axi_req[UART].ar.prot  ),
    .ARREGION_i(periph_narrow_axi_req[UART].ar.region),
    .ARUSER_i  (periph_narrow_axi_req[UART].ar.user  ),
    .ARQOS_i   (periph_narrow_axi_req[UART].ar.qos   ),
    .ARVALID_i (periph_narrow_axi_req[UART].ar_valid ),
    .ARREADY_o (periph_narrow_axi_resp[UART].ar_ready),
    .RID_o     (periph_narrow_axi_resp[UART].r.id    ),
    .RDATA_o   (periph_narrow_axi_resp[UART].r.data  ),
    .RRESP_o   (periph_narrow_axi_resp[UART].r.resp  ),
    .RLAST_o   (periph_narrow_axi_resp[UART].r.last  ),
    .RUSER_o   (periph_narrow_axi_resp[UART].r.user  ),
    .RVALID_o  (periph_narrow_axi_resp[UART].r_valid ),
    .RREADY_i  (periph_narrow_axi_req[UART].r_ready  ),
    .PENABLE   (uart_penable_o                       ),
    .PWRITE    (uart_pwrite_o                        ),
    .PADDR     (uart_paddr_o                         ),
    .PSEL      (uart_psel_o                          ),
    .PWDATA    (uart_pwdata_o                        ),
    .PRDATA    (uart_prdata_i                        ),
    .PREADY    (uart_pready_i                        ),
    .PSLVERR   (uart_pslverr_i                       )
  );

  axi_dw_converter #(
    .AxiSlvPortDataWidth(AxiWideDataWidth     ),
    .AxiMstPortDataWidth(AxiNarrowDataWidth   ),
    .AxiAddrWidth       (AxiAddrWidth         ),
    .AxiIdWidth         (AxiPeriphIdWidth        ),
    .AxiMaxReads        (2                    ),
    .ar_chan_t          (periph_wide_ar_chan_t   ),
    .mst_r_chan_t       (periph_narrow_r_chan_t  ),
    .slv_r_chan_t       (periph_wide_r_chan_t    ),
    .aw_chan_t          (periph_narrow_aw_chan_t ),
    .b_chan_t           (periph_wide_b_chan_t    ),
    .mst_w_chan_t       (periph_narrow_w_chan_t  ),
    .slv_w_chan_t       (periph_wide_w_chan_t    ),
    .axi_mst_req_t      (periph_narrow_req_t     ),
    .axi_mst_resp_t     (periph_narrow_resp_t    ),
    .axi_slv_req_t      (periph_wide_req_t       ),
    .axi_slv_resp_t     (periph_wide_resp_t      )
  ) i_axi_slave_uart_dwc (
    .clk_i     (clk_i                       ),
    .rst_ni    (rst_ni                      ),
    .slv_req_i (periph_wide_axi_req[UART]   ),
    .slv_resp_o(periph_wide_axi_resp[UART]  ),
    .mst_req_o (periph_narrow_axi_req[UART] ),
    .mst_resp_i(periph_narrow_axi_resp[UART])
  );

  /////////////////////////
  //  Control registers  //
  /////////////////////////

  periph_narrow_lite_req_t  axi_lite_ctrl_registers_req;
  periph_narrow_lite_resp_t axi_lite_ctrl_registers_resp;

  axi_to_axi_lite #(
    .AxiAddrWidth   (AxiAddrWidth          ),
    .AxiDataWidth   (AxiNarrowDataWidth    ),
    .AxiIdWidth     (AxiPeriphIdWidth      ),
    .AxiUserWidth   (AxiUserWidth          ),
    .AxiMaxReadTxns (1                     ),
    .AxiMaxWriteTxns(1                     ),
    .FallThrough    (1'b0                  ),
    .full_req_t     (periph_narrow_req_t      ),
    .full_resp_t    (periph_narrow_resp_t     ),
    .lite_req_t     (periph_narrow_lite_req_t ),
    .lite_resp_t    (periph_narrow_lite_resp_t)
  ) i_axi_to_axi_lite (
    .clk_i     (clk_i                        ),
    .rst_ni    (rst_ni                       ),
    .test_i    (1'b0                         ),
    .slv_req_i (periph_narrow_axi_req[CTRL]  ),
    .slv_resp_o(periph_narrow_axi_resp[CTRL] ),
    .mst_req_o (axi_lite_ctrl_registers_req  ),
    .mst_resp_i(axi_lite_ctrl_registers_resp )
  );

  ctrl_registers #(
    .DRAMBaseAddr   (DRAMBase              ),
    .DRAMLength     (DRAMLength            ),
    .DataWidth      (AxiNarrowDataWidth    ),
    .AddrWidth      (AxiAddrWidth          ),
    .axi_lite_req_t (periph_narrow_lite_req_t ),
    .axi_lite_resp_t(periph_narrow_lite_resp_t)
  ) i_ctrl_registers (
    .clk_i                (clk_i                       ),
    .rst_ni               (rst_ni                      ),
    .axi_lite_slave_req_i (axi_lite_ctrl_registers_req ),
    .axi_lite_slave_resp_o(axi_lite_ctrl_registers_resp),
    .hw_cnt_en_o          (hw_cnt_en_o                 ),
    .dram_base_addr_o     (dram_base_addr_o            ),
    .dram_end_addr_o      (dram_end_addr_o             ),
    .exit_o               (exit_o                      ),
    .event_trigger_o      (event_trigger_o             )
  );

  axi_dw_converter #(
    .AxiSlvPortDataWidth(AxiWideDataWidth    ),
    .AxiMstPortDataWidth(AxiNarrowDataWidth  ),
    .AxiAddrWidth       (AxiAddrWidth        ),
    .AxiIdWidth         (AxiPeriphIdWidth       ),
    .AxiMaxReads        (2                   ),
    .ar_chan_t          (periph_wide_ar_chan_t  ),
    .mst_r_chan_t       (periph_narrow_r_chan_t ),
    .slv_r_chan_t       (periph_wide_r_chan_t   ),
    .aw_chan_t          (periph_narrow_aw_chan_t),
    .b_chan_t           (periph_narrow_b_chan_t ),
    .mst_w_chan_t       (periph_narrow_w_chan_t ),
    .slv_w_chan_t       (periph_wide_w_chan_t   ),
    .axi_mst_req_t      (periph_narrow_req_t    ),
    .axi_mst_resp_t     (periph_narrow_resp_t   ),
    .axi_slv_req_t      (periph_wide_req_t      ),
    .axi_slv_resp_t     (periph_wide_resp_t     )
  ) i_axi_slave_ctrl_dwc (
    .clk_i     (clk_i                       ),
    .rst_ni    (rst_ni                      ),
    .slv_req_i (periph_wide_axi_req[CTRL]   ),
    .slv_resp_o(periph_wide_axi_resp[CTRL]  ),
    .mst_req_o (periph_narrow_axi_req[CTRL] ),
    .mst_resp_i(periph_narrow_axi_resp[CTRL])
  );

  ////////////////////////////
  //  ARA + CVA6 System     //
  ////////////////////////////
  localparam          NrHarts  = 1;
  logic [NrHarts-1:0] debug_req_dm_cva6;
  logic [2:0]         hart_id_ara_system;

  assign hart_id_ara_system = '0;

  localparam ariane_pkg::ariane_cfg_t ArianeAraConfig = '{
    RASDepth             : 2,
    BTBEntries           : 32,
    BHTEntries           : 128,
    // idempotent region
    NrNonIdempotentRules : 2,
    NonIdempotentAddrBase: {64'b0, 64'b0},
    NonIdempotentLength  : {64'b0, 64'b0},
    NrExecuteRegionRules : 3,
    ExecuteRegionAddrBase: {DRAMBase  , BOOTBase  , DMBase  },
    ExecuteRegionLength  : {DRAMLength, BOOTLength, DMLength},
    // cached region
    NrCachedRegionRules  : 1,
    CachedRegionAddrBase : {DRAMBase},
    CachedRegionLength   : {DRAMLength},
    //  cache config
    Axi64BitCompliant    : 1'b1,
    SwapEndianess        : 1'b0,
    // debug
    DmBaseAddress        : DMBase,
    NrPMPEntries         : 0
  };


  // Ara System interrupt sources 
  logic [1:0]              irq_ara_system;        // level sensitive IR lines, mip & sip (async)
  logic                    ipi_ara_system;        // inter-processor interrupts (async)
  logic                    time_irq_ara_system;   // timer interrupt in (async)
    
  // Tie to zero for now
  assign irq_ara_system       = '0;
  assign ipi_ara_system       = '0;
  assign time_irq_ara_system  = '0;

`ifndef TARGET_GATESIM
  ara_system #(
    .NrLanes           (NrLanes              ),
    .FPUSupport        (FPUSupport           ),
    .FPExtSupport      (FPExtSupport         ),
    .FixPtSupport      (FixPtSupport         ),
    .ArianeCfg         (ArianeAraConfig      ),
    .AxiAddrWidth      (AxiAddrWidth         ),
    .AxiIdWidth        (AxiCoreIdWidth       ),
    .AxiNarrowDataWidth(AxiNarrowDataWidth   ),
    .AxiWideDataWidth  (AxiWideDataWidth     ),
    .ara_axi_ar_t      (ara_axi_ar_chan_t    ),
    .ara_axi_aw_t      (ara_axi_aw_chan_t    ),
    .ara_axi_b_t       (ara_axi_b_chan_t     ),
    .ara_axi_r_t       (ara_axi_r_chan_t     ),
    .ara_axi_w_t       (ara_axi_w_chan_t     ),
    .ara_axi_req_t     (ara_axi_req_t        ),
    .ara_axi_resp_t    (ara_axi_resp_t       ),
    .ariane_axi_ar_t   (ariane_axi_ar_chan_t ),
    .ariane_axi_aw_t   (ariane_axi_aw_chan_t ),
    .ariane_axi_b_t    (ariane_axi_b_chan_t  ),
    .ariane_axi_r_t    (ariane_axi_r_chan_t  ),
    .ariane_axi_w_t    (ariane_axi_w_chan_t  ),
    .ariane_axi_req_t  (ariane_axi_req_t     ),
    .ariane_axi_resp_t (ariane_axi_resp_t    ),
    .system_axi_ar_t   (master_wide_ar_chan_t ),
    .system_axi_aw_t   (master_wide_aw_chan_t ),
    .system_axi_b_t    (master_wide_b_chan_t  ),
    .system_axi_r_t    (master_wide_r_chan_t  ),
    .system_axi_w_t    (master_wide_w_chan_t  ),
    .system_axi_req_t  (master_wide_req_t     ),
    .system_axi_resp_t (master_wide_resp_t    )
    )
`else
  ara_system
`endif
  i_system (
    .clk_i        ( clk_i                    ),
    .rst_ni       ( rst_ni                   ),
    .boot_addr_i  ( BOOTBase                 ), // start fetching from Bootrom
    // .boot_addr_i  ( DRAMBase                 ), // DEBUG: start fetching from DRAM
    .hart_id_i    ( hart_id_ara_system       ),
    .irq_i        ( irq_ara_system           ),
    .ipi_i        ( ipi_ara_system           ),
    .time_irq_i   ( time_irq_ara_system      ),
    .debug_req_i  ( debug_req_dm_cva6        ),
    .scan_enable_i( scan_enable_i            ),
    .scan_data_i  ( scan_data_i              ),
    .scan_data_o  ( scan_data_o              ),
`ifndef TARGET_GATESIM
    .axi_req_o    ( master_wide_axi_req  [AraAriane] ),
    .axi_resp_i   ( master_wide_axi_resp [AraAriane] )
  );
`else
  //   .axi_req_o    (master_wide_axi_req_spill     ),
  //   .axi_resp_i   (master_wide_axi_resp_spill_delayed)
  // );
`endif


`ifdef TARGET_GATESIM
  assert ( 1 ) else $error("just error out for now");
  // assign #(AxiRespDelay*1ps) master_wide_axi_resp_spill_delayed = master_wide_axi_resp_spill;

  // axi_cut #(
  //   .ar_chan_t   (master_wide_ar_chan_t     ),
  //   .aw_chan_t   (master_wide_aw_chan_t     ),
  //   .b_chan_t    (master_wide_b_chan_t      ),
  //   .r_chan_t    (master_wide_r_chan_t      ),
  //   .w_chan_t    (master_wide_w_chan_t      ),
  //   .axi_req_t       (master_wide_req_t         ),
  //   .axi_resp_t      (master_wide_resp_t        )
  // ) i_master_wide_cut (
  //   .clk_i       (clk_i),
  //   .rst_ni      (rst_ni),
  //   .slv_req_i   (master_wide_axi_req_spill),
  //   .slv_resp_o  (master_wide_axi_resp_spill),
  //   .mst_req_o   (master_wide_axi_req),
  //   .mst_resp_i  (master_wide_axi_resp)
  // );
`endif

  //////////////////
  // Debug Module
  //////////////////

  // For ETX_JTAG, unused with BSCANE2
  localparam logic [15:0]        PartNumber = 2;
  localparam logic [31:0]        IDCODE   = (dm::DbgVersion013 << 28) | (PartNumber << 12) | 32'b1; // 0x20002001
  localparam hartinfo_t          HARTINFO = '{  zero1:        8'h0,
                                                nscratch:     4'h2,
                                                zero0:        3'b0,
                                                dataaccess:   1'b1,
                                                datasize:     dm::DataCount,
                                                dataaddr:     dm::DataAddr
                                              };
  localparam logic [NrHarts-1:0] SELECTABLE_HARTS = '{1'b1};
  
  // signals for debug unit
  logic                        dm_dmi_rst_n;
  dm::dmi_req_t                dm_dmi_req;
  logic                        dm_dmi_req_valid;
  dm::dmi_resp_t               dm_dmi_resp;
  logic                        dm_dmi_resp_ready;
  logic                        dm_dmi_resp_valid;

  // debug unit slave interface
  logic                             dm_slave_rvalid;
  logic                             dm_slave_req;
  logic                             dm_slave_grant;
  logic                             dm_slave_we;
  logic [AxiNarrowDataWidth-1:0]    dm_slave_addr;
  logic [AxiNarrowDataWidth-1:0]    dm_slave_wdata;
  logic [AxiNarrowDataWidth-1:0]    dm_slave_rdata;
  logic [AxiNarrowDataWidth/8-1:0]  dm_slave_be;

  // debug unit master interface (system bus access)
  logic                             dm_master_req;
  logic                             dm_master_we;
  logic [AxiNarrowDataWidth-1:0]    dm_master_addr;
  logic [AxiNarrowDataWidth-1:0]    dm_master_wdata;
  logic [AxiNarrowDataWidth/8-1:0]  dm_master_be;
  logic                             dm_master_gnt;
  logic                             dm_master_rvalid;
  logic [AxiNarrowDataWidth-1:0]    dm_master_rdata;

  // debug subsystem
  dmi_jtag #(
    .IdcodeValue          ( IDCODE            )
  ) i_dmi_jtag (
    .clk_i                ( clk_i             ),
    .rst_ni               ( rst_ni            ),
    .testmode_i           ( 1'b0              ),
    // DMI interface
    .dmi_resp_i           ( dm_dmi_resp       ),
    .dmi_req_o            ( dm_dmi_req        ),
    .dmi_req_valid_o      ( dm_dmi_req_valid  ),
    .dmi_req_ready_i      ( dm_req_ready      ),
    .dmi_resp_ready_o     ( dm_dmi_resp_ready ),
    .dmi_resp_valid_i     ( dm_dmi_resp_valid ),
    .dmi_rst_no           ( dm_dmi_rst_n      ), 
    // JTAG interface
    .tck_i                ( jtag_tck_i        ),
    .tms_i                ( jtag_tms_i        ),
    .trst_ni              ( jtag_trst_ni      ), 
    .td_i                 ( jtag_tdi_i        ),
    .td_o                 ( jtag_tdo_o        ),
    .tdo_oe_o             ( jtag_tdo_oe_o     ) 
  );

  // Read response is valid one cycle after request
  `FF(dm_slave_rvalid, dm_slave_req, 1'b0, clk_i, rst_ni)

  dm_top #(
    .NrHarts          ( NrHarts            ),
    .BusWidth         ( AxiNarrowDataWidth ),
    .DmBaseAddress    ( DMBase             ),
    .SelectableHarts  ( SELECTABLE_HARTS   )
  ) i_dm_top (
    .clk_i             ( clk_i             ),
    .rst_ni            ( jtag_trst_ni      ), 
    .testmode_i        ( 1'b0              ),
    .ndmreset_o        (                   ), // Open
    .dmactive_o        ( dmactive_o        ), 
    .debug_req_o       ( debug_req_dm_cva6 ),
    .unavailable_i     ( ~SELECTABLE_HARTS ),
    .hartinfo_i        ( HARTINFO          ),
    // Slave port
    .slave_req_i       ( dm_slave_req      ),
    .slave_we_i        ( dm_slave_we       ),
    .slave_addr_i      ( dm_slave_addr     ),
    .slave_be_i        ( dm_slave_be       ),
    .slave_wdata_i     ( dm_slave_wdata    ),
    .slave_rdata_o     ( dm_slave_rdata    ),
    // Master port
    .master_req_o      ( dm_master_req     ),
    .master_add_o      ( dm_master_addr    ),
    .master_we_o       ( dm_master_we      ),
    .master_wdata_o    ( dm_master_wdata   ),
    .master_be_o       ( dm_master_be      ),
    .master_gnt_i      ( dm_master_gnt     ),
    .master_r_valid_i  ( dm_master_rvalid  ),
    .master_r_err_i    ( 1'b0              ),
    .master_r_other_err_i ( 1'b0           ),
    .master_r_rdata_i  ( dm_master_rdata   ),
    // DMI interface
    .dmi_rst_ni        ( dm_dmi_rst_n      ),
    .dmi_req_valid_i   ( dm_dmi_req_valid  ),
    .dmi_req_ready_o   ( dm_req_ready      ),
    .dmi_req_i         ( dm_dmi_req        ),
    .dmi_resp_valid_o  ( dm_dmi_resp_valid ),
    .dmi_resp_ready_i  ( dm_dmi_resp_ready ),
    .dmi_resp_o        ( dm_dmi_resp       )
  );

  //////////////////////////////////
  // DM master to SoC wide bus
  //////////////////////////////////
  // How many requests can be in flight at the same time. (Depth of the response mux FIFO).
  localparam DbgMaxReqs = 1; 

  // DM master to AxiNarrowDataWidth
  axi_from_mem #(
    .MemAddrWidth ( AxiAddrWidth         ),
    .AxiAddrWidth ( AxiAddrWidth         ),
    .DataWidth    ( AxiNarrowDataWidth   ),
    .MaxRequests  ( DbgMaxReqs           ), 
    .AxiProt      ( '0                   ),
    .axi_req_t    ( dm_narrow_axi_req_t  ),
    .axi_rsp_t    ( dm_narrow_axi_resp_t )
  ) i_dm_master_axi_from_mem (
    .clk_i,
    .rst_ni,
    .mem_req_i       ( dm_master_req             ),
    .mem_addr_i      ( dm_master_addr            ),
    .mem_we_i        ( dm_master_we              ),
    .mem_wdata_i     ( dm_master_wdata           ),
    .mem_be_i        ( dm_master_be              ),
    .mem_gnt_o       ( dm_master_gnt             ),
    .mem_rsp_valid_o ( dm_master_rvalid          ),
    .mem_rsp_rdata_o ( dm_master_rdata           ),
    .mem_rsp_error_o ( dm_master_err             ),
    .slv_aw_cache_i  ( axi_pkg::CACHE_MODIFIABLE ), 
    .slv_ar_cache_i  ( axi_pkg::CACHE_MODIFIABLE ), 
    .axi_req_o       ( dm_narrow_axi_req         ),
    .axi_rsp_i       ( dm_narrow_axi_resp        )
  );

  // DM master AXI AxiNarrowDataWidth to AxiWideDataWidth
  axi_dw_converter #(
    .AxiSlvPortDataWidth( AxiNarrowDataWidth       ),
    .AxiMstPortDataWidth( AxiWideDataWidth         ),
    .AxiAddrWidth       ( AxiAddrWidth             ),
    .AxiIdWidth         ( AxiSysIdWidth            ),
    .AxiMaxReads        ( 4                        ),
    .ar_chan_t          ( master_wide_ar_chan_t    ),
    .mst_r_chan_t       ( master_wide_r_chan_t     ),
    .slv_r_chan_t       ( dm_narrow_axi_r_chan_t   ),
    .aw_chan_t          ( master_wide_aw_chan_t    ),
    .b_chan_t           ( master_wide_b_chan_t     ),
    .mst_w_chan_t       ( master_wide_w_chan_t     ),
    .slv_w_chan_t       ( dm_narrow_axi_w_chan_t   ),
    .axi_mst_req_t      ( master_wide_req_t        ),
    .axi_mst_resp_t     ( master_wide_resp_t       ),
    .axi_slv_req_t      ( dm_narrow_axi_req_t      ),
    .axi_slv_resp_t     ( dm_narrow_axi_resp_t     )
  ) i_axi_dm_master_dwc (
    .clk_i      ( clk_i                            ),
    .rst_ni     ( rst_ni                           ),
    .slv_req_i  ( dm_narrow_axi_req                ),
    .slv_resp_o ( dm_narrow_axi_resp               ),
    .mst_req_o  ( master_wide_axi_req  [DM_master] ),
    .mst_resp_i ( master_wide_axi_resp [DM_master] )
  );

  //////////////////////////////////
  // DM slave to SoC wide bus
  //////////////////////////////////

  // AxiNarrowDataWidth to DM slave 
  axi_to_mem #(
    .BufDepth   ( 1                    ), 
    .axi_req_t  ( periph_narrow_req_t  ), 
    .axi_resp_t ( periph_narrow_resp_t ),
    .AddrWidth  ( AxiAddrWidth         ), 
    .DataWidth  ( AxiNarrowDataWidth   ), 
    .IdWidth    ( AxiPeriphIdWidth     ), 
    .NumBanks   ( 1                    ) // from Cheshire and Occamy
  ) i_dm_slave_axi_to_mem (
    .clk_i        ( clk_i                             ),
    .rst_ni       ( rst_ni                            ),
    .busy_o       (                                   ), // Open ?
    .axi_req_i    ( periph_narrow_axi_req  [DM_slave] ),
    .axi_resp_o   ( periph_narrow_axi_resp [DM_slave] ),
    .mem_req_o    ( dm_slave_req                      ),
    .mem_gnt_i    ( dm_slave_req                      ),
    .mem_addr_o   ( dm_slave_addr                     ),
    .mem_wdata_o  ( dm_slave_wdata                    ),
    .mem_strb_o   ( dm_slave_be                       ),
    .mem_atop_o   (                                   ), // Open ?
    .mem_we_o     ( dm_slave_we                       ),
    .mem_rvalid_i ( dm_slave_rvalid                   ),
    .mem_rdata_i  ( dm_slave_rdata                    )
  );

  // DM slave AXI AxiWideDataWidth to AxiNarrowDataWidth
  axi_dw_converter #(
    .AxiSlvPortDataWidth( AxiWideDataWidth     ),
    .AxiMstPortDataWidth( AxiNarrowDataWidth   ),
    .AxiAddrWidth       ( AxiAddrWidth         ),
    .AxiIdWidth         ( AxiPeriphIdWidth     ),
    .AxiMaxReads        ( 2                    ),
    .ar_chan_t          ( periph_wide_ar_chan_t   ),
    .mst_r_chan_t       ( periph_narrow_r_chan_t  ),
    .slv_r_chan_t       ( periph_wide_r_chan_t    ),
    .aw_chan_t          ( periph_narrow_aw_chan_t ),
    .b_chan_t           ( periph_wide_b_chan_t    ),
    .mst_w_chan_t       ( periph_narrow_w_chan_t  ),
    .slv_w_chan_t       ( periph_wide_w_chan_t    ),
    .axi_mst_req_t      ( periph_narrow_req_t     ),
    .axi_mst_resp_t     ( periph_narrow_resp_t    ),
    .axi_slv_req_t      ( periph_wide_req_t       ),
    .axi_slv_resp_t     ( periph_wide_resp_t      )
  ) i_axi_dm_slave_dwc (
    .clk_i      ( clk_i                              ),
    .rst_ni     ( rst_ni                             ),
    .slv_req_i  ( periph_wide_axi_req     [DM_slave] ),
    .slv_resp_o ( periph_wide_axi_resp    [DM_slave] ),
    .mst_req_o  ( periph_narrow_axi_req   [DM_slave] ),
    .mst_resp_i ( periph_narrow_axi_resp  [DM_slave] )
  );

  //////////////////
  //  Assertions  //
  //////////////////

  if (NrLanes == 0)
    $error("[ara_soc] Ara needs to have at least one lane.");

  if (AxiDataWidth == 0)
    $error("[ara_soc] The AXI data width must be greater than zero.");

  if (AxiAddrWidth == 0)
    $error("[ara_soc] The AXI address width must be greater than zero.");

  if (AxiUserWidth == 0)
    $error("[ara_soc] The AXI user width must be greater than zero.");

  if (AxiIdWidth == 0)
    $error("[ara_soc] The AXI ID width must be greater than zero.");

  if (AxiIdWidth != 4)
    $error("[ara_soc] The AXI ID width must be 4 because of the current ariane_axi_pkg.");

endmodule : ara_soc
