// Testbench for pause_stretch: assertion must be combinational, release
// must lag by exactly HOLD clk_sys cycles, and a re-assert mid-stretch must
// re-arm the counter without any glitch on the output.

`timescale 1ns / 1ps

module tb_pause_stretch;
  reg clk_sys = 0;
  always #23.28 clk_sys = ~clk_sys;  // 21.48 MHz

  localparam [6:0] HOLD = 7'd64;

  reg pause_in = 0;
  wire pause_out;

  pause_stretch #(
      .HOLD(HOLD)
  ) dut (
      .clk_sys(clk_sys),
      .pause_in(pause_in),
      .pause_out(pause_out)
  );

  integer errors = 0;
  integer lag;

  // Any low output while the input is high is a glitch
  always @(negedge pause_out) begin
    if (pause_in) begin
      $display("FAIL: pause_out dropped while pause_in high");
      errors = errors + 1;
    end
  end

  task expect_release_lag;
    begin
      @(negedge clk_sys);
      pause_in = 0;
      lag = 0;
      while (pause_out && lag < 1000) begin
        @(posedge clk_sys);
        lag = lag + 1;
      end
      // hold_cnt was reloaded to HOLD every cycle while pause_in was high,
      // so the output falls HOLD+1 posedges after the release
      if (lag != HOLD + 1) begin
        $display("FAIL: release lag %0d cycles, expected %0d", lag, HOLD + 1);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (5) @(posedge clk_sys);

    // Combinational assertion
    @(negedge clk_sys);
    pause_in = 1;
    #1;
    if (!pause_out) begin
      $display("FAIL: pause_out did not assert combinationally");
      errors = errors + 1;
    end
    repeat (10) @(posedge clk_sys);

    // Exact release lag
    expect_release_lag;
    if (errors == 0) $display("PASS: release lags by HOLD cycles");

    repeat (10) @(posedge clk_sys);

    // Re-assert mid-stretch: counter re-arms, no glitch
    @(negedge clk_sys);
    pause_in = 1;
    repeat (10) @(posedge clk_sys);
    @(negedge clk_sys);
    pause_in = 0;
    repeat (20) @(posedge clk_sys);  // inside the stretch
    if (!pause_out) begin
      $display("FAIL: stretch ended early");
      errors = errors + 1;
    end
    @(negedge clk_sys);
    pause_in = 1;  // re-arm
    repeat (5) @(posedge clk_sys);
    expect_release_lag;
    if (errors == 0) $display("PASS: re-assert mid-stretch re-arms cleanly");

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d ERRORS", errors);
    $finish;
  end
endmodule
