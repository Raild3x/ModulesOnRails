#!/usr/bin/env python3
"""
Generate README.md from wally.toml files in the lib directory.
"""

import os
import re
import subprocess
import sys
from datetime import date
from pathlib import Path
from typing import Dict, Optional, Tuple

# ---------------------------------------------------------------------------
# Local shared utilities (scripts/_common.py)
# ---------------------------------------------------------------------------
# Insert scripts/ onto sys.path so _common is importable regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import SRC_DIR, find_project_root, parse_wally_toml


def get_git_remote_info() -> Tuple[Optional[str], Optional[str]]:
    """Extract repository owner and name from git remote URL."""
    try:
        remote_url = subprocess.check_output(
            ["git", "config", "--get", "remote.origin.url"],
            text=True
        ).strip()
    except subprocess.CalledProcessError:
        print("Error: Could not get git remote URL")
        return None, None

    # Handle both HTTPS and SSH URLs
    # HTTPS: https://github.com/owner/repo.git
    # SSH: git@github.com:owner/repo.git
    match = re.search(r"github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$", remote_url)
    if match:
        return match.group(1), match.group(2)
    
    print(f"Error: Could not parse remote URL: {remote_url}")
    return None, None



def get_config_value(config: Dict[str, Dict[str, str]], key: str, default: str = "") -> str:
    """Get a value from config, checking both package and custom sections."""
    # Check custom section first (for formattedName, docsLink, etc.)
    if key in config.get("custom", {}):
        return config["custom"][key]
    # Then check package section
    if key in config.get("package", {}):
        return config["package"][key]
    return default


def generate_table_row(config: Dict[str, Dict[str, str]], docs_link: str) -> str:
    """Generate a markdown table row for a package."""
    formatted_name = get_config_value(config, "formattedName")
    package_docs_link = get_config_value(config, "docsLink")
    package_name = get_config_value(config, "name")
    package_version = get_config_value(config, "version")
    package_description = get_config_value(config, "description")
    
    # Use package name if no formatted name provided
    if not formatted_name:
        formatted_name = package_name.replace("raild3x/", "")
        print(f"  No formatted name provided for {formatted_name}. Using package name.")
    
    full_docs_link = f"{docs_link}/api/{package_docs_link}"
    
    return f'| [{formatted_name}]({full_docs_link}) | `{formatted_name} = "{package_name}@{package_version}"` | {package_description} |'


def main():
    find_project_root()

    # Check if source directory exists
    if not SRC_DIR.is_dir():
        print(f"Error: Source directory {SRC_DIR} does not exist.")
        return 1
    
    # Get repository info
    repo_owner, repo_name = get_git_remote_info()
    if not repo_owner or not repo_name:
        return 1
    
    print(f"Repository Owner: {repo_owner}")
    print(f"Repository Name: {repo_name}")
    
    docs_link = f"https://{repo_owner.lower()}.github.io/{repo_name}"
    print(f"Docs Link: {docs_link}")
    
    # Collect packages
    released_packages = []
    unreleased_packages = []
    
    print("\nGenerating README.md...")
    
    # Iterate through package directories
    for package_dir in sorted(SRC_DIR.iterdir()):
        if not package_dir.is_dir():
            continue
        
        wally_toml = package_dir / "wally.toml"
        
        if not wally_toml.is_file():
            print(f"Warning: {wally_toml} not found")
            continue
        
        print(f"Parsing package directory: {package_dir}/")
        
        # Parse the wally.toml file
        config = parse_wally_toml(wally_toml)
        
        # Check if package should be ignored
        if get_config_value(config, "ignore").lower() == "true":
            print(f"  Ignoring package {get_config_value(config, 'name', 'unknown')}")
            continue
        
        # Generate table row
        table_row = generate_table_row(config, docs_link)
        
        # Sort into released or unreleased
        if get_config_value(config, "unreleased").lower() == "true":
            unreleased_packages.append(table_row)
            print("  -> Marked as unreleased")
        else:
            released_packages.append(table_row)
    
    # Generate README content
    readme_content = f"""{repo_name} is a collection of Wally packages to streamline Roblox development.

# Packages

| Package | Latest Version | Description |
|---------|----------------|-------------|
"""
    
    # Add released packages
    if released_packages:
        readme_content += "\n".join(released_packages) + "\n"
    
    # Add unreleased packages section if there are any
    if unreleased_packages:
        readme_content += """

---

# Unreleased Packages

> ⚠️ **Warning:** The following packages are unreleased and have not been fully tested for production use. Use them at your own risk.

| Package | Latest Version | Description |
|---------|----------------|-------------|
"""
    readme_content += "\n".join(unreleased_packages) + "\n"
    
    readme_content += f"\n---\n\n*Last Modified: {date.today().strftime('%B %d, %Y')}*\n"

    # Write README file
    readme_file = Path("README.md")
    with open(readme_file, "w", encoding="utf-8") as f:
        f.write(readme_content)
    
    print("\nREADME.md has been generated successfully.")
    print(readme_content)
    return 0


if __name__ == "__main__":
    exit(main())
