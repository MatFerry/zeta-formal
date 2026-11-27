// Controller properties for euler_maclaurin_top with the three datapath
// units (npow_s_kernel, mpf_mul, mpf_add) black-boxed.
//
// The unit outputs are free. The only thing assumed about a unit is its
// handshake contract: a completion pulse arrives only while an operand is in
// flight. The same contract is asserted on the real units in ../units.
//
// Bound into euler_maclaurin_top by em_ctrl_top.sv. The state encoding below
// is a copy of the RTL enum; h_enum_in_sync fails if the RTL enum changes.
module em_ctrl_checker #(
    // Optional upper bounds on N and M. 0 leaves them unbounded.
    parameter int unsigned N_BOUND = 0,
    parameter int unsigned M_BOUND = 0
) (
    input logic         clk,
    input logic         rst_n,
    input logic [323:0] enum_codes,
    input logic [5:0]   state,
    input logic [5:0]   ret_cm,
    input logic [5:0]   ret_ad,
    input logic         start_valid,
    input logic         start_ready,
    input logic         ps_only,
    input logic [23:0]  n_in,
    input logic [11:0]  m_in,
    input logic         entry_valid,
    input logic         entry_ready,
    input logic         bern_valid,
    input logic         bern_ready,
    input logic         np_go,
    input logic         np_done,
    input logic         mul_go,
    input logic         mul_done,
    input logic         add_go,
    input logic         add_done,
    input logic         ps_q,
    input logic [23:0]  n_q,
    input logic [23:0]  n_ctr,
    input logic [11:0]  m_q,
    input logic [11:0]  j_ctr,
    input logic         out_valid
);
  // Copy of euler_maclaurin_top.state_e. Keep the order identical.
  typedef enum logic [5:0] {
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
  } state_e;

  localparam logic [323:0] LOCAL_CODES = {
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
  };

  // ---- state classification -------------------------------------------------
  logic np_wait, mul_wait, add_wait, in_cm, in_ad;
  assign np_wait  = state inside {PS_W, P_W, T_W};
  assign mul_wait = state inside {INT_M1W, INT_M2W, TB_M1W, TB_M2W, TB_S1W, TB_S2W,
                                  CM_W1, CM_W2, CM_W3, CM_W4};
  assign add_wait = state inside {T_S1W, TB_C1W, TB_C2W, CM_WA1, CM_WA2, AD_WR, AD_WI};
  assign in_cm    = state inside {CM_P1, CM_W1, CM_P2, CM_W2, CM_P3, CM_W3, CM_P4, CM_W4,
                                  CM_A1, CM_WA1, CM_A2, CM_WA2};
  assign in_ad    = state inside {AD_R, AD_WR, AD_I, AD_WI};

  // ---- request and stream bookkeeping ---------------------------------------
  logic accepted, entry_beat, bern_beat;
  logic pending, ps_l, first_cycle;
  logic [23:0] n_l;
  logic [11:0] m_l;
  logic [24:0] entry_cnt;
  logic [12:0] bern_cnt;
  logic np_busy, mul_busy, add_busy;

  assign accepted   = start_valid && start_ready;
  assign entry_beat = entry_valid && entry_ready;
  assign bern_beat  = bern_valid && bern_ready;

  always_ff @(posedge clk) begin
    first_cycle <= !rst_n;
    if (!rst_n) begin
      pending   <= 1'b0;
      ps_l      <= 1'b0;
      n_l       <= '0;
      m_l       <= '0;
      entry_cnt <= '0;
      bern_cnt  <= '0;
      np_busy   <= 1'b0;
      mul_busy  <= 1'b0;
      add_busy  <= 1'b0;
    end else begin
      if (accepted) begin
        pending   <= 1'b1;
        ps_l      <= ps_only;
        n_l       <= n_in;
        m_l       <= m_in;
        entry_cnt <= '0;
        bern_cnt  <= '0;
      end else begin
        if (out_valid) pending <= 1'b0;
        if (entry_beat) entry_cnt <= entry_cnt + 1'b1;
        if (bern_beat) bern_cnt <= bern_cnt + 1'b1;
      end
      // A unit holds an operand from the cycle after its launch strobe until
      // the cycle of its completion pulse.
      if (np_go) np_busy <= 1'b1;
      else if (np_done) np_busy <= 1'b0;
      if (mul_go) mul_busy <= 1'b1;
      else if (mul_done) mul_busy <= 1'b0;
      if (add_go) add_busy <= 1'b1;
      else if (add_done) add_busy <= 1'b0;
    end
  end

  // ---- environment ----------------------------------------------------------
  // The host always sends N >= 1, and M >= 1 unless the request is power-sum
  // only (rs_setup.py sends M = 0 with ps_only, and M is then unused). N = 0
  // would run the power-sum counter through its whole 24-bit range, and M = 0
  // on the full path the tail counter through its 12-bit range.
  a_n_legal: assume property (@(posedge clk) disable iff (!rst_n)
      accepted |-> n_in >= 24'd1 && (N_BOUND == 0 || n_in <= 24'(N_BOUND)));
  a_m_legal: assume property (@(posedge clk) disable iff (!rst_n)
      accepted |-> (ps_only || m_in >= 12'd1) && (M_BOUND == 0 || m_in <= 12'(M_BOUND)));

  // Unit contract, assumed here and asserted on the real units.
  a_np_done_in_flight: assume property (@(posedge clk) disable iff (!rst_n)
      np_done |-> np_busy);
  a_mul_done_in_flight: assume property (@(posedge clk) disable iff (!rst_n)
      mul_done |-> mul_busy);
  a_add_done_in_flight: assume property (@(posedge clk) disable iff (!rst_n)
      add_done |-> add_busy);

  // Observe the reset values when the units can first sample these strobes.
  ap_reset_launch_clear: assert property (@(posedge clk) disable iff (!rst_n)
      first_cycle |-> !np_go && !mul_go && !add_go);

  // ---- 1. launch discipline ---------------------------------------------------
  // A unit is launched or busy only while the controller waits for it.
  ap_np_launch_in_wait: assert property (@(posedge clk) disable iff (!rst_n)
      np_go || np_busy |-> np_wait);
  ap_mul_launch_in_wait: assert property (@(posedge clk) disable iff (!rst_n)
      mul_go || mul_busy |-> mul_wait);
  ap_add_launch_in_wait: assert property (@(posedge clk) disable iff (!rst_n)
      add_go || add_busy |-> add_wait);

  // "Single operand in flight", the claim in the RTL comment about np_ready.
  ap_np_single_flight: assert property (@(posedge clk) disable iff (!rst_n)
      np_go |-> !np_busy);
  ap_mul_single_flight: assert property (@(posedge clk) disable iff (!rst_n)
      mul_go |-> !mul_busy);
  ap_add_single_flight: assert property (@(posedge clk) disable iff (!rst_n)
      add_go |-> !add_busy);

  // A waiting controller always has the operation it waits for in flight.
  ap_np_wait_has_flight: assert property (@(posedge clk) disable iff (!rst_n)
      np_wait |-> np_go || np_busy);
  ap_mul_wait_has_flight: assert property (@(posedge clk) disable iff (!rst_n)
      mul_wait |-> mul_go || mul_busy);
  ap_add_wait_has_flight: assert property (@(posedge clk) disable iff (!rst_n)
      add_wait |-> add_go || add_busy);

  // ---- 2. one result per request ---------------------------------------------
  ap_result_has_request: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> pending && state == IDLE);
  ap_busy_until_result: assert property (@(posedge clk) disable iff (!rst_n)
      pending && start_ready |-> out_valid);
  ap_active_has_request: assert property (@(posedge clk) disable iff (!rst_n)
      state != IDLE |-> pending);

  // ---- 3. stream beats consumed per request ----------------------------------
  ap_entry_beats: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> entry_cnt == (ps_l ? {1'b0, n_l} : {1'b0, n_l} + 25'd2));
  ap_bern_beats: assert property (@(posedge clk) disable iff (!rst_n)
      out_valid |-> bern_cnt == (ps_l ? 13'd0 : {1'b0, m_l}));

  // ---- helper invariants ------------------------------------------------------
  // These make properties 2 and 3 inductive for unbounded N and M. Each one
  // is an assertion in its own right.
  logic [24:0] nq, nc;
  logic [12:0] mq, jc;
  assign nq = {1'b0, n_q};
  assign nc = {1'b0, n_ctr};
  assign mq = {1'b0, m_q};
  assign jc = {1'b0, j_ctr};

  h_enum_in_sync: assert property (@(posedge clk) enum_codes == LOCAL_CODES);
  h_state_legal: assert property (@(posedge clk) disable iff (!rst_n)
      state <= DONE && state != T_CM && state != TB_ACC);
  h_config_latched: assert property (@(posedge clk) disable iff (!rst_n)
      pending |-> n_q == n_l && m_q == m_l && ps_q == ps_l);
  // The tail loop relies on M >= 1; without this the set is not inductive.
  h_tail_count_legal: assert property (@(posedge clk) disable iff (!rst_n)
      pending && !ps_l |-> m_l >= 12'd1);
  h_ret_ad_legal: assert property (@(posedge clk) disable iff (!rst_n)
      in_ad |-> ret_ad inside {PS_REQ, P_REQ, DONE, HALF, T_S1, TB_NEXT});
  h_ret_cm_legal: assert property (@(posedge clk) disable iff (!rst_n)
      in_cm |-> ret_cm inside {INT_ACC, T_U0, TB_U1, TB_U2});
  h_ps_only_path: assert property (@(posedge clk) disable iff (!rst_n)
      in_ad && ret_ad == DONE |-> ps_q);
  h_full_path: assert property (@(posedge clk) disable iff (!rst_n)
      (state inside {[P_REQ:TB_S2W]}) || in_cm ||
      (in_ad && ret_ad inside {P_REQ, HALF, T_S1, TB_NEXT}) |-> !ps_q);

  // Entry beats against the power-sum counter and the phase.
  logic e_ps_req, e_n0, e_n1, e_n2;
  assign e_ps_req = state == PS_REQ || (in_ad && ret_ad == PS_REQ);
  assign e_n0 = state == P_REQ || (in_ad && ret_ad inside {P_REQ, DONE}) ||
                (state == DONE && ps_q);
  assign e_n1 = (state inside {P_W, INT_M1, INT_M1W, INT_M2, INT_M2W, INT_CM, INT_ACC,
                               HALF, T_S1, T_S1W, T_REQ}) ||
                (in_cm && ret_cm == INT_ACC) || (in_ad && ret_ad inside {HALF, T_S1});
  assign e_n2 = (state inside {T_W, T_U0, [TB_REQ:TB_S2W]}) ||
                (in_cm && ret_cm inside {T_U0, TB_U1, TB_U2}) ||
                (in_ad && ret_ad == TB_NEXT) || (state == DONE && !ps_q);

  h_entry_ps_req: assert property (@(posedge clk) disable iff (!rst_n)
      e_ps_req |-> entry_cnt + 25'd1 == nc && n_ctr <= n_q);
  h_entry_ps_wait: assert property (@(posedge clk) disable iff (!rst_n)
      state == PS_W |-> entry_cnt == nc && n_ctr <= n_q);
  h_entry_n0: assert property (@(posedge clk) disable iff (!rst_n)
      e_n0 |-> entry_cnt == nq);
  h_entry_n1: assert property (@(posedge clk) disable iff (!rst_n)
      e_n1 |-> entry_cnt == nq + 25'd1);
  h_entry_n2: assert property (@(posedge clk) disable iff (!rst_n)
      e_n2 |-> entry_cnt == nq + 25'd2);

  // Bernoulli beats against the tail counter and the phase.
  logic b_pre, b_body_a, b_body_b;
  assign b_pre = (state inside {[PS_REQ:T_U0]}) ||
                 (in_cm && ret_cm inside {INT_ACC, T_U0}) ||
                 (in_ad && ret_ad inside {PS_REQ, P_REQ, DONE, HALF, T_S1}) ||
                 (state == DONE && ps_q);
  assign b_body_a = (state inside {TB_M1, TB_M1W, TB_M2, TB_M2W, TB_NEXT}) ||
                    (in_ad && ret_ad == TB_NEXT);
  assign b_body_b = (state inside {TB_C1, TB_C1W, TB_C2, TB_C2W, TB_UCM1, TB_U1,
                                   TB_UCM2, TB_U2, TB_S1, TB_S1W, TB_S2, TB_S2W}) ||
                    (in_cm && ret_cm inside {TB_U1, TB_U2});

  h_bern_pre: assert property (@(posedge clk) disable iff (!rst_n)
      b_pre |-> bern_cnt == 13'd0);
  h_bern_req: assert property (@(posedge clk) disable iff (!rst_n)
      state == TB_REQ |-> bern_cnt + 13'd1 == jc && j_ctr <= m_q);
  h_bern_body_a: assert property (@(posedge clk) disable iff (!rst_n)
      b_body_a |-> bern_cnt == jc && j_ctr <= m_q);
  h_bern_body_b: assert property (@(posedge clk) disable iff (!rst_n)
      b_body_b |-> bern_cnt == jc && j_ctr < m_q);
  h_bern_done: assert property (@(posedge clk) disable iff (!rst_n)
      state == DONE && !ps_q |-> bern_cnt == mq);

  // ---- covers -----------------------------------------------------------------
  cp_result_full: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && !ps_l);
  cp_result_ps_only: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && ps_l);
  cp_result_two_tail_terms: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && !ps_l && n_l >= 24'd2 && m_l >= 12'd2);
  cp_result_ps_only_m0: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && ps_l && m_l == 12'd0);
  cp_back_to_back: cover property (@(posedge clk) disable iff (!rst_n)
      out_valid && accepted);
endmodule
