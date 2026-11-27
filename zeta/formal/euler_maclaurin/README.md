# Euler–Maclaurin JasperGold experiment

Status: nothing in this directory has been run in JasperGold by anyone. The
scripts were written without access to the tool. The harness has been
elaborated with Slang and Verilator and simulated with Verilator. See
[Simulation results](#simulation-results) for what was run and by whom.

## JasperGold batch run

From the repository root on the Jasper launch host, prepare the ROMs once
with Python 3 and `mpmath`, then launch the experiment.

```sh
formal/euler_maclaurin/run_jasper.sh prepare
formal/euler_maclaurin/run_jasper.sh run
```

`run` executes `half`, `neighbor`, and `released` in order in one JasperGold
session.
The directed cases use `t_raw=0x000E227D` with `sigma_raw=0x00008000` and
`0x00008001`, respectively. The released case leaves both inputs symbolic
over the full legal range. Jasper ProofGrid manages engine dispatch using
your site's settings.

Expected outcomes at the default thresholds, taken from simulation and the
Python model and not from Jasper:

| Case | `ap_matches_golden` | `ap_small_implies_near_half` | `cp_result`, `cp_small_result` |
| --- | --- | --- | --- |
| `half` | holds | holds | both reachable |
| `neighbor` | holds | fails, the result is below `2**-16` one sigma step from one half | both reachable |
| `released` | not present | fails, the `neighbor` input is inside the released domain | both reachable |

A `released` run that reports no counterexample has not reached the known
one, which needs 8,908 cycles after the request is accepted.

In simulation both directed points return 8,908 clock cycles after the
request is accepted. The latency was `8688 + 55 * (N - 38)` cycles at every
simulated input, from 8,688 cycles at `t = 0` to 508,088 cycles at the
largest legal `t`. In Jasper, check
`cp_result` for a completed result and its trace length under the selected
reset setup. Read a bounded result with its explored depth. A bound that
ends before `out_valid` exercises no result. Released-case convergence is
unverified.

If your ProofGrid settings live in a Tcl file, set `ZETA_PROOFGRID_TCL`.
Each case loads that file after design setup and before `prove`, so use
your existing ProofGrid configuration commands in the file.

```sh
ZETA_PROOFGRID_TCL=/path/to/site-proofgrid.tcl formal/euler_maclaurin/run_jasper.sh run
```

Use `half`, `neighbor`, or `released` in place of `run` to select a single
case. From a Jasper Tcl console opened at the repository root, you can
also run `source formal/euler_maclaurin/run.tcl`. For example, enter
`set ::env(ZETA_CASE) 2` before sourcing to select the released case.

| Variable | Purpose |
| --- | --- |
| `ZETA_EPS_EXP` | Output threshold exponent, default `-16` |
| `ZETA_EPS_FROM_RE_ONEHALF_EXP` | Sigma tolerance exponent, defaults to `ZETA_EPS_EXP` |
| `ZETA_PROVE_TIME_LIMIT` | Optional per-case limit, for example `2h`. Empty or `none` uses the Jasper or site setting. |
| `ZETA_JG` | JasperGold executable, default `jg` |
| `ZETA_PYTHON` | Python for `prepare`, default `python3`. It needs `mpmath`. Python 3.9.6 and 3.11 were tried, and `pyproject.toml` asks for 3.11. |
| `ZETA_RUN_ROOT` | Output directory, default `sim_build/zeta_jasper/` in the checkout |

The launcher keeps one Jasper project, `jasper.log`, `config.txt`, and
`exit_code` per session. It saves `properties-half.csv`,
`properties-neighbor.csv`, and `properties-released.csv` as the cases
finish. The process exit code reports tool execution status. Check
`ap_small_implies_near_half` and `cp_small_result` in the property CSVs
for the assertion and cover outcomes. Check `cp_result` and
`ap_matches_golden` together for directed results.

## Transaction and properties

The Z64 harness interprets the raw inputs as signed Q16.16. It constrains
accepted requests to `0 < sigma < 1` and `t >= 0`, generates the host's Z64
payload for each request, and records the raw sigma on the start handshake.
The driver sends the full Euler–Maclaurin transaction with the upstream
testbench's `N+2` log beats and `M` Bernoulli beats. It requests again in the
cycle a result arrives and never stalls a stream, so one host timing is
explored. `gen_tables.py` checks a Python copy of the harness formula for
`N(t)` against the upstream host selection at every transition. The
SystemVerilog expression is a separate hand copy of the same coefficient and
shift, compared with the host by simulation only (see below).

The controller and power kernel explicitly reset their internal launch
strobes. `run.tcl` uses `reset -expression {!rst_n}` and passes
`-disable_auto_bbox`. The intent is that Jasper leaves the other unreset
registers unconstrained and black-boxes nothing. Confirm both in the log of
the first run.

`ap_small_implies_near_half` requires `abs(sigma - 0.5) < eps_from_re_onehalf`
when `out_valid && below_eps`. It uses the recorded sigma and compares the
absolute difference in Q16.16 steps. `cp_small_result` covers the antecedent.
The magnitude checker decodes
the signed MPF exponent and mantissa, uses squared magnitude for a strict
comparison, treats either signed zero as zero, and excludes MPF specials.

In the directed cases `ap_matches_golden` checks the packed result against
the upstream bit-true Python model. `ap_flags_clear` checks sticky overflow
and underflow separately from the magnitude assertion.
`ap_result_normalized` checks the normalized finite mantissas on which
the magnitude checker relies.

## Simulation results

None of this is a JasperGold result. Two sets of runs exist, and the scripts
of neither are in the repository.

The author of the harness recorded these before the launch-strobe reset fix:
the table below, a Verilator run of the harness with assertions and covers,
a check of 1,016 released-mode host payloads against Python, Slang and
Verilator elaboration, and the stock cocotb test at Z64, Z128, and Z192.

An automated review (Claude, on the owner's Mac, 2026-11-27, Verilator
5.051, Slang, cocotb 2.1 dev, Python 3.11 with mpmath 1.4.1) repeated them
on the current RTL, after the reset fix, with its own testbenches:

- Both directed transactions used `N=42`, `M=50`, took 44 log beats and 50
  Bernoulli beats, and returned 8,908 cycles after the request was accepted,
  in this harness and through the upstream cocotb driver coroutines.
  Overflow and underflow flags were clear. The RTL matched the upstream
  bit-true Python model.
- With assertions enabled the half case hit both covers and fired nothing.
  At the equal default thresholds the off-half case fired only
  `ap_small_implies_near_half`, because its distance from `0.5` is exactly
  one Q16.16 step (`2**-16`). With only `ZETA_EPS_FROM_RE_ONEHALF_EXP=-15`
  the same result hit the cover and passed the assertion.
- The released configuration was driven back to back with `sigma_raw`
  `0x8001`, `0x8000`, `0x7FFF`, `0x8000` at `t_raw=0x000E227D`. Every result
  and the next request shared a clock edge, and the assertion fired for
  `0x8001` and `0x7FFF` only, so each result was judged against its own
  request.
- The harness payload (sigma, t, `N`, `1/(s-1)`, `1/(N+1)^2`) equalled
  `build_program` on 26,054 input pairs, including the corners of the legal
  range and both sides of all 9,080 changes of `N`.
- Slang and `verilator --lint-only -Wall` elaborated all three cases.
- The stock cocotb test passed at Z64, Z128, and Z192, with the stock Z256
  nightly skip.

| `sigma_raw` | Packed `z_re` | Packed `z_im` | `abs(Z_RTL)` | Implication at equal defaults |
| --- | --- | --- | ---: | --- |
| `0x00008000` | `0x0FFFECB12ECE85BA6398AC` | `0x1FFFEF8B1E6D66D0FCCD7C` | `4.198277156250244e-6` | Holds at this point |
| `0x00008001` | `0x0FFFF0D398A8A130E78CA8` | `0x1FFFEE968B264A73F3F151` | `1.281007184473255e-5` | Fails at this point |

The Jasper proofs and the released-input symbolic search remain unverified.
The input `sigma_raw=0x00008001`, `t_raw=0x000E227D` lies in the released
domain, so the released assertion is false. This is not an RTL defect:
mpmath gives `abs(zeta) = 1.2810e-5` at that input, below
`2**-16 = 1.5259e-5`. With equal default exponents the assertion demands
sigma exactly one half, and the zeta function itself is that small one grid
step from its first zero.
