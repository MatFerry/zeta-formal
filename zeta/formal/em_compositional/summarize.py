"""Compare JasperGold results with the expectations written by gen_jobs.py.

    python3 formal/em_compositional/summarize.py [results_dir]

Reads <job>.tsv files written by run.tcl (job, property, type, status, trace
length, time) and the session's snapshot of expected.tsv. Property names
are matched on their last hierarchical component.

Exit status: 0 every expectation is met; 1 a contradiction, a property missing
from a finished case, or a counterexample on a property without an
expectation; 2 incomplete results, or results of a case that expected.tsv does
not name; 3 unusable input.
"""

import sys
from pathlib import Path
from typing import NoReturn

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "sim_build" / "zeta_compositional"

# Jasper status words, grouped. Anything else counts as open.
PROVEN = {"proven"}
FAILED = {"cex"}
COVERED = {"covered"}
UNREACHABLE = {"unreachable"}


def fail(message: str) -> NoReturn:
    print(f"summarize.py: {message}", file=sys.stderr)
    sys.exit(3)


def verdict(expected: str, status: str) -> str:
    status = status.strip().lower()
    if expected == "pass":
        return "ok" if status in PROVEN else "CONTRADICTS" if status in FAILED else "open"
    if expected == "cex":
        return "ok" if status in FAILED else "CONTRADICTS" if status in PROVEN else "open"
    if expected == "covered":
        return "ok" if status in COVERED else "CONTRADICTS" if status in UNREACHABLE else "open"
    if expected == "uncovered":
        return "ok" if status in UNREACHABLE else "CONTRADICTS" if status in COVERED else "open"
    if expected == "observe" and status in PROVEN | FAILED | COVERED | UNREACHABLE:
        return "observed"
    return "open"


def main() -> None:
    args = [arg for arg in sys.argv[1:] if arg != "-v"]
    if len(args) > 1 or any(arg.startswith("-") for arg in args):
        fail("usage: summarize.py [results_dir] [-v]")
    results_dir = Path(args[0]) if args else OUT / "results"
    if not results_dir.is_dir():
        fail(f"results directory does not exist: {results_dir}")
    expected_path = results_dir / "expected.tsv"
    if not expected_path.is_file():
        expected_path = OUT / "expected.tsv"
    if not expected_path.is_file():
        fail(f"no expected.tsv in {results_dir} or {OUT}. Run gen_jobs.py first.")
    expected_rows: list[tuple[str, str, str]] = []
    for number, line in enumerate(expected_path.read_text().splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 3:
            fail(f"{expected_path}:{number}: expected job, property and outcome, got {line!r}")
        expected_rows.append((fields[0], fields[1], fields[2]))
    results: dict[tuple[str, str], tuple[str, str, str]] = {}
    full_names: dict[tuple[str, str], str] = {}
    jobs_seen = set()
    for path in sorted(results_dir.glob("*.tsv")):
        if path.name in {"expected.tsv", "jobs.tsv"}:
            continue
        for line in path.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) != 6:
                continue
            job, name, _type, status, length, time = fields
            jobs_seen.add(job)
            key = (job, name.rsplit(".", 1)[-1])
            if full_names.setdefault(key, name) != name:
                fail(f"{path}: {full_names[key]} and {name} end in the same name")
            results[key] = (status, length, time)

    counts = {"ok": 0, "observed": 0, "open": 0, "CONTRADICTS": 0, "missing": 0, "not run": 0}
    rows = []
    for job, prop, expected in expected_rows:
        if (job, prop) not in results:
            state = "missing" if job in jobs_seen else "not run"
            counts[state] += 1
            rows.append((job, prop, expected, "-", "-", state))
            continue
        status, length, _time = results[(job, prop)]
        state = verdict(expected, status)
        counts[state] += 1
        rows.append((job, prop, expected, status, length, state))

    # Results nobody listed. A counterexample there is a failure all the same,
    # and an unreachable cover (Jasper's ":precondition" covers included) can
    # mean that a proof is vacuous.
    expected_jobs = {job for job, _prop, _expected in expected_rows}
    listed = {(job, prop) for job, prop, _expected in expected_rows}
    unreachable: dict[str, list[str]] = {}
    for (job, prop), (status, length, _time) in sorted(results.items()):
        if job not in expected_jobs or (job, prop) in listed:
            continue
        word = status.strip().lower()
        if word in FAILED:
            counts["CONTRADICTS"] += 1
            rows.append((job, prop, "(none)", status, length, "CONTRADICTS"))
        elif word in UNREACHABLE:
            unreachable.setdefault(prop, []).append(job)
    unknown_jobs = sorted(jobs_seen - expected_jobs)

    width = [max(len(row[i]) for row in rows) for i in range(6)] if rows else [0] * 6
    for row in rows:
        if row[5] != "ok" or "-v" in sys.argv:
            print("  ".join(cell.ljust(width[i]) for i, cell in enumerate(row)).rstrip())
    print(
        f"{counts['ok']} as expected, {counts['observed']} observed, {counts['open']} open, "
        f"{counts['CONTRADICTS']} contradict the expectation, "
        f"{counts['missing']} missing from a finished case, {counts['not run']} not run"
    )
    for prop, jobs in sorted(unreachable.items()):
        more = f" and {len(jobs) - 3} more" if len(jobs) > 3 else ""
        print(f"Unreachable without an expectation: {prop} in {', '.join(jobs[:3])}{more}")
    if unknown_jobs:
        print("Not compared, expected.tsv does not name the case: " + ", ".join(unknown_jobs))
    if counts["CONTRADICTS"] or counts["missing"]:
        sys.exit(1)
    if counts["open"] or counts["not run"] or unknown_jobs or not rows:
        sys.exit(2)


if __name__ == "__main__":
    main()
