"""Host-side checks of the generators under formal/ (no simulator, no JasperGold).

The formal harnesses hard-code a fixed-point N(t) coefficient and expected
packed results. These tests pin them to the host model on the platform that
runs the tests, and pin the manifest format to what run_suite.tcl accepts.
"""

import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType

import pytest

REPO = Path(__file__).resolve().parents[1]

# sigma_raw, t_raw, packed z_re, packed z_im (formal/euler_maclaurin/README.md).
DIRECTED = [
    (0x8000, 0xE227D, 0x0FFFECB12ECE85BA6398AC, 0x1FFFEF8B1E6D66D0FCCD7C),
    (0x8001, 0xE227D, 0x0FFFF0D398A8A130E78CA8, 0x1FFFEE968B264A73F3F151),
]


def _load(relative: str) -> ModuleType:
    path = REPO / relative
    spec = importlib.util.spec_from_file_location(f"formal_{path.stem}", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


gen_tables = _load("formal/euler_maclaurin/gen_tables.py")
gen_jobs = _load("formal/em_compositional/gen_jobs.py")
summarize = _load("formal/em_compositional/summarize.py")


def test_fixed_point_n_matches_host_select_nm() -> None:
    # select_nm uses math.pow; this fails on a platform whose libm moves an N boundary.
    gen_tables.check_n_selection()


def test_generators_share_the_n_formula() -> None:
    assert gen_jobs.N_COEFFICIENT == gen_tables.N_COEFFICIENT
    for _zero, t_raw in gen_jobs.ZERO_POINTS:
        assert gen_jobs.host_n(t_raw) == gen_tables.fixed_n(t_raw) == gen_tables.host_n(t_raw)
    assert gen_jobs.host_n(0xE227D) == 42


@pytest.mark.parametrize(("sigma_raw", "t_raw", "z_re", "z_im"), DIRECTED)
def test_directed_golden_words(sigma_raw: int, t_raw: int, z_re: int, z_im: int) -> None:
    golden = gen_jobs.load_golden()
    assert golden is not None
    assert golden(sigma_raw, t_raw) == (z_re, z_im)
    # abs(z) is 4.2e-6 and 1.3e-5: below 2**-16, not below 2**-18.
    assert gen_jobs.below_eps(z_re, z_im, -16)
    assert not gen_jobs.below_eps(z_re, z_im, -18)


def test_below_eps_special_and_zero_words() -> None:
    special = 1 << 86
    zero = 1 << 85
    assert not gen_jobs.below_eps(special, zero, -16)
    assert gen_jobs.below_eps(zero, zero, -16)


def _suite_keys() -> set[str]:
    text = (REPO / "formal/em_compositional/run_suite.tcl").read_text()
    match = re.search(r"set suite_keys \{(.*?)\}", text, re.DOTALL)
    assert match is not None
    return set(match.group(1).split())


def test_manifest_fields_are_accepted_by_run_suite(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(gen_jobs, "OUT", tmp_path)
    monkeypatch.setattr(sys, "argv", ["gen_jobs.py", "--zeros", "1", "--full-rom"])
    gen_jobs.main()
    keys = _suite_keys()
    names = []
    for line in (tmp_path / "jobs.tsv").read_text().splitlines():
        fields = dict(field.split("=", 1) for field in line.split("\t"))
        assert set(fields) <= keys, set(fields) - keys
        assert all(fields.values())
        assert re.fullmatch(r"[A-Za-z0-9_.-]+", fields["ZETA_JOB"])
        names.append(fields["ZETA_JOB"])
    assert len(names) == len(set(names)) == 7 + 2 * 3 + 2
    expected = [line.split("\t") for line in (tmp_path / "expected.tsv").read_text().splitlines()]
    assert {job for job, _prop, _outcome in expected} == set(names)
    assert {outcome for _job, _prop, outcome in expected} <= {
        "pass",
        "cex",
        "covered",
        "uncovered",
        "observe",
    }
    by_job = {(job, prop): outcome for job, prop, outcome in expected}
    assert by_job[("pt_z01_t0e227d_p0", "ap_small_implies_near_half")] == "pass"
    assert by_job[("pt_z01_t0e227d_p1", "ap_small_implies_near_half")] == "cex"


@pytest.mark.parametrize(
    ("expected", "status", "state"),
    [
        ("pass", "proven", "ok"),
        ("pass", "cex", "CONTRADICTS"),
        ("pass", "undetermined", "open"),
        ("cex", "cex", "ok"),
        ("cex", "proven", "CONTRADICTS"),
        ("covered", "covered", "ok"),
        ("covered", "unreachable", "CONTRADICTS"),
        ("uncovered", "unreachable", "ok"),
        ("uncovered", "covered", "CONTRADICTS"),
        ("observe", "cex", "observed"),
        ("observe", "undetermined", "open"),
    ],
)
def test_summarize_verdict(expected: str, status: str, state: str) -> None:
    assert summarize.verdict(expected, status) == state


@pytest.mark.parametrize(
    ("status", "code"), [("proven", None), ("cex", 1), ("undetermined", 2), (None, 2)]
)
def test_summarize_exit_code(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, status: str | None, code: int | None
) -> None:
    (tmp_path / "expected.tsv").write_text("job\tap_x\tpass\n")
    if status is not None:
        (tmp_path / "job.tsv").write_text(f"job\ttop.ap_x\tassert\t{status}\t1\t0.1\n")
    monkeypatch.setattr(sys, "argv", ["summarize.py", str(tmp_path)])
    if code is None:
        summarize.main()
    else:
        with pytest.raises(SystemExit) as info:
            summarize.main()
        assert info.value.code == code
