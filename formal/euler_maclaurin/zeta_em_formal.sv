// Z64 transaction driver and properties for euler_maclaurin_top.
`ifndef ZETA_CASE
  `define ZETA_CASE 2
`endif
`ifndef ZETA_EPS_EXP
  `define ZETA_EPS_EXP (-16)
`endif
`ifndef ZETA_EPS_FROM_RE_ONEHALF_EXP
  `define ZETA_EPS_FROM_RE_ONEHALF_EXP EPS_EXP
`endif

module zeta_em_formal #(
    parameter int RUN_CASE = `ZETA_CASE, // 0: half, 1: half + 2^-16, 2: released
    parameter int EPS_EXP = `ZETA_EPS_EXP,
    parameter int EPS_FROM_RE_ONEHALF_EXP = `ZETA_EPS_FROM_RE_ONEHALF_EXP
) (
    input logic clk,
    input logic rst_n,
    input logic [31:0] sigma_raw,
    input logic [31:0] t_raw
);
  localparam int WIDTH = 64;
  localparam int EXPW = 20;
  localparam int MPW = WIDTH + EXPW + 3;
  localparam int M = 50;
  localparam int N_MIN = 38;
  localparam int N_MAX = 9118;
  localparam int DIRECTED_N = 42;
  localparam int ENTRY_COUNT_W = $clog2(N_MAX + 3);
  localparam int BERN_COUNT_W = $clog2(M + 1);
  localparam logic [31:0] SIGMA_HALF = 32'h0000_8000;
  // The distance is an integer number of Q16.16 steps. For a tolerance
  // below one step only zero qualifies, and 2^32 steps covers every distance.
  localparam int SIGMA_EPS_RAW_EXP =
      (EPS_FROM_RE_ONEHALF_EXP <= -16) ? 0 :
      (EPS_FROM_RE_ONEHALF_EXP >= 16) ? 32 : EPS_FROM_RE_ONEHALF_EXP + 16;
  localparam logic [32:0] SIGMA_EPS_RAW = 33'd1 << SIGMA_EPS_RAW_EXP;
  localparam logic [31:0] DIRECTED_T = 32'h000e_227d;
  localparam logic [MPW-1:0] MPF_ZERO = {3'b010, {(WIDTH + EXPW){1'b0}}};

  function automatic int msb_index(input logic [63:0] value);
    int index;
    index = 0;
    for (int i = 0; i < 64; i++) begin
      if (value[i]) index = i;
    end
    return index;
  endfunction

  function automatic logic [MPW-1:0] fixed_to_mpf(input logic [31:0] raw);
    int index;
    logic [WIDTH-1:0] mantissa;
    if (raw == 0) return MPF_ZERO;
    index = msb_index({32'b0, raw});
    mantissa = WIDTH'(raw) << (WIDTH - 1 - index);
    return {3'b000, EXPW'(index + 1 - 16), mantissa};
  endfunction

  // Encode -numerator/denominator with the host's round-to-nearest-even MPF.
  // For legal Q16.16 inputs, denominator < 2^62 and the normalized
  // numerator before division is < denominator * 2^64.
  function automatic logic [MPW-1:0] negative_ratio_mpf(
      input logic [63:0] numerator, denominator
  );
    int power, exponent;
    logic [127:0] scaled;
    logic [WIDTH:0] quotient;
    logic [63:0] remainder;
    logic [64:0] twice_remainder;

    if (numerator == 0 || denominator == 0) return MPF_ZERO;
    power = msb_index(numerator) - msb_index(denominator);
    if (power >= 0 ? numerator < (denominator << power)
                   : (numerator << -power) < denominator) begin
      power -= 1;
    end
    exponent = power + 1;
    scaled = 128'(numerator) << (WIDTH - exponent);
    quotient = (WIDTH + 1)'(scaled / 128'(denominator));
    remainder = 64'(scaled - 128'(quotient) * 128'(denominator));
    twice_remainder = {remainder, 1'b0};
    if (twice_remainder > {1'b0, denominator} ||
        (twice_remainder == {1'b0, denominator} && quotient[0])) begin
      quotient += 1'b1;
    end
    if (quotient[WIDTH]) begin
      quotient >>= 1;
      exponent += 1;
    end
    return {3'b001, EXPW'(exponent), quotient[WIDTH-1:0]};
  endfunction

  logic start_ready, start_valid, accepted;
  logic entry_ready, entry_valid, bern_ready, bern_valid, out_valid, ovf, unf;
  logic [31:0] sigma_input, t_input;
  logic [63:0] a, b, denominator;
  logic [MPW-1:0] sigma_mpf, t_mpf, inv_re, inv_im, inv_np2;
  logic [MPW-1:0] z_re, z_im, bern_data;
  logic [ENTRY_COUNT_W-1:0] n_input, n_latched, entry_count, entry_index;
  logic [BERN_COUNT_W-1:0] bern_count;
  logic [95:0] lnn_fx;
  logic [135:0] lnn2pi;
  logic pending, below_eps;
  logic [31:0] sigma_latched, sigma_delta_raw;

  // A finite nonzero MPF from the RTL adder has its mantissa MSB set.
  function automatic logic normalized(input logic [MPW-1:0] word);
    return word[MPW-1] || word[MPW-2] || word[WIDTH-1];
  endfunction

  assign start_valid = rst_n && start_ready;
  assign accepted = start_valid && start_ready;

  a_legal_q16: assume property (@(posedge clk) disable iff (!rst_n)
      accepted |-> (sigma_raw > 32'd0 && sigma_raw < 32'd65536 && !t_raw[31]));

  if (RUN_CASE == 2) begin : released
    // Z64 host select_nm. The generator checks the quantized coefficient
    // against every transition in the host function on the Q16.16 grid.
    localparam logic [58:0] N_FACTOR = 59'h46f057ef67cc9a1;
    logic [90:0] n_scaled;
    logic [231:0] entries [0:N_MAX];

    initial $readmemh("sim_build/zeta_formal/entries_released.mem", entries);
    assign sigma_input = sigma_raw;
    assign t_input = t_raw;
    assign n_scaled = 91'(t_input + 32'd6553600) * 91'(N_FACTOR) +
                      {15'b0, {76{1'b1}}};
    assign n_input = ENTRY_COUNT_W'(n_scaled[90:76]) + ENTRY_COUNT_W'(10);
    assign {lnn_fx, lnn2pi} = entries[entry_index];
  end else begin : directed
    localparam logic [31:0] SIGMA = SIGMA_HALF + 32'(RUN_CASE);
    logic [231:0] entries [0:DIRECTED_N];

    initial $readmemh("sim_build/zeta_formal/entries_directed.mem", entries);
    // Constants keep the directed datapath and host arithmetic concrete.
    a_directed_point: assume property (@(posedge clk) disable iff (!rst_n)
        accepted |-> (sigma_raw == SIGMA && t_raw == DIRECTED_T));
    assign sigma_input = SIGMA;
    assign t_input = DIRECTED_T;
    assign n_input = ENTRY_COUNT_W'(DIRECTED_N);
    assign {lnn_fx, lnn2pi} = entries[$clog2(DIRECTED_N + 1)'(entry_index)];

    // Packed reference from host/zetafpga/golden/zeta_em.py at this point.
    // Read this assertion together with cp_result to verify result reachability.
    localparam logic [MPW-1:0] GOLDEN_RE =
        (RUN_CASE == 0) ? 87'h0fffecb12ece85ba6398ac : 87'h0ffff0d398a8a130e78ca8;
    localparam logic [MPW-1:0] GOLDEN_IM =
        (RUN_CASE == 0) ? 87'h1fffef8b1e6d66d0fccd7c : 87'h1fffee968b264a73f3f151;
    ap_matches_golden: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> z_re == GOLDEN_RE && z_im == GOLDEN_IM);
  end

  logic [MPW-1:0] inv_np2_table [0:N_MAX-N_MIN];
  logic [MPW-1:0] bern_table [0:M-1];
  initial begin
    $readmemh("sim_build/zeta_formal/inv_np2.mem", inv_np2_table);
    $readmemh("sim_build/zeta_formal/bern.mem", bern_table);
  end

  // 1/(s-1) = (-a - i*b) * 2^16 / (a*a + b*b), in raw Q16.16 units.
  assign a = 64'd65536 - 64'(sigma_input);
  assign b = 64'(t_input);
  assign denominator = a * a + b * b;
  assign inv_re = negative_ratio_mpf(a << 16, denominator);
  assign inv_im = negative_ratio_mpf(b << 16, denominator);
  assign inv_np2 = inv_np2_table[n_input - ENTRY_COUNT_W'(N_MIN)];
  assign sigma_mpf = fixed_to_mpf(sigma_input);
  assign t_mpf = fixed_to_mpf(t_input);

  // Feed ln(1)..ln(N+1), repeat ln(N+1), and supply M Bernoulli beats.
  // The two streams advance independently on valid/ready handshakes.
  assign entry_valid = pending && entry_count < n_latched + ENTRY_COUNT_W'(2);
  assign entry_index = entry_count > n_latched ? n_latched : entry_count;
  assign bern_valid = pending && bern_count < BERN_COUNT_W'(M);
  assign bern_data = bern_valid ? bern_table[bern_count] : '0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pending       <= 1'b0;
      sigma_latched <= '0;
      n_latched     <= '0;
      entry_count   <= '0;
      bern_count    <= '0;
    end else if (accepted) begin
      pending       <= 1'b1;
      sigma_latched <= sigma_input;
      n_latched     <= n_input;
      entry_count   <= '0;
      bern_count    <= '0;
    end else begin
      if (out_valid) pending <= 1'b0;
      if (entry_valid && entry_ready) entry_count <= entry_count + 1'b1;
      if (bern_valid && bern_ready) bern_count <= bern_count + 1'b1;
    end
  end

  euler_maclaurin_top #(
      .LIMBS(1), .EXPW(EXPW), .PHW(96), .FG(88), .CONSTW(96),
      .TERMS(22), .CTERMS(11),
      .EXP_ROM("rtl/common/fn/tables/expln_w64_exp.mem"),
      .CEXP_ROM("rtl/common/fn/tables/cexp_w64.mem")
  ) dut (
      .clk, .rst_n, .start_valid, .start_ready, .ps_only(1'b0),
      .sigma(sigma_mpf), .t_mpf, .t_fx({16'b0, t_input, 16'b0}),
      .n_in(24'(n_input)), .m_in(12'(M)),
      .inv_sm1_re(inv_re), .inv_sm1_im(inv_im), .inv_np2,
      .entry_valid, .entry_ready, .entry_lnn_fx(lnn_fx), .entry_lnn2pi(lnn2pi),
      .bern_valid, .bern_ready, .bern_data,
      .out_valid, .z_re, .z_im, .ovf, .unf
  );

  zeta_mpf_magnitude #(.WIDTH(WIDTH), .EXPW(EXPW), .EPS_EXP(EPS_EXP)) magnitude (
      .z_re, .z_im, .below_eps
  );

  assign sigma_delta_raw = (sigma_latched >= SIGMA_HALF) ?
                           sigma_latched - SIGMA_HALF : SIGMA_HALF - sigma_latched;

  // SVA samples the previous transaction's tag even if a new start coincides
  // with out_valid. The nonblocking updates then save the next request's tag.
  ap_result_has_request: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> pending);
  ap_small_implies_near_half: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid && below_eps |-> {1'b0, sigma_delta_raw} < SIGMA_EPS_RAW);
  // Report sticky arithmetic flags separately from the magnitude predicate.
  ap_flags_clear: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> !ovf && !unf);
  // zeta_mpf_magnitude is exact only for normalized mantissas.
  ap_result_normalized: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> normalized(z_re) && normalized(z_im));
  // A reached trace measures latency in this Jasper reset and sampling setup.
  cp_result: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid);
  cp_small_result: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && below_eps);
endmodule
