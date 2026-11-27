// Top for the controller proof. Every DUT input is a free top-level input,
// so the environment is fully symbolic. Elaborate with npow_s_kernel,
// mpf_mul and mpf_add black-boxed.
`ifndef ZETA_CTRL_N_BOUND
  `define ZETA_CTRL_N_BOUND 0
`endif
`ifndef ZETA_CTRL_M_BOUND
  `define ZETA_CTRL_M_BOUND 0
`endif

module em_ctrl_top (
    input logic         clk,
    input logic         rst_n,
    input logic         start_valid,
    input logic         ps_only,
    input logic [86:0]  sigma,
    input logic [86:0]  t_mpf,
    input logic [63:0]  t_fx,
    input logic [23:0]  n_in,
    input logic [11:0]  m_in,
    input logic [86:0]  inv_sm1_re,
    input logic [86:0]  inv_sm1_im,
    input logic [86:0]  inv_np2,
    input logic         entry_valid,
    input logic [95:0]  entry_lnn_fx,
    input logic [135:0] entry_lnn2pi,
    input logic         bern_valid,
    input logic [86:0]  bern_data
);
  logic start_ready, entry_ready, bern_ready, out_valid, ovf, unf;
  logic [86:0] z_re, z_im;

  euler_maclaurin_top #(
      .LIMBS(1), .EXPW(20), .PHW(96), .FG(88), .CONSTW(96),
      .TERMS(22), .CTERMS(11),
      .EXP_ROM("rtl/common/fn/tables/expln_w64_exp.mem"),
      .CEXP_ROM("rtl/common/fn/tables/cexp_w64.mem")
  ) dut (
      .clk, .rst_n, .start_valid, .start_ready, .ps_only,
      .sigma, .t_mpf, .t_fx, .n_in, .m_in,
      .inv_sm1_re, .inv_sm1_im, .inv_np2,
      .entry_valid, .entry_ready, .entry_lnn_fx, .entry_lnn2pi,
      .bern_valid, .bern_ready, .bern_data,
      .out_valid, .z_re, .z_im, .ovf, .unf
  );
endmodule

bind euler_maclaurin_top em_ctrl_checker #(
    .N_BOUND(`ZETA_CTRL_N_BOUND),
    .M_BOUND(`ZETA_CTRL_M_BOUND)
) u_ctrl_checker (
    .clk(clk),
    .rst_n(rst_n),
    .enum_codes({
        IDLE,
        PS_REQ, PS_W,
        P_REQ, P_W,
        INT_M1, INT_M1W, INT_M2, INT_M2W, INT_CM, INT_ACC,
        HALF,
        T_S1, T_S1W,
        T_REQ, T_W, T_CM, T_U0,
        TB_REQ, TB_M1, TB_M1W, TB_M2, TB_M2W, TB_ACC,
        TB_NEXT, TB_C1, TB_C1W, TB_C2, TB_C2W, TB_UCM1, TB_U1, TB_UCM2, TB_U2,
        TB_S1, TB_S1W, TB_S2, TB_S2W,
        CM_P1, CM_W1, CM_P2, CM_W2, CM_P3, CM_W3, CM_P4, CM_W4,
        CM_A1, CM_WA1, CM_A2, CM_WA2,
        AD_R, AD_WR, AD_I, AD_WI,
        DONE
    }),
    .state(state),
    .ret_cm(ret_cm),
    .ret_ad(ret_ad),
    .start_valid(start_valid),
    .start_ready(start_ready),
    .ps_only(ps_only),
    .n_in(n_in),
    .m_in(m_in),
    .entry_valid(entry_valid),
    .entry_ready(entry_ready),
    .bern_valid(bern_valid),
    .bern_ready(bern_ready),
    .np_go(np_go),
    .np_done(np_done),
    .mul_go(mul_go),
    .mul_done(mul_done),
    .add_go(add_go),
    .add_done(add_done),
    .ps_q(ps_q),
    .n_q(n_q),
    .n_ctr(n_ctr),
    .m_q(m_q),
    .j_ctr(j_ctr),
    .out_valid(out_valid)
);
