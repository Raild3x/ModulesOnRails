#!/usr/bin/env python3
"""
Setup script for Wally packages environment.
Sets up proper linting by installing dependencies and generating types.
"""

import os
import sys
import subprocess
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


def run_command(cmd: list, error_msg: str) -> bool:
    """Run a command and return True if successful."""
    try:
        subprocess.run(cmd, check=True)
        return True
    except subprocess.CalledProcessError:
        print(f"Error: {error_msg}")
        return False
    except FileNotFoundError:
        print(f"Error: Command not found - {cmd[0]}")
        return False


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
