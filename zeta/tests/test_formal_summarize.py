"""formal/em_compositional/summarize.py: verdicts, counts, and exit status.

The result files are written here in the format run.tcl produces: one line
per property with job, hierarchical name, type, status, trace length, time.
"""

import importlib.util
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType

import pytest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "formal" / "em_compositional" / "summarize.py"

Summarize = Callable[..., tuple[int, list[str]]]


@pytest.fixture
def summarize_module(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    spec = importlib.util.spec_from_file_location("formal_summarize", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "OUT", tmp_path / "zeta_compositional")
    return module


@pytest.fixture
def summarize(
    summarize_module: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> Summarize:
    def run(*arguments: str | Path) -> tuple[int, list[str]]:
        monkeypatch.setattr(sys, "argv", ["summarize.py", *map(str, arguments)])
        code = 0
        try:
            summarize_module.main()
        except SystemExit as stop:
            assert isinstance(stop.code, int), stop.code
            code = stop.code
        return code, capsys.readouterr().out.splitlines()

    return run


def write_expected(directory: Path, rows: list[tuple[str, str, str]]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "expected.tsv").write_text("".join("\t".join(row) + "\n" for row in rows))


def write_results(directory: Path, job: str, rows: list[tuple[str, str, str]]) -> None:
    """rows: (hierarchical property name, type, status)."""
    directory.mkdir(parents=True, exist_ok=True)
    lines = ["\t".join((job, name, sva, status, "12", "0.5")) + "\n" for name, sva, status in rows]
    (directory / f"{job}.tsv").write_text("".join(lines))


EXPECTED = [
    ("unit_mul", "ap_done_in_flight", "pass"),
    ("unit_mul", "cp_done", "covered"),
    ("mag_unnormalized", "ap_checker_matches_reference", "cex"),
    ("pt", "cp_small_result", "uncovered"),
    ("pt", "ap_small_implies_near_half", "observe"),
]
AS_EXPECTED = {
    "unit_mul": [
        ("em_unit_mul_top.contract.a_single_flight", "assume", "temporary"),
        ("em_unit_mul_top.contract.ap_done_in_flight", "assert", "proven"),
        ("em_unit_mul_top.contract.ap_done_in_flight:precondition1", "cover", "covered"),
        ("em_unit_mul_top.contract.cp_done", "cover", "covered"),
    ],
    "mag_unnormalized": [("mag_equiv.ap_checker_matches_reference", "assert", "cex")],
    "pt": [
        ("zeta_em_e2e.cp_small_result", "cover", "unreachable"),
        ("zeta_em_e2e.ap_small_implies_near_half", "assert", "proven"),
    ],
}


def totals(lines: list[str]) -> str:
    (line,) = [line for line in lines if " as expected" in line]
    return line


def table(lines: list[str]) -> list[list[str]]:
    """The printed rows, up to the line with the totals."""
    return [line.split() for line in lines[: lines.index(totals(lines))]]


def write_session(directory: Path, **overrides: list[tuple[str, str, str]]) -> None:
    write_expected(directory, EXPECTED)
    for job, rows in (AS_EXPECTED | overrides).items():
        write_results(directory, job, rows)


@pytest.mark.parametrize(
    ("expected", "status", "result"),
    [
        ("pass", "proven", "ok"),
        ("pass", "cex", "CONTRADICTS"),
        ("pass", "undetermined", "open"),
        ("pass", "covered", "open"),
        ("pass", " Proven\n", "ok"),
        ("pass", "bounded_proven", "open"),
        ("cex", "cex", "ok"),
        ("cex", "proven", "CONTRADICTS"),
        ("cex", "ar_cex", "open"),
        ("covered", "covered", "ok"),
        ("covered", "unreachable", "CONTRADICTS"),
        ("covered", "ar_covered", "open"),
        ("uncovered", "unreachable", "ok"),
        ("uncovered", "covered", "CONTRADICTS"),
        ("uncovered", "undetermined", "open"),
        ("observe", "proven", "observed"),
        ("observe", "cex", "observed"),
        ("observe", "covered", "observed"),
        ("observe", "unreachable", "observed"),
        ("observe", "undetermined", "open"),
        ("pass", "?", "open"),
        ("pass", "", "open"),
        ("typo", "proven", "open"),
    ],
)
def test_verdict(summarize_module: ModuleType, expected: str, status: str, result: str) -> None:
    assert summarize_module.verdict(expected, status) == result


def test_all_expectations_met(summarize: Summarize, tmp_path: Path) -> None:
    write_session(tmp_path)
    code, lines = summarize(tmp_path)
    assert code == 0
    # Only rows that are not "ok" are printed: here the observed one.
    assert table(lines) == [
        ["pt", "ap_small_implies_near_half", "observe", "proven", "12", "observed"]
    ]
    assert totals(lines).startswith("4 as expected")
    assert "1 observed, 0 open, 0 contradict the expectation" in totals(lines)
    assert "0 missing from a finished case, 0 not run" in totals(lines)


def test_verbose_lists_every_row(summarize: Summarize, tmp_path: Path) -> None:
    write_session(tmp_path)
    code, lines = summarize(tmp_path, "-v")
    assert code == 0
    assert [row[:2] for row in table(lines)] == [list(row[:2]) for row in EXPECTED]
    assert table(lines)[0] == ["unit_mul", "ap_done_in_flight", "pass", "proven", "12", "ok"]


def test_contradictions_exit_1(summarize: Summarize, tmp_path: Path) -> None:
    write_session(
        tmp_path,
        mag_unnormalized=[("mag_equiv.ap_checker_matches_reference", "assert", "proven")],
        pt=[
            ("zeta_em_e2e.cp_small_result", "cover", "covered"),
            ("zeta_em_e2e.ap_small_implies_near_half", "assert", "undetermined"),
        ],
    )
    code, lines = summarize(tmp_path)
    assert code == 1  # a contradiction outranks the open row
    assert [row[-1] for row in table(lines)] == ["CONTRADICTS", "CONTRADICTS", "open"]
    assert totals(lines).startswith("2 as expected") and "1 open, 2 contradict" in totals(lines)


def test_missing_property_exits_1(summarize: Summarize, tmp_path: Path) -> None:
    rows = [("em_unit_mul_top.contract.ap_done_in_flight", "assert", "proven")]
    write_session(tmp_path, unit_mul=rows)
    code, lines = summarize(tmp_path)
    assert code == 1
    assert table(lines)[0] == ["unit_mul", "cp_done", "covered", "-", "-", "missing"]
    assert "1 missing from a finished case, 0 not run" in totals(lines)


def test_case_without_results_exits_2(summarize: Summarize, tmp_path: Path) -> None:
    write_session(tmp_path)
    (tmp_path / "unit_mul.tsv").unlink()
    code, lines = summarize(tmp_path)
    assert code == 2
    assert [row[-2:] for row in table(lines)[:2]] == [["not", "run"], ["not", "run"]]
    assert "0 missing from a finished case, 2 not run" in totals(lines)


def test_open_result_exits_2(summarize: Summarize, tmp_path: Path) -> None:
    rows = [("mag_equiv.ap_checker_matches_reference", "assert", "undetermined")]
    write_session(tmp_path, mag_unnormalized=rows)
    code, lines = summarize(tmp_path)
    assert code == 2
    assert table(lines)[0] == [
        "mag_unnormalized", "ap_checker_matches_reference", "cex", "undetermined", "12", "open",
    ]  # fmt: skip
    assert "1 open, 0 contradict" in totals(lines)


def test_failed_property_query_stays_open(summarize: Summarize, tmp_path: Path) -> None:
    # run.tcl writes "?" for every field when get_property_info is rejected.
    rows = [("em_unit_mul_top.contract.ap_done_in_flight", "?", "?")]
    rows.append(("em_unit_mul_top.contract.cp_done", "?", "?"))
    write_session(tmp_path, unit_mul=rows)
    code, lines = summarize(tmp_path)
    assert code == 2
    assert "2 open" in totals(lines)


def test_only_result_files_are_parsed(summarize: Summarize, tmp_path: Path) -> None:
    write_session(tmp_path)
    # The suite's manifest snapshot, a leftover temporary file, a native CSV
    # report, and a truncated line must not turn into results.
    (tmp_path / "jobs.tsv").write_text("ZETA_KIND=unit_mul\tZETA_JOB=unit_mul\n")
    (tmp_path / "unit_mul.tsv.123.tmp").write_text(
        "unit_mul\ttop.cp_done\tcover\tunreachable\t1\t1\n"
    )
    (tmp_path / "unit_mul.csv").write_text("Name,Type,Status\n")
    with (tmp_path / "pt.tsv").open("a") as out:
        out.write("pt\tzeta_em_e2e.cp_small_result\tcover\n")
    code, lines = summarize(tmp_path)
    assert code == 0
    assert totals(lines).startswith("4 as expected")


def test_expected_falls_back_to_generator_output(
    summarize: Summarize, summarize_module: ModuleType, tmp_path: Path
) -> None:
    results = tmp_path / "single"
    write_results(results, "unit_mul", AS_EXPECTED["unit_mul"])
    out: Path = summarize_module.OUT
    write_expected(out, EXPECTED[:2])
    code, lines = summarize(results)
    assert code == 0
    assert totals(lines).startswith("2 as expected")


def test_default_results_directory(summarize: Summarize, summarize_module: ModuleType) -> None:
    out: Path = summarize_module.OUT
    write_expected(out, EXPECTED[:2])
    write_results(out / "results", "unit_mul", AS_EXPECTED["unit_mul"])
    code, lines = summarize()
    assert code == 0
    assert totals(lines).startswith("2 as expected")


def test_no_expectations_is_incomplete(summarize: Summarize, tmp_path: Path) -> None:
    write_expected(tmp_path, [])
    write_results(tmp_path, "unit_mul", AS_EXPECTED["unit_mul"])
    code, lines = summarize(tmp_path)
    assert code == 2
    assert totals(lines).startswith("0 as expected")
