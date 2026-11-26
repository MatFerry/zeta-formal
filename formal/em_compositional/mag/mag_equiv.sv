// Exact reference for "|z| < 2**EPS_EXP" on two packed MPF words, and the
// equivalence check against formal/euler_maclaurin/mpf_magnitude.sv.
//
// A finite MPF word is value = mantissa * 2**(exponent - WIDTH). In units of
// 2**(2*(EPS_EXP - WIDTH)) its square is mantissa**2 * 4**d with
// d = exponent - EPS_EXP, and |z| < eps reads term_re + term_im < 2**(2*WIDTH).
//
// The reference makes no normalization assumption:
//   d > 0   the component alone reaches eps iff mantissa >= 2**(WIDTH - d);
//           otherwise mantissa**2 * 4**d is an integer below 2**(2*WIDTH).
//   d <= 0  the term is mantissa**2 / 4**(-d), kept as its integer floor.
// A term with d < 0 is below 2**(2*WIDTH)/4. Two such terms sum below the
// bound. Adding one such term to an integer term and flooring gives the same
// strict comparison against an integer bound. Lean proves both facts for
// every width in ../lean/MagnitudeCompare.lean.
module zeta_mpf_magnitude_ref #(
    parameter int WIDTH = 64,
    parameter int EXPW = 20,
    parameter int EPS_EXP = -16,
    localparam int MPW = WIDTH + EXPW + 3
) (
    input  logic [MPW-1:0] z_re,
    input  logic [MPW-1:0] z_im,
    output logic           below_eps,
    output logic           has_fraction
);
  localparam int SQW = 2 * WIDTH;
  localparam int ZERO_BIT = WIDTH + EXPW + 1;
  localparam int SPECIAL_BIT = WIDTH + EXPW + 2;

  typedef struct packed {
    logic           reaches_eps;
    logic           has_fraction;
    logic [SQW-1:0] floor;
  } term_t;

  function automatic term_t term(input logic [MPW-1:0] word);
    logic [WIDTH-1:0] mantissa;
    logic [SQW-1:0] square;
    logic [2*SQW-1:0] wide;
    int exponent, shift;
    longint d;
    term_t result;

    mantissa = word[WIDTH-1:0];
    square = SQW'(mantissa) * SQW'(mantissa);
    exponent = int'($signed(word[WIDTH+:EXPW]));
    d = longint'(exponent) - longint'(EPS_EXP);
    result = '0;
    if (word[SPECIAL_BIT] || word[ZERO_BIT] || mantissa == '0) begin
      result = '0;
    end else if (d > longint'(WIDTH)) begin
      result.reaches_eps = 1'b1;
    end else if (d > 0) begin
      result.reaches_eps = (mantissa >> (WIDTH - int'(d))) != '0;
      wide = (2 * SQW)'(square) << (2 * int'(d));
      result.floor = result.reaches_eps ? '0 : wide[SQW-1:0];
    end else if (d > -longint'(WIDTH)) begin
      shift = -2 * int'(d);
      result.floor = square >> shift;
      result.has_fraction = (result.floor << shift) != square;
    end else begin
      // The entire square falls below the least significant stored bit.
      result.has_fraction = 1'b1;
    end
    return result;
  endfunction

  term_t term_re, term_im;
  logic [SQW:0] sum;

  assign term_re = term(z_re);
  assign term_im = term(z_im);
  assign sum = {1'b0, term_re.floor} + {1'b0, term_im.floor};
  assign has_fraction = term_re.has_fraction || term_im.has_fraction;
  assign below_eps = !z_re[SPECIAL_BIT] && !z_im[SPECIAL_BIT] &&
                     !term_re.reaches_eps && !term_im.reaches_eps && !sum[SQW];
endmodule

`ifndef ZETA_EPS_EXP
  `define ZETA_EPS_EXP (-16)
`endif
`ifndef ZETA_MAG_ASSUME_NORMALIZED
  `define ZETA_MAG_ASSUME_NORMALIZED 1
`endif

module mag_equiv #(
    parameter int WIDTH = 64,
    parameter int EXPW = 20,
    parameter int EPS_EXP = `ZETA_EPS_EXP,
    // 1: finite nonzero inputs have the mantissa MSB set, as the RTL adder
    //    produces them. 0: any mantissa, where the two checkers differ.
    parameter bit ASSUME_NORMALIZED = `ZETA_MAG_ASSUME_NORMALIZED,
    localparam int MPW = WIDTH + EXPW + 3
) (
    input logic           clk,
    input logic [MPW-1:0] z_re,
    input logic [MPW-1:0] z_im
);
  localparam int ZERO_BIT = WIDTH + EXPW + 1;
  localparam int SPECIAL_BIT = WIDTH + EXPW + 2;

  logic below_checker, below_ref, ref_has_fraction;
  int exp_re, exp_im;

  zeta_mpf_magnitude #(.WIDTH(WIDTH), .EXPW(EXPW), .EPS_EXP(EPS_EXP)) checker_i (
      .z_re, .z_im, .below_eps(below_checker)
  );
  zeta_mpf_magnitude_ref #(.WIDTH(WIDTH), .EXPW(EXPW), .EPS_EXP(EPS_EXP)) ref_i (
      .z_re, .z_im, .below_eps(below_ref), .has_fraction(ref_has_fraction)
  );

  function automatic logic normalized(input logic [MPW-1:0] word);
    return word[SPECIAL_BIT] || word[ZERO_BIT] || word[WIDTH-1];
  endfunction

  if (ASSUME_NORMALIZED) begin : normalized_inputs
    a_re_normalized: assume property (@(posedge clk) normalized(z_re));
    a_im_normalized: assume property (@(posedge clk) normalized(z_im));
  end

  assign exp_re = int'($signed(z_re[WIDTH+:EXPW]));
  assign exp_im = int'($signed(z_im[WIDTH+:EXPW]));

  ap_checker_matches_reference: assert property (@(posedge clk)
      below_checker == below_ref);
  // The checker never reports "below" for a value the reference rejects,
  // normalized or not. Only the other direction needs normalization.
  ap_checker_never_optimistic: assert property (@(posedge clk)
      below_checker |-> below_ref);

  cp_below: cover property (@(posedge clk) below_checker && below_ref);
  cp_above_same_exponent: cover property (@(posedge clk)
      !below_ref && exp_re == EPS_EXP && exp_im == EPS_EXP &&
      !z_re[SPECIAL_BIT] && !z_im[SPECIAL_BIT] && !z_re[ZERO_BIT] && !z_im[ZERO_BIT]);
  // Exercise a nonzero discarded fraction next to an exactly aligned square.
  cp_below_with_truncation: cover property (@(posedge clk)
      below_ref && !z_re[ZERO_BIT] && !z_im[ZERO_BIT] &&
      (exp_re == EPS_EXP || exp_im == EPS_EXP) && ref_has_fraction);
endmodule
