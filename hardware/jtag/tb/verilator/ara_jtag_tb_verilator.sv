// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Vincenzo Maisto <vincenzo.maisto2@unina.it>
// Description: testbench for Ara SoC with JTAG

import ara_pkg::*;

module ara_jtag_tb_verilator ();

  //////////////////
  //  Definitions //
  //////////////////
  localparam int unsigned NrLanes = 
  localparam int unsigned CLOCK_PERIOD = 20ns;
  localparam AxiAddrWidth     = 64;

  // Signals
  logic   clk_i        ;
  logic   rst_ni       ;
  logic   exit_o       ;
  logic   jtag_tck_i   ;
  logic   jtag_trst_ni ; 
  logic   jtag_tdo_o   ;
  logic   jtag_tdi_i   ;
  logic   jtag_tms_i   ;
 
  //////////
  //  DUT //
  //////////
  ara_jtag_testharness #(
    .NrLanes      ( NrLanes          ),
    .AxiAddrWidth ( AxiAddrWidth     )
  ) dut (
    .clk_i            ( clk_i        ),
    .rst_ni           ( rst_ni       ),
    .exit_o           ( exit_o       ),
    .jtag_tck_i       ( jtag_tck_i   ),
    .jtag_trst_ni     ( jtag_trst_ni ), 
    .jtag_tdo_o       ( jtag_tdo_o   ),
    .jtag_tdi_i       ( jtag_tdi_i   ),
    .jtag_tms_i       ( jtag_tms_i   )
  );


  /////////////////////
  // Clock and reset //
  /////////////////////
  initial begin
      clk_i = 1'b0;
      rst_ni = 1'b0;
      repeat(8)
          #(CLOCK_PERIOD/2) clk_i = ~clk_i;
      rst_ni = 1'b1;
      forever begin
          #(CLOCK_PERIOD/2) clk_i = 1'b1;
          #(CLOCK_PERIOD/2) clk_i = 1'b0;

          //if (cycles > max_cycles)
          //    $fatal(1, "Simulation reached maximum cycle count of %d", max_cycles);

          cycles++;
      end
  end



  //////////
  //  EOC //
  //////////

  always @(posedge clk_i) begin
    if (exit_o[0]) begin
      if (exit_o >> 1) begin
        $warning("Core Test ", $sformatf("*** FAILED *** (tohost = %0d)", (exit_o >> 1)));
      end else begin
        // Print vector HW runtime
        $display("[hw-cycles]: %d", int'(dut.runtime_buf_q));
        $info("Core Test ", $sformatf("*** SUCCESS *** (tohost = %0d)", (exit_o >> 1)));
      end

      $finish(exit_o >> 1);
    end
  end

endmodule : ara_tb_verilator
