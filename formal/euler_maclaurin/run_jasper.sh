#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s {prepare|run|half|neighbor|released}\n' "${0##*/}" >&2
    exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_dir=$(cd -- "$script_dir/../.." && pwd -P)

case "${1:-}" in
    prepare)
        [[ $# == 1 ]] || usage
        exec "${ZETA_PYTHON:-python3}" "$script_dir/gen_tables.py"
        ;;
    run|half|neighbor|released)
        [[ $# == 1 ]] || usage
        job=$1
        case "$job" in
            run) unset ZETA_CASE ;;
            half) export ZETA_CASE=0 ;;
            neighbor) export ZETA_CASE=1 ;;
            released) export ZETA_CASE=2 ;;
        esac
        expected_reports=("$job")
        if [[ $job == run ]]; then expected_reports=(half neighbor released); fi
        ;;
    *) usage ;;
esac

if ! jg_bin=$(type -P "${ZETA_JG:-jg}"); then
    printf 'JasperGold executable not found. Set ZETA_JG or put jg on PATH.\n' >&2
    exit 1
fi
[[ $jg_bin == /* ]] || jg_bin=$PWD/$jg_bin
if [[ -n ${ZETA_PROOFGRID_TCL:-} && $ZETA_PROOFGRID_TCL != /* ]]; then
    export ZETA_PROOFGRID_TCL=$PWD/$ZETA_PROOFGRID_TCL
fi

run_root=${ZETA_RUN_ROOT:-"$repo_dir/sim_build/zeta_jasper"}
mkdir -p -- "$run_root"
run_root=$(cd -- "$run_root" && pwd -P)
job_dir=$(mktemp -d "$run_root/$job.XXXXXXXX")
export ZETA_REPORT_DIR=$job_dir
printf 'JasperGold session directory %s\n' "$job_dir"

{
    printf 'host=%s\n' "$(hostname)"
    printf 'repo=%s\n' "$repo_dir"
    printf 'cases=%s\n' "${expected_reports[*]}"
    printf 'proofgrid_tcl=%s\n' "${ZETA_PROOFGRID_TCL:-}"
    printf 'eps_exp=%s\n' "${ZETA_EPS_EXP:--16}"
    printf 'sigma_eps_exp=%s\n' "${ZETA_EPS_FROM_RE_ONEHALF_EXP:-${ZETA_EPS_EXP:--16}}"
    printf 'prove_time_limit=%s\n' "${ZETA_PROVE_TIME_LIMIT:-Jasper default}"
} > "$job_dir/config.txt"

cd -- "$job_dir"
status=0
"$jg_bin" -batch "$script_dir/run.tcl" -proj "$job_dir/jgproject" > jasper.log 2>&1 || status=$?
printf '%s\n' "$status" > exit_code
if (( status != 0 )); then
    printf 'JasperGold exited with status %s. See %s\n' "$status" "$job_dir/jasper.log" >&2
    exit "$status"
fi
for case_name in "${expected_reports[@]}"; do
    if [[ ! -s properties-$case_name.csv ]]; then
        printf 'Missing property report for %s. See %s\n' "$case_name" "$job_dir/jasper.log" >&2
        exit 1
    fi
done
