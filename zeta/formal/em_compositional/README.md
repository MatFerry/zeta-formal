# Euler–Maclaurin compositional checks

This suite checks the RTL controller, the datapath-unit handshakes, the MPF
magnitude comparator, and the original near-half assertion on selected
end-to-end inputs. Use [the full-domain experiment](../euler_maclaurin/README.md)
for the released-input check.

Status: no case of this suite has been run in JasperGold by anyone, and
`run.tcl`, `run_suite.tcl`, and `summarize.py` have never seen real Jasper
output. The table says what each case is designed to check. See
[Verification history](#verification-history) for what has been run.

| Case | Tool | What it checks |
| --- | --- | --- |
| `ctrl` | JasperGold | Controller safety and stream counts under the datapath completion contract |
| `units` | JasperGold | Datapath completion contract under single-flight stimulus |
| `mag` | JasperGold | Equivalence of the Z64 magnitude checker and a bit-vector reference |
| `lean` | Lean 4.36.0 | Exact magnitude comparison in a finite-width model of the decoded MPF datapath |
| `e2e` | JasperGold | Packed RTL results, reachable small magnitudes, and the near-half assertion on a point or input window |

`units` stands for the kinds `unit_mul`, `unit_add`, and `unit_npow`. The
manifest names its cases `ctrl_proof`, `ctrl_small`, `unit_mul`, `unit_add`,
`unit_npow`, `mag_equiv`, `mag_unnormalized`, `pt_z<zero>_t<t_raw>_m<steps>`
or `_p<steps>` for a point, and `win_z<zero>_t<t_raw>_w<steps>` for a window.
`lean` is a separate build. The Jasper suite and `summarize.py` do not
include it.

## Running in one JasperGold session

From the repository root on the Jasper launch host, generate the ROMs and
manifest. Python needs `mpmath`. Versions 3.9.6 and 3.11 were tried, and
`pyproject.toml` asks for 3.11. This example starts with points and windows
near the first zero.
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
contradiction, a missing property in a reported case, or a counterexample
on a property without an expectation, 2 for incomplete results or results
of a case that `expected.tsv` does not name, and 3 for unusable input.
Unreachable covers without an expectation, Jasper's precondition covers
included, are listed after the totals. Bounded, undetermined, and
analysis-region outcomes stay open.
Read the native Jasper CSV or log if the TSV query is unavailable in your
Jasper version. Add `-v` to print all rows.

Use `--zeros 0 --window-zeros 0` to run the controller, unit, and magnitude
checks. `--offsets` changes the number of sigma steps on either side of
one half, and `--window` changes the half-width in steps of each symbolic
sigma window.
`--eps-exp` sets the output threshold exponent of the end-to-end cases and
of the two magnitude cases, and `--sigma-eps-exp` sets the end-to-end sigma
tolerance exponent. Both default to `-16`.

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
| `ZETA_MAX_TRACE_LENGTH`, `ZETA_ENGINE_MODE` | Optional Jasper trace and engine settings. A simulated transaction takes `6598 + 55*N` cycles (8,908 at zero 1, 10,888 at zero 50), and a shorter trace limit cannot reach `out_valid`. |
| `ZETA_ELABORATE_OPTIONS` | Extra `elaborate` options |
| `ZETA_CTRL_N_BOUND`, `ZETA_CTRL_M_BOUND` | Optional count bounds for `ctrl` |
| `ZETA_MAG_ASSUME_NORMALIZED` | `1` (default) for the normalized magnitude check, `0` for the unrestricted one |
| `ZETA_SIGMA_LO/HI`, `ZETA_T_LO/HI` | Inclusive `e2e` box bounds, as sized 32-bit hex literals |
| `ZETA_EXPECT_RE/IM`, `ZETA_ENTRY_ROWS`, `ZETA_RESET_ZERO` | Optional packed golden result, ROM slice size, and zero-initialized unreset registers for `e2e` |
| `ZETA_EPS_EXP`, `ZETA_EPS_FROM_RE_ONEHALF_EXP` | Output threshold exponent for `mag` and `e2e`, default `-16`, and sigma tolerance exponent for `e2e`, defaults to `ZETA_EPS_EXP` |

In a suite run `jobs.tsv` supplies `ZETA_KIND`, `ZETA_JOB`, the `ctrl`
bounds, `ZETA_MAG_ASSUME_NORMALIZED`, the box bounds, `ZETA_ENTRY_ROWS`,
both epsilon exponents, and `ZETA_EXPECT_RE/IM` for every case. Values of
these exported in the shell are ignored during the suite. Change them with
the `gen_jobs.py` options. The other variables apply to every case.

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
Before the fix a stale strobe could start an operation on reset release and
corrupt the first result. In the review runs listed under
[Verification history](#verification-history), 40 randomized-start Verilator
replays of the upstream RTL fired `ap_reset_launch_clear` in 37 and returned
a wrong first result in 33. With the fix all 40 fired nothing and returned
the golden result.

**Magnitude and Lean.** The Z64 reference compares the packed MPF
components. One Jasper case assumes finite nonzero mantissas are normalized
and checks equality. The unrestricted case checks that the production
checker remains conservative. Neither case has been run in JasperGold yet.
`mag/mag_equiv.sby` runs the same two cases with SymbiYosys and Bitwuzla.
Both assertions hold with the mantissa squares replaced by free values, so
a proof that does not converge is stuck in the two 64-bit multipliers and
not in the comparison.

The Lean model covers arbitrary positive mantissa widths and starts with
decoded fields. `Zeta.rtl_below_bits_exact` proves that its fixed-width
datapath gives the exact strict squared magnitude comparison for
normalized inputs. The proof handles zero and special flags, both signs of
the exponent distance, the large-shift cutoff, and the product, shift
count, and sum widths. `Zeta.rtl_below_bits_sound` proves the one-way
comparison of the same fixed-width datapath for arbitrary mantissas that
fit the declared width. `Zeta.z64_below_bits_exact` and
`Zeta.z64_below_bits_sound` restate both on packed 87-bit Z64 words for
every `EPS_EXP`, with the field decode `Zeta.decodeMpf`. The Lean model is
a transcription of `mpf_magnitude.sv`, not the SystemVerilog itself. The
`mag` case checks the actual packed SystemVerilog at Z64.

The Lean directory pins Lean 4.36.0 through Elan and uses only the bundled
library. Start the package build from the repository root.

```sh
cd formal/em_compositional/lean
lean --version
lake build
```

The build fails if a main theorem depends on an axiom other than `propext`
and `Quot.sound`. From the repository root, you can replay the main theorems
with the checkers in the toolchain's `bin` directory.

```sh
sh formal/em_compositional/lean/replay.sh
```

The script builds the package and exits non-zero if a theorem is missing
from the export or a checker has nothing to check. The checkers confirm
that the exported proofs type-check. They accept any axiom, so the axiom
check is the one in the build.

**End to end.** The harness asserts `ap_small_implies_near_half`, the
near-half property, together with `ap_result_has_request`,
`ap_rom_covers_request`, `ap_flags_clear`, `ap_result_normalized`, and for a
fixed point `ap_matches_golden`. Its driver requests again in the cycle a
result arrives and never stalls a stream, so it explores one host timing.
Stalls and idle gaps are the business of the `ctrl` case.

The selected points are the Q16.16 grid points next to zeros 1 through 50
where an mpmath scan found `abs(zeta(0.5 + i*t)) < 2**-16`. There are 57
such values of `t` at 47 zeros. Zeros 39, 42, and 46 have none. Each is run
at sigma one half and at `--offsets` steps on either side, 171 cases by
default. The suite computes expected point results with the upstream
bit-true model during generation. A window leaves sigma symbolic at a fixed
height and has no single golden word. Its expected cover and near-half
outcomes come from the bit-true model at every sigma of the window, for
windows up to 64 steps either side. ROM slices are regenerated from the full
table. `gen_jobs.py --check-points` recomputes the point table with mpmath.

Read `cp_result` and `ap_matches_golden` together for a fixed point. The cover
confirms a transaction reaches `out_valid`, and the assertion compares the
packed result. `cp_small_result` checks antecedent reachability.
`ap_result_normalized` checks the comparator's input format, and
`ap_flags_clear` records sticky overflow and underflow separately.

At the default tolerances the bit-true model gives a small result at all 57
points on the line and at four points off it, the two neighbors of each of
the two zero-1 points. Those four cases are the expected counterexamples to
`ap_small_implies_near_half`. At the other 110 off-line points
`cp_small_result` is expected unreachable, so the assertion holds there only
because its antecedent never occurs. The simulated point
`sigma_raw=0x00008001`, `t_raw=0x000E227D` is one of the four. It is not an
evaluator defect: mpmath gives `abs(zeta) = 1.2810e-5` there, below
`2**-16 = 1.5259e-5`. With equal default exponents the assertion demands
sigma exactly one half.

Both default windows contain such a neighbor, so a correct run must report a
counterexample for `ap_small_implies_near_half` in them. Trust a
counterexample in a window, or in the released run, only after the
fixed-point cases with golden words have passed in the same session. Those
cases are the only check that the ROMs loaded and that the reset setup is
the intended one.

With `--sigma-eps-exp -15` no listed point is expected to fail. The full
input domain still holds counterexamples at that tolerance next to the close
pair of zeros at `t = 7005.063` and `7005.101`. The mathematics reviewer of
the 2026-11-27 review reported `sigma_raw=0x00008002`, `t_raw=0x1B5D1018`
giving `abs(Z) = 0.829 * 2**-16` in mpmath, the bit-true model, and an RTL
simulation of 115,443 cycles. That run was not repeated independently.

## Open-source pre-check

The controller, unit, and magnitude cases also run in SymbiYosys with the
yosys-slang frontend, so mistakes show up before a farm run. JasperGold
stays the reference. From the repository root with OSS CAD Suite on `PATH`:

```sh
sh formal/em_compositional/oss/run.sh
sby -f --prefix sim_build/zeta_compositional/sby/mag formal/em_compositional/mag/mag_equiv.sby
scripts/formal_lint.sh all
```

`oss/run.sh` proves every controller assertion by k-induction with the three
units as free cut points, proves the unit contracts on the real RTL, and
reaches the unit covers. `mag_equiv.sby` proves both magnitude assertions and
finds the expected counterexample without normalization. `formal_lint.sh`
elaborates every formal top with Verilator and Slang.

This check found that the helper invariants as first committed were not
inductive: nothing kept `M >= 1` after the accept cycle, and `h_bern_req`
failed the induction step. `h_tail_count_legal` closes that gap.

## Verification history

No JasperGold run exists for any case, the launch-reset edits and the
single-session suite included.

The author of the harness recorded Slang elaboration and directed Verilator
runs on the RTL before the reset fix. No logs or scripts were kept.

An automated review (Claude, on the owner's Mac, 2026-11-27, Verilator
5.051, Slang, cocotb 2.1 dev, Python 3.11 with mpmath 1.4.1, Lean 4.36.0)
ran the following on the current tree. Its testbenches are not in the
repository.

- Slang and `verilator --lint-only -Wall` elaborated `zeta_em_e2e` for the
  default box, a fixed point with and without golden words, a sigma window,
  and a ROM slice.
- The harness payload equalled `build_program` on 26,054 input pairs.
- A Verilator replay of all 171 default point cases and 12 corner inputs, up
  to the largest legal `t`, returned the word of the bit-true model every
  time with clear flags. The near-half assertion fired at exactly the four
  expected inputs. Latency was `8688 + 55 * (N - 38)` cycles.
- `run_point.sh 8000 e227d <seed>` for seeds 1 to 40 gave the results quoted
  under [Reading the results](#reading-the-results) for the upstream and the
  current RTL.
- `lake build` and both checker replays succeeded.
- `oss/run.sh` passed in 58 s: controller k-induction, unit contracts by
  PDR and k-induction, and the unit covers. With the strobe resets removed
  from `euler_maclaurin_top` the controller proof failed in the base case.
- `mag_equiv.sby` passed in 15 s, including the expected counterexample.
- The 160 Python tests, ruff, and mypy passed with `formal/` included.

A directed simulation replay is available on a host with Verilator and
generated ROMs.

```sh
formal/em_compositional/sim/run_point.sh 8001 e227d
```

A third argument selects a randomized initialization seed for registers the
RTL leaves unreset. The replay reads `ZETA_EPS_EXP` and
`ZETA_EPS_FROM_RE_ONEHALF_EXP`, builds under `ZETA_SIM_BUILD` (default
`sim_build/zeta_compositional`), and exits with status 3 when an assertion
fired, as it does at the point above with the default tolerances.
