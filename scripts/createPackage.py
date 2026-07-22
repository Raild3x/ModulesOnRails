#!/usr/bin/env python3
"""
Create a new package scaffold in the lib directory.
Usage:
    python scripts/createPackage.py <PackageName> [description]
"""

import os
import re
import sys
from pathlib import Path

SRC_DIR = Path("lib")
DEFAULT_AUTHOR = "Logan Hunt (Raildex)"
DEFAULT_LICENSE = "MIT"
DEFAULT_REGISTRY = "https://github.com/UpliftGames/wally-index"
DEFAULT_REALM = "shared"
DEFAULT_VERSION = "0.1.0"


def find_project_root() -> Path:
    """Find and change to the project root directory."""
    current_dir = Path.cwd()
    while current_dir != current_dir.parent:
        if (current_dir / SRC_DIR).is_dir():
            os.chdir(current_dir)
            return current_dir
        current_dir = current_dir.parent
    return Path.cwd()


def normalize_names(raw_name: str) -> tuple[str, str]:
    """
    Convert user input into:
    - package_slug: lowercase, filesystem-safe package folder name
    - formatted_name: PascalCase name used in docs and source file
    """
    words = re.findall(r"[A-Za-z0-9]+", raw_name)
    if not words:
        raise ValueError("Package name must contain letters or numbers.")

    formatted_name = "".join(word[:1].upper() + word[1:] for word in words)
    package_slug = "".join(words).lower()

    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", formatted_name):
        raise ValueError(
            "Package name must start with a letter and contain only letters and numbers."
        )

    return package_slug, formatted_name


def build_wally_toml(package_slug: str, formatted_name: str, description: str) -> str:
    return (
        "[package]\n"
        f"name = \"raild3x/{package_slug}\"\n"
        f"description = \"{description}\"\n"
        f"authors = [\"{DEFAULT_AUTHOR}\"]\n"
        f"version = \"{DEFAULT_VERSION}\"\n"
        f"license = \"{DEFAULT_LICENSE}\"\n"
        f"registry = \"{DEFAULT_REGISTRY}\"\n"
        f"realm = \"{DEFAULT_REALM}\"\n\n"
        "[custom]\n"
        "# The properly capitalized and spaced name of the library\n"
        f"formattedName = \"{formatted_name}\"\n"
        "# The intro page for the documentation\n"
        f"docsLink = \"{formatted_name}\"\n\n"
        "[dependencies]\n"
    )


def build_init_luau(formatted_name: str) -> str:
    return (
        f"local {formatted_name} = {{}}\n\n"
        f"return {formatted_name}\n"
    )


def prompt_for_name() -> str:
    """Prompt until a valid, non-empty package name is provided."""
    while True:
        try:
            raw_name = input("Package name: ").strip()
        except EOFError:
            return ""

        if raw_name:
            return raw_name

        print("Package name cannot be empty.")


def prompt_for_description(raw_name: str) -> str:
    """Prompt for description, allowing empty input to use default."""
    default_description = f"Description for {raw_name}."
    try:
        value = input(f"Description [{default_description}]: ").strip()
    except EOFError:
        return default_description

    return value or default_description


def main() -> int:
    find_project_root()

    if not SRC_DIR.is_dir():
        print(f"Error: Source directory {SRC_DIR} does not exist.")
        return 1

    args = sys.argv[1:]

    raw_name = args[0].strip() if len(args) >= 1 else ""
    if not raw_name:
        raw_name = prompt_for_name()
        if not raw_name:
            print("Error: Package name is required.")
            return 1

    if len(args) >= 2:
        description = " ".join(args[1:]).strip()
    else:
        description = ""

    if not description:
        description = prompt_for_description(raw_name)

    try:
        package_slug, formatted_name = normalize_names(raw_name)
    except ValueError as err:
        print(f"Error: {err}")
        return 1

    package_dir = SRC_DIR / package_slug
    src_dir = package_dir / "src"

    if package_dir.exists():
        print(f"Error: Package directory already exists: {package_dir}")
        return 1

    src_dir.mkdir(parents=True, exist_ok=False)

    wally_toml_path = package_dir / "wally.toml"
    init_luau_path = src_dir / "init.luau"

    wally_toml_path.write_text(
        build_wally_toml(package_slug, formatted_name, description),
        encoding="utf-8",
    )
    init_luau_path.write_text(build_init_luau(formatted_name), encoding="utf-8")

    print(f"Created package scaffold at: {package_dir}")
    print("Next steps:")
    print(f"  npm run setup -- {package_slug}")
    print("  npm run readme")

    return 0


if __name__ == "__main__":
    sys.exit(main())
