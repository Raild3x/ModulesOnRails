#!/usr/bin/env python3
"""
Publish a Wally package with version management.
Handles version incrementing, publishing, and rebuilding sourcemaps.
"""

import argparse
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Local shared utilities (scripts/_common.py)
# ---------------------------------------------------------------------------
# Insert scripts/ onto sys.path so _common is importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import SRC_DIR, WALLY_IGNORE_LIST, find_project_root, clear_package_dir, increment_version, run_command

# Publish also needs to preserve README.md when cleaning the package directory
# (it may have been committed alongside the package source).
PUBLISH_IGNORE_LIST = WALLY_IGNORE_LIST + ["README.md"]


def find_exported_types(src_file: Path) -> list[tuple[str, str]]:
    """Return (type_name, type_params_str) pairs for every `export type` in a Luau file.

    type_params_str includes the angle brackets, e.g. "<T>" or "<T, U>", or is an
    empty string when the type has no type parameters.
    """
    content = src_file.read_text(encoding="utf-8")
    # Handles one level of nesting inside type params, e.g. <Foo<T>>.
    pattern = re.compile(
        r'^export\s+type\s+(\w+)((?:\s*<(?:[^<>]|<[^<>]*>)*>)?)\s*=',
        re.MULTILINE,
    )
    results: list[tuple[str, str]] = []
    for match in pattern.finditer(content):
        name = match.group(1)
        params = match.group(2).strip() if match.group(2) else ""
        results.append((name, params))
    return results


def strip_type_param_defaults(type_params: str) -> str:
    """Return *type_params* with generic defaults removed, e.g. ``<T = string, U>`` -> ``<T, U>``.

    Luau permits defaults only where a generic is declared; a usage site must
    pass bare arguments. The passthrough alias keeps defaults on its left-hand
    side but needs them stripped on the right-hand side.
    """
    if not type_params:
        return ""
    inner = type_params.strip()[1:-1]
    names: list[str] = []
    current: list[str] = []
    depth = 0
    for char in inner + ",":
        if char == "," and depth == 0:
            param = "".join(current).strip()
            if param:
                names.append(param.split("=", 1)[0].strip())
            current = []
            continue
        if char in "<{(":
            depth += 1
        elif char in ">})":
            depth -= 1
        current.append(char)
    return f"<{', '.join(names)}>"


def generate_passthrough_init(module_stem: str, exported_types: list[tuple[str, str]]) -> str:
    """Return the text of a passthrough init.luau that re-exports *module_stem*.

    The generated file:
    * requires the sibling module via ``script.<module_stem>``
    * re-exports every exported type so callers can reference them without
      going through the internal module path
    * returns the module table unchanged
    """
    lines = [
        "--!strict",
        "-- AUTO-GENERATED passthrough file --.",
        f"local Module = require(script.{module_stem})",
        "",
    ]
    for type_name, type_params in exported_types:
        usage_params = strip_type_param_defaults(type_params)
        lines.append(f"export type {type_name}{type_params} = Module.{type_name}{usage_params}")
    if exported_types:
        lines.append("")
    lines.append("return Module")
    lines.append("")
    return "\n".join(lines)


def is_unpublished_file(name: str) -> bool:
    """Return True for files that must never ship in the published package."""
    lowered = name.lower()
    return lowered.endswith(".spec.luau") or lowered.endswith(".spec.lua") or lowered == "claude.md"


def stash_unpublished_files(package_dir: Path, stash_dir: Path) -> tuple[list[tuple[Path, Path]], list[Path]]:
    """Move every spec file and ``CLAUDE.md`` under *package_dir* into *stash_dir*.

    Spec files are test-only and ``CLAUDE.md`` is agent-only context; neither
    must ship in the published package. Each file is moved to the same relative
    path under *stash_dir* so it can be restored afterwards. Directories left
    empty by the move (e.g. ``Tests/`` folders that contained only specs) are
    removed as well.

    Returns:
        A ``(moved, removed_dirs)`` pair: ``moved`` is a list of
        ``(original_path, stashed_path)`` tuples, ``removed_dirs`` the
        directories deleted because stashing emptied them.
    """
    moved: list[tuple[Path, Path]] = []
    for entry in sorted(package_dir.rglob("*")):
        if entry.is_file() and is_unpublished_file(entry.name):
            stashed = stash_dir / entry.relative_to(package_dir)
            stashed.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(entry), str(stashed))
            moved.append((entry, stashed))

    # Prune directories emptied by the move, deepest first so parents that
    # only contained now-empty children are removed too.
    removed_dirs: list[Path] = []
    for directory in sorted((d for d in package_dir.rglob("*") if d.is_dir()), reverse=True):
        if not any(directory.iterdir()):
            directory.rmdir()
            removed_dirs.append(directory)
    return moved, removed_dirs


def restore_unpublished_files(moved: list[tuple[Path, Path]], removed_dirs: list[Path]):
    """Undo :func:`stash_unpublished_files`: recreate pruned dirs and move files back."""
    for directory in reversed(removed_dirs):
        directory.mkdir(parents=True, exist_ok=True)
    for original, stashed in moved:
        original.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(stashed), str(original))


def get_current_version(wally_toml: Path) -> Optional[str]:
    """Extract the current version from wally.toml."""
    content = wally_toml.read_text(encoding="utf-8")
    match = re.search(r'^version\s*=\s*"([^"]+)"', content, re.MULTILINE)
    return match.group(1) if match else None


def update_version(wally_toml: Path, old_version: str, new_version: str):
    """Update the version in wally.toml."""
    content = wally_toml.read_text(encoding="utf-8")
    new_content = content.replace(f'version = "{old_version}"', f'version = "{new_version}"')
    wally_toml.write_text(new_content, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    """Parse command line arguments for interactive/non-interactive publishing."""
    parser = argparse.ArgumentParser(
        description="Publish a Wally package with optional non-interactive arguments."
    )
    parser.add_argument(
        "--package-name",
        type=str,
        help="Package name under lib/ to publish (for example: heap).",
    )
    parser.add_argument(
        "--version-change",
        type=str,
        choices=["major", "minor", "patch", "none"],
        help="Version bump type. Use 'none' to skip version increment.",
    )
    parser.add_argument(
        "--publish",
        action="store_true",
        help="Publish package without prompting.",
    )
    parser.add_argument(
        "--no-publish",
        action="store_true",
        help="Skip publishing without prompting.",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Auto-accept prompts and publish without an explicit publish prompt.",
    )
    return parser.parse_args()


def is_ci_environment() -> bool:
    """Return True when running in CI environments."""
    ci = os.getenv("CI", "").strip().lower()
    return ci not in {"", "0", "false", "no"} or os.getenv("GITHUB_ACTIONS") == "true"


def main():
    args = parse_args()

    if args.publish and args.no_publish:
        print("Error: --publish and --no-publish cannot be used together.")
        return 1

    original_dir = find_project_root()

    # Check if source directory exists
    if not SRC_DIR.is_dir():
        print(f"Error: Source directory {SRC_DIR} does not exist.")
        return 1

    # Prompt for package name
    package_name = args.package_name or input("Enter the package name: ").strip()
    
    package_dir = SRC_DIR / package_name
    if not package_dir.is_dir():
        print(f"Package directory {package_dir} does not exist.")
        return 1

    wally_toml = package_dir / "wally.toml"
    if not wally_toml.is_file():
        print(f"Could not find wally.toml in {package_dir}")
        return 1

    # Get current version
    current_version = get_current_version(wally_toml)
    if not current_version:
        print("Could not find the version number in wally.toml.")
        return 1

    print(f"Current version: {current_version}")

    increment_type = args.version_change
    if increment_type is None:
        # Prompt to increment version
        should_increment = "y" if args.yes else input("Do you want to increment the version? (y/n): ").strip().lower()
        if should_increment == "y":
            increment_type = input("Do you want to increment the version by major, minor, or patch? ").strip().lower()
        else:
            increment_type = "none"

    if increment_type != "none":
        try:
            new_version = increment_version(current_version, increment_type)
            update_version(wally_toml, current_version, new_version)
            print(f"Version updated to {new_version} in wally.toml.")
        except ValueError as e:
            print(str(e))
            return 1

    if args.no_publish:
        publish_now = False
    elif args.publish or args.yes:
        publish_now = True
    elif is_ci_environment():
        print("Error: In CI, publishing intent must be explicit. Use --publish or --no-publish.")
        return 1
    else:
        publish_now = input("Do you want to publish the package now? (y/n): ").strip().lower() == "y"

    if not publish_now:
        print("Publishing skipped.")
        return 0

    print("Clearing the package directory...")
    clear_package_dir(package_dir, PUBLISH_IGNORE_LIST)

    # Create default.project.json
    default_project = package_dir / "default.project.json"
    default_project.write_text(f'''{{\n    "name": "{package_name}",\n    "tree": {{\n        "$path": "src"\n    }}\n}}\n''', encoding="utf-8")
    print("default.project.json created.")

    # If src/ has no init.luau / init.lua, look for a file named after the package
    # and create a temporary passthrough init.luau that re-exports it.
    src_dir = package_dir / "src"
    temp_init: Optional[Path] = None
    publish_success: Optional[bool] = None
    stash_dir = Path(tempfile.mkdtemp(prefix=f"wally-publish-stash-{package_name}-"))
    stashed_files: list[tuple[Path, Path]] = []
    stashed_dirs: list[Path] = []
    try:
        # Spec files are test-only and CLAUDE.md is agent-only context; keep
        # both out of the published package.
        stashed_files, stashed_dirs = stash_unpublished_files(package_dir, stash_dir)
        if stashed_files:
            print(f"Stashed {len(stashed_files)} spec/CLAUDE.md file(s) out of the package for publish.")

        if src_dir.is_dir() and not (src_dir / "init.luau").is_file() and not (src_dir / "init.lua").is_file():
            candidate: Optional[Path] = None
            for ext in (".luau", ".lua"):
                target = f"{package_name}{ext}".lower()
                for entry in src_dir.iterdir():
                    if entry.is_file() and entry.name.lower() == target:
                        candidate = entry
                        break
                if candidate:
                    exported_types = find_exported_types(candidate)
                    init_content = generate_passthrough_init(candidate.stem, exported_types)
                    temp_init = (src_dir / "init.luau").resolve()
                    temp_init.write_text(init_content, encoding="utf-8")
                    print(f"Created temporary passthrough init.luau (entrypoint: {candidate.name}).")
                    break
            else:
                print(
                    f"Error: src/ has no init.luau, init.lua, or a '{package_name}[.luau|.lua]' "
                    "entrypoint file. Cannot publish."
                )
                return 1

        # Change to package directory and publish
        os.chdir(package_dir)
        publish_success = run_command(["wally", "publish"])
    finally:
        os.chdir(original_dir)
        if temp_init and temp_init.is_file():
            temp_init.unlink()
            print("Cleaned up temporary init.luau.")
        if default_project.is_file():
            default_project.unlink()
            print("default.project.json deleted.")
        restore_unpublished_files(stashed_files, stashed_dirs)
        if stashed_files:
            print(f"Restored {len(stashed_files)} stashed file(s) to the package.")
        shutil.rmtree(stash_dir, ignore_errors=True)

    if publish_success:
        print("Package published successfully.")
    else:
        print("Package publishing failed.")

    # Rebuild sourcemap using setup script
    # print("Rebuilding sourcemap...")
    # run_command([sys.executable, "scripts/setup.py", package_name])

    return 0 if publish_success else 1


if __name__ == "__main__":
    sys.exit(main())
