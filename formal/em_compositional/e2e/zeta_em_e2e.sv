// End-to-end Z64 harness for euler_maclaurin_top with a selectable input box.
//
// Derived from formal/euler_maclaurin/zeta_em_formal.sv (driver, host payload
// functions and the main property are unchanged). What is added:
//   - the accepted request is confined to [SIGMA_LO, SIGMA_HI] x [T_LO, T_HI];
//     a bound pair that is equal makes that input a constant, so one point
//     folds to a fully concrete run and a narrow box is a small symbolic one;
//   - the ln(n) ROM can be a slice holding only the rows the box reaches
//     (ZETA_ENTRY_ROWS, written by gen_jobs.py);
//   - ap_matches_golden compares the packed output to the bit-true Python
//     output at a fixed input;
//   - ap_flags_clear checks sticky flags, and ap_result_normalized checks
//     the mantissas of finite, nonzero results.
`ifndef ZETA_SIGMA_LO
  `define ZETA_SIGMA_LO 32'h0000_0001
`endif
`ifndef ZETA_SIGMA_HI
  `define ZETA_SIGMA_HI 32'h0000_ffff
`endif
`ifndef ZETA_T_LO
  `define ZETA_T_LO 32'h0000_0000
`endif
`ifndef ZETA_T_HI
  `define ZETA_T_HI 32'h7fff_ffff
`endif
`ifndef ZETA_EPS_EXP
  `define ZETA_EPS_EXP (-16)
`endif
`ifndef ZETA_EPS_FROM_RE_ONEHALF_EXP
  `define ZETA_EPS_FROM_RE_ONEHALF_EXP EPS_EXP
`endif
`ifdef ZETA_EXPECT_RE
  `define ZETA_HAS_EXPECT 1
`else
  `define ZETA_HAS_EXPECT 0
  `define ZETA_EXPECT_RE '0
  `define ZETA_EXPECT_IM '0
`endif
// ZETA_ENTRY_ROWS=<rows> selects sim_build/zeta_compositional/rom/entries_<rows>.mem,
// the first <rows> lines of the released table. Unset, the full table is used.
`ifdef ZETA_ENTRY_ROWS
  `define ZETA_ENTRIES_FILE `"sim_build/zeta_compositional/rom/entries_`ZETA_ENTRY_ROWS.mem`"
`else
  `define ZETA_ENTRY_ROWS 9119
  `define ZETA_ENTRIES_FILE "sim_build/zeta_formal/entries_released.mem"
`endif

module zeta_em_e2e #(
    parameter logic [31:0] SIGMA_LO = `ZETA_SIGMA_LO,
    parameter logic [31:0] SIGMA_HI = `ZETA_SIGMA_HI,
    parameter logic [31:0] T_LO = `ZETA_T_LO,
    parameter logic [31:0] T_HI = `ZETA_T_HI,
    parameter int EPS_EXP = `ZETA_EPS_EXP,
    parameter int EPS_FROM_RE_ONEHALF_EXP = `ZETA_EPS_FROM_RE_ONEHALF_EXP,
    parameter bit HAS_EXPECT = `ZETA_HAS_EXPECT,
    parameter logic [86:0] EXPECT_RE = `ZETA_EXPECT_RE,
    parameter logic [86:0] EXPECT_IM = `ZETA_EXPECT_IM
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
  localparam int ENTRY_ROWS = `ZETA_ENTRY_ROWS;
  localparam int ENTRY_COUNT_W = $clog2(N_MAX + 3);
  localparam int BERN_COUNT_W = $clog2(M + 1);
  localparam logic [31:0] SIGMA_HALF = 32'h0000_8000;
  // The distance is an integer number of Q16.16 steps. For a tolerance
  // below one step only zero qualifies, and 2^32 steps covers every distance.
  localparam int SIGMA_EPS_RAW_EXP =
      (EPS_FROM_RE_ONEHALF_EXP <= -16) ? 0 :
      (EPS_FROM_RE_ONEHALF_EXP >= 16) ? 32 : EPS_FROM_RE_ONEHALF_EXP + 16;
  localparam logic [32:0] SIGMA_EPS_RAW = 33'd1 << SIGMA_EPS_RAW_EXP;
  localparam logic [MPW-1:0] MPF_ZERO = {3'b010, {(WIDTH + EXPW){1'b0}}};
  // Z64 host select_nm coefficient r/(2*pi) at 60 fractional bits. See
  // formal/euler_maclaurin/gen_tables.py, which checks it against the host.
  localparam logic [58:0] N_FACTOR = 59'h46f057ef67cc9a1;
  localparam bit SIGMA_FIXED = SIGMA_LO == SIGMA_HI;
  localparam bit T_FIXED = T_LO == T_HI;

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

  function automatic logic [ENTRY_COUNT_W-1:0] host_n(input logic [31:0] t);
    logic [90:0] scaled;
    scaled = 91'(t + 32'd6553600) * 91'(N_FACTOR) + {15'b0, {76{1'b1}}};
    return ENTRY_COUNT_W'(scaled[90:76]) + ENTRY_COUNT_W'(10);
  endfunction

  function automatic logic normalized(input logic [MPW-1:0] word);
    // Only finite, nonzero encodings use the mantissa.
    return word[MPW-1] || word[MPW-2] || word[WIDTH-1];
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

  assign start_valid = rst_n && start_ready;
  assign accepted = start_valid && start_ready;

  a_legal_q16: assume property (@(posedge clk) disable iff (!rst_n)
      accepted |-> (sigma_raw > 32'd0 && sigma_raw < 32'd65536 && !t_raw[31]));
  a_input_box: assume property (@(posedge clk) disable iff (!rst_n)
      accepted |-> (sigma_raw >= SIGMA_LO && sigma_raw <= SIGMA_HI &&
                    t_raw >= T_LO && t_raw <= T_HI));

  // A fixed input is a constant so that its whole cone folds at elaboration.
  if (SIGMA_FIXED) begin : sigma_const
    assign sigma_input = SIGMA_LO;
  end else begin : sigma_free
    assign sigma_input = sigma_raw;
  end
  if (T_FIXED) begin : t_const
    assign t_input = T_LO;
  end else begin : t_free
    assign t_input = t_raw;
  end
  assign n_input = host_n(t_input);

  logic [231:0] entries [0:ENTRY_ROWS-1];
  logic [MPW-1:0] inv_np2_table [0:N_MAX-N_MIN];
  logic [MPW-1:0] bern_table [0:M-1];
  initial begin
    $readmemh(`ZETA_ENTRIES_FILE, entries);
    $readmemh("sim_build/zeta_formal/inv_np2.mem", inv_np2_table);
    $readmemh("sim_build/zeta_formal/bern.mem", bern_table);
  end
  assign {lnn_fx, lnn2pi} = entries[entry_index];

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
  // The ln(n) ROM supplies rows 0..N, and inv_np2 is indexed by N - N_MIN.
  ap_rom_covers_request: assert property (@(posedge clk) disable iff (!rst_n)
      accepted |-> int'(n_input) >= N_MIN && int'(n_input) <= N_MAX &&
                    int'(n_input) < ENTRY_ROWS);
  // Check the sticky overflow and underflow indicators for the whole request.
  ap_flags_clear: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> !ovf && !unf);
  // The magnitude equivalence check in ../mag assumes normalized finite,
  // nonzero operands.
  ap_result_normalized: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> normalized(z_re) && normalized(z_im));

  if (HAS_EXPECT) begin : golden
    // Compare the packed output with host/zetafpga/golden/zeta_em.py.
    ap_matches_golden: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> z_re == EXPECT_RE && z_im == EXPECT_IM);
  end

  cp_result: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid);
  cp_small_result: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && below_eps);
endmodule
