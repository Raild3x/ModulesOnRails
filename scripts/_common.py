#!/usr/bin/env python3
"""Shared utilities for all scripts in this repository.

This module is NOT a Python package (no ``__init__.py``). Each script that
needs it inserts its own parent directory onto ``sys.path`` so that
``from _common import ...`` resolves correctly regardless of the working
directory when the script is invoked.

Usage from a script located in ``scripts/``::

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from _common import SRC_DIR, find_project_root, run_command

Usage from a script located in ``scripts/workflow_actions/``::

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from _common import write_github_output, increment_version

Exported names
--------------
SRC_DIR               : Path constant pointing to ``lib/``
WALLY_IGNORE_LIST     : Default list of names preserved when cleaning a package dir
find_project_root()   : Walk up cwd until ``lib/`` is found; chdir there
run_command()         : Thin subprocess wrapper with error printing
clear_package_dir()   : Remove all entries in a package dir except ignored names
increment_version()   : Bump a ``MAJOR.MINOR.PATCH`` semver string
write_github_output() : Append a key=value pair to the GitHub Actions output file
parse_wally_toml()    : Lightweight ``wally.toml`` section/key parser
"""

from __future__ import annotations

import fnmatch
import os
import shutil
import subprocess
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Package layout constants
# ---------------------------------------------------------------------------

#: Root directory that contains every Wally package subdirectory.
SRC_DIR: Path = Path("lib")

#: File and directory names (or glob patterns) that are always preserved when
#: a package directory is cleaned before ``wally install`` or ``wally
#: publish``.  Extend this list when a caller needs extra files kept.
WALLY_IGNORE_LIST: list[str] = ["src", "default.project.json", "wally.toml", "*.md", "docs"]


# ---------------------------------------------------------------------------
# Project root discovery
# ---------------------------------------------------------------------------

def find_project_root() -> Path:
    """Walk up from the current directory until a ``lib/`` folder is found.

    Changes the current working directory to the project root and returns it.
    If no ancestor directory containing ``lib/`` is found (e.g. the script is
    already at the repository root), the function returns the current directory
    unchanged so that callers always get a valid path.

    Returns:
        The resolved project-root :class:`~pathlib.Path`.
    """
    current_dir = Path.cwd()
    while current_dir != current_dir.parent:
        if (current_dir / SRC_DIR).is_dir():
            os.chdir(current_dir)
            return current_dir
        current_dir = current_dir.parent
    # Already at filesystem root, or lib/ is not present in any ancestor.
    return Path.cwd()


# ---------------------------------------------------------------------------
# Subprocess helper
# ---------------------------------------------------------------------------

def run_command(cmd: list, error_msg: Optional[str] = None) -> bool:
    """Run *cmd* as a subprocess and return ``True`` on success.

    Arguments:
        cmd:       The command and its arguments, passed directly to
                   :func:`subprocess.run`.
        error_msg: Human-readable message to print when the command exits
                   with a non-zero status.  Pass ``None`` to suppress the
                   error message (the function still returns ``False``).

    Returns:
        ``True`` if the process exited with code 0, ``False`` otherwise.
    """
    try:
        subprocess.run(cmd, check=True)
        return True
    except subprocess.CalledProcessError:
        if error_msg:
            print(f"Error: {error_msg}")
        return False
    except FileNotFoundError:
        print(f"Error: Command not found — {cmd[0]}")
        return False


# ---------------------------------------------------------------------------
# Package directory management
# ---------------------------------------------------------------------------

def clear_package_dir(
    package_dir: Path,
    ignore_list: list[str] = WALLY_IGNORE_LIST,
) -> int:
    """Remove every entry inside *package_dir* that is not in *ignore_list*.

    This is called before ``wally install`` or ``wally publish`` to ensure that
    stale generated files (old dependency packages, type stubs, etc.) do not
    pollute the package directory.

    Arguments:
        package_dir: Path to the package directory to clean.
        ignore_list: Names or glob patterns (not full paths) of entries to
                     preserve. Defaults to :data:`WALLY_IGNORE_LIST`. Pass a
                     custom list to preserve additional files, for example::

                         clear_package_dir(pkg, WALLY_IGNORE_LIST + ["CHANGELOG.txt"])
    """
    count = 0
    for item in package_dir.iterdir():
        if not any(fnmatch.fnmatch(item.name, pattern) for pattern in ignore_list):
            if item.is_dir():
                shutil.rmtree(item)
            else:
                item.unlink()
            count += 1
    return count


# ---------------------------------------------------------------------------
# Semantic versioning
# ---------------------------------------------------------------------------

def increment_version(version: str, increment_type: str) -> str:
    """Return a bumped semantic version string.

    Arguments:
        version:        A version string in ``MAJOR.MINOR.PATCH`` format,
                        e.g. ``"1.2.3"``.
        increment_type: One of ``"major"``, ``"minor"``, or ``"patch"``.

    Returns:
        The bumped version string, e.g. ``"1.2.4"`` for a patch bump of
        ``"1.2.3"``.

    Raises:
        ValueError: If *version* is not a valid three-part semver string, any
                    component is non-numeric, or *increment_type* is not one of
                    the accepted values.

    Examples::

        increment_version("1.2.3", "patch")  # "1.2.4"
        increment_version("1.2.3", "minor")  # "1.3.0"
        increment_version("1.2.3", "major")  # "2.0.0"
    """
    parts = version.split(".")
    if len(parts) != 3:
        raise ValueError(f"Invalid semantic version (expected MAJOR.MINOR.PATCH): {version!r}")

    try:
        major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
    except ValueError:
        raise ValueError(f"Non-integer version component in: {version!r}")

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
        raise ValueError(
            f"Invalid increment type: {increment_type!r}. "
            "Expected 'major', 'minor', or 'patch'."
        )

    return f"{major}.{minor}.{patch}"


# ---------------------------------------------------------------------------
# GitHub Actions integration
# ---------------------------------------------------------------------------

def write_github_output(name: str, value: str) -> None:
    """Append a ``name=value`` pair to the GitHub Actions output file.

    When running locally (i.e. ``GITHUB_OUTPUT`` is not set in the
    environment), this function is a no-op so that scripts can be tested
    without a live Actions runner.

    Arguments:
        name:  The output variable name, e.g. ``"version_change"``.
        value: The output variable value, e.g. ``"patch"``.

    See Also:
        https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/passing-information-between-jobs
    """
    github_output = os.getenv("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"{name}={value}\n")


# ---------------------------------------------------------------------------
# Wally TOML parsing
# ---------------------------------------------------------------------------

def parse_wally_toml(file_path: Path) -> dict[str, dict[str, str]]:
    """Parse a ``wally.toml`` file into a nested section → key → value dict.

    This is an intentionally lightweight parser rather than a full TOML
    implementation — Wally configuration files are simple enough that adding
    a third-party dependency just to read them would be excessive.

    Supported syntax:

    * ``[section]`` headers
    * ``key = "value"`` or ``key = 'value'`` assignments
    * Full-line ``# comments`` and inline trailing ``# comments``
    * Blank lines (ignored)

    The ``"package"`` and ``"custom"`` sections are always present in the
    returned dict, even when empty.  Any additional sections found in the file
    are included as well.

    Arguments:
        file_path: Path to the ``wally.toml`` file to parse.

    Returns:
        A dict mapping section name → {key: value}.  All values are strings
        with surrounding quotes stripped.

    Example::

        config = parse_wally_toml(package_dir / "wally.toml")
        version = config["package"]["version"]   # e.g. "0.3.1"
        docs_link = config["custom"].get("docsLink", "")
    """
    config: dict[str, dict[str, str]] = {
        "package": {},
        "custom": {},
    }
    current_section: Optional[str] = None

    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()

            # Skip blank lines and full-line comments.
            if not line or line.startswith("#"):
                continue

            # Detect section headers, e.g. [package] or [dependencies].
            if line.startswith("[") and line.endswith("]"):
                current_section = line[1:-1]
                if current_section not in config:
                    config[current_section] = {}
                continue

            # Parse ``key = value`` pairs; strip trailing inline comments.
            if "=" in line and current_section is not None:
                key, _, raw_value = line.partition("=")
                key = key.strip()
                # Remove inline comment, then strip surrounding quotes.
                value = raw_value.split("#")[0].strip().strip('"').strip("'")
                config[current_section][key] = value

    return config
