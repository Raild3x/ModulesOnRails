#!/usr/bin/env python3
"""
Clear Wally packages from lib directories.
Removes all files except src, default.project.json, .md files, and wally.toml.
"""

import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Local shared utilities (scripts/_common.py)
# ---------------------------------------------------------------------------
# Insert scripts/ onto sys.path so _common is importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import SRC_DIR, WALLY_IGNORE_LIST, find_project_root, clear_package_dir


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
            # print(f"Skipping non-directory: {package_dir}")
            continue

        # Check if this package should be processed
        if not process_all and package_dir.name not in args:
            # print(f"Skipping non-argument directory: {package_dir}")
            continue

        raw_name = package_dir.name
        # print(f"Parsing directory: {raw_name}")

        try:
            removedCount = clear_package_dir(package_dir)
            if removedCount > 0:
                print(f"Removed {removedCount} files from {package_dir}")
        except Exception as e:
            print(f"Error: Failed to remove files from {package_dir}: {e}")
            return 1

    print("Cleared packages successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
