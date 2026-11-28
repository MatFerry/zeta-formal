"""Write the JasperGold job list for the compositional Euler-Maclaurin demo.

Each line of jobs.tsv configures one case for run_suite.tcl in a single
Jasper session. expected.tsv records the expected property outcomes.

    python3 formal/em_compositional/gen_jobs.py [--zeros 10] [--offsets 1]

The end-to-end points are the Q16.16 grid points next to the first zeta zeros
where the true |zeta(1/2 + it)| is below 2**-16 (ZERO_POINTS, from an mpmath
scan). The script runs the repository's bit-true Python model (it needs
mpmath) at every point, passes the packed result to the harness as
ap_matches_golden, and derives from it the expected outcome of the near-half
assertion and of its cover, for a window at every sigma of the window.
--no-golden generates the cases without these checks: their outcomes are
then only observed.

A fixed sign box samples the four corners and two center-column points near
an mpmath zero estimate. It checks Re(a * conj(b)) < 0 on both rows and the
center column. The test is invariant under a common rotation of the results.

--symbolic-box adds a released sign-box case after the fixed boxes. It uses
the full ROM and leaves the box coordinates to Jasper.
"""

import argparse
import sys
from collections.abc import Callable
from fractions import Fraction
from itertools import islice
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "sim_build" / "zeta_compositional"
FRAC = 16
SIGMA_HALF = 0x8000
RELEASED_ROM = REPO / "sim_build" / "zeta_formal" / "entries_released.mem"
# Z64 host select_nm in fixed point, as in formal/euler_maclaurin/gen_tables.py.
N_COEFFICIENT = 0x046F057EF67CC9A1
# golden(sigma_raw, t_raw) -> packed (z_re, z_im)
Golden = Callable[[int, int], tuple[int, int]]

# (zero index, t_raw) with |zeta(1/2 + i*t_raw/2**16)| < 2**-16, zeros 1..50.
# Zeros 39, 42 and 46 have no such grid point.
ZERO_POINTS = [
    (1, 0x0E227D),
    (1, 0x0E227E),
    (2, 0x1505A4),
    (2, 0x1505A5),
    (3, 0x1902C7),
    (3, 0x1902C8),
    (4, 0x1E6CC4),
    (4, 0x1E6CC5),
    (5, 0x20EF60),
    (6, 0x259610),
    (7, 0x28EB31),
    (8, 0x2B53BB),
    (9, 0x300151),
    (9, 0x300152),
    (10, 0x31C61A),
    (11, 0x34F867),
    (12, 0x38723D),
    (13, 0x3B58D8),
    (14, 0x3CD4EF),
    (14, 0x3CD4F0),
    (15, 0x411CD0),
    (16, 0x43146E),
    (16, 0x43146F),
    (17, 0x458BE1),
    (18, 0x481131),
    (19, 0x4BB467),
    (20, 0x4D2514),
    (21, 0x4F565E),
    (22, 0x52E90F),
    (23, 0x54BC49),
    (24, 0x576CDF),
    (25, 0x58CF22),
    (26, 0x5C7DED),
    (27, 0x5EA6BE),
    (27, 0x5EA6BF),
    (28, 0x5FDEE2),
    (29, 0x62D4C9),
    (30, 0x65515F),
    (31, 0x67B9BD),
    (32, 0x697256),
    (33, 0x6B2B2A),
    (34, 0x6F0790),
    (35, 0x6FDFE9),
    (35, 0x6FDFEA),
    (36, 0x7251FA),
    (37, 0x743A08),
    (38, 0x76CA71),
    (40, 0x7AF263),
    (40, 0x7AF264),
    (41, 0x7C41BF),
    (43, 0x819426),
    (44, 0x831673),
    (45, 0x857F6C),
    (47, 0x8A1DB5),
    (48, 0x8BBC78),
    (49, 0x8D1FAB),
    (50, 0x8F1CA2),
]

# Largest symbolic-sigma window whose outcome is derived from the bit-true model.
MAX_GOLDEN_WINDOW = 64

# "pass" expects a proof, "cex" a counterexample, and "covered" a witness.
CTRL_ASSERTS = [
    "ap_reset_launch_clear",
    "ap_np_launch_in_wait",
    "ap_mul_launch_in_wait",
    "ap_add_launch_in_wait",
    "ap_np_single_flight",
    "ap_mul_single_flight",
    "ap_add_single_flight",
    "ap_np_wait_has_flight",
    "ap_mul_wait_has_flight",
    "ap_add_wait_has_flight",
    "ap_result_has_request",
    "ap_busy_until_result",
    "ap_active_has_request",
    "ap_entry_beats",
    "ap_bern_beats",
    "h_enum_in_sync",
    "h_state_legal",
    "h_config_latched",
    "h_tail_count_legal",
    "h_ret_ad_legal",
    "h_ret_cm_legal",
    "h_ps_only_path",
    "h_full_path",
    "h_entry_ps_req",
    "h_entry_ps_wait",
    "h_entry_n0",
    "h_entry_n1",
    "h_entry_n2",
    "h_bern_pre",
    "h_bern_req",
    "h_bern_body_a",
    "h_bern_body_b",
    "h_bern_done",
]
CTRL_COVERS = [
    "cp_result_full",
    "cp_result_ps_only",
    "cp_result_ps_only_m0",
    "cp_result_two_tail_terms",
    "cp_back_to_back",
]
E2E_ASSERTS = [
    "ap_result_has_request",
    "ap_rom_covers_request",
    "ap_flags_clear",
    "ap_result_normalized",
]


class Job:
    def __init__(self, name: str, kind: str, **env: str) -> None:
        self.name = name
        self.env = {"ZETA_KIND": kind, "ZETA_JOB": name, **env}
        self.expected: list[tuple[str, str]] = []

    def expect(self, prop: str, outcome: str) -> "Job":
        self.expected.append((prop, outcome))
        return self


def fixed_jobs(eps_exp: int = -16) -> list[Job]:
    jobs = []
    # The magnitude cases check the comparator at the threshold the end-to-end
    # cases use, as long as an MPF exponent can equal it (the covers need that).
    mag_eps = {"ZETA_EPS_EXP": str(eps_exp)} if -(1 << 19) <= eps_exp < (1 << 19) else {}

    job = Job("ctrl_proof", "ctrl")
    for prop in CTRL_ASSERTS:
        job.expect(prop, "pass")
    for prop in CTRL_COVERS:
        job.expect(prop, "covered")
    jobs.append(job)

    job = Job("ctrl_small", "ctrl", ZETA_CTRL_N_BOUND="6", ZETA_CTRL_M_BOUND="4")
    for prop in CTRL_ASSERTS:
        job.expect(prop, "pass")
    jobs.append(job)

    for unit in ("mul", "add", "npow"):
        job = Job(f"unit_{unit}", f"unit_{unit}")
        job.expect("ap_done_in_flight", "pass").expect("cp_done", "covered")
        job.expect("cp_two_results", "covered")
        if unit == "npow":
            job.expect("ap_ready_when_idle", "pass").expect("ap_reset_launch_clear", "pass")
            job.expect("cp_done_computed", "covered")
        else:
            job.expect("ap_done_arrives", "pass")
        jobs.append(job)

    job = Job("mag_equiv", "mag", ZETA_MAG_ASSUME_NORMALIZED="1", **mag_eps)
    job.expect("ap_checker_matches_reference", "pass")
    job.expect("ap_checker_never_optimistic", "pass")
    for prop in ("cp_below", "cp_above_same_exponent", "cp_below_with_truncation"):
        job.expect(prop, "covered")
    jobs.append(job)

    # Without normalization the checker is only conservative.
    job = Job("mag_unnormalized", "mag", ZETA_MAG_ASSUME_NORMALIZED="0", **mag_eps)
    job.expect("ap_checker_matches_reference", "cex")
    job.expect("ap_checker_never_optimistic", "pass")
    jobs.append(job)
    return jobs


def load_golden() -> Golden:
    """Return golden(sigma_raw, t_raw) -> (z_re, z_im) packed."""
    sys.path.insert(0, str(REPO / "host"))
    try:
        import mpmath as mp

        from zetafpga.golden import mpfloat as mf
        from zetafpga.golden import zeta_em
        from zetafpga.kernel.em_setup import build_program, mpf_from_real
    except ImportError as error:
        # Carrying on would drop ap_matches_golden and every expectation derived
        # from the model, and still exit 0.
        sys.exit(
            f"Cannot import the bit-true model ({error}). Install mpmath, or pass "
            "--no-golden to generate the cases without ap_matches_golden."
        )
    fmt = mf.Format(limbs=1)

    def golden(sigma_raw: int, t_raw: int) -> tuple[int, int]:
        sigma = mpf_from_real(mp.mpf(sigma_raw) / (1 << FRAC), fmt)
        re, im, ovf, unf = zeta_em.zeta_em(build_program(sigma, t_raw << FRAC, fmt))
        if ovf or unf:
            raise ValueError(f"golden model saturated at {sigma_raw:#x}, {t_raw:#x}")
        return mf.pack(re, fmt), mf.pack(im, fmt)

    return golden


def host_n(t_raw: int) -> int:
    product = N_COEFFICIENT * (t_raw + (100 << FRAC))
    return 10 + ((product + (1 << 76) - 1) >> 76)


def rom_slice(t_raw_max: int, full_rom: bool) -> dict[str, str]:
    """Write the first N+1 rows of the ln(n) table, the rows a request up to t reads."""
    if full_rom:
        return {}
    rows = host_n(t_raw_max) + 1
    path = OUT / "rom" / f"entries_{rows}.mem"
    if not RELEASED_ROM.exists():
        sys.exit(f"Missing {RELEASED_ROM}. Run formal/euler_maclaurin/gen_tables.py first.")
    with RELEASED_ROM.open(encoding="ascii") as source:
        lines = list(islice(source, rows))
    if len(lines) != rows:
        sys.exit(f"{RELEASED_ROM} has fewer than {rows} rows")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(lines), encoding="ascii")
    return {"ZETA_ENTRY_ROWS": str(rows)}


def below_eps(word_re: int, word_im: int, eps_exp: int) -> bool:
    """Exact |z| < 2**eps_exp on packed Z64 words (width 64, 20-bit exponent)."""
    total = Fraction(0)
    for word in (word_re, word_im):
        if (word >> 86) & 1:
            return False
        if (word >> 85) & 1:
            continue
        mantissa = word & ((1 << 64) - 1)
        if mantissa == 0:
            continue
        if eps_exp <= -(1 << 19) - 64:
            return False
        if eps_exp >= (1 << 19):
            continue
        exponent = (word >> 64) & 0xFFFFF
        if exponent >> 19:
            exponent -= 1 << 20
        total += (Fraction(mantissa) * Fraction(2) ** (exponent - 64)) ** 2
    return total == 0 or total < Fraction(2) ** (2 * eps_exp)


def tolerance_steps(sigma_eps_exp: int) -> int:
    return 1 << min(max(sigma_eps_exp + FRAC, 0), 32)


def point_jobs(args: argparse.Namespace, golden: Golden | None) -> list[Job]:
    jobs = []
    limit = tolerance_steps(args.sigma_eps_exp)
    for zero, t_raw in ZERO_POINTS:
        if zero > args.zeros:
            continue
        for k in range(-args.offsets, args.offsets + 1):
            sigma_raw = SIGMA_HALF + k
            side = "m" if k < 0 else "p"
            job = Job(
                f"pt_z{zero:02d}_t{t_raw:06x}_{side}{abs(k)}",
                "e2e",
                ZETA_SIGMA_LO=f"32'h{sigma_raw:08x}",
                ZETA_SIGMA_HI=f"32'h{sigma_raw:08x}",
                ZETA_T_LO=f"32'h{t_raw:08x}",
                ZETA_T_HI=f"32'h{t_raw:08x}",
                ZETA_EPS_EXP=str(args.eps_exp),
                ZETA_EPS_FROM_RE_ONEHALF_EXP=str(args.sigma_eps_exp),
                **rom_slice(t_raw, args.full_rom),
            )
            job.expect("cp_result", "covered")
            for prop in E2E_ASSERTS:
                job.expect(prop, "pass")
            if golden is not None:
                z_re, z_im = golden(sigma_raw, t_raw)
                job.env["ZETA_EXPECT_RE"] = f"87'h{z_re:022x}"
                job.env["ZETA_EXPECT_IM"] = f"87'h{z_im:022x}"
                small = below_eps(z_re, z_im, args.eps_exp)
                job.expect("ap_matches_golden", "pass")
                job.expect("cp_small_result", "covered" if small else "uncovered")
                job.expect(
                    "ap_small_implies_near_half", "cex" if small and abs(k) >= limit else "pass"
                )
            else:
                job.expect("cp_small_result", "observe")
                job.expect("ap_small_implies_near_half", "observe")
            jobs.append(job)
    return jobs


def window_jobs(args: argparse.Namespace, golden: Golden | None) -> list[Job]:
    """Sigma symbolic over a few steps around 1/2 at a fixed t. Experimental."""
    jobs = []
    limit = tolerance_steps(args.sigma_eps_exp)
    for zero, t_raw in ZERO_POINTS:
        if zero > args.window_zeros:
            continue
        job = Job(
            f"win_z{zero:02d}_t{t_raw:06x}_w{args.window}",
            "e2e",
            ZETA_SIGMA_LO=f"32'h{SIGMA_HALF - args.window:08x}",
            ZETA_SIGMA_HI=f"32'h{SIGMA_HALF + args.window:08x}",
            ZETA_T_LO=f"32'h{t_raw:08x}",
            ZETA_T_HI=f"32'h{t_raw:08x}",
            ZETA_EPS_EXP=str(args.eps_exp),
            ZETA_EPS_FROM_RE_ONEHALF_EXP=str(args.sigma_eps_exp),
            **rom_slice(t_raw, args.full_rom),
        )
        for prop in E2E_ASSERTS:
            job.expect(prop, "pass")
        job.expect("cp_result", "covered")
        if golden is not None and args.window <= MAX_GOLDEN_WINDOW:
            # The bit-true model at every sigma of the window decides both outcomes.
            small = [
                k
                for k in range(-args.window, args.window + 1)
                if below_eps(*golden(SIGMA_HALF + k, t_raw), args.eps_exp)
            ]
            job.expect("cp_small_result", "covered" if small else "uncovered")
            job.expect(
                "ap_small_implies_near_half",
                "cex" if any(abs(k) >= limit for k in small) else "pass",
            )
        else:
            job.expect("cp_small_result", "observe")
            job.expect("ap_small_implies_near_half", "observe")
        jobs.append(job)
    return jobs


def zero_t_below(zero: int) -> int:
    """Largest Q16.16 grid value of t below the ordinate of the given zero."""
    try:
        import mpmath as mp
    except ImportError:
        sys.exit("Sign-box cases need mpmath to locate the zeros; pass --box-zeros 0.")
    with mp.workdps(40):
        return int(mp.floor(mp.zetazero(zero).imag * (1 << FRAC)))


def word_value(word: int) -> Fraction | None:
    """Exact value of a packed Z64 word, None for a special."""
    if (word >> 86) & 1:
        return None
    mantissa = word & ((1 << 64) - 1)
    if (word >> 85) & 1 or mantissa == 0:
        return Fraction(0)
    exponent = (word >> 64) & 0xFFFFF
    if exponent >> 19:
        exponent -= 1 << 20
    value = Fraction(mantissa) * Fraction(2) ** (exponent - 64)
    return -value if (word >> 84) & 1 else value


def points_opposite(a: tuple[int, int], b: tuple[int, int]) -> bool:
    """Re(a * conj(b)) < 0 for packed (re, im) pairs, as the harness computes it."""
    values = [word_value(word) for word in (*a, *b)]
    if any(value is None for value in values):
        return False
    a_re, a_im, b_re, b_im = (value for value in values if value is not None)
    return a_re * b_re + a_im * b_im < 0


def box_jobs(args: argparse.Namespace, golden: Golden | None) -> list[Job]:
    """The grid cell around a zero: four corners and the middle column."""
    jobs = []
    limit = tolerance_steps(args.sigma_eps_exp)
    step = args.box_sigma
    for zero in range(1, args.box_zeros + 1):
        t_lo = zero_t_below(zero)
        t_hi = t_lo + 1
        corners = [
            (SIGMA_HALF - step, t_lo),
            (SIGMA_HALF + step, t_lo),
            (SIGMA_HALF - step, t_hi),
            (SIGMA_HALF + step, t_hi),
            (SIGMA_HALF, t_lo),
            (SIGMA_HALF, t_hi),
        ]
        job = Job(
            f"box_z{zero:02d}_t{t_lo:06x}_s{step}",
            "e2e",
            ZETA_SIGN_BOX="1",
            ZETA_SIGMA_LO=f"32'h{SIGMA_HALF - step:08x}",
            ZETA_SIGMA_HI=f"32'h{SIGMA_HALF + step:08x}",
            ZETA_T_LO=f"32'h{t_lo:08x}",
            ZETA_T_HI=f"32'h{t_hi:08x}",
            ZETA_EPS_EXP=str(args.eps_exp),
            ZETA_EPS_FROM_RE_ONEHALF_EXP=str(args.sigma_eps_exp),
            **rom_slice(t_hi, args.full_rom),
        )
        for prop in E2E_ASSERTS:
            job.expect(prop, "pass")
        job.expect("ap_box_six_results", "pass")
        job.expect("cp_result", "covered").expect("cp_box_done", "covered")
        if golden is None:
            for prop in (
                "cp_small_result",
                "ap_small_implies_near_half",
                "ap_opposite_across_sigma",
                "ap_opposite_across_t",
            ):
                job.expect(prop, "observe")
            jobs.append(job)
            continue
        words = [golden(sigma_raw, t_raw) for sigma_raw, t_raw in corners]
        job.env["ZETA_BOX_EXPECT_RE"] = "522'h" + format(
            sum(re << (87 * i) for i, (re, _) in enumerate(words)), "0131x"
        )
        job.env["ZETA_BOX_EXPECT_IM"] = "522'h" + format(
            sum(im << (87 * i) for i, (_, im) in enumerate(words)), "0131x"
        )
        job.expect("ap_box_matches_golden", "pass")
        small = [below_eps(re, im, args.eps_exp) for re, im in words]
        job.expect("cp_small_result", "covered" if any(small) else "uncovered")
        # Only the corners lie off the line.
        job.expect(
            "ap_small_implies_near_half",
            "cex" if any(small[:4]) and step >= limit else "pass",
        )
        across_sigma = points_opposite(words[0], words[1]) and points_opposite(words[2], words[3])
        job.expect("ap_opposite_across_sigma", "pass" if across_sigma else "cex")
        job.expect("ap_opposite_across_t", "pass" if points_opposite(words[4], words[5]) else "cex")
        jobs.append(job)
    return jobs


def symbolic_box_job() -> Job:
    """Leave the box coordinates symbolic and report the centered assertion's outcome."""
    job = Job("box_symbolic", "e2e", ZETA_SYMBOLIC_BOX="1")
    for prop in (
        *E2E_ASSERTS,
        "ap_box_six_results",
        "ap_symbolic_box_request_order",
        "ap_symbolic_box_completes",
    ):
        job.expect(prop, "pass")
    for prop in ("cp_result", "cp_box_done", "cp_first_zero_box"):
        job.expect(prop, "covered")
    job.expect("ap_opposite_box_centered", "observe")
    return job


def check_points() -> None:
    """Recompute ZERO_POINTS from the true zeta function with mpmath."""
    import mpmath as mp

    with mp.workdps(40):
        threshold = mp.mpf(2) ** -FRAC
        found = []
        for zero in range(1, 51):
            low = int(mp.floor(mp.zetazero(zero).imag * (1 << FRAC)))
            # The two grid points around the ordinate. The next ones out are
            # scanned too and must not be small.
            for t_raw in range(low - 1, low + 3):
                if abs(mp.zeta(mp.mpc(0.5, mp.mpf(t_raw) / (1 << FRAC)))) < threshold:
                    found.append((zero, t_raw))
    if found != ZERO_POINTS:
        missing = sorted(set(found) - set(ZERO_POINTS))
        extra = sorted(set(ZERO_POINTS) - set(found))
        sys.exit(f"ZERO_POINTS disagrees with mpmath: missing {missing}, not small {extra}")
    print(f"ZERO_POINTS matches mpmath ({len(found)} points)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--zeros", type=int, default=50, help="use zeros 1..ZEROS (max 50)")
    parser.add_argument(
        "--offsets",
        type=int,
        default=1,
        help="sigma offsets -OFFSETS..OFFSETS Q16.16 steps around 1/2",
    )
    parser.add_argument(
        "--window",
        type=int,
        default=4,
        help="half width in steps of the symbolic-sigma window jobs",
    )
    parser.add_argument(
        "--window-zeros", type=int, default=1, help="window jobs for zeros 1..N (0 for none)"
    )
    parser.add_argument("--eps-exp", type=int, default=-16)
    parser.add_argument("--sigma-eps-exp", type=int, default=None, help="defaults to --eps-exp")
    parser.add_argument(
        "--box-zeros", type=int, default=1, help="sign-box cases for zeros 1..N (0 for none)"
    )
    parser.add_argument(
        "--box-sigma",
        type=int,
        default=1,
        help="sign-box sigma half width in Q16.16 steps around 1/2",
    )
    parser.add_argument(
        "--symbolic-box", action="store_true", help="add a released sign-box case after fixed boxes"
    )
    parser.add_argument("--no-golden", action="store_true")
    parser.add_argument(
        "--check-points", action="store_true", help="recompute ZERO_POINTS with mpmath and exit"
    )
    parser.add_argument(
        "--full-rom", action="store_true", help="use the full ln(n) table instead of per-N slices"
    )
    args = parser.parse_args()
    if args.check_points:
        check_points()
        return
    if args.sigma_eps_exp is None:
        args.sigma_eps_exp = args.eps_exp
    if not (0 <= args.zeros <= 50 and 0 <= args.window_zeros <= 50):
        parser.error("--zeros and --window-zeros must be between 0 and 50")
    if not 0 <= args.box_zeros <= 50 or not 1 <= args.box_sigma < SIGMA_HALF:
        parser.error("--box-zeros must be between 0 and 50, --box-sigma between 1 and 32767")
    if not (0 <= args.offsets < SIGMA_HALF and 0 <= args.window < SIGMA_HALF):
        parser.error("--offsets and --window must keep sigma in its legal domain")
    if not all(
        -(1 << 31) <= exponent < (1 << 31) for exponent in (args.eps_exp, args.sigma_eps_exp)
    ):
        parser.error("threshold exponents must fit a signed 32-bit integer")

    # The controller, unit and magnitude cases need no model.
    needs_model = args.zeros > 0 or args.window_zeros > 0 or args.box_zeros > 0
    golden = load_golden() if needs_model and not args.no_golden else None
    jobs = (
        fixed_jobs(args.eps_exp)
        + point_jobs(args, golden)
        + window_jobs(args, golden)
        + box_jobs(args, golden)
    )
    if args.symbolic_box:
        jobs.append(symbolic_box_job())

    OUT.mkdir(parents=True, exist_ok=True)
    with (OUT / "jobs.tsv").open("w", encoding="ascii") as out:
        for job in jobs:
            out.write("\t".join(f"{name}={value}" for name, value in job.env.items()) + "\n")
    with (OUT / "expected.tsv").open("w", encoding="ascii") as out:
        for job in jobs:
            for prop, outcome in job.expected:
                out.write(f"{job.name}\t{prop}\t{outcome}\n")
    print(f"{len(jobs)} cases in {OUT / 'jobs.tsv'}")


if __name__ == "__main__":
    main()
