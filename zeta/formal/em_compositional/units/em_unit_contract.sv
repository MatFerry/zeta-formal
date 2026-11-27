// Handshake contract of one datapath unit, checked on the real RTL.
//
// The controller proof (../ctrl) assumes exactly this about each black-boxed
// unit and proves the single-flight discipline that is assumed here.
module em_unit_contract #(
    parameter bit HAS_READY = 1'b0,
    // Longest launch-to-completion time in cycles. 0 disables the check.
    parameter int unsigned MAX_LATENCY = 0
) (
    input logic clk,
    input logic rst_n,
    input logic go,     // launch strobe (in_valid)
    input logic done,   // completion pulse (out_valid)
    input logic ready   // in_ready, when the unit has one
);
  logic busy;

  always_ff @(posedge clk) begin
    if (!rst_n) busy <= 1'b0;
    else if (go) busy <= 1'b1;
    else if (done) busy <= 1'b0;
  end

  // Proven on the controller as ap_*_single_flight.
  a_single_flight: assume property (@(posedge clk) disable iff (!rst_n)
      go |-> !busy);

  // Assumed in the controller proof as a_*_done_in_flight.
  ap_done_in_flight: assert property (@(posedge clk) disable iff (!rst_n)
      done |-> busy);

  if (HAS_READY) begin : with_ready
    // The controller never looks at in_ready, so an idle unit must accept.
    ap_ready_when_idle: assert property (@(posedge clk) disable iff (!rst_n)
        !busy |-> ready);
  end

  if (MAX_LATENCY != 0) begin : with_response
    // Every launch is answered. The controller proof only assumes that a
    // completion needs a launch; this shows that a launch gets a completion.
    logic [15:0] age;
    always_ff @(posedge clk) begin
      if (!rst_n) age <= '0;
      else if (go) age <= 16'd1;
      else if (done) age <= '0;
      else if (busy && age != '1) age <= age + 16'd1;
    end
    ap_done_arrives: assert property (@(posedge clk) disable iff (!rst_n)
        busy && !done |-> age < 16'(MAX_LATENCY));
  end

  cp_done: cover property (@(posedge clk) disable iff (!rst_n) done);
  cp_two_results: cover property (@(posedge clk) disable iff (!rst_n)
      done ##[1:$] done);
endmodule

// One top per unit, at the Z64 configuration used by the demo.
module em_unit_mul_top (
    input logic        clk,
    input logic        rst_n,
    input logic        in_valid,
    input logic [86:0] x,
    input logic [86:0] y
);
  logic out_valid, ovf, unf;
  logic [86:0] result;

  mpf_mul #(.LIMBS(1), .EXPW(20)) dut (
      .clk, .rst_n, .in_valid, .x, .y, .out_valid, .result, .ovf, .unf
  );
  // TILE_LATENCY 2 + two tree levels + the rounding stage.
  em_unit_contract #(.MAX_LATENCY(5)) contract (
      .clk, .rst_n, .go(in_valid), .done(out_valid), .ready(1'b1)
  );
endmodule

module em_unit_add_top (
    input logic        clk,
    input logic        rst_n,
    input logic        in_valid,
    input logic [86:0] x,
    input logic [86:0] y
);
  logic out_valid, ovf, unf;
  logic [86:0] result;

  mpf_add #(.LIMBS(1), .EXPW(20)) dut (
      .clk, .rst_n, .in_valid, .x, .y, .out_valid, .result, .ovf, .unf
  );
  em_unit_contract #(.MAX_LATENCY(3)) contract (
      .clk, .rst_n, .go(in_valid), .done(out_valid), .ready(1'b1)
  );
endmodule

module em_unit_npow_top (
    input logic         clk,
    input logic         rst_n,
    input logic         in_valid,
    input logic [86:0]  sigma,
    input logic [95:0]  lnn_fx,
    input logic [135:0] lnn2pi,
    input logic [63:0]  t_fx
);
  logic in_ready, out_valid, ovf, unf, first_cycle;
  logic [86:0] re_o, im_o;

  npow_s_kernel #(
      .LIMBS(1), .EXPW(20), .PHW(96), .FG(88), .CONSTW(96),
      .TERMS(22), .CTERMS(11),
      .EXP_ROM("rtl/common/fn/tables/expln_w64_exp.mem"),
      .CEXP_ROM("rtl/common/fn/tables/cexp_w64.mem")
  ) dut (
      .clk, .rst_n, .in_valid, .in_ready, .sigma, .lnn_fx, .lnn2pi, .t_fx,
      .out_valid, .re_o, .im_o, .ovf, .unf
  );
  // No MAX_LATENCY here yet: 43 cycles is the expected bound for this
  // configuration, but that proof has not been closed.
  em_unit_contract #(.HAS_READY(1'b1)) contract (
      .clk, .rst_n, .go(in_valid), .done(out_valid), .ready(in_ready)
  );

  // The arithmetic subunits can sample these strobes on the first active edge.
  always_ff @(posedge clk) first_cycle <= !rst_n;

  ap_reset_launch_clear: assert property (@(posedge clk) disable iff (!rst_n)
      first_cycle |-> !dut.exp_launch && !dut.cexp_launch && !dut.mul_launch);

  // cp_done is reached one cycle after a launch with a special sigma. This
  // one needs the amplitude, the phase and both multiplications.
  cp_done_computed: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && dut.a_done && dut.c_done && !dut.amp_q[86]);
endmodule
