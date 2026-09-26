#!/usr/bin/env python3
"""
Setup script for Wally packages environment.
Sets up proper linting by installing dependencies and generating types.
"""

import json
import os
import shutil
import sys
from convert_requires_to_string_format import process_directory
from pathlib import Path

# ---------------------------------------------------------------------------
# Local shared utilities (scripts/_common.py)
# ---------------------------------------------------------------------------
# Insert scripts/ onto sys.path so _common is importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import SRC_DIR, WALLY_IGNORE_LIST, find_project_root, clear_package_dir, parse_wally_toml, run_command


def _first_project_path(node) -> str | None:
    """Return the first ``$path`` value found in a Rojo project tree, if any."""
    if isinstance(node, dict):
        path = node.get("$path")
        if isinstance(path, str):
            return path
        for value in node.values():
            found = _first_project_path(value)
            if found is not None:
                return found
    return None


def generate_lune_index_shims(index_dir: Path) -> None:
    """Add ``init.luau`` shims so Wally deps resolve under Lune require-by-string.

    Wally packages published with a ``default.project.json`` that redirects
    ``$path`` to a subfolder (e.g. ``src``) are resolvable by Rojo/Roblox but not
    by Lune: the generated linker requires the package folder as a directory, and
    Lune looks for an ``init.luau`` there rather than following the Rojo project
    redirect. For each such folder that lacks its own ``init``, drop in a shim
    that re-exports the redirect target via ``@self``. This is a no-op for Rojo
    (an explicit ``default.project.json`` takes precedence over the loose file).
    """
    if not index_dir.is_dir():
        return

    for project_file in index_dir.rglob("default.project.json"):
        pkg_dir = project_file.parent
        # Skip if the folder is already resolvable as a module on its own.
        if (pkg_dir / "init.luau").exists() or (pkg_dir / "init.lua").exists():
            continue

        try:
            project = json.loads(project_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue

        target = _first_project_path(project)
        # Only handle a redirect into a child path; "." would just point at the
        # folder itself and can't be re-exported this way.
        if not target or target.strip() in ("", "."):
            continue

        # Normalize into a require path: forward slashes, no source extension.
        require_target = target.replace("\\", "/").strip("/")
        for ext in (".luau", ".lua"):
            if require_target.endswith(ext):
                require_target = require_target[: -len(ext)]
                break

        shim = pkg_dir / "init.luau"
        shim.write_text(f'return require("@self/{require_target}")\n', encoding="utf-8")
        print(f"Generated Lune require shim: {shim}")


# Unpublished in-repo dependencies are declared as `[custom] siblings = "a,b"` in wally.toml
# (kept out of [dependencies] so `wally install` never looks for them in the registry). Setup
# vendors each one in Wally's layout; the coverage adapter refreshes their `src` on every run.
SIBLING_SCOPE_PREFIX = "raild3x_"
SIBLING_VERSION = "local"
_siblings_in_progress: set[str] = set()


def read_siblings(package_dir: Path) -> list[str]:
    """Return the package's `[custom] siblings` names (comma-separated string)."""
    wally_toml = package_dir / "wally.toml"
    if not wally_toml.is_file():
        return []
    raw = parse_wally_toml(wally_toml).get("custom", {}).get("siblings", "")
    return [name.strip() for name in raw.split(",") if name.strip()]


def link_siblings(package_dir: Path) -> bool:
    """Set up each sibling, then vendor it as `_Index/raild3x_<name>@local/<name>` plus a
    `<FormattedName>.lua` link module at the package root, mirroring a Wally install."""
    for sibling in read_siblings(package_dir):
        sibling_dir = SRC_DIR / sibling
        if not (sibling_dir / "src").is_dir():
            print(f"Error: sibling '{sibling}' of '{package_dir.name}' has no {sibling_dir / 'src'}")
            return False
        if sibling in _siblings_in_progress:
            print(f"Error: sibling cycle through '{sibling}'")
            return False
        _siblings_in_progress.add(sibling)
        ok = setup_package(sibling_dir)
        _siblings_in_progress.discard(sibling)
        if not ok:
            return False

        formatted = parse_wally_toml(sibling_dir / "wally.toml").get("custom", {}).get("formattedName") or sibling
        dest = package_dir / "_Index" / f"{SIBLING_SCOPE_PREFIX}{sibling}@{SIBLING_VERSION}" / sibling
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(
            sibling_dir,
            dest,
            ignore=shutil.ignore_patterns("sourcemap.json", "wally.lock", "*.md", "Packages"),
        )
        # Lune resolves the folder through init.luau; Rojo turns the folder into a ModuleScript.
        (dest / "init.luau").write_text(f'return require("@self/src/{formatted}")\n', encoding="utf-8")
        (package_dir / f"{formatted}.lua").write_text(
            f'return require("./_Index/{SIBLING_SCOPE_PREFIX}{sibling}@{SIBLING_VERSION}/{sibling}")\n',
            encoding="utf-8",
        )
        print(f"Linked sibling '{sibling}' into {package_dir.name} as {formatted}")
    return True


def setup_package(package_dir: Path) -> bool:
    """Setup a single package directory."""
    raw_name = package_dir.name
    print(f"Parsing directory: {raw_name}")

    # Clear existing files except ignored ones
    clear_package_dir(package_dir)

    # Install Wally packages
    print("Installing Wally Package Dependencies...")
    original_dir = Path.cwd()
    os.chdir(package_dir)
    
    if not run_command(["wally", "install"], "Failed to install Wally packages."):
        os.chdir(original_dir)
        return False
    
    os.chdir(original_dir)

    # Generate sourcemap
    print("Generating sourcemap...")
    if not run_command(
        ["rojo", "sourcemap", ".", "-o", "sourcemap.json"],
        "Failed to generate sourcemap."
    ):
        return False

    # Handle Packages directory if it exists
    packages_dir = package_dir / "Packages"
    if packages_dir.is_dir():
        # Generate Wally Package Types
        print("Generating Wally Package Types...")
        if not run_command(
            ["wally-package-types", "--sourcemap", "sourcemap.json", str(packages_dir)],
            "Failed to generate Wally package types."
        ):
            return False

        process_directory(packages_dir)

        # Make Wally deps resolvable under Lune's require-by-string (the linter
        # and the Lune coverage pipeline both require these folders directly).
        generate_lune_index_shims(packages_dir / "_Index")

        # Move files out of Packages directory
        print("Moving Wally Packages out of Packages directory...")
        for item in packages_dir.iterdir():
            dest = package_dir / item.name
            shutil.move(str(item), str(dest))
        print("Moved visible files.")

        # Remove the empty Packages directory
        print("Removing original Packages directory...")
        packages_dir.rmdir()

    # Vendor unpublished in-repo siblings LAST: the move above would otherwise nest the
    # registry `_Index` inside an `_Index` that link_siblings already created.
    if not link_siblings(package_dir):
        return False

    return True


def main():
    print("Setting up your environment...")

    find_project_root()

    # Check if source directory exists
    if not SRC_DIR.is_dir():
        print(f"Error: Source directory {SRC_DIR} does not exist.")
        return 1

    # Get list of packages to process (from args or all)
    args = sys.argv[1:]
    process_all = len(args) == 0

    # Process each package directory
    for package_dir in sorted(SRC_DIR.iterdir()):
        if not package_dir.is_dir():
            print(f"Skipping non-directory: {package_dir}")
            continue

        # Check if this package should be processed
        if not process_all and package_dir.name not in args:
            print(f"Skipping non-argument directory: {package_dir}")
            continue

        if not setup_package(package_dir):
            return 1

    # Regenerate final sourcemap
    print("Regenerating sourcemap...")
    if not run_command(
        ["rojo", "sourcemap", "default.project.json", "-o", "sourcemap.json"],
        "Failed to generate sourcemap."
    ):
        return 1

    print("Setup complete!  :D")
    return 0


if __name__ == "__main__":
    sys.exit(main())
