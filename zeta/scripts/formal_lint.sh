#!/usr/bin/env bash
# Elaborate every formal top with the macro combinations the Jasper scripts use.
#
#   scripts/formal_lint.sh [verilator|slang|all]
#
# The file lists mirror formal/euler_maclaurin/run.tcl and
# formal/em_compositional/run.tcl. No ROM is needed: $readmemh is not
# evaluated at elaboration. Runs from any directory; needs bash >= 3.2.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

tool=${1:-all}
case "$tool" in verilator|slang|all) ;; *) echo "usage: $0 [verilator|slang|all]" >&2; exit 2 ;; esac

rtl=(
    rtl/common/prim/lzc.sv rtl/common/prim/skid_buffer.sv rtl/arch/generic-sim/mul_tile.sv
    rtl/common/mp/limb_mul.sv rtl/common/mp/limb_shift.sv rtl/common/mp/limb_addsub.sv
    rtl/common/mp/mpf_mul.sv rtl/common/mp/mpf_add.sv rtl/common/fx/fx_mul_mod1.sv
    rtl/common/fn/exp_mpf.sv rtl/common/fn/cexp_turns.sv rtl/common/zeta/npow_s_kernel.sv
    rtl/common/zeta/euler_maclaurin_top.sv
)
mag=formal/euler_maclaurin/mpf_magnitude.sv
comp=formal/em_compositional
point=("-DZETA_SIGMA_LO=32'h00008000" "-DZETA_SIGMA_HI=32'h00008000"
       "-DZETA_T_LO=32'h000e227d" "-DZETA_T_HI=32'h000e227d"
       -DZETA_EPS_EXP=-16 -DZETA_EPS_FROM_RE_ONEHALF_EXP=-16)

failed=0
check() {  # check <label> <top> <defines and sources...>
    local label=$1 top=$2
    shift 2
    if [[ $tool != slang ]]; then
        if verilator --lint-only --assert --timing -Wno-fatal -Wno-MULTITOP \
                --top-module "$top" "$@" > /dev/null 2> "$log"; then
            printf 'ok    verilator %s\n' "$label"
        else
            printf 'FAIL  verilator %s\n' "$label"; grep -E '^%Error' "$log" || true; failed=1
        fi
    fi
    if [[ $tool != verilator ]]; then
        if slang --top "$top" "$@" > "$log" 2>&1; then
            printf 'ok    slang     %s\n' "$label"
        else
            printf 'FAIL  slang     %s\n' "$label"; grep -E 'error:' "$log" || true; failed=1
        fi
    fi
}
log=$(mktemp)
trap 'rm -f "$log"' EXIT

for case_id in 0 1 2; do
    check "euler_maclaurin case $case_id" zeta_em_formal -DZETA_CASE=$case_id \
        "${rtl[@]}" $mag formal/euler_maclaurin/zeta_em_formal.sv
done
check "ctrl" em_ctrl_top "${rtl[@]}" $comp/ctrl/em_ctrl_checker.sv $comp/ctrl/em_ctrl_top.sv
check "ctrl bounded" em_ctrl_top -DZETA_CTRL_N_BOUND=6 -DZETA_CTRL_M_BOUND=4 \
    "${rtl[@]}" $comp/ctrl/em_ctrl_checker.sv $comp/ctrl/em_ctrl_top.sv
for unit in mul add npow; do
    check "unit_$unit" em_unit_${unit}_top "${rtl[@]}" $comp/units/em_unit_contract.sv
done
for normalized in 1 0; do
    check "mag normalized=$normalized" mag_equiv -DZETA_EPS_EXP=-16 \
        -DZETA_MAG_ASSUME_NORMALIZED=$normalized $mag $comp/mag/mag_equiv.sv
done
check "e2e released box" zeta_em_e2e "${rtl[@]}" $mag $comp/e2e/zeta_em_e2e.sv
check "e2e point" zeta_em_e2e "${point[@]}" -DZETA_ENTRY_ROWS=43 \
    "-DZETA_EXPECT_RE=87'h0fffecb12ece85ba6398ac" "-DZETA_EXPECT_IM=87'h1fffef8b1e6d66d0fccd7c" \
    "${rtl[@]}" $mag $comp/e2e/zeta_em_e2e.sv
check "e2e window" zeta_em_e2e "-DZETA_SIGMA_LO=32'h00007ffc" "-DZETA_SIGMA_HI=32'h00008004" \
    "-DZETA_T_LO=32'h000e227d" "-DZETA_T_HI=32'h000e227d" -DZETA_ENTRY_ROWS=43 \
    "${rtl[@]}" $mag $comp/e2e/zeta_em_e2e.sv
check "sim tb_point" tb_point "${point[@]}" "${rtl[@]}" $mag $comp/e2e/zeta_em_e2e.sv \
    $comp/ctrl/em_ctrl_checker.sv $comp/ctrl/em_ctrl_top.sv $comp/sim/tb_point.sv

exit $failed
