module zeta_mpf_magnitude #(
    parameter int WIDTH = 64,
    parameter int EXPW = 20,
    parameter int EPS_EXP = -16,
    localparam int MPW = WIDTH + EXPW + 3
) (
    input  logic [MPW-1:0] z_re,
    input  logic [MPW-1:0] z_im,
    output logic           below_eps
);
  localparam int SQUARE_WIDTH = 2 * WIDTH;
  localparam int SHIFT_WIDTH = $clog2(SQUARE_WIDTH);
  localparam int ZERO_BIT = WIDTH + EXPW + 1;
  localparam int SPECIAL_BIT = WIDTH + EXPW + 2;
  localparam logic [SQUARE_WIDTH:0] EPS_SQUARED = {1'b1, {SQUARE_WIDTH{1'b0}}};

  int exp_re, exp_im;
  logic [SQUARE_WIDTH-1:0] square_re, square_im;
  logic [SQUARE_WIDTH:0] square_sum;

  // A finite nonzero MPF has |value| = mantissa * 2**(exponent - WIDTH).
  // Express its square in units of 2**(2 * (EPS_EXP - WIDTH)).
  function automatic logic [SQUARE_WIDTH-1:0] aligned_square(
      input logic [WIDTH-1:0] mantissa,
      input int exponent,
      input logic is_zero
  );
    longint distance;
    logic [SQUARE_WIDTH-1:0] square;
    distance = longint'(EPS_EXP) - longint'(exponent);
    square = mantissa * mantissa;
    if (is_zero || distance < 0 || distance >= longint'(WIDTH)) begin
      return '0;
    end
    return square >> SHIFT_WIDTH'(2 * int'(distance));
  endfunction

  assign exp_re = int'($signed(z_re[WIDTH+:EXPW]));
  assign exp_im = int'($signed(z_im[WIDTH+:EXPW]));
  assign square_re = aligned_square(z_re[WIDTH-1:0], exp_re, z_re[ZERO_BIT]);
  assign square_im = aligned_square(z_im[WIDTH-1:0], exp_im, z_im[ZERO_BIT]);
  assign square_sum = {1'b0, square_re} + {1'b0, square_im};

  // An exponent above EPS_EXP already implies |component| >= EPS. If both
  // exponents are below EPS_EXP, each component is less than EPS/2 in
  // magnitude. Otherwise at least one square aligns exactly, so the sum
  // discards less than one unit and the strict integer comparison is exact.
  assign below_eps = !z_re[SPECIAL_BIT] && !z_im[SPECIAL_BIT] &&
                     (z_re[ZERO_BIT] || exp_re <= EPS_EXP) &&
                     (z_im[ZERO_BIT] || exp_im <= EPS_EXP) &&
                     (square_sum < EPS_SQUARED);
endmodule
