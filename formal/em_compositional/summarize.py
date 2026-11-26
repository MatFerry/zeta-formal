"""Compare JasperGold results with the expectations written by gen_jobs.py.

    python3 formal/em_compositional/summarize.py [results_dir]

Reads <job>.tsv files written by run.tcl (job, property, type, status, trace
length, time) and the session's snapshot of expected.tsv. Property names
are matched on their last hierarchical component.
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "sim_build" / "zeta_compositional"

# Jasper status words, grouped. Anything else counts as open.
PROVEN = {"proven"}
FAILED = {"cex"}
COVERED = {"covered"}
UNREACHABLE = {"unreachable"}


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
    if len(args) > 1:
        sys.exit("Usage: summarize.py [results_dir] [-v]")
    results_dir = Path(args[0]) if args else OUT / "results"
    expected_path = results_dir / "expected.tsv"
    if not expected_path.is_file():
        expected_path = OUT / "expected.tsv"
    results: dict[tuple[str, str], tuple[str, str, str]] = {}
    jobs_seen = set()
    for path in sorted(results_dir.glob("*.tsv")):
        if path.name in {"expected.tsv", "jobs.tsv"}:
            continue
        for line in path.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) != 6:
                continue
            job, prop, _type, status, length, time = fields
            jobs_seen.add(job)
            results[(job, prop.rsplit(".", 1)[-1])] = (status, length, time)

    counts = {"ok": 0, "observed": 0, "open": 0, "CONTRADICTS": 0, "missing": 0, "not run": 0}
    rows = []
    for line in expected_path.read_text().splitlines():
        job, prop, expected = line.split("\t")
        if (job, prop) not in results:
            state = "missing" if job in jobs_seen else "not run"
            counts[state] += 1
            rows.append((job, prop, expected, "-", "-", state))
            continue
        status, length, _time = results[(job, prop)]
        state = verdict(expected, status)
        counts[state] += 1
        rows.append((job, prop, expected, status, length, state))

    width = [max(len(row[i]) for row in rows) for i in range(6)] if rows else [0] * 6
    for row in rows:
        if row[5] != "ok" or "-v" in sys.argv:
            print("  ".join(cell.ljust(width[i]) for i, cell in enumerate(row)).rstrip())
    print(f"{counts['ok']} as expected, {counts['observed']} observed, {counts['open']} open, "
          f"{counts['CONTRADICTS']} contradict the expectation, "
          f"{counts['missing']} missing from a finished case, {counts['not run']} not run")
    if counts["CONTRADICTS"] or counts["missing"]:
        sys.exit(1)
    if counts["open"] or counts["not run"] or not rows:
        sys.exit(2)


if __name__ == "__main__":
    main()
