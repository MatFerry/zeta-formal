# Open-source check of the controller proof and the unit contracts
Runs `ctrl/em_ctrl_checker.sv` and `units/em_unit_contract.sv` through SymbiYosys with the
yosys-slang frontend. JasperGold stays the reference; this catches mistakes before a farm run.

    sh <this directory>/run.sh                # from the repository root, OSS CAD Suite on PATH
    sh <this directory>/run.sh ctrl:cover     # one task; ctrl:cover takes about nine minutes

- `sva2bool.py` copies the three sources to `sim_build/zeta_oss/src` with `a |-> b` rewritten to
  `!(a) || (b)` and `cover a ##[1:$] b` to a one-register form (yosys-slang rejects both operators).
- `oss_reset.sv` models `reset -expression {!rst_n}`: one reset cycle, then none; registers
  without a reset value start arbitrary.
- `ctrl.sby`: `kind` proves all controller assertions by k-induction with the three units as free
  cut points; `cover` reaches the four covers (the deepest at step 169).
- `units.sby`: `mul_pdr`, `add_pdr`, `npow_pdr`, `npow_kind` prove the contracts on the real RTL;
  `*_cover` reach the covers. Reported step numbers are one more than the cycle count.
