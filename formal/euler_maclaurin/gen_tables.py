"""Generate the Z64 host payload ROMs used by the JasperGold experiment."""

import sys
from collections.abc import Callable, Iterable
from pathlib import Path

import mpmath as mp

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "host"))

from zetafpga.golden import mpfloat as mf
from zetafpga.kernel.em_setup import build_program, mpf_from_real, select_nm
from zetafpga.kernel.tables import lnn_table

FMT = mf.Format(limbs=1)
FRAC = 16
LN2PI_WIDTH = FMT.width + 64 + 8
LN_WIDTH = FMT.width + 24 + 8
MAX_T_RAW = (1 << 31) - 1
SEED_T_RAW = 0x000E227D
N_MIN = 38
N_MAX = 9118
M = 50

# Z64 host select_nm coefficient r/(2*pi), rounded at 60 fractional bits.
# The harness uses the same coefficient. The transition check below verifies
# that this rounding preserves the host's N on the entire signed Q16.16 grid.
N_COEFFICIENT = 0x046F057EF67CC9A1
N_SHIFT = 60 + FRAC


def fixed_n(t_raw: int) -> int:
    product = N_COEFFICIENT * (t_raw + (2 * M << FRAC))
    return 10 + ((product + (1 << N_SHIFT) - 1) >> N_SHIFT)


def host_n(t_raw: int) -> int:
    n, m = select_nm(t_raw / (1 << FRAC), FMT.width)
    if m != M:
        raise ValueError(f"expected host M={M}, got {m}")
    return n


def first_t_for_n(n_at: Callable[[int], int], n: int) -> int:
    low, high = 0, MAX_T_RAW
    while low < high:
        mid = (low + high) // 2
        if n_at(mid) < n:
            low = mid + 1
        else:
            high = mid
    return low


def check_n_selection() -> None:
    # Both functions are monotone, so equal endpoints and transition locations
    # imply equality for every input, without enumerating 2**31 points.
    for n_at in (host_n, fixed_n):
        if (n_at(0), n_at(MAX_T_RAW)) != (N_MIN, N_MAX):
            raise ValueError("Z64 N bounds disagree with the harness")
    for n in range(N_MIN + 1, N_MAX + 1):
        if first_t_for_n(host_n, n) != first_t_for_n(fixed_n, n):
            raise ValueError(f"Z64 N transition disagrees with the host at N={n}")


def write_words(path: Path, words: Iterable[int], bits: int) -> None:
    digits = (bits + 3) // 4
    with path.open("w", encoding="ascii") as mem:
        for word in words:
            mem.write(f"{word:0{digits}x}\n")


def main() -> None:
    check_n_selection()

    directed = build_program(mpf_from_real(mp.mpf("0.5"), FMT), SEED_T_RAW << FRAC, FMT)
    if (directed.n, directed.m) != (42, M):
        raise ValueError("directed host configuration disagrees with the harness")

    out = REPO / "sim_build" / "zeta_formal"
    out.mkdir(parents=True, exist_ok=True)

    for kind, entries in (
        ("directed", directed.entries),
        ("released", lnn_table(N_MAX + 1, FMT, LN2PI_WIDTH - 8)),
    ):
        # First row is ln(1). The driver reads each transaction's N+1 entry twice.
        words = ((lnn_fx << LN2PI_WIDTH) | lnn2pi for lnn_fx, lnn2pi in entries)
        write_words(out / f"entries_{kind}.mem", words, LN_WIDTH + LN2PI_WIDTH)

    with mp.workprec(2 * FMT.width + 64):
        # First row is N=38, matching the lower bound of the harness ROM.
        inv_np2 = (mpf_from_real(1 / mp.mpf(n + 1) ** 2, FMT) for n in range(N_MIN, N_MAX + 1))
        write_words(out / "inv_np2.mem", (mf.pack(v, FMT) for v in inv_np2), FMT.mpw)
    # First row is the j=1 coefficient B_2/2!.
    write_words(out / "bern.mem", (mf.pack(v, FMT) for v in directed.bern), FMT.mpw)


if __name__ == "__main__":
    main()
