#!/usr/bin/env bash
# Simulate two back-to-back transactions at one Q16.16 point with Verilator.
#
#   formal/em_compositional/sim/run_point.sh <sigma_raw hex> <t_raw hex> [seed]
#   formal/em_compositional/sim/run_point.sh 8001 e227d
#
# Assertion failures are printed while the replay continues to its second
# result. A seed enables randomized initial state before reset.
# Needs the ROMs from formal/euler_maclaurin/gen_tables.py.
# ZETA_SIM_BUILD sets the build directory.
# ZETA_EPS_EXP and ZETA_EPS_FROM_RE_ONEHALF_EXP match the Jasper settings.
set -euo pipefail
[[ $# == 2 || $# == 3 ]] || { sed -n '2,11p' "$0" >&2; exit 2; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
cd -- "$repo"
sigma=${1#0x}
sigma=${sigma#0X}
t=${2#0x}
t=${t#0X}
if [[ ! $sigma =~ ^[0-9a-fA-F]{1,8}$ || ! $t =~ ^[0-9a-fA-F]{1,8}$ ]]; then
    printf 'sigma_raw and t_raw must be 32-bit hexadecimal values\n' >&2
    exit 2
fi
if (( 16#$sigma == 0 || 16#$sigma >= 0x10000 || 16#$t >= 0x80000000 )); then
    printf 'Expected 0 < sigma_raw < 0x10000 and 0 <= t_raw < 0x80000000\n' >&2
    exit 2
fi
printf -v sigma '%08x' "$((16#$sigma))"
printf -v t '%08x' "$((16#$t))"

eps_exp=${ZETA_EPS_EXP:--16}
sigma_eps_exp=${ZETA_EPS_FROM_RE_ONEHALF_EXP:-$eps_exp}
for exponent in "$eps_exp" "$sigma_eps_exp"; do
    if [[ ! $exponent =~ ^-?(0|[1-9][0-9]{0,9})$ ]] ||
       (( exponent < -2147483648 || exponent > 2147483647 )); then
        printf 'EPS exponents must be signed 32-bit decimal integers\n' >&2
        exit 2
    fi
done

for rom in entries_released inv_np2 bern; do
    if [[ ! -r sim_build/zeta_formal/$rom.mem ]]; then
        printf 'Missing %s. Run python3 formal/euler_maclaurin/gen_tables.py first.\n' "sim_build/zeta_formal/$rom.mem" >&2
        exit 1
    fi
done
here=formal/em_compositional
# GNU Make cannot build under a path with spaces, so fall back to TMPDIR.
build_root=${ZETA_SIM_BUILD:-$repo/sim_build/zeta_compositional}
if [[ $build_root == *[[:space:]]* ]]; then build_root=${TMPDIR:-/tmp}/zeta_compositional_sim; fi
if [[ $build_root == *[[:space:]]* ]]; then build_root=/tmp/zeta_compositional_sim; fi
mkdir -p -- "$build_root"
build=$build_root/sim_${sigma}_${t}_${eps_exp}_${sigma_eps_exp}

verilator --binary --assert --timing -Wno-fatal -Wno-lint -Wno-style -Wno-MULTITOP -O2 -j 4 \
    "-DZETA_SIGMA_LO=32'h$sigma" "-DZETA_SIGMA_HI=32'h$sigma" \
    "-DZETA_T_LO=32'h$t" "-DZETA_T_HI=32'h$t" \
    "-DZETA_EPS_EXP=$eps_exp" "-DZETA_EPS_FROM_RE_ONEHALF_EXP=$sigma_eps_exp" \
    --top tb_point --Mdir "$build" -o sim \
    rtl/common/prim/lzc.sv rtl/common/prim/skid_buffer.sv rtl/arch/generic-sim/mul_tile.sv \
    rtl/common/mp/limb_mul.sv rtl/common/mp/limb_shift.sv rtl/common/mp/limb_addsub.sv \
    rtl/common/mp/mpf_mul.sv rtl/common/mp/mpf_add.sv rtl/common/fx/fx_mul_mod1.sv \
    rtl/common/fn/exp_mpf.sv rtl/common/fn/cexp_turns.sv rtl/common/zeta/npow_s_kernel.sv \
    rtl/common/zeta/euler_maclaurin_top.sv formal/euler_maclaurin/mpf_magnitude.sv \
    $here/e2e/zeta_em_e2e.sv $here/ctrl/em_ctrl_checker.sv $here/ctrl/em_ctrl_top.sv \
    $here/sim/tb_point.sv > "$build.log" 2>&1 || { tail -20 "$build.log" >&2; exit 1; }

args=(+verilator+error+limit+1000)
if [[ $# == 3 ]]; then args+=(+verilator+rand+reset+2 "+verilator+seed+$3"); fi
printf 'POINT sigma_raw=0x%s t_raw=0x%s EPS=2^%s sigma_tolerance=2^%s\n' "$sigma" "$t" "$eps_exp" "$sigma_eps_exp"
"$build/sim" "${args[@]}" 2>&1 | grep -v -e '^- ' -e '^-Info'
