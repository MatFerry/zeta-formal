"""Replay the fixed-point end-to-end cases of jobs.tsv in Verilator.

    python3 formal/em_compositional/sim/replay_jobs.py [--seed N] [--limit K]

A simulation stand-in for the JasperGold point cases, for hosts without
Jasper. For every e2e case with one sigma and one t, run_point.sh simulates
two back-to-back transactions. Both results must equal the manifest's golden
words (ZETA_EXPECT_RE/IM, from the bit-true Python model), and the assertions
that fire must be exactly the ones expected.tsv marks "cex".

Run gen_tables.py and gen_jobs.py first. Exits 0 when every case agrees.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "sim_build" / "zeta_compositional"
RUN_POINT = Path(__file__).resolve().parent / "run_point.sh"
RESULT = re.compile(r"^RESULT .* z_re=([0-9a-f]+) z_im=([0-9a-f]+) ", re.MULTILINE)
FAILED = re.compile(r"Assertion failed in \S*?(\w+): ")


def hex_value(literal: str) -> int:
    return int(literal.split("'h", 1)[1].replace("_", ""), 16)


def replay(env: dict[str, str], expected: dict[str, str], seed: str | None) -> list[str]:
    command = [
        str(RUN_POINT),
        f"{hex_value(env['ZETA_SIGMA_LO']):x}",
        f"{hex_value(env['ZETA_T_LO']):x}",
    ]
    if seed is not None:
        command.append(seed)
    settings = {key: env[key] for key in ("ZETA_EPS_EXP", "ZETA_EPS_FROM_RE_ONEHALF_EXP")}
    run = subprocess.run(
        command, env={**os.environ, **settings}, capture_output=True, text=True, check=False
    )
    problems = []
    if run.returncode != 0:
        problems.append(f"run_point.sh exited {run.returncode}: {run.stderr.strip()[-400:]}")
    golden = (hex_value(env["ZETA_EXPECT_RE"]), hex_value(env["ZETA_EXPECT_IM"]))
    results = [(int(re_, 16), int(im, 16)) for re_, im in RESULT.findall(run.stdout)]
    if len(results) != 2:
        problems.append(f"{len(results)} results instead of 2")
    for index, result in enumerate(results):
        if result != golden:
            problems.append(f"result {index} is {result[0]:022x} {result[1]:022x}, not the golden")
    fired = set(FAILED.findall(run.stdout))
    may_fire = {prop for prop, outcome in expected.items() if outcome == "cex"}
    if fired != may_fire:
        problems.append(f"assertions fired {sorted(fired)}, expected {sorted(may_fire)}")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--seed", help="randomize unreset registers with this Verilator seed")
    parser.add_argument("--limit", type=int, help="replay only the first LIMIT point cases")
    args = parser.parse_args()

    for name in ("jobs.tsv", "expected.tsv"):
        if not (OUT / name).is_file():
            sys.exit(f"Missing {OUT / name}. Run formal/em_compositional/gen_jobs.py first.")
    expected: dict[str, dict[str, str]] = {}
    for line in (OUT / "expected.tsv").read_text(encoding="ascii").splitlines():
        job, prop, outcome = line.split("\t")
        expected.setdefault(job, {})[prop] = outcome

    cases = []
    for line in (OUT / "jobs.tsv").read_text(encoding="ascii").splitlines():
        env = dict(field.split("=", 1) for field in line.split("\t"))
        if (
            env["ZETA_KIND"] == "e2e"
            and "ZETA_EXPECT_RE" in env
            and env["ZETA_SIGMA_LO"] == env["ZETA_SIGMA_HI"]
            and env["ZETA_T_LO"] == env["ZETA_T_HI"]
        ):
            cases.append(env)
    if args.limit is not None:
        cases = cases[: args.limit]
    if not cases:
        sys.exit(
            "jobs.tsv has no point case with golden words (was gen_jobs.py run with --no-golden?)"
        )

    failures = 0
    for env in cases:
        problems = replay(env, expected[env["ZETA_JOB"]], args.seed)
        print(f"{'FAIL' if problems else 'ok  '} {env['ZETA_JOB']}", flush=True)
        for problem in problems:
            print(f"     {problem}")
        failures += bool(problems)
    print(
        f"{len(cases) - failures} of {len(cases)} point cases agree with the model and expected.tsv"
    )
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
