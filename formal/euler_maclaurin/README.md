# Euler–Maclaurin JasperGold experiment

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

The directed simulations took 8,908 transaction cycles. In Jasper, check
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
testbench's `N+2` log beats and `M` Bernoulli beats. The generator checks the
RTL formula for `N(t)` at every transition of the upstream host selection.

The controller and power kernel explicitly reset their internal launch
strobes. Jasper leaves other unreset registers unconstrained and disables
automatic black-boxing for this full-RTL experiment.

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

## Earlier simulation results

Both directed transactions used `N=42`, `M=50`, and returned after 8,908
cycles in the independent Verilator/cocotb driver. Overflow and underflow
flags were clear. The RTL matched the upstream bit-true Python model.

| `sigma_raw` | Packed `z_re` | Packed `z_im` | `abs(Z_RTL)` | Implication at equal defaults |
| --- | --- | --- | ---: | --- |
| `0x00008000` | `0x0FFFECB12ECE85BA6398AC` | `0x1FFFEF8B1E6D66D0FCCD7C` | `4.198277156250244e-6` | Holds at this point |
| `0x00008001` | `0x0FFFF0D398A8A130E78CA8` | `0x1FFFEE968B264A73F3F151` | `1.281007184473255e-5` | Fails at this point |

Verilator also simulated the actual harness with assertions and coverage.
The half case hit the cover. At the equal default thresholds, the off-half
case fires `ap_small_implies_near_half` because its distance from `0.5` is
exactly one Q16.16 step (`2**-16`). With the released configuration, concrete
stimulus exercised a result and a new request on the same edge and replayed
the same counterexample. With only `ZETA_EPS_FROM_RE_ONEHALF_EXP=-15`, the
same off-half result hit the cover and passed the assertion. A separate simulation
checked 1,016 released-mode host payloads against Python. Slang and Verilator elaborated all three
configurations. The stock cocotb test passed at Z64, Z128, and Z192, with
the stock Z256 nightly skip.

These results predate the launch-strobe reset fix. The Jasper proofs and
released-input symbolic search remain unverified. The directed RTL trace
at `sigma_raw=0x00008001` belongs to the released input domain.
