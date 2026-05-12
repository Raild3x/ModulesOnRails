#!/usr/bin/env python3
"""
Validate publish setup by checking package structure and workflow configuration.
Ensures all packages are properly configured for publishing with Wally.
"""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import List, Tuple

# ---------------------------------------------------------------------------
# Local shared utilities (scripts/_common.py)
# ---------------------------------------------------------------------------
# Insert scripts/ onto sys.path so _common is importable from this subdirectory.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from _common import increment_version


def validate_wally_ready() -> bool:
    """Check that the first package under lib/ has the structure Wally needs.

    This is intended to run AFTER the Wally binary has been verified on PATH.
    It performs three jobs:

    1. Locates the first alphabetical package directory under ``lib/``.
    2. Confirms that ``wally.toml`` and ``src/`` are present.
    3. Creates ``default.project.json`` if it is absent — Wally requires this
       file to be present before it will publish or login from a package dir.
    4. Reads and prints the package ``name`` and ``version`` from wally.toml
       so the workflow log shows which package is being used as the probe.

    Returns ``True`` if all checks pass, ``False`` otherwise.
    """
    lib_dir = Path("lib")
    if not lib_dir.is_dir():
        print("✗ lib/ directory not found")
        return False

    packages = sorted([d for d in lib_dir.iterdir() if d.is_dir()])
    if not packages:
        print("✗ No package directories found under lib/")
        return False

    pkg_dir = packages[0]
    pkg_name = pkg_dir.name
    print(f"Checking package: {pkg_name}")

    # Verify wally.toml is present.
    if not (pkg_dir / "wally.toml").is_file():
        print(f"✗ {pkg_name}: missing wally.toml")
        return False
    print("✓ wally.toml present")

    # Verify src/ directory is present.
    if not (pkg_dir / "src").is_dir():
        print(f"✗ {pkg_name}: missing src/ directory")
        return False
    print("✓ src/ directory present")

    # Create default.project.json if absent (required by wally).
    default_proj = pkg_dir / "default.project.json"
    if not default_proj.is_file():
        print(f"Creating default.project.json for {pkg_name}...")
        default_proj.write_text(
            f'{{\n    "name": "{pkg_name}",\n    "tree": {{\n        "$path": "src"\n    }}\n}}\n',
            encoding="utf-8",
        )
        print("✓ default.project.json created")
    else:
        print("✓ default.project.json present")

    # Parse and display package name + version.
    content = (pkg_dir / "wally.toml").read_text(encoding="utf-8")
    name_match = re.search(r'^name\s*=\s*"([^"]+)"', content, re.MULTILINE)
    ver_match = re.search(r'^version\s*=\s*"([^"]+)"', content, re.MULTILINE)

    if not name_match or not ver_match:
        print("✗ Could not parse package info from wally.toml")
        return False

    print(f"✓ Package: {name_match.group(1)} @ {ver_match.group(1)}")
    return True


def find_packages() -> List[Path]:
    """Find all package directories under lib/."""
    lib_dir = Path("lib")
    if not lib_dir.is_dir():
        print("✗ lib/ directory not found")
        return []
    
    packages = sorted([d for d in lib_dir.iterdir() if d.is_dir()])
    if not packages:
        print("✗ No package directories found in lib/")
    return packages


def check_wally_toml(pkg_dir: Path) -> Tuple[bool, str]:
    """Check if package has valid wally.toml."""
    wally_file = pkg_dir / "wally.toml"
    
    if not wally_file.is_file():
        return False, f"Missing wally.toml"
    
    try:
        content = wally_file.read_text(encoding="utf-8")
        if not re.search(r"^\[package\]", content, re.MULTILINE):
            return False, "Invalid wally.toml format (missing [package] section)"
        
        if not re.search(r'^version\s*=\s*"[^"]+"', content, re.MULTILINE):
            return False, "Invalid wally.toml format (missing version)"
        
        if not re.search(r'^name\s*=\s*"[^"]+"', content, re.MULTILINE):
            return False, "Invalid wally.toml format (missing name)"
        
        return True, "Valid wally.toml"
    except Exception as e:
        return False, f"Error reading wally.toml: {e}"


def check_src_directory(pkg_dir: Path) -> Tuple[bool, str]:
    """Check if package has src/ directory."""
    src_dir = pkg_dir / "src"
    
    if not src_dir.is_dir():
        return False, "Missing src/ directory"
    
    return True, "Has src/ directory"


def check_default_project_json(pkg_dir: Path) -> Tuple[bool, str]:
    """Check if package has default.project.json or can generate it."""
    default_proj = pkg_dir / "default.project.json"
    
    if default_proj.is_file():
        try:
            json.loads(default_proj.read_text(encoding="utf-8"))
            return True, "Has default.project.json"
        except json.JSONDecodeError:
            return False, "Invalid default.project.json (malformed JSON)"
    
    # Check if we can generate it
    if (pkg_dir / "src").is_dir():
        return True, "Can generate default.project.json"
    
    return False, "Cannot generate default.project.json (no src/ directory)"


def validate_packages() -> bool:
    """Validate all packages in lib/."""
    print("Checking package structure...")
    
    packages = find_packages()
    if not packages:
        return False
    
    all_valid = True
    checks = [
        ("wally.toml", check_wally_toml),
        ("src/ directory", check_src_directory),
        ("default.project.json", check_default_project_json),
    ]
    
    for pkg_dir in packages:
        pkg_name = pkg_dir.name
        pkg_valid = True
        
        for check_name, check_func in checks:
            is_valid, message = check_func(pkg_dir)
            symbol = "✓" if is_valid else "✗"
            print(f"  {symbol} {pkg_name}: {check_name} - {message}")
            if not is_valid:
                pkg_valid = False
        
        if not pkg_valid:
            all_valid = False
    
    return all_valid


def validate_action_inputs() -> bool:
    """Check if publish action has all required inputs."""
    print("Checking publish action configuration...")
    
    action_file = Path(".github/actions/publish-packages/action.yml")
    
    if not action_file.is_file():
        print(f"✗ Action file not found: {action_file}")
        return False
    
    content = action_file.read_text(encoding="utf-8")
    required_inputs = ["changed-packages-file", "version-change", "wally-token"]
    
    all_valid = True
    for input_name in required_inputs:
        if re.search(f"^\\s*{re.escape(input_name)}:", content, re.MULTILINE):
            print(f"✓ Action has input: {input_name}")
        else:
            print(f"✗ Action missing input: {input_name}")
            all_valid = False
    
    return all_valid


def validate_workflow_inputs() -> bool:
    """Check if workflow passes all required inputs to the publish action."""
    print("Checking workflow configuration...")
    
    workflow_file = Path(".github/workflows/publish-package.yml")
    
    if not workflow_file.is_file():
        print(f"✗ Workflow file not found: {workflow_file}")
        return False
    
    content = workflow_file.read_text(encoding="utf-8")
    required_inputs = ["changed-packages-file", "version-change", "wally-token"]
    
    all_valid = True
    for input_name in required_inputs:
        if re.search(f"^\\s*{input_name}:", content, re.MULTILINE):
            print(f"✓ Workflow passes input: {input_name}")
        else:
            print(f"✗ Workflow missing input: {input_name}")
            all_valid = False
    
    return all_valid


def validate_version_preview(version_change: str, changed_packages_file: str) -> bool:
    """Echo detected version type and preview package version updates."""
    print(f"Detected version type: {version_change}")
    if version_change == "none":
        print("No semver change detected; skipping update preview.")
        return True

    changed_path = Path(changed_packages_file)
    if not changed_path.is_file():
        print(f"✗ Changed packages file not found: {changed_packages_file}")
        return False

    packages = [line.strip() for line in changed_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not packages:
        print("No changed packages detected; skipping update preview.")
        return True

    all_valid = True
    for pkg in packages:
        wally_file = Path("lib") / pkg / "wally.toml"
        if not wally_file.is_file():
            print(f"✗ Package {pkg} is missing wally.toml")
            all_valid = False
            continue

        content = wally_file.read_text(encoding="utf-8")
        match = re.search(r'^version\s*=\s*"([^"]+)"', content, re.MULTILINE)
        if not match:
            print(f"✗ Package {pkg} is missing a valid version in wally.toml")
            all_valid = False
            continue

        old_version = match.group(1)
        try:
            new_version = increment_version(old_version, version_change)
        except ValueError as e:
            print(f"✗ Package {pkg} has invalid version/increment: {e}")
            all_valid = False
            continue

        print(f"Will update {pkg} from {old_version} to {new_version}")

    return all_valid


def run_all_checks() -> int:
    """Run all validation checks."""
    print("\n" + "="*60)
    print("VALIDATING PUBLISH SETUP")
    print("="*60 + "\n")
    
    try:
        packages_valid = validate_packages()
        print()
        action_valid = validate_action_inputs()
        print()
        workflow_valid = validate_workflow_inputs()
        
        print("\n" + "="*60)
        print("SUMMARY")
        print("="*60)
        
        if packages_valid and action_valid and workflow_valid:
            print("✓ All validations passed!")
            return 0
        else:
            print("✗ Some validations failed.")
            return 1
    
    except Exception as e:
        print(f"\n✗ Validation error: {e}", file=sys.stderr)
        return 1


def main():
    parser = argparse.ArgumentParser(description="Validate publish setup configuration.")
    parser.add_argument(
        "--check",
        choices=["packages", "action-inputs", "workflow-inputs", "version-preview", "wally-ready", "all"],
        default="all",
        help="Which check to run (default: all)"
    )
    parser.add_argument(
        "--version-change",
        choices=["major", "minor", "patch", "none"],
        default="none",
        help="Version change type used for version-preview check."
    )
    parser.add_argument(
        "--changed-packages-file",
        default="changed-packages.txt",
        help="Path to newline-delimited changed package names used for version-preview check."
    )
    args = parser.parse_args()
    
    try:
        if args.check == "packages":
            result = validate_packages()
            return 0 if result else 1
        elif args.check == "action-inputs":
            result = validate_action_inputs()
            return 0 if result else 1
        elif args.check == "workflow-inputs":
            result = validate_workflow_inputs()
            return 0 if result else 1
        elif args.check == "version-preview":
            result = validate_version_preview(args.version_change, args.changed_packages_file)
            return 0 if result else 1
        elif args.check == "wally-ready":
            result = validate_wally_ready()
            return 0 if result else 1
        else:  # all
            return run_all_checks()
    
    except Exception as e:
        print(f"✗ Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
