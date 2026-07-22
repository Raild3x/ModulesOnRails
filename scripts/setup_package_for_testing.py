#!/usr/bin/env python3
"""
Setup script for Wally packages environment.
Sets up proper linting by installing dependencies and generating types.
"""

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
from _common import SRC_DIR, WALLY_IGNORE_LIST, find_project_root, clear_package_dir, run_command


def _remove_duplicate_dependency_item(item: Path) -> None:
    if item.is_dir():
        shutil.rmtree(item)
    else:
        item.unlink()


def _move_dependency_item(source_item: Path, dest_item: Path, rewrite_server_requires: bool = False) -> bool:
    if dest_item.exists():
        print(f"Skipping duplicate dependency item: {dest_item.name}")
        _remove_duplicate_dependency_item(source_item)
        return True

    if rewrite_server_requires and source_item.suffix in {".lua", ".luau"}:
        source_text = source_item.read_text(encoding="utf-8")
        rewritten_text = source_text.replace(
            "script.Parent.ServerPackages._Index",
            "script.Parent._Index",
        )
        dest_item.write_text(rewritten_text, encoding="utf-8")
        source_item.unlink()
        return True

    shutil.move(str(source_item), str(dest_item))
    return True


def _unpack_dependency_directory(
    package_dir: Path,
    dependency_dir_name: str,
    rewrite_server_requires: bool = False,
) -> bool:
    dependency_dir = package_dir / dependency_dir_name
    if not dependency_dir.is_dir():
        return True

    print(f"Generating Wally Package Types for {dependency_dir_name}...")
    if not run_command(
        ["wally-package-types", "--sourcemap", "sourcemap.json", str(dependency_dir)],
        f"Failed to generate Wally package types for {dependency_dir_name}."
    ):
        return False

    print(f"Moving Wally Packages out of {dependency_dir_name} directory...")
    shared_index_dir = package_dir / "_Index"
    source_index_dir = dependency_dir / "_Index"
    if source_index_dir.is_dir():
        shared_index_dir.mkdir(exist_ok=True)
        for item in source_index_dir.iterdir():
            if not _move_dependency_item(item, shared_index_dir / item.name):
                return False
        source_index_dir.rmdir()

    for item in dependency_dir.iterdir():
        if not _move_dependency_item(
            item,
            package_dir / item.name,
            rewrite_server_requires=rewrite_server_requires,
        ):
            return False

    print(f"Removing original {dependency_dir_name} directory...")
    dependency_dir.rmdir()
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

    if not _unpack_dependency_directory(package_dir, "Packages"):
        return False

        process_directory(packages_dir)

        # Move files out of Packages directory
        print("Moving Wally Packages out of Packages directory...")
        for item in packages_dir.iterdir():
            dest = package_dir / item.name
            shutil.move(str(item), str(dest))
        print("Moved visible files.")

        # Remove the empty Packages directory
        print("Removing original Packages directory...")
        packages_dir.rmdir()

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
