#!/usr/bin/env bash
# Lint everything: RTL (verilator, verible if present) + Python (ruff, mypy).
set -euo pipefail
cd "$(dirname "$0")/.."

verilator --version
# Elaborate each independent top so parameter specializations are linted separately.
for top in skid_buffer limb_mul_ks sincos_turns zeta_engine; do
    echo "== verilator --lint-only $top =="
    verilator --lint-only -Wall --top-module "$top" -f rtl/filelists/generic-sim.f
done

if [[ ${1:-} == --rtl-only ]]; then
    exit 0
fi

if command -v verible-verilog-lint >/dev/null 2>&1; then
    echo "== verible-verilog-lint =="
    find rtl -name '*.sv' -print0 | xargs -0 verible-verilog-lint
else
    echo "== verible not installed — skipping (optional) =="
fi

echo "== ruff check =="
uv run ruff check .
echo "== ruff format --check =="
uv run ruff format --check .
echo "== mypy =="
uv run mypy

echo "lint OK"
