#!/usr/bin/env python3
"""
Clear Wally packages from lib directories.
Removes all files except src, default.project.json, and wally.toml.
"""

import os
import sys
import shutil
from pathlib import Path


SRC_DIR = Path("lib")
IGNORE_LIST = ["src", "default.project.json", "wally.toml"]


def find_project_root() -> Path:
    """Find and change to the project root directory."""
    current_dir = Path.cwd()
    while current_dir != current_dir.parent:
        if (current_dir / SRC_DIR).is_dir():
            os.chdir(current_dir)
            return current_dir
        current_dir = current_dir.parent
    return Path.cwd()


def clear_package_dir(package_dir: Path):
    """Remove all files/directories except those in IGNORE_LIST."""
    for item in package_dir.iterdir():
        if item.name not in IGNORE_LIST:
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()


def main():
    print("Clearing packages...")

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

        raw_name = package_dir.name
        print(f"Parsing directory: {raw_name}")

        try:
            clear_package_dir(package_dir)
        except Exception as e:
            print(f"Error: Failed to remove files from {package_dir}: {e}")
            return 1

    print("Packages Removed!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
