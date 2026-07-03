// Delays only the release of the console freeze.
//
// When the save state controller drops ss_pause, the SDRAM port handback
// (ss_pause resynchronized into clk_mem, plus a possible in-flight refresh)
// and a fresh read of the pending ROM address must complete before any bus
// master may sample its data bus again: during the freeze the save state
// traffic overwrote the sdram controller's read register. SNES.sv holds
// ROM_Q at its pre pause value until that re-read completes, and the
// re-read fires on its own at the handback: the frozen console holds its
// read strobe levels (the parked SA-1 clock enable keeps ROM_RD_N
// asserted), the sdram edge detector was cleared while the transport drove
// the port, and the pending address differs from the last blob address, so
// the pending word is re-read within ~10 clk_sys; HOLD only has to outlast
// that with margin.
//
// The assertion path is combinational so freezing is never delayed.

module pause_stretch #(
    parameter [6:0] HOLD = 7'd64  // clk_sys cycles (~3 us), >6x worst case
) (
    input  wire clk_sys,
    input  wire pause_in,   // raw ss_pause, also feeds save_state_mem
    output wire pause_out   // CPU-facing: asserts at once, releases late
);

  reg [6:0] hold_cnt = 0;

  always @(posedge clk_sys) begin
    if (pause_in) hold_cnt <= HOLD;
    else if (hold_cnt != 0) hold_cnt <= hold_cnt - 1'd1;
  end

  assign pause_out = pause_in | (hold_cnt != 0);

endmodule
