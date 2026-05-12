#!/usr/bin/env python3
"""
Publish a Wally package with version management.
Handles version incrementing, publishing, and rebuilding sourcemaps.
"""

import argparse
import os
import re
import sys
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

    # Change to package directory and publish
    os.chdir(package_dir)
    
    if run_command(["wally", "publish"]):
        print("Package published successfully.")
    else:
        print("Package publishing failed.")

    # Delete default.project.json
    os.chdir(original_dir)
    default_project.unlink()
    print("default.project.json deleted.")

    # Rebuild sourcemap using setup script
    print("Rebuilding sourcemap...")
    run_command([sys.executable, "scripts/setup.py", package_name])

    return 0


if __name__ == "__main__":
    sys.exit(main())
