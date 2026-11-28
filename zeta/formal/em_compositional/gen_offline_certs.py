"""Prepare Arb enclosures and candidate RTL checks for a Q16.16 rectangle.

The four raw bounds are inclusive. The sigma = 1/2 column is omitted.
Each resolved tile supplies an analytic enclosure, candidate RTL bounds
and a conditional component error bound. Jasper must establish the RTL
bounds and completion independently. An unresolved tile contributes no
candidate job.

Use --check DIR to check the archived partition, exact arithmetic and TSV
association. This trusts the archived Arb intervals. Add --reevaluate to
recompute the candidate tiles with Arb at the recorded precision and check
the same RTL/error bounds against the fresh enclosures.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import deque
from collections.abc import Iterator
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

FRAC = 16
SIGMA_HALF = 1 << (FRAC - 1)
SIGMA_MAX = (1 << FRAC) - 1
T_MAX = (1 << 31) - 1
WIDTH = 64
EXPW = 20
SCHEMA_VERSION = 1
COMPONENTS = ("real", "imag")
PASS_PROPERTIES = (
    "ap_result_has_request",
    "ap_rom_covers_request",
    "ap_flags_clear",
    "ap_result_normalized",
    "ap_offline_request_legal",
    "ap_offline_single_result",
    "ap_offline_completes",
    "ap_offline_rtl_enclosure",
    "ap_offline_excludes_zero",
)
COVER_PROPERTIES = ("cp_result", "cp_offline_result")

Interval = tuple[Fraction, Fraction]
Projections = tuple[Interval | None, Interval | None]


def power_of_two(exponent: int) -> Fraction:
    return Fraction(1 << exponent) if exponent >= 0 else Fraction(1, 1 << -exponent)


def integer(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{label} must be an integer")
    return value


def dyadic(value: Fraction) -> list[str | int]:
    denominator = value.denominator
    if denominator & (denominator - 1):
        raise ValueError("expected an exact dyadic")
    return [str(value.numerator), 1 - denominator.bit_length()]


def read_dyadic(value: object) -> Fraction:
    if (
        not isinstance(value, list)
        or len(value) != 2
        or not isinstance(value[0], str)
        or not re.fullmatch(r"-?(0|[1-9][0-9]*)", value[0])
    ):
        raise ValueError("invalid archived dyadic")
    exponent = integer(value[1], "dyadic exponent")
    if not -(1 << 20) <= exponent <= 0:
        raise ValueError("archived dyadic exponent is out of range")
    return Fraction(int(value[0])) * power_of_two(exponent)


@dataclass(frozen=True)
class Rectangle:
    sigma_lo: int
    sigma_hi: int
    t_lo: int
    t_hi: int

    def __post_init__(self) -> None:
        if not 1 <= self.sigma_lo <= self.sigma_hi <= SIGMA_MAX:
            raise ValueError("sigma bounds must be ordered and in [1, 0xffff]")
        if not 0 <= self.t_lo <= self.t_hi <= T_MAX:
            raise ValueError("t bounds must be ordered and in [0, 0x7fffffff]")

    @property
    def count(self) -> int:
        return (self.sigma_hi - self.sigma_lo + 1) * (self.t_hi - self.t_lo + 1)

    def raw(self) -> dict[str, int]:
        return {
            "sigma_lo": self.sigma_lo,
            "sigma_hi": self.sigma_hi,
            "t_lo": self.t_lo,
            "t_hi": self.t_hi,
        }

    @classmethod
    def from_raw(cls, value: object) -> Rectangle:
        if not isinstance(value, dict):
            raise ValueError("expected a rectangle of raw Q16.16 bounds")
        bounds = {
            key: integer(value.get(key), key)
            for key in ("sigma_lo", "sigma_hi", "t_lo", "t_hi")
        }
        return cls(**bounds)

    def off_line_roots(self) -> Iterator[tuple[str, Rectangle]]:
        if self.sigma_lo < SIGMA_HALF:
            yield "L", Rectangle(
                self.sigma_lo, min(self.sigma_hi, SIGMA_HALF - 1), self.t_lo, self.t_hi
            )
        if SIGMA_HALF < self.sigma_hi:
            yield "R", Rectangle(
                max(self.sigma_lo, SIGMA_HALF + 1), self.sigma_hi, self.t_lo, self.t_hi
            )

    def split(self) -> tuple[Rectangle, Rectangle]:
        if self.count == 1:
            raise ValueError("a singleton tile cannot be split")
        if self.sigma_hi - self.sigma_lo >= self.t_hi - self.t_lo:
            mid = (self.sigma_lo + self.sigma_hi) // 2
            return (
                Rectangle(self.sigma_lo, mid, self.t_lo, self.t_hi),
                Rectangle(mid + 1, self.sigma_hi, self.t_lo, self.t_hi),
            )
        mid = (self.t_lo + self.t_hi) // 2
        return (
            Rectangle(self.sigma_lo, self.sigma_hi, self.t_lo, mid),
            Rectangle(self.sigma_lo, self.sigma_hi, mid + 1, self.t_hi),
        )


def mpf_value(word: int) -> Fraction:
    """Decode a positive, finite normalized Z64 word."""
    if not 0 <= word < 1 << (WIDTH + EXPW):
        raise ValueError("Z64 bounds must have clear flags and sign")
    mantissa = word & ((1 << WIDTH) - 1)
    if mantissa < 1 << (WIDTH - 1):
        raise ValueError("Z64 bound mantissa must be normalized")
    exponent = word >> WIDTH
    if exponent >= 1 << (EXPW - 1):
        exponent -= 1 << EXPW
    return Fraction(mantissa) * power_of_two(exponent - WIDTH)


def mpf_round(value: Fraction, *, up: bool) -> int:
    """Round an exact positive bound to a normalized Z64 word."""
    if value <= 0:
        raise ValueError("Z64 bound must be positive")
    power = value.numerator.bit_length() - value.denominator.bit_length()
    if value < power_of_two(power):
        power -= 1
    exponent = power + 1
    scaled = value * power_of_two(WIDTH - exponent)
    mantissa, remainder = divmod(scaled.numerator, scaled.denominator)
    if up and remainder:
        mantissa += 1
    if mantissa == 1 << WIDTH:
        mantissa >>= 1
        exponent += 1
    if not -(1 << (EXPW - 1)) <= exponent < 1 << (EXPW - 1):
        raise ValueError("bound does not fit the Z64 exponent range")
    return ((exponent & ((1 << EXPW) - 1)) << WIDTH) | mantissa


def word_literal(word: int) -> str:
    return f"87'h{word:022x}"


def read_word(value: object) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"87'h[0-9a-f]{22}", value):
        raise ValueError("expected a packed Z64 bound")
    return int(value[4:], 16)


def magnitude(interval: Interval, negative: bool) -> Interval:
    lo, hi = interval
    return (-hi, -lo) if negative else (lo, hi)


@dataclass(frozen=True)
class Candidate:
    component: int
    negative: bool
    rtl_lo: int
    rtl_hi: int
    error: int

    def validate(self, projection: Interval | None) -> Fraction:
        if projection is None:
            raise ValueError("candidate has no finite analytic projection")
        a, b = magnitude(projection, self.negative)
        lo, hi, error = map(mpf_value, (self.rtl_lo, self.rtl_hi, self.error))
        if not 0 < lo <= a <= b <= hi:
            raise ValueError("candidate does not contain the signed analytic projection")
        if not max(hi - a, b - lo) <= error < lo:
            raise ValueError("candidate error bound is insufficient or does not exclude zero")
        return lo - error

    def archived(self) -> dict[str, object]:
        return {
            "component": COMPONENTS[self.component],
            "negative": self.negative,
            "rtl_lo_word": word_literal(self.rtl_lo),
            "rtl_hi_word": word_literal(self.rtl_hi),
            "error_word": word_literal(self.error),
            "rtl_magnitude_dyadic": [dyadic(mpf_value(w)) for w in (self.rtl_lo, self.rtl_hi)],
            "error_dyadic": dyadic(mpf_value(self.error)),
        }

    @classmethod
    def from_archive(cls, value: object) -> Candidate:
        if not isinstance(value, dict):
            raise ValueError("expected a candidate")
        component = value.get("component")
        negative = value.get("negative")
        if component not in COMPONENTS or not isinstance(negative, bool):
            raise ValueError("invalid candidate projection")
        candidate = cls(
            COMPONENTS.index(component),
            negative,
            read_word(value.get("rtl_lo_word")),
            read_word(value.get("rtl_hi_word")),
            read_word(value.get("error_word")),
        )
        if candidate.archived() != value:
            raise ValueError("packed candidate values disagree with archived dyadics")
        return candidate


def choose_candidate(projections: Projections) -> Candidate | None:
    best: Candidate | None = None
    best_margin = Fraction(0)
    for component, projection in enumerate(projections):
        if projection is None:
            continue
        negative = projection[1] < 0
        a, b = magnitude(projection, negative)
        # Before MPF rounding, a projection with width less than a has room
        # for an outer interval and an error bound strictly below its lower end.
        slack = 2 * a - b
        if a <= 0 or slack <= 0:
            continue
        padding = slack / 4
        try:
            lo = mpf_round(a - padding, up=False)
            hi = mpf_round(b + padding, up=True)
            error = mpf_round(max(mpf_value(hi) - a, b - mpf_value(lo)), up=True)
            candidate = Candidate(component, negative, lo, hi, error)
            margin = candidate.validate(projection)
        except ValueError:
            continue
        if margin > best_margin:
            best, best_margin = candidate, margin
    return best


@contextmanager
def arb_precision(precision: int) -> Iterator[str]:
    try:
        from flint import __version__, ctx
    except ImportError as error:
        raise ValueError(
            "Arb evaluation requires python-flint (the project's arb extra)"
        ) from error
    previous = ctx.prec
    ctx.prec = precision
    try:
        yield str(__version__)
    finally:
        ctx.prec = previous


def arb_projections(rectangle: Rectangle) -> Projections:
    from flint import acb, arb

    def coordinate(lo: int, hi: int) -> Any:
        # (integer, exponent) is exact dyadic input; Arb rounds radii upwards.
        return arb((lo + hi, -FRAC - 1), (hi - lo, -FRAC - 1))

    def endpoint(bound: Any) -> Fraction:
        mantissa, exponent = bound.man_exp()
        return Fraction(int(mantissa)) * power_of_two(int(exponent))

    def projection(ball: Any) -> Interval | None:
        if not ball.is_finite():
            return None
        return endpoint(ball.lower()), endpoint(ball.upper())

    zeta = acb(
        coordinate(rectangle.sigma_lo, rectangle.sigma_hi),
        coordinate(rectangle.t_lo, rectangle.t_hi),
    ).zeta()
    return projection(zeta.real), projection(zeta.imag)


def interval_archive(interval: Interval | None) -> list[list[str | int]] | None:
    return [dyadic(interval[0]), dyadic(interval[1])] if interval is not None else None


def read_interval(value: object) -> Interval | None:
    if value is None:
        return None
    if not isinstance(value, list) or len(value) != 2:
        raise ValueError("expected an archived interval")
    lo, hi = map(read_dyadic, value)
    if lo > hi:
        raise ValueError("archived projection bounds are inverted")
    return lo, hi


@dataclass(frozen=True)
class Tile:
    key: str
    rectangle: Rectangle
    projections: Projections | None
    candidate: Candidate | None
    unresolved_reason: str | None

    @property
    def job(self) -> str:
        return f"offline_cert_{self.key}"

    def archived(self) -> dict[str, object]:
        return {
            "tile": self.key,
            "bounds_raw": self.rectangle.raw(),
            "grid_points": self.rectangle.count,
            "analytic_projections_dyadic": (
                None if self.projections is None else {
                    name: interval_archive(interval)
                    for name, interval in zip(COMPONENTS, self.projections, strict=True)
                }
            ),
            "candidate": None if self.candidate is None else self.candidate.archived(),
            "unresolved_reason": self.unresolved_reason,
        }

    @classmethod
    def from_archive(cls, value: object) -> Tile:
        if not isinstance(value, dict):
            raise ValueError("expected an archived tile")
        key = value.get("tile")
        if not isinstance(key, str) or not re.fullmatch(r"[LR][01]{0,47}", key):
            raise ValueError("invalid tile identifier")
        rectangle = Rectangle.from_raw(value.get("bounds_raw"))
        if integer(value.get("grid_points"), "tile grid_points") != rectangle.count:
            raise ValueError(f"{key}: tile grid-point count disagrees with bounds")
        raw_projections = value.get("analytic_projections_dyadic")
        projections = None
        if raw_projections is not None:
            if not isinstance(raw_projections, dict) or set(raw_projections) != set(COMPONENTS):
                raise ValueError(f"{key}: invalid archived projections")
            projections = (
                read_interval(raw_projections["real"]),
                read_interval(raw_projections["imag"]),
            )
        raw_candidate = value.get("candidate")
        reason = value.get("unresolved_reason")
        if raw_candidate is not None:
            if projections is None or reason is not None:
                raise ValueError(f"{key}: inconsistent candidate record")
            candidate = Candidate.from_archive(raw_candidate)
            candidate.validate(projections[candidate.component])
            return cls(key, rectangle, projections, candidate, None)
        if projections is None and reason == "tile_budget_exhausted":
            return cls(key, rectangle, None, None, reason)
        if projections is not None and rectangle.count == 1 and reason == "no_usable_projection":
            return cls(key, rectangle, projections, None, reason)
        raise ValueError(f"{key}: inconsistent unresolved tile")


def make_tiles(requested: Rectangle, max_tiles: int) -> list[Tile]:
    pending = deque(requested.off_line_roots())
    finished = []
    for _ in range(max_tiles):
        if not pending:
            break
        key, rectangle = pending.popleft()
        projections = arb_projections(rectangle)
        candidate = choose_candidate(projections)
        if candidate is not None:
            finished.append(Tile(key, rectangle, projections, candidate, None))
        elif rectangle.count == 1:
            finished.append(Tile(key, rectangle, projections, None, "no_usable_projection"))
        else:
            lo, hi = rectangle.split()
            pending.append((key + "0", lo))
            pending.append((key + "1", hi))
    finished.extend(
        Tile(key, rectangle, None, None, "tile_budget_exhausted") for key, rectangle in pending
    )
    return sorted(finished, key=lambda tile: tile.key)


def coverage(requested: Rectangle, tiles: list[Tile]) -> dict[str, int]:
    leaves = {tile.key: tile for tile in tiles}
    if len(leaves) != len(tiles):
        raise ValueError("duplicate tile identifier")
    parents = {tile.key[:i] for tile in tiles for i in range(1, len(tile.key))}
    pending = list(requested.off_line_roots())
    visited = set()
    internal_count = 0
    while pending:
        key, rectangle = pending.pop()
        if key in leaves:
            if leaves[key].rectangle != rectangle:
                raise ValueError(f"{key}: bounds disagree with the disjoint partition")
            visited.add(key)
        elif key in parents:
            lo, hi = rectangle.split()
            pending.extend(((key + "0", lo), (key + "1", hi)))
            internal_count += 1
        else:
            raise ValueError(f"{key}: missing part of the requested domain")
    if visited != set(leaves):
        raise ValueError("tile lies outside the partition or overlaps an ancestor")
    off_line = sum(rectangle.count for _, rectangle in requested.off_line_roots())
    candidate = sum(tile.rectangle.count for tile in tiles if tile.candidate is not None)
    unresolved = sum(tile.rectangle.count for tile in tiles if tile.candidate is None)
    if candidate + unresolved != off_line:
        raise ValueError("tile counts do not cover the requested off-line domain")
    return {
        "requested_grid_points": requested.count,
        "excluded_center_grid_points": requested.count - off_line,
        "off_line_grid_points": off_line,
        "candidate_grid_points": candidate,
        "unresolved_grid_points": unresolved,
        "rtl_verified_grid_points": 0,
        "evaluated_tiles": internal_count + sum(tile.projections is not None for tile in tiles),
        "candidate_tiles": sum(tile.candidate is not None for tile in tiles),
        "unresolved_tiles": sum(tile.candidate is None for tile in tiles),
    }


def manifest(tiles: list[Tile]) -> tuple[str, str]:
    jobs, expected = [], []
    for tile in tiles:
        candidate = tile.candidate
        if candidate is None:
            continue
        options = {
            "ZETA_KIND": "e2e",
            "ZETA_JOB": tile.job,
            "ZETA_CERTIFY_OFFLINE": "1",
            **{
                f"ZETA_{key.upper()}": f"32'h{value:08x}"
                for key, value in tile.rectangle.raw().items()
            },
            "ZETA_CERT_COMPONENT": str(candidate.component),
            "ZETA_CERT_NEGATIVE": str(int(candidate.negative)),
            "ZETA_CERT_RTL_LO": word_literal(candidate.rtl_lo),
            "ZETA_CERT_RTL_HI": word_literal(candidate.rtl_hi),
            "ZETA_CERT_ERROR": word_literal(candidate.error),
        }
        jobs.append("\t".join(f"{name}={value}" for name, value in options.items()) + "\n")
        expected.extend(f"{tile.job}\t{prop}\tpass\n" for prop in PASS_PROPERTIES)
        expected.extend(f"{tile.job}\t{prop}\tcovered\n" for prop in COVER_PROPERTIES)
    return "".join(jobs), "".join(expected)


def check_bundle(
    directory: Path, *, reevaluate: bool
) -> tuple[dict[str, int], dict[str, int]]:
    payload: object = json.loads((directory / "certificates.json").read_text(encoding="ascii"))
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported certificates.json schema")
    if integer(payload.get("q_fraction_bits"), "q_fraction_bits") != FRAC:
        raise ValueError("unsupported archived Q format")
    requested = Rectangle.from_raw(payload.get("requested_bounds_raw"))
    raw_tiles = payload.get("tiles")
    if not isinstance(raw_tiles, list):
        raise ValueError("missing tile records")
    tiles = [Tile.from_archive(tile) for tile in raw_tiles]
    counts = coverage(requested, tiles)
    if payload.get("coverage") != counts:
        raise ValueError("archived coverage counts disagree with the partition")
    budget = integer(payload.get("max_tiles"), "max_tiles")
    if budget < 1 or counts["evaluated_tiles"] > budget:
        raise ValueError("invalid archived tile budget")
    if any(tile.projections is None for tile in tiles) and counts["evaluated_tiles"] != budget:
        raise ValueError("unexamined tiles recorded before the budget was exhausted")
    precision = integer(payload.get("arb_precision_bits"), "arb_precision_bits")
    if not 64 <= precision <= 4096:
        raise ValueError("archived Arb precision is out of range")
    jobs, expected = manifest(tiles)
    for name, content in (("jobs.tsv", jobs), ("expected.tsv", expected)):
        if (directory / name).read_bytes() != content.encode("ascii"):
            raise ValueError(f"{name} disagrees with certificates.json")
    if reevaluate:
        with arb_precision(precision):
            for tile in tiles:
                if tile.candidate is not None:
                    fresh = arb_projections(tile.rectangle)
                    tile.candidate.validate(fresh[tile.candidate.component])
    checked = "fresh Arb enclosures" if reevaluate else "archived Arb enclosures"
    print(f"Checked partition, bounds and manifests using {checked}. No RTL results checked.")
    print_counts(counts)
    candidate_points = {
        tile.job: tile.rectangle.count for tile in tiles if tile.candidate is not None
    }
    return counts, candidate_points


def print_counts(counts: dict[str, int]) -> None:
    print(
        f"{counts['candidate_grid_points']} candidate points in {counts['candidate_tiles']} tiles; "
        f"{counts['unresolved_grid_points']} unresolved points in "
        f"{counts['unresolved_tiles']} tiles; "
        f"{counts['excluded_center_grid_points']} center-column points excluded."
    )


def write_bundle(directory: Path, requested: Rectangle, precision: int, max_tiles: int) -> None:
    if directory.exists() or directory.is_symlink():
        raise ValueError(f"output directory already exists: {directory}")
    with arb_precision(precision) as version:
        tiles = make_tiles(requested, max_tiles)
    counts = coverage(requested, tiles)
    jobs, expected = manifest(tiles)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "q_fraction_bits": FRAC,
        "arb_python_flint_version": version,
        "arb_precision_bits": precision,
        "max_tiles": max_tiles,
        "requested_bounds_raw": requested.raw(),
        "coverage": counts,
        "tiles": [tile.archived() for tile in tiles],
    }

    directory.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=directory.parent, prefix=".offline-certs-") as temporary:
        bundle = Path(temporary) / "bundle"
        bundle.mkdir()
        (bundle / "jobs.tsv").write_text(jobs, encoding="ascii")
        (bundle / "expected.tsv").write_text(expected, encoding="ascii")
        (bundle / "certificates.json").write_text(
            json.dumps(payload, indent=2) + "\n", encoding="ascii"
        )
        # Reserve a new destination so an existing bundle is never overwritten.
        directory.mkdir()
        try:
            bundle.replace(directory)
        except OSError:
            with suppress(OSError):
                directory.rmdir()
            raise
    print(f"Wrote candidate bundle to {directory}. No RTL results checked.")
    print_counts(counts)


def raw_value(literal: str) -> int:
    return int(literal, 16 if literal.lower().startswith("0x") else 10)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    for bound in ("sigma-lo", "sigma-hi", "t-lo", "t-hi"):
        parser.add_argument(f"--{bound}", type=raw_value, help="inclusive raw Q16.16 bound")
    parser.add_argument("--out-dir", type=Path, help="new directory for the candidate bundle")
    parser.add_argument("--precision", type=int, help="Arb precision in bits (default: 128)")
    parser.add_argument("--max-tiles", type=int, help="maximum Arb tile evaluations (default: 256)")
    parser.add_argument(
        "--check", type=Path, help="verify an archived bundle's partition and bounds"
    )
    parser.add_argument(
        "--reevaluate", action="store_true", help="recheck candidate tiles with Arb"
    )
    args = parser.parse_args()
    bounds = (args.sigma_lo, args.sigma_hi, args.t_lo, args.t_hi)
    try:
        if args.check is not None:
            if any(
                value is not None
                for value in (*bounds, args.out_dir, args.precision, args.max_tiles)
            ):
                parser.error("--check uses the existing bundle's bounds, precision and tile budget")
            check_bundle(args.check, reevaluate=args.reevaluate)
        else:
            if args.reevaluate:
                parser.error("--reevaluate requires --check")
            if args.out_dir is None or any(bound is None for bound in bounds):
                parser.error("generation needs all four raw bounds and --out-dir")
            precision = 128 if args.precision is None else args.precision
            max_tiles = 256 if args.max_tiles is None else args.max_tiles
            if not 64 <= precision <= 4096 or max_tiles < 1:
                parser.error("expected 64 <= --precision <= 4096 and --max-tiles >= 1")
            write_bundle(args.out_dir, Rectangle(*bounds), precision, max_tiles)
    except (ValueError, OSError) as error:
        print(f"gen_offline_certs.py: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
