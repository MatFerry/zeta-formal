"""Behaviour added by the proposed fixes to gen_jobs.py and summarize.py.

These tests fail on the unpatched scripts; add them together with the fixes.
"""

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pytest

REPO = Path(__file__).resolve().parents[1]
FORMAL = REPO / "formal" / "em_compositional"


def _load(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(f"formal_fix_{name}", FORMAL / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def gen_jobs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    module = _load("gen_jobs")
    rom = tmp_path / "entries_released.mem"
    rom.write_text("".join(f"{row:058x}\n" for row in range(9119)), encoding="ascii")
    monkeypatch.setattr(module, "OUT", tmp_path / "zeta_compositional")
    monkeypatch.setattr(module, "RELEASED_ROM", rom)
    monkeypatch.setattr(sys, "path", list(sys.path))
    return module


def _generate(module: ModuleType, monkeypatch: pytest.MonkeyPatch, *options: str) -> None:
    monkeypatch.setattr(sys, "argv", ["gen_jobs.py", *options])
    module.main()


def _expected(module: ModuleType) -> dict[tuple[str, str], str]:
    out: Path = module.OUT
    rows = [line.split("\t") for line in (out / "expected.tsv").read_text().splitlines()]
    return {(job, prop): outcome for job, prop, outcome in rows}


def test_missing_model_is_an_error(gen_jobs: ModuleType, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(sys.modules, "mpmath", None)  # "import mpmath" now raises ImportError
    with pytest.raises(SystemExit, match="--no-golden"):
        _generate(gen_jobs, monkeypatch, "--zeros", "1")
    out: Path = gen_jobs.OUT
    assert not (out / "jobs.tsv").exists()
    # Asking for no model, or for cases that need none, still works.
    _generate(gen_jobs, monkeypatch, "--zeros", "1", "--no-golden")
    _generate(gen_jobs, monkeypatch, "--zeros", "0", "--window-zeros", "0")


@pytest.mark.parametrize(
    ("options", "cover", "assertion"),
    [
        ((), "covered", "cex"),  # sigma = 1/2 +- one step is still below 2**-16
        (("--sigma-eps-exp", "-15"), "covered", "pass"),
        (("--eps-exp", "-20"), "uncovered", "pass"),
        (("--window", "0"), "covered", "pass"),
        (("--window", "300"), "observe", "observe"),
        (("--no-golden",), "observe", "observe"),
    ],
)
def test_window_expectations_follow_the_model(
    gen_jobs: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    options: tuple[str, ...],
    cover: str,
    assertion: str,
) -> None:
    _generate(gen_jobs, monkeypatch, "--zeros", "0", "--window-zeros", "1", *options)
    expected = _expected(gen_jobs)
    windows = {job for job, _prop in expected if job.startswith("win_")}
    assert len(windows) == 2
    for job in windows:
        assert expected[(job, "cp_small_result")] == cover
        assert expected[(job, "ap_small_implies_near_half")] == assertion


@pytest.mark.parametrize(("eps_exp", "forwarded"), [(-16, True), (-20, True), (-600000, False)])
def test_magnitude_cases_use_the_end_to_end_threshold(
    gen_jobs: ModuleType, monkeypatch: pytest.MonkeyPatch, eps_exp: int, forwarded: bool
) -> None:
    _generate(
        gen_jobs, monkeypatch, "--zeros", "0", "--window-zeros", "0", "--eps-exp", str(eps_exp)
    )
    out: Path = gen_jobs.OUT
    lines = [
        line for line in (out / "jobs.tsv").read_text().splitlines() if "ZETA_KIND=mag" in line
    ]
    assert len(lines) == 2
    for line in lines:
        assert (f"ZETA_EPS_EXP={eps_exp}" in line.split("\t")) == forwarded
        assert ("ZETA_EPS_EXP" in line) == forwarded


def _summarize(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], *arguments: str | Path
) -> tuple[int, str, str]:
    module = _load("summarize")
    monkeypatch.setattr(sys, "argv", ["summarize.py", *map(str, arguments)])
    code = 0
    try:
        module.main()
    except SystemExit as stop:
        assert isinstance(stop.code, int), stop.code
        code = stop.code
    captured = capsys.readouterr()
    return code, captured.out, captured.err


def _session(directory: Path, extra: str = "") -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "expected.tsv").write_text("unit_mul\tap_done_in_flight\tpass\n")
    (directory / "unit_mul.tsv").write_text(
        "unit_mul\tem_unit_mul_top.contract.ap_done_in_flight\tassert\tproven\t3\t0.1\n" + extra
    )


def test_unlisted_counterexample_is_a_contradiction(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _session(tmp_path, "unit_mul\tem_unit_mul_top.dut._assert_3\tassert\tcex\t4\t0.1\n")
    code, out, _err = _summarize(monkeypatch, capsys, tmp_path)
    assert code == 1
    assert "_assert_3" in out and "1 contradict the expectation" in out


def test_unlisted_unreachable_cover_is_reported(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    row = "unit_mul\tem_unit_mul_top.contract.ap_done_in_flight:precondition1\tcover\tunreachable"
    _session(tmp_path, row + "\t-\t0.1\n")
    code, out, _err = _summarize(monkeypatch, capsys, tmp_path)
    assert code == 0
    assert "Unreachable without an expectation: ap_done_in_flight:precondition1 in unit_mul" in out


def test_results_of_an_unknown_case_are_incomplete(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _session(tmp_path)
    (tmp_path / "ctrl.tsv").write_text("ctrl\tem_ctrl_top.dut.x.ap_y\tassert\tcex\t4\t0.1\n")
    code, out, _err = _summarize(monkeypatch, capsys, tmp_path)
    assert code == 2
    assert "expected.tsv does not name the case: ctrl" in out


def test_unusable_input_exits_3(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    code, _out, err = _summarize(monkeypatch, capsys, tmp_path / "absent")
    assert code == 3 and "does not exist" in err
    code, _out, err = _summarize(monkeypatch, capsys, "--help")
    assert code == 3 and "usage" in err
    _session(tmp_path)
    with (tmp_path / "expected.tsv").open("a") as out_file:
        out_file.write("unit_mul\tjunk\n")
    code, _out, err = _summarize(monkeypatch, capsys, tmp_path)
    assert code == 3 and "expected.tsv:2" in err
    _session(tmp_path, "unit_mul\tem_unit_mul_top.other.ap_done_in_flight\tassert\tcex\t4\t0.1\n")
    code, _out, err = _summarize(monkeypatch, capsys, tmp_path)
    assert code == 3 and "end in the same name" in err
