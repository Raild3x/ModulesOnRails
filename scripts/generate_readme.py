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
from urllib.parse import quote

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



def generate_banner(repo_owner: str, repo_name: str) -> str:
    """Generate the banner logo line shown at the very top of the README.

    Uses an absolute raw.githubusercontent.com URL (not a repo-relative path)
    so the image also renders on the Moonwave landing page, not just GitHub.
    """
    banner_url = f"https://raw.githubusercontent.com/{repo_owner}/{repo_name}/main/brand/banner_logo.png"
    return f"![{repo_name} banner]({banner_url})"


def generate_badges(repo_owner: str, repo_name: str, docs_link: str) -> str:
    """Generate the badge line shown at the top of the README.

    The README renders both on GitHub and as the Moonwave landing page, so
    every link is an absolute URL. The coverage badge reads a shields
    endpoint JSON that the Coverage Badge workflow publishes to the `badges`
    branch; it renders as "invalid" until that branch exists.
    """
    repo_url = f"https://github.com/{repo_owner}/{repo_name}"
    coverage_json_url = (
        f"https://raw.githubusercontent.com/{repo_owner}/{repo_name}/badges/coverage.json"
    )
    badges = [
        f"[![CI]({repo_url}/actions/workflows/ci.yml/badge.svg)]({repo_url}/actions/workflows/ci.yml)",
        f"[![Docs](https://img.shields.io/badge/docs-site-blue)]({docs_link}/)",
        f"[![License](https://img.shields.io/github/license/{repo_owner}/{repo_name})]({repo_url}/blob/main/LICENSE)",
        f"[![Coverage](https://img.shields.io/endpoint?url={quote(coverage_json_url, safe='')})]({repo_url}/actions/workflows/coverage-badge.yml)",
    ]
    return " ".join(badges)


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

    # Absolute docs-site URL. The README is rendered on two surfaces: GitHub's repo
    # page (where the table is the only navigation) and the Moonwave landing page.
    # A root-relative /api/... link would 404 on GitHub, so we use the full published
    # URL, which works there and on the production docs site. The one tradeoff is that
    # in `moonwave dev` these links point at the live site rather than localhost; that
    # only affects this index page (guide pages use root-relative links and are fine).
    full_docs_link = f"{docs_link}/api/{package_docs_link}"

    return f'| [{formatted_name}]({full_docs_link}) | `{formatted_name} = "{package_name}@{package_version}"` | {package_description} |'


def main():
    # The generated README (echoed below for the CI log) contains non-Latin-1
    # characters such as the ⚠️ warning emoji. On Windows the console defaults to
    # cp1252, so print() would raise UnicodeEncodeError after the file is already
    # written. Force UTF-8 so the confirmation echo works on any platform.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

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
    readme_content = f"""{generate_badges(repo_owner, repo_name, docs_link)}

{generate_banner(repo_owner, repo_name)}

{repo_name} is a collection of Wally packages to streamline Roblox development.

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

    # Compare new body against existing README body (ignoring the date footer).
    readme_file = Path("README.md")
    DATE_FOOTER_RE = re.compile(r"\n---\n\n\*Last Modified:.*?\*\n$", re.DOTALL)

    existing_body = ""
    existing_date_line = ""
    if readme_file.is_file():
        existing_raw = readme_file.read_text(encoding="utf-8")
        m = DATE_FOOTER_RE.search(existing_raw)
        if m:
            existing_body = existing_raw[: m.start()]
            existing_date_line = m.group(0)
        else:
            existing_body = existing_raw

    if readme_content == existing_body:
        print("\nREADME.md is already up to date. No changes written.")
        return 0

    # Body changed — append a fresh date footer and write.
    readme_content += f"\n---\n\n*Last Modified: {date.today().strftime('%B %d, %Y')}*\n"
    readme_file.write_text(readme_content, encoding="utf-8")

    print(readme_content)
    print("\nREADME.md has been generated successfully.")
    return 0


if __name__ == "__main__":
    exit(main())
