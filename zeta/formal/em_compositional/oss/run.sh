#!/bin/sh
# Open-source check of the controller proof and the unit contracts.
#   sh <this directory>/run.sh [ctrl:kind ctrl:cover units:mul_pdr ...]
# Run from the repository root with OSS CAD Suite on PATH.
set -eu
flow=$(dirname "$0")
here=formal/em_compositional
out=sim_build/zeta_oss
if [ ! -f rtl/common/zeta/euler_maclaurin_top.sv ]; then
    echo "run.sh: start from the repository root" >&2
    exit 2
fi
"${PYTHON:-python3}" "$flow/sva2bool.py" "$out/src" \
    "$here/ctrl/em_ctrl_checker.sv" "$here/ctrl/em_ctrl_top.sv" "$here/units/em_unit_contract.sv"
cp "$flow/oss_reset.sv" "$out/src/"
if [ $# -eq 0 ]; then
    set -- ctrl:kind units:mul_pdr units:add_pdr units:npow_pdr units:npow_kind \
        units:mul_cover units:add_cover units:npow_cover
fi
status=0
for item in "$@"; do
    file=${item%%:*}
    task=${item#*:}
    work="$out/${file}_$task"
    if sby -f -d "$work" "$flow/$file.sby" "$task" > "$work.log" 2>&1; then
        echo "PASS $item"
    else
        echo "FAIL $item (see $work.log)"
        status=1
    fi
    grep -E "summary: +(failed assertion|reached cover statement|unreached cover statement)|Assert failed" \
        "$work.log" | sed -e 's/^SBY [0-9:]* \[[^]]*\] //' -e 's/^/    /' | sort -u || true
done
exit $status
