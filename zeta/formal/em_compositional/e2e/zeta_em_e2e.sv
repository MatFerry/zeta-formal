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
//     the mantissas of finite, nonzero results;
//   - ZETA_SIGN_BOX=1 evaluates six points in a fixed box: four corners (SIGMA_LO,
//     T_LO), (SIGMA_HI, T_LO), (SIGMA_LO, T_HI), (SIGMA_HI, T_HI), and the
//     two points (SIGMA_MID, T_LO), (SIGMA_MID, T_HI) on the middle column,
//     SIGMA_MID = (SIGMA_LO + SIGMA_HI) / 2. It checks the exact packed-word
//     dot product Re(a * conj(b)) < 0 across each row and the middle column.
//     ZETA_BOX_EXPECT_RE/IM optionally supply all six golden results.
//   - ZETA_SYMBOLIC_BOX=1 samples the raw ports once after reset as the center
//     sigma and lower t. It evaluates the same six positions at center +/-
//     one sigma step and at t and t+1, then checks the chosen center if all
//     three dot products are negative. The test concerns the RTL endpoints.
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
`ifndef ZETA_SIGN_BOX
  `define ZETA_SIGN_BOX 0
`endif
`ifndef ZETA_SYMBOLIC_BOX
  `define ZETA_SYMBOLIC_BOX 0
`endif
// Six packed words per component, request r in bits [87*r +: 87].
`ifdef ZETA_BOX_EXPECT_RE
  `define ZETA_HAS_BOX_EXPECT 1
`else
  `define ZETA_HAS_BOX_EXPECT 0
  `define ZETA_BOX_EXPECT_RE '0
  `define ZETA_BOX_EXPECT_IM '0
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
    parameter logic [86:0] EXPECT_IM = `ZETA_EXPECT_IM,
    parameter bit SIGN_BOX = `ZETA_SIGN_BOX,
    parameter bit HAS_BOX_EXPECT = `ZETA_HAS_BOX_EXPECT,
    parameter logic [6*87-1:0] BOX_EXPECT_RE = `ZETA_BOX_EXPECT_RE,
    parameter logic [6*87-1:0] BOX_EXPECT_IM = `ZETA_BOX_EXPECT_IM,
    parameter bit SYMBOLIC_BOX = `ZETA_SYMBOLIC_BOX
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
  localparam int SIGN_BIT = WIDTH + EXPW;
  localparam int ZERO_BIT = WIDTH + EXPW + 1;
  localparam int SPECIAL_BIT = WIDTH + EXPW + 2;
  localparam logic [31:0] SIGMA_MID = (SIGMA_LO + SIGMA_HI) / 2;
  localparam int BOX_REQUESTS = 6;
  localparam bit BOX_MODE = SIGN_BOX || SYMBOLIC_BOX;

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
  logic pending, result_matches_pending;
  logic below_eps;
  logic [31:0] sigma_latched, sigma_delta_raw;
  // Sign box bookkeeping: requests issued, results received, the six results.
  logic [2:0] box_requests, box_results;
  logic [MPW-1:0] box_re [0:BOX_REQUESTS-1];
  logic [MPW-1:0] box_im [0:BOX_REQUESTS-1];
  logic box_configured, box_result_matches, box_done;
  logic opposite_t_lo, opposite_t_hi, opposite_mid;

  assign start_valid = rst_n && start_ready && box_configured &&
                       (!BOX_MODE || box_requests < 3'(BOX_REQUESTS)) &&
                       (!SYMBOLIC_BOX || !pending || (out_valid && box_result_matches));
  assign accepted = start_valid && start_ready;

  a_legal_q16: assume property (@(posedge clk) disable iff (!rst_n)
      !SYMBOLIC_BOX && accepted |->
          (sigma_raw > 32'd0 && sigma_raw < 32'd65536 && !t_raw[31]));
  a_input_box: assume property (@(posedge clk) disable iff (!rst_n)
      !SYMBOLIC_BOX && accepted |->
          (sigma_raw >= SIGMA_LO && sigma_raw <= SIGMA_HI && t_raw >= T_LO && t_raw <= T_HI));

  // A fixed input is a constant so that its whole cone folds at elaboration.
  if (BOX_MODE) begin : box_inputs
    logic [31:0] sigma_lo, sigma_hi, sigma_mid, t_lo, t_hi;

    if (SYMBOLIC_BOX) begin : symbolic_box
      // Per-request allowance above the Z64 controller's 55 cycles per
      // power-sum term and its fixed setup and tail latency. The extra
      // cycles include selecting the box and storing the final result.
      localparam int BOX_CYCLE_LIMIT = BOX_REQUESTS * (7000 + 60 * N_MAX);
      localparam int BOX_AGE_W = $clog2(BOX_CYCLE_LIMIT + 1);
      localparam logic [31:0] FIRST_ZERO_T_LO = 32'h000e_227d;
      logic [31:0] center_sigma, lower_t;
      logic [BOX_AGE_W-1:0] box_age;
      logic opposite_box;

      if (SIGN_BOX || HAS_EXPECT || HAS_BOX_EXPECT || ENTRY_ROWS != N_MAX + 1) begin : box_misuse
        $error("ZETA_SYMBOLIC_BOX requires the full entry table and no fixed box or golden words");
      end

      // Selection happens on the first active clock, ahead of the first DUT
      // request. Both raw inputs are free on every later clock.
      a_symbolic_box_inputs: assume property (@(posedge clk) disable iff (!rst_n)
          !box_configured |->
              sigma_raw >= 32'd2 && sigma_raw <= 32'h0000_fffe && t_raw <= 32'h7fff_fffe);

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          box_configured <= 1'b0;
          center_sigma <= '0;
          lower_t <= '0;
          box_age <= '0;
        end else begin
          if (!box_configured) begin
            box_configured <= 1'b1;
            center_sigma <= sigma_raw;
            lower_t <= t_raw;
          end
          if (!box_done && box_age < BOX_AGE_W'(BOX_CYCLE_LIMIT)) begin
            box_age <= box_age + 1'b1;
          end
        end
      end

      assign sigma_lo = center_sigma - 32'd1;
      assign sigma_hi = center_sigma + 32'd1;
      assign sigma_mid = center_sigma;
      assign t_lo = lower_t;
      assign t_hi = lower_t + 32'd1;
      assign opposite_box = opposite_t_lo && opposite_t_hi && opposite_mid;

      ap_symbolic_box_request_order: assert property (@(posedge clk) disable iff (!rst_n)
          accepted |-> box_requests < 3'(BOX_REQUESTS) &&
              ((box_requests == box_results && !pending && !out_valid) ||
               (out_valid && box_result_matches)));
      ap_box_six_results: assert property (@(posedge clk) disable iff (!rst_n)
          out_valid |-> box_result_matches);
      ap_symbolic_box_completes: assert property (@(posedge clk) disable iff (!rst_n)
          !box_done |-> box_age < BOX_AGE_W'(BOX_CYCLE_LIMIT));
      ap_opposite_box_centered: assert property (@(posedge clk) disable iff (!rst_n)
          box_done && opposite_box |-> center_sigma == SIGMA_HALF);
      cp_box_done: cover property (@(posedge clk) disable iff (!rst_n)
          box_done);
      cp_first_zero_box: cover property (@(posedge clk) disable iff (!rst_n)
          box_done && opposite_box && center_sigma == SIGMA_HALF && lower_t == FIRST_ZERO_T_LO);
    end else begin : fixed_box
      if (SIGMA_FIXED || T_FIXED || HAS_EXPECT || (SIGMA_LO + SIGMA_HI) % 2 != 0) begin : box_misuse
        $error("ZETA_SIGN_BOX needs SIGMA_LO < SIGMA_HI with an even sum, T_LO < T_HI, %s",
               "and no ZETA_EXPECT_RE/IM");
      end
      assign box_configured = 1'b1;
      assign sigma_lo = SIGMA_LO;
      assign sigma_hi = SIGMA_HI;
      assign sigma_mid = SIGMA_MID;
      assign t_lo = T_LO;
      assign t_hi = T_HI;
    end

    // Requests 0-3 are the corners, 4 and 5 the middle column.
    assign sigma_input = box_requests >= 3'd4 ? sigma_mid :
                         box_requests[0] ? sigma_hi : sigma_lo;
    assign t_input = (box_requests >= 3'd4 ? box_requests[0] : box_requests[1]) ? t_hi : t_lo;
  end else begin : point_or_window
    assign box_configured = 1'b1;
    assign sigma_input = SIGMA_FIXED ? SIGMA_LO : sigma_raw;
    assign t_input = T_FIXED ? T_LO : t_raw;
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
  // The driver requests again in the cycle a result arrives, so pending stays
  // set after the first request. The completed stream counts are what tie a
  // result to the request whose tag is sampled here.
  assign result_matches_pending = pending && entry_count == n_latched + ENTRY_COUNT_W'(2) &&
                                  bern_count == BERN_COUNT_W'(M);
  ap_result_has_request: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> result_matches_pending);
  if (!SYMBOLIC_BOX) begin : small_result
    ap_small_implies_near_half: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid && below_eps |-> {1'b0, sigma_delta_raw} < SIGMA_EPS_RAW);
    cp_small_result: cover property (@(posedge clk) disable iff (!rst_n)
        out_valid && below_eps);
  end
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

  // ---- sign box ------------------------------------------------------------
  function automatic logic word_is_zero(input logic [MPW-1:0] word);
    return word[ZERO_BIT] || word[WIDTH-1:0] == '0;
  endfunction

  function automatic int word_exponent(input logic [MPW-1:0] word);
    return int'($signed(word[WIDTH+:EXPW]));
  endfunction

  // Re(a * conj(b)) = a_re*b_re + a_im*b_im < 0, exactly, for finite words.
  // A word is (-1)^sign * mantissa * 2^(exponent - WIDTH); the two products
  // are compared on a common scale, so no normalization is assumed.
  function automatic logic points_opposite(
      input logic [MPW-1:0] a_re, a_im, b_re, b_im
  );
    logic zero_re, zero_im, neg_re, neg_im, re_larger;
    logic [2*WIDTH-1:0] mag_re, mag_im;
    logic [4*WIDTH-1:0] scaled_re, scaled_im;
    int shift;
    if (a_re[SPECIAL_BIT] || a_im[SPECIAL_BIT] || b_re[SPECIAL_BIT] || b_im[SPECIAL_BIT])
      return 1'b0;
    zero_re = word_is_zero(a_re) || word_is_zero(b_re);
    zero_im = word_is_zero(a_im) || word_is_zero(b_im);
    neg_re = a_re[SIGN_BIT] ^ b_re[SIGN_BIT];
    neg_im = a_im[SIGN_BIT] ^ b_im[SIGN_BIT];
    if (zero_re && zero_im) return 1'b0;
    if (zero_re) return neg_im;
    if (zero_im) return neg_re;
    if (neg_re == neg_im) return neg_re;
    // Opposite signs: the sum is negative when the negative product is larger.
    mag_re = (2*WIDTH)'(a_re[WIDTH-1:0]) * (2*WIDTH)'(b_re[WIDTH-1:0]);
    mag_im = (2*WIDTH)'(a_im[WIDTH-1:0]) * (2*WIDTH)'(b_im[WIDTH-1:0]);
    shift = word_exponent(a_re) + word_exponent(b_re) - word_exponent(a_im) - word_exponent(b_im);
    if (shift >= 2*WIDTH) begin
      re_larger = 1'b1;  // mag_re >= 1 and mag_im < 2^(2*WIDTH)
    end else if (shift <= -2*WIDTH) begin
      re_larger = 1'b0;
    end else begin
      scaled_re = (4*WIDTH)'(mag_re) << (shift > 0 ? shift : 0);
      scaled_im = (4*WIDTH)'(mag_im) << (shift < 0 ? -shift : 0);
      if (scaled_re == scaled_im) return 1'b0;  // the sum is exactly zero
      re_larger = scaled_re > scaled_im;
    end
    return neg_re ? re_larger : !re_larger;
  endfunction

  assign box_result_matches = box_results < 3'(BOX_REQUESTS) &&
      (!SYMBOLIC_BOX || (box_requests == box_results + 3'd1 && result_matches_pending));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      box_requests <= '0;
      box_results  <= '0;
      box_done     <= 1'b0;
    end else if (BOX_MODE) begin
      if (accepted) box_requests <= box_requests + 3'd1;
      if (out_valid && box_result_matches) begin
        box_re[box_results] <= z_re;
        box_im[box_results] <= z_im;
        box_results <= box_results + 3'd1;
        if (box_results == 3'(BOX_REQUESTS - 1)) box_done <= 1'b1;
      end
    end
  end

  assign opposite_t_lo = points_opposite(box_re[0], box_im[0], box_re[1], box_im[1]);
  assign opposite_t_hi = points_opposite(box_re[2], box_im[2], box_re[3], box_im[3]);
  assign opposite_mid  = points_opposite(box_re[4], box_im[4], box_re[5], box_im[5]);

  if (SIGN_BOX) begin : sign_box
    // Negative dot products between SIGMA_LO and SIGMA_HI on both rows.
    ap_opposite_across_sigma: assert property (@(posedge clk) disable iff (!rst_n)
        box_done |-> opposite_t_lo && opposite_t_hi);
    // A negative dot product between T_LO and T_HI on the middle column.
    ap_opposite_across_t: assert property (@(posedge clk) disable iff (!rst_n)
        box_done |-> opposite_mid);
    // The driver stops after the sixth request.
    ap_box_six_results: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> box_results < 3'(BOX_REQUESTS));
    if (HAS_BOX_EXPECT) begin : box_golden
      ap_box_matches_golden: assert property (@(posedge clk) disable iff (!rst_n)
          out_valid && box_results < 3'(BOX_REQUESTS) |->
              z_re == BOX_EXPECT_RE[MPW*box_results +: MPW] &&
              z_im == BOX_EXPECT_IM[MPW*box_results +: MPW]);
    end
    cp_box_done: cover property (@(posedge clk) disable iff (!rst_n)
        box_done);
  end

  cp_result: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid);
endmodule
