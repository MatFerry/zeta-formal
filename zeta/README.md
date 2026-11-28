# fpga-zeta

Hardware-optimized, parametric SystemVerilog libraries to compute Riemann-zeta-related
functions on FPGAs, driven by a host CPU over PCIe.

- **Phase 1**: full pipeline computing ζ(s) for any complex s (Euler–Maclaurin engine),
  developed simulation-first (Verilator + cocotb) with bit-true Python golden models
  verified against mpmath/Arb.
- **Phase 2**: Riemann–Siegel Z(t) engine, FFT multi-evaluation, PCIe bring-up, and
  massively parallel multi-FPGA operation (zero hunting, real-time visualization).

## Layout

| Path | Purpose |
|---|---|
| `rtl/common/` | Portable SystemVerilog (no vendor primitives) |
| `rtl/arch/` | Architecture-specific tiles (`generic-sim`, `xilinx-usplus`, …) |
| `rtl/filelists/` | Build filelists selecting the tile implementations |
| `host/zetafpga/` | Typed Python package: golden models, oracles, kernel builder, drivers, apps |
| `tb/` | cocotb testbenches mirroring `rtl/common/` |
| `tests/` | Python unit tests of the golden models and the host stack |
| `formal/` | Formal checks of the Euler–Maclaurin engine (fork addition, see below) |
| `tools/` | Coefficient/ROM generators (Sollya or mpmath-Remez) |
| `scripts/` | `lint.sh`, `formal_lint.sh`, and the table regeneration entry point |
| `DESIGN.md` | Numeric formats, error budgets, decision log — living document |

## Quick start

```sh
uv sync            # install Python deps (needs uv + Python >= 3.11)
make lint          # Verilator lint + ruff + mypy
make test          # cocotb tests under Verilator + Python unit tests
```

Requires [Verilator](https://verilator.org) >= 5.0 on PATH. The Verilator builds use GNU Make,
which cannot build in a checkout whose path contains a space.

The golden models read the committed ROM tables from `rtl/common/fn/tables/` relative to
the checkout, so use the editable install that `uv sync` creates. A built wheel does not
contain the tables.

## Formal checks (fork addition)

`formal/` is not part of upstream fpga-zeta. It holds two harnesses for
`euler_maclaurin_top` at Z64:

- [`formal/euler_maclaurin/`](formal/euler_maclaurin/README.md): the full-domain JasperGold
  experiment on the near-half assertion.
- [`formal/em_compositional/`](formal/em_compositional/README.md): controller, unit-contract,
  magnitude-comparator and end-to-end cases for JasperGold, including fixed and symbolic
  opposite-direction boxes and a one-request off-line certificate benchmark. It also has a
  Lean 4 proof of the magnitude comparison.

Each README records what has and has not been run; JasperGold results are not claimed here.
The parts that need no JasperGold licence run from the repository root:

```sh
make formal-lint                                          # elaborate every formal top (Verilator + slang)
python3 formal/euler_maclaurin/gen_tables.py              # harness ROMs under sim_build/ (needs mpmath)
python3 formal/em_compositional/gen_jobs.py --zeros 1     # case manifest and expected outcomes
python3 formal/em_compositional/sim/replay_jobs.py        # Verilator replay of the point cases
(cd formal/em_compositional/lean && lake build)           # Lean 4.36.0 through elan
```

The fork's only RTL change resets six launch strobes in `euler_maclaurin_top.sv` and
`npow_s_kernel.sv` and moves the declaration of `t_fx_q` above its first use.

## Status

Upstream history reaches M21 (on-chip Z(t), multi-lane Riemann–Siegel, the
Odlyzko–Schönhage grid sum). The decision log in `DESIGN.md` records the milestones;
there is no `ARCHITECTURE.md` in this tree.
