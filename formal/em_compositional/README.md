# Euler–Maclaurin compositional checks

This suite checks the RTL controller, the datapath-unit handshakes, the MPF
magnitude comparator, and the original near-half assertion on selected
end-to-end inputs. Use [the full-domain experiment](../euler_maclaurin/README.md)
for the released-input check.

| Case | Tool | What it checks |
| --- | --- | --- |
| `ctrl` | JasperGold | Controller safety and stream counts under the datapath completion contract |
| `units` | JasperGold | Datapath completion contract under single-flight stimulus |
| `mag` | JasperGold | Equivalence of the Z64 magnitude checker and a bit-vector reference |
| `lean` | Lean 4 | Integer arithmetic lemmas behind the magnitude comparison |
| `e2e` | JasperGold | Packed RTL results, reachable small magnitudes, and the near-half assertion on a point or input window |

## Running in one JasperGold session

From the repository root on the Jasper launch host, generate the ROMs and
manifest. This example starts with points and windows near the first zero.
Omit `--zeros 1` to include the default sweep through zero 50.

```sh
python3 formal/euler_maclaurin/gen_tables.py
python3 formal/em_compositional/gen_jobs.py --zeros 1
session_dir=$(mktemp -d "$PWD/sim_build/zeta_compositional/session.XXXXXXXX")
ZETA_RESULTS_DIR="$session_dir/results" \
    jg -batch formal/em_compositional/run_suite.tcl -proj "$session_dir/jgproject"
python3 formal/em_compositional/summarize.py "$session_dir/results"
```

Jasper loads the cases in order and uses the site's ProofGrid configuration
for each proof. If that configuration lives in a Tcl file, export
`ZETA_PROOFGRID_TCL` with its absolute path before launching. The Tcl file
is sourced again after loading each design. The results directory holds
snapshots of the case manifest and expected outcomes, along with per-case
TSV and native Jasper CSV reports.

The summary exits 0 for completed checks with expected outcomes, 1 for a
contradiction or missing property in a reported case, and 2 for incomplete
results. Bounded, undetermined, and analysis-region outcomes stay open.
Read the native Jasper CSV or log if the TSV query is unavailable in your
Jasper version. Add `-v` to print all rows.

Use `--zeros 0 --window-zeros 0` to run the controller, unit, and magnitude
checks. `--offsets` changes the number of sigma steps on either side of
one half, and `--window` changes the width of each symbolic sigma window.
`--eps-exp` sets the end-to-end output threshold exponent, and
`--sigma-eps-exp` sets the end-to-end sigma tolerance exponent. Both
default to `-16`. The fixed magnitude cases use `2**-16`.

A single case remains available through `run.tcl`.

```sh
ZETA_KIND=ctrl jg -batch formal/em_compositional/run.tcl -proj /tmp/zeta_ctrl
```

| Variable | Purpose |
| --- | --- |
| `ZETA_KIND` | `ctrl`, `unit_mul`, `unit_add`, `unit_npow`, `mag`, or `e2e` for a single case |
| `ZETA_JOB` | Result file stem for a single case, defaults to the kind |
| `ZETA_RESULTS_DIR` | Report directory. A suite uses a fresh directory. |
| `ZETA_PROOFGRID_TCL` | Site ProofGrid Tcl, sourced before each proof |
| `ZETA_PROVE_TIME_LIMIT` | Optional time limit passed to `prove` |
| `ZETA_MAX_TRACE_LENGTH`, `ZETA_ENGINE_MODE` | Optional Jasper trace and engine settings |
| `ZETA_ELABORATE_OPTIONS` | Extra `elaborate` options |
| `ZETA_CTRL_N_BOUND`, `ZETA_CTRL_M_BOUND` | Optional count bounds for `ctrl` |
| `ZETA_MAG_ASSUME_NORMALIZED` | Selects the normalized or unrestricted magnitude check |
| `ZETA_SIGMA_LO/HI`, `ZETA_T_LO/HI` | Inclusive `e2e` box bounds, as sized 32-bit hex literals |
| `ZETA_EXPECT_RE/IM`, `ZETA_ENTRY_ROWS`, `ZETA_RESET_ZERO` | Optional packed golden result, ROM slice size, and zero-initialized unreset registers for `e2e` |

## Reading the results

**Controller and units.** The controller proof explicitly black-boxes the
three datapath units. Each black box may assert completion only while an
operand is in flight. The unit cases check that same rule on real RTL under
single-flight input. The controller assertions cover launch discipline,
request/result association, and entry and Bernoulli counts conditional on
completion. The unit contract and stream inputs allow stalls, so these are
safety checks. The cover properties give example completing traces.

The Euler–Maclaurin controller and power kernel now reset their internal
launch strobes. Each has an `ap_reset_launch_clear` regression assertion.
Before the fix, the prior randomized-start Verilator runs showed that a
stale strobe could start an operation on reset release and corrupt the
first result.

**Magnitude and Lean.** The Z64 reference compares the packed MPF
components. One Jasper case assumes finite nonzero mantissas are normalized
and checks equality. The unrestricted case checks that the production
checker remains conservative. The Lean file proves integer lemmas for
all mantissa widths. The mapping from the packed SV operands to those
lemmas is a source-level argument.

**End to end.** The selected points are adjacent Q16.16 grid points near
zeros 1 through 50 where the precomputed scan found
`abs(zeta(0.5 + i*t)) < 2**-16`. The suite computes expected point results
with the upstream bit-true model during generation. A window leaves sigma
symbolic at a fixed height and reports the property outcomes without a
single golden word. ROM slices are regenerated from the full table.

Read `cp_result` and `ap_matches_golden` together for a fixed point. The cover
confirms a transaction reaches `out_valid`, and the assertion compares the
packed result. `cp_small_result` checks antecedent reachability.
`ap_result_normalized` checks the comparator's input format, and
`ap_flags_clear` records sticky overflow and underflow separately. At the
default tolerances, the previously simulated point `sigma_raw=0x00008001`
and `t_raw=0x000E227D` violated the strict near-half assertion. That result
concerns the Z64 evaluator on its input grid.

## Verification history

The pre-audit author recorded Slang elaboration, a Lean 4.29.1 check, and
directed Verilator runs on the earlier RTL. The launch-reset edits and
single-session suite still need Jasper execution. A directed simulation
replay is available on a host with Verilator and generated ROMs.

```sh
formal/em_compositional/sim/run_point.sh 8001 e227d
```

A third argument selects a randomized initialization seed for registers the
RTL leaves unreset. The replay forwards both epsilon exponent settings.
