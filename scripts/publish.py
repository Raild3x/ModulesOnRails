#!/usr/bin/env python3
"""
Publish a Wally package with version management.
Handles version incrementing, publishing, and rebuilding sourcemaps.
"""

import os
import sys
import re
import subprocess
import shutil
from pathlib import Path
from typing import Optional


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


def increment_version(version: str, increment_type: str) -> str:
    """Increment version based on type (major, minor, patch)."""
    parts = version.split(".")
    major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])

    if increment_type == "major":
        major += 1
        minor = 0
        patch = 0
    elif increment_type == "minor":
        minor += 1
        patch = 0
    elif increment_type == "patch":
        patch += 1
    else:
        raise ValueError(f"Invalid increment type: {increment_type}")

    return f"{major}.{minor}.{patch}"


def run_command(cmd: list, error_msg: str = None) -> bool:
    """Run a command and return True if successful."""
    try:
        subprocess.run(cmd, check=True)
        return True
    except subprocess.CalledProcessError:
        if error_msg:
            print(f"Error: {error_msg}")
        return False
    except FileNotFoundError:
        print(f"Error: Command not found - {cmd[0]}")
        return False


def main():
    original_dir = find_project_root()

    # Check if source directory exists
    if not SRC_DIR.is_dir():
        print(f"Error: Source directory {SRC_DIR} does not exist.")
        return 1

    # Prompt for package name
    package_name = input("Enter the package name: ").strip()
    
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

    # Prompt to increment version
    should_increment = input("Do you want to increment the version? (y/n): ").strip().lower()

    if should_increment == "y":
        increment_type = input("Do you want to increment the version by major, minor, or patch? ").strip().lower()
        
        try:
            new_version = increment_version(current_version, increment_type)
            update_version(wally_toml, current_version, new_version)
            print(f"Version updated to {new_version} in wally.toml.")
        except ValueError as e:
            print(str(e))
            return 1

    # Prompt to publish
    publish = input("Do you want to publish the package now? (y/n): ").strip().lower()
    if publish != "y":
        print("Publishing skipped.")
        return 0

    print("Clearing the package directory...")
    clear_package_dir(package_dir)

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
