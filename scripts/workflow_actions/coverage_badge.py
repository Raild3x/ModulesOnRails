#!/usr/bin/env python3
"""Maintain the repo-wide coverage badge published on the `badges` branch.

Two subcommands, both driven by .github/workflows/coverage-badge.yml:

``stale``
    Decide which packages need a fresh coverage run by diffing HEAD against
    the main SHA recorded in the cached ``coverage-state.json`` (fetched from
    the `badges` branch). Packages with no cached entry are always stale, and
    a change to the coverage tooling itself invalidates every package.

``merge``
    Fold this run's ``.coverage/<pkg>/coverage.json`` reports into the cached
    state, then emit the shields.io endpoint badge JSON plus the updated
    state file into ``--out-dir`` (published back to the `badges` branch).

The overall percentage is a weighted mean of per-package line coverage with
weight = ``lines ** (1/3)``: larger packages count for more, but sublinearly,
so a huge package cannot drown out the small ones.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Local shared utilities (scripts/_common.py)
# ---------------------------------------------------------------------------
# Insert scripts/ onto sys.path so _common is importable from this subdirectory.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from _common import SRC_DIR, find_project_root, write_github_output

STATE_SCHEMA = "coverage-badge-state/1"

#: A change to any of these paths invalidates every cached package result:
#: they alter how coverage itself is measured or reported.
GLOBAL_INVALIDATION_PREFIXES = (
    "tools/coverage/",
    "test/",
    "coverage.luau",
    "scripts/test_package.py",
    "scripts/workflow_actions/coverage_badge.py",
    ".github/workflows/coverage-badge.yml",
)


def packages_with_specs() -> list[str]:
    """Return lib/ package names that contain at least one spec file."""
    names = []
    for pkg_dir in sorted(SRC_DIR.iterdir()):
        if not pkg_dir.is_dir():
            continue
        specs = (p for p in pkg_dir.rglob("*.spec.luau") if "_Index" not in p.parts)
        if next(specs, None) is not None:
            names.append(pkg_dir.name)
    return names


def load_state(state_file: Path) -> dict | None:
    if not state_file.is_file():
        return None
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"Warning: could not read state file {state_file}: {e}")
        return None
    return state if isinstance(state, dict) else None


def changed_files_since(sha: str) -> list[str] | None:
    """Files changed between *sha* and HEAD, or None if the diff fails
    (e.g. the cached SHA no longer exists after a history rewrite)."""
    completed = subprocess.run(
        ["git", "diff", "--name-only", sha, "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return None
    return [line.strip() for line in completed.stdout.splitlines() if line.strip()]


def git_head_sha() -> str:
    return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()


# ---------------------------------------------------------------------------
# stale
# ---------------------------------------------------------------------------

def cmd_stale(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file).resolve()
    out_path = Path(args.stale_packages_file).resolve()
    find_project_root()

    packages = packages_with_specs()
    state = load_state(state_file)

    if args.full:
        stale, reason = packages, "full run requested"
    elif state is None:
        stale, reason = packages, "no cached coverage state"
    else:
        last_sha = str(state.get("last_main_sha", "")).strip()
        changed = changed_files_since(last_sha) if last_sha else None
        if changed is None:
            stale, reason = packages, f"cannot diff against cached SHA {last_sha or '<none>'}"
        elif any(f.startswith(GLOBAL_INVALIDATION_PREFIXES) for f in changed):
            stale, reason = packages, "coverage tooling changed"
        else:
            cached = set(state.get("packages", {}))
            changed_pkgs = set()
            for f in changed:
                parts = f.split("/")
                if len(parts) >= 3 and parts[0] == "lib":
                    changed_pkgs.add(parts[1])
            stale = sorted((set(packages) & changed_pkgs) | (set(packages) - cached))
            reason = f"diff against {last_sha[:12]}"

    if stale:
        out_path.write_text("\n".join(stale) + "\n", encoding="utf-8")
    elif out_path.exists():
        out_path.unlink()

    write_github_output("has_stale", "true" if stale else "false")
    print(f"Stale packages ({reason}): {' '.join(stale) if stale else '<none>'}")
    return 0


# ---------------------------------------------------------------------------
# merge
# ---------------------------------------------------------------------------

def _badge_color(pct: float) -> str:
    if pct >= 90:
        return "brightgreen"
    if pct >= 75:
        return "green"
    if pct >= 60:
        return "yellow"
    return "red"


def cmd_merge(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file).resolve()
    out_dir = Path(args.out_dir).resolve()
    find_project_root()

    state = load_state(state_file) or {}
    packages: dict[str, dict] = dict(state.get("packages", {}))
    main_sha = args.main_sha or git_head_sha()

    coverage_root = Path(args.coverage_dir)
    fresh = 0
    for report_path in sorted(coverage_root.glob("*/coverage.json")):
        try:
            data = json.loads(report_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            print(f"::warning::Unreadable coverage report {report_path}: {e}")
            continue
        name = str(data.get("package") or report_path.parent.name)
        tally = (data.get("run") or {}).get("status_tally") or {}
        if int(tally.get("fail") or 0) > 0:
            print(f"::warning::{name}: {tally['fail']} failing test(s); keeping cached coverage.")
            continue
        lines = (data.get("totals") or {}).get("lines") or {}
        total = int(lines.get("total") or 0)
        if total <= 0:
            print(f"{name}: no measurable lines; skipping.")
            continue
        packages[name] = {
            "pct": round(float(lines.get("pct") or 0.0), 2),
            "lines": total,
            "sha": main_sha,
        }
        fresh += 1

    # Drop cached entries for packages that no longer exist under lib/.
    packages = {name: entry for name, entry in packages.items() if (SRC_DIR / name).is_dir()}

    weighted = [
        (float(entry["lines"]) ** (1.0 / 3.0), float(entry["pct"]))
        for entry in packages.values()
        if float(entry.get("lines") or 0) > 0
    ]
    total_weight = sum(w for w, _ in weighted)
    if total_weight > 0:
        overall = sum(w * p for w, p in weighted) / total_weight
        message, color = f"{overall:.0f}%", _badge_color(overall)
    else:
        message, color = "unknown", "lightgrey"

    out_dir.mkdir(parents=True, exist_ok=True)
    badge = {"schemaVersion": 1, "label": "coverage", "message": message, "color": color}
    (out_dir / "coverage.json").write_text(json.dumps(badge, indent=2) + "\n", encoding="utf-8")

    new_state = {
        "schema": STATE_SCHEMA,
        "last_main_sha": main_sha,
        "packages": {name: packages[name] for name in sorted(packages)},
    }
    (out_dir / "coverage-state.json").write_text(
        json.dumps(new_state, indent=2) + "\n", encoding="utf-8"
    )

    for name in sorted(packages):
        entry = packages[name]
        print(f"  {name}: {entry['pct']}% of {entry['lines']} lines")
    print(f"Merged {fresh} fresh report(s); {len(packages)} package(s) total.")
    print(f"Badge: {message} ({color}) -> {out_dir}")
    return 0


# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    stale = sub.add_parser("stale", help="List packages needing a fresh coverage run.")
    stale.add_argument("--state-file", required=True, help="Cached coverage-state.json path.")
    stale.add_argument(
        "--stale-packages-file",
        default="stale-packages.txt",
        help="Output file for newline-delimited stale package names.",
    )
    stale.add_argument("--full", action="store_true", help="Mark every package stale.")
    stale.set_defaults(func=cmd_stale)

    merge = sub.add_parser("merge", help="Merge coverage reports and emit the badge JSON.")
    merge.add_argument("--state-file", required=True, help="Cached coverage-state.json path.")
    merge.add_argument("--out-dir", required=True, help="Directory for the updated badge files.")
    merge.add_argument("--coverage-dir", default=".coverage", help="Coverage output root.")
    merge.add_argument("--main-sha", default="", help="Main SHA the reports were computed at.")
    merge.set_defaults(func=cmd_merge)

    return parser.parse_args()


if __name__ == "__main__":
    _args = parse_args()
    raise SystemExit(_args.func(_args))
