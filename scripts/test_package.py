#!/usr/bin/env python3
"""
Run tests (and coverage) for a package via the Lune coverage runner.

Usage:
    npm run test <package> [flags...]

Examples:
    npm run test tablemanager
    npm run test all
    npm run test last
    npm run test tablemanager --per-file --recommend

If <package> is omitted, defaults to "last" (test/last_tested_package.txt).
Any additional arguments (e.g. --per-file, --mutate) are passed through to
`lune run coverage.luau`.

Before running, any target package that declares Wally dependencies but has
not been set up yet (no resolved `_Index` folder) is automatically set up via
`npm run setup <package>`.
"""

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import SRC_DIR, find_project_root

# Wally dependency section headers in wally.toml.
_DEP_SECTIONS = {"[dependencies]", "[server-dependencies]", "[dev-dependencies]"}


def _has_wally_dependencies(package_dir: Path) -> bool:
    """Return True if wally.toml declares at least one dependency."""
    wally_toml = package_dir / "wally.toml"
    if not wally_toml.is_file():
        return False

    in_dep_section = False
    for raw_line in wally_toml.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            in_dep_section = line in _DEP_SECTIONS
            continue
        if in_dep_section and "=" in line:
            return True
    return False


def _needs_setup(package_dir: Path) -> bool:
    """A package needs setup if it has deps but no resolved `_Index` folder."""
    return _has_wally_dependencies(package_dir) and not (package_dir / "_Index").is_dir()


def _resolve_packages(package: str) -> list[str]:
    """Resolve the runner's package selector to concrete lib/ directory names."""
    if package == "all":
        return [p.name for p in sorted(SRC_DIR.iterdir()) if p.is_dir()]
    if package == "last":
        last_file = Path("test") / "last_tested_package.txt"
        if last_file.is_file():
            name = last_file.read_text(encoding="utf-8").strip()
            return [name] if name else []
        return []
    return [package]


def _ensure_setup(package: str) -> int:
    """Run `npm run setup <name>` for any target package that needs it."""
    for name in _resolve_packages(package):
        package_dir = SRC_DIR / name
        if not package_dir.is_dir():
            continue  # Let the coverage runner report an unknown package.
        if _needs_setup(package_dir):
            print(f"Package '{name}' is not set up yet; running setup...", flush=True)
            code = subprocess.call(["npm", "run", "setup", name], shell=(sys.platform == "win32"))
            if code != 0:
                print(f"Setup failed for '{name}' (exit {code}).", flush=True)
                return code
    return 0


def main():
    find_project_root()

    args = sys.argv[1:]

    # First non-flag argument is the package name; rest are passthrough flags.
    package = None
    passthrough = []
    for arg in args:
        if package is None and not arg.startswith("-"):
            package = arg
        else:
            passthrough.append(arg)
    if package is None:
        package = "last"

    setup_code = _ensure_setup(package)
    if setup_code != 0:
        return setup_code

    cmd = ["lune", "run", "coverage.luau", f"package={package}", *passthrough]
    print(f"Running: {' '.join(cmd)}", flush=True)
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
