#!/usr/bin/env python3
"""
Create a new Wally package under lib/ with the standard scaffolding.
Creates the directory, wally.toml, src/init.luau, and src/init.spec.luau,
then runs setup to install dependencies and generate types.
"""

import os
import re
import sys
from datetime import date
from pathlib import Path

# ---------------------------------------------------------------------------
# Local shared utilities (scripts/_common.py)
# ---------------------------------------------------------------------------
# Insert scripts/ onto sys.path so _common is importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import SRC_DIR, find_project_root, run_command

AUTHOR = "Logan Hunt (Raildex)"
WALLY_SCOPE = "raild3x"
REGISTRY = "https://github.com/UpliftGames/wally-index"


def to_formatted_name(name: str) -> str:
    """Convert a lowercased package dir name to a PascalCase formatted name."""
    return "".join(word.capitalize() for word in re.split(r"[-_]", name))


def create_wally_toml(package_dir: Path, folder_name: str, formatted_name: str, description: str) -> None:
    content = f"""[package]
name = "{WALLY_SCOPE}/{folder_name}"
description = "{description}"
authors = ["{AUTHOR}"]
version = "0.1.0"
license = "MIT"
registry = "{REGISTRY}"
realm = "shared"

[custom]
# The properly capitalized and spaced name of the library
formattedName = "{formatted_name}"
# The intro page for the documentation
docsLink = "{formatted_name}"

[dependencies]
"""
    (package_dir / "wally.toml").write_text(content, encoding="utf-8")


def create_init_luau(src_dir: Path, formatted_name: str) -> None:
    today = date.today().strftime("%B %d, %Y")
    content = f"""-- Authors: {AUTHOR}
-- {today}
--[=[
    @class {formatted_name}

    TODO: Add description.
]=]

local {formatted_name} = {{}}

return {formatted_name}
"""
    (src_dir / "init.luau").write_text(content, encoding="utf-8")


def create_init_spec_luau(src_dir: Path, formatted_name: str) -> None:
    today = date.today().strftime("%B %d, %Y")
    content = f"""-- Authors: {AUTHOR}
-- {today}
--[=[
    @class {formatted_name}.spec
    @ignore

    This is a test suite for the {formatted_name} class.
]=]

return function(t: tiniest)
    local {formatted_name} = require(script.Parent)

    local describe = t.describe
    local expect = t.expect
    local test = t.test

    
end
"""
    (src_dir / "init.spec.luau").write_text(content, encoding="utf-8")


def main() -> int:
    find_project_root()

    if not SRC_DIR.is_dir():
        print(f"Error: Source directory '{SRC_DIR}' does not exist.")
        return 1

    # Prompt for package details
    folder_name = input("Enter the package folder name (lowercase, e.g. 'mypackage'): ").strip().lower()
    if not folder_name:
        print("Error: Package name cannot be empty.")
        return 1
    if not re.match(r"^[a-z][a-z0-9_-]*$", folder_name):
        print("Error: Package name must start with a letter and contain only lowercase letters, digits, hyphens, or underscores.")
        return 1

    package_dir = SRC_DIR / folder_name
    if package_dir.exists():
        print(f"Error: Directory '{package_dir}' already exists.")
        return 1

    suggested_name = to_formatted_name(folder_name)
    formatted_name = input(f"Enter the formatted display name [{suggested_name}]: ").strip()
    if not formatted_name:
        formatted_name = suggested_name

    description = input("Enter a short description: ").strip()

    # Create directory structure
    src_dir = package_dir / "src"
    src_dir.mkdir(parents=True)
    print(f"Created directory: {package_dir}")

    # Write scaffolding files
    create_wally_toml(package_dir, folder_name, formatted_name, description)
    print("Created wally.toml")

    create_init_luau(src_dir, formatted_name)
    print("Created src/init.luau")

    create_init_spec_luau(src_dir, formatted_name)
    print("Created src/init.spec.luau")

    # Run setup for the new package
    run_setup = input("Run setup now (wally install + generate types)? (y/n): ").strip().lower()
    if run_setup == "y":
        print("Running setup...")
        run_command([sys.executable, "scripts/setup_package_for_testing.py", folder_name], "Setup failed.")

    print(f"\nPackage '{formatted_name}' created successfully at {package_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
