"""Benchmark one offline certificate manifest under two Jasper ProofGrid profiles."""

import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from time import monotonic

from gen_offline_certs import COVER_PROPERTIES, PASS_PROPERTIES, check_bundle

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = REPO / "sim_build" / "zeta_compositional" / "benchmarks"
MANIFEST_FILES = ("jobs.tsv", "expected.tsv", "certificates.json")
TERMINAL = {
    **dict.fromkeys(PASS_PROPERTIES, "proven"),
    **dict.fromkeys(COVER_PROPERTIES, "covered"),
}
ROM_FORMATS = {
    "sim_build/zeta_formal/entries_released.mem": (9119, 58),
    "sim_build/zeta_formal/inv_np2.mem": (9081, 22),
    "sim_build/zeta_formal/bern.mem": (50, 22),
    "rtl/common/fn/tables/expln_w64_exp.mem": (24, 24),
    "rtl/common/fn/tables/cexp_w64.mem": (2049, 24),
}
WORKER_MENTION = re.compile(
    r"\b(?:(?:active|allocated|connected|running) (?:ProofGrid )?(?:workers?|hosts?)"
    r"\s*[:=]\s*\d+|\d+ (?:active|allocated|connected|running) (?:ProofGrid )?"
    r"(?:workers?|hosts?))\b",
    re.IGNORECASE,
)


def digest(path: Path) -> str:
    with path.open("rb") as data:
        return hashlib.file_digest(data, "sha256").hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def validate_roms() -> None:
    for name, (rows, digits) in ROM_FORMATS.items():
        words = (REPO / name).read_text(encoding="ascii").splitlines()
        word = re.compile(rf"[0-9a-fA-F]{{{digits}}}")
        if len(words) != rows or any(not word.fullmatch(value) for value in words):
            raise ValueError(f"{name} must contain {rows} rows of {digits} hex digits")


def proof_assets() -> dict[str, str]:
    roots = (REPO / "rtl", HERE, REPO / "formal" / "euler_maclaurin")
    sources = {
        source
        for root in roots
        for source in root.rglob("*")
        if source.is_file() and source.suffix in {".sv", ".svh", ".v", ".vh", ".tcl"}
    }
    sources.update((Path(__file__).resolve(), HERE / "summarize.py", HERE / "gen_offline_certs.py"))
    sources.update(REPO / rom for rom in ROM_FORMATS)
    return {str(path.relative_to(REPO)): digest(path) for path in sorted(sources)}


def revision() -> str | None:
    git = shutil.which("git")
    if git is None:
        return None
    result = subprocess.run(
        [git, "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=False
    )
    return result.stdout.strip() if result.returncode == 0 else None


def tile_result(path: Path, name: str) -> tuple[str, dict[str, str]]:
    statuses: dict[str, str] = {}
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            if len(fields) != 6 or fields[0] != name:
                return "unusable", statuses
            prop = fields[1].rsplit(".", 1)[-1]
            status = fields[3].strip().lower()
            if prop in statuses:
                return "unusable", statuses
            statuses[prop] = status
    if "cex" in statuses.values() or any(
        statuses.get(prop) == "unreachable" for prop in COVER_PROPERTIES
    ):
        return "contradiction", statuses
    if all(statuses.get(prop) == want for prop, want in TERMINAL.items()):
        return "conclusive", statuses
    return "open", statuses


def run_profile(
    directory: Path,
    jg: Path,
    site_tcl: Path,
    requested_capacity: int,
    environment: dict[str, str],
    tiles: dict[str, int],
) -> dict[str, object]:
    directory.mkdir()
    results = directory / "results"
    command = [
        str(jg),
        "-batch",
        str(HERE / "run_suite.tcl"),
        "-proj",
        str(directory / "jgproject"),
    ]
    env = {**environment, "ZETA_PROOFGRID_TCL": str(site_tcl), "ZETA_RESULTS_DIR": str(results)}
    log_path = directory / "jasper.log"
    started = datetime.now(UTC).isoformat()
    start = monotonic()
    with log_path.open("wb") as log, subprocess.Popen(
        command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT
    ) as process:
        jasper_exit = process.wait()
    elapsed = monotonic() - start
    with (directory / "summary.txt").open("wb") as log:
        if (results / "expected.tsv").is_file():
            summary_exit = subprocess.run(
                [sys.executable, str(HERE / "summarize.py"), str(results), "-v"],
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            ).returncode
        else:
            log.write(b"Jasper did not write the run's expected.tsv snapshot.\n")
            summary_exit = 3
    observations = []
    with log_path.open(encoding="utf-8", errors="replace") as log:
        for number, line in enumerate(log, 1):
            observations.extend(
                {"line": number, "report": match.group()} for match in WORKER_MENTION.finditer(line)
            )
    outcomes = {}
    property_names = {}
    conclusive = []
    for name, vectors in tiles.items():
        outcome, statuses = tile_result(results / f"{name}.tsv", name)
        outcomes[name] = {"outcome": outcome, "vectors": vectors, "statuses": statuses}
        property_names[name] = sorted(statuses)
        if outcome == "conclusive":
            conclusive.append(name)
    return {
        "command": command,
        "pid": process.pid,
        "started_utc": started,
        "elapsed_seconds": elapsed,
        "requested_profile_capacity": requested_capacity,
        "worker_mentions_in_jasper_log": observations,
        "jasper_exit": jasper_exit,
        "summary_exit": summary_exit,
        "conclusive_tiles": len(conclusive),
        "total_tiles": len(tiles),
        "conclusive_vectors": sum(tiles[name] for name in conclusive),
        "total_vectors": sum(tiles.values()),
        "all_manifest_tiles_conclusive": (
            jasper_exit == summary_exit == 0 and len(conclusive) == len(tiles)
        ),
        "reported_property_names": property_names,
        "tiles": outcomes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest-dir", required=True, type=Path)
    parser.add_argument("--one-worker-tcl", required=True, type=Path)
    parser.add_argument("--eighty-host-tcl", required=True, type=Path)
    parser.add_argument("--time-limit", required=True, help="shared Jasper proof limit, e.g. 30m")
    parser.add_argument("--output-root", type=Path, default=OUT)
    parser.add_argument("--jg", default=os.environ.get("ZETA_JG", "jg"))
    args = parser.parse_args()
    if args.time_limit.strip() in {"", "none"}:
        parser.error("--time-limit requires a finite Jasper limit")
    executable = shutil.which(args.jg)
    if executable is None:
        parser.error(f"JasperGold executable not found: {args.jg}")
    jg = Path(executable).resolve()
    profiles = (
        ("one-worker", 1, args.one_worker_tcl.resolve()),
        ("eighty-host", 80, args.eighty_host_tcl.resolve()),
    )
    sites = {label: digest(tcl) for label, _, tcl in profiles}
    if len(set(sites.values())) != len(profiles):
        parser.error("Provide two distinct site ProofGrid Tcl configurations")

    validate_roms()
    assets = proof_assets()
    commit = revision()
    args.output_root.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="offline-", dir=args.output_root.resolve()))
    print(f"Benchmark directory {run_dir}", flush=True)
    snapshot = run_dir / "manifest"
    snapshot.mkdir()
    manifest_assets = {name: digest(args.manifest_dir / name) for name in MANIFEST_FILES}
    for name in MANIFEST_FILES:
        shutil.copyfile(args.manifest_dir / name, snapshot / name)
        (snapshot / name).chmod(0o444)
    snapshot.chmod(0o555)
    coverage, tiles = check_bundle(snapshot, reevaluate=False)
    if not tiles:
        raise ValueError("The manifest contains no offline candidate tiles")
    settings = {
        "ZETA_PROVE_TIME_LIMIT": args.time_limit,
        "ZETA_MAX_TRACE_LENGTH": os.environ.get("ZETA_MAX_TRACE_LENGTH", ""),
        "ZETA_ENGINE_MODE": os.environ.get("ZETA_ENGINE_MODE", ""),
        "ZETA_RESET_ZERO": "0",
        "ZETA_ELABORATE_OPTIONS": "",
    }
    tool_digest = digest(jg)
    write_json(
        run_dir / "inputs.json",
        {
            "git_head": commit,
            "launch_host": socket.gethostname(),
            "proof_assets_sha256": assets,
            "manifest_sha256": manifest_assets,
            "jasper_executable_sha256": tool_digest,
            "proof_settings": settings,
            "site_profiles": {
                label: {
                    "requested_capacity": count,
                    "capacity_unit": "worker" if count == 1 else "hosts",
                    "tcl_basename": tcl.name,
                    "sha256": sites[label],
                }
                for label, count, tcl in profiles
            },
        },
    )

    def check_inputs() -> None:
        if (
            assets != proof_assets()
            or commit != revision()
            or tool_digest != digest(jg)
            or manifest_assets != {name: digest(snapshot / name) for name in MANIFEST_FILES}
            or sites != {label: digest(tcl) for label, _, tcl in profiles}
        ):
            raise ValueError("A proof input changed during the benchmark")

    environment = {**os.environ, **settings, "ZETA_MANIFEST_DIR": str(snapshot)}
    profile_reports = {}
    for label, count, tcl in profiles:
        check_inputs()
        print(f"Starting requested {label} profile", flush=True)
        report = run_profile(run_dir / label, jg, tcl, count, environment, tiles)
        write_json(run_dir / label / "profile.json", report)
        check_inputs()
        profile_reports[label] = report
        print(
            f"{label}: {report['elapsed_seconds']} s, "
            f"{report['conclusive_tiles']}/{report['total_tiles']} conclusive tiles, "
            f"{report['conclusive_vectors']}/{report['total_vectors']} tile vectors",
            flush=True,
        )
    same_properties = (
        profile_reports["one-worker"]["reported_property_names"]
        == profile_reports["eighty-host"]["reported_property_names"]
    )
    comparison: dict[str, object] = {
        "offline_interval_coverage": coverage,
        "profiles": profile_reports,
        "identical_reported_property_names": same_properties,
    }
    comparable = same_properties and all(
        report["all_manifest_tiles_conclusive"] for report in profile_reports.values()
    )
    if comparable:
        one = profile_reports["one-worker"]["elapsed_seconds"]
        eighty = profile_reports["eighty-host"]["elapsed_seconds"]
        assert isinstance(one, float) and isinstance(eighty, float)
        comparison["wall_clock_ratio_one_to_eighty_requested_profiles"] = one / eighty
        print(f"Wall-clock ratio for the two requested profiles {one / eighty:.2f}×")
    else:
        print("No ratio: the two profiles did not conclusively resolve identical obligations.")
    write_json(run_dir / "comparison.json", comparison)
    print("Confirm actual worker use from site scheduler or Jasper logs before interpreting scaling.")
    return 0 if comparable else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(f"benchmark_offline.py: {error}")
