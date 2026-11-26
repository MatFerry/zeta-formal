// Replays one end-to-end point on zeta_em_e2e in Verilator, with the
// controller checker bound in. Inputs are random between accepted requests,
// as they are free in the formal runs. See run_point.sh.
module tb_point;
  localparam int unsigned MAX_CYCLES = 2_000_000;
  logic clk = 0, rst_n = 0;
  logic [31:0] sigma_raw = 0, t_raw = 0;
  int unsigned results = 0, cycle = 0, last = 0;

  zeta_em_e2e dut (.*);

  always #5 clk = ~clk;
  initial begin
    repeat (5) @(posedge clk);
    // Release reset before the falling edge that drives the first request.
    #1 rst_n = 1;
  end

  always @(negedge clk) begin
    if (rst_n && dut.start_ready) begin
      sigma_raw = `ZETA_SIGMA_LO;
      t_raw     = `ZETA_T_LO;
    end else begin
      sigma_raw = $urandom;
      t_raw     = $urandom;
    end
  end

  always @(posedge clk) if (rst_n) begin
    cycle <= cycle + 1;
    if (cycle == MAX_CYCLES - 1)
      $fatal(1, "Only %0d of 2 results after %0d cycles (N=%0d, state=%0d)",
             results, MAX_CYCLES, dut.n_latched, dut.dut.state);
    if (dut.out_valid) begin
      $display("RESULT latency=%0d N=%0d z_re=%h z_im=%h below_eps=%b sigma_steps_from_half=%0d ovf=%b unf=%b entry_beats=%0d bern_beats=%0d",
               cycle - last, dut.n_latched, dut.z_re, dut.z_im, dut.below_eps,
               dut.sigma_delta_raw, dut.ovf, dut.unf,
               dut.dut.u_ctrl_checker.entry_cnt, dut.dut.u_ctrl_checker.bern_cnt);
      last <= cycle;
      results <= results + 1;
      if (results == 1) $finish;
    end
  end
endmodule
