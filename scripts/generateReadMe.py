#!/usr/bin/env python3
"""
Generate README.md from wally.toml files in the lib directory.
"""

import os
import subprocess
import re
from pathlib import Path


def get_git_remote_info():
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


def parse_wally_toml(file_path: Path) -> dict:
    """Parse a wally.toml file and extract relevant fields."""
    config = {}
    current_section = None
    
    with open(file_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            
            # Check for section headers
            if line.startswith("[") and line.endswith("]"):
                current_section = line[1:-1]
                continue
            
            # Parse key-value pairs
            if "=" in line:
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                
                # Store with section prefix for custom fields
                if current_section == "custom":
                    config[key] = value
                elif current_section == "package":
                    config[key] = value
                else:
                    config[key] = value
    
    return config


def generate_table_row(package: dict, docs_link: str) -> str:
    """Generate a markdown table row for a package."""
    formatted_name = package.get("formattedName", "")
    package_docs_link = package.get("docsLink", "")
    package_name = package.get("name", "")
    package_version = package.get("version", "")
    package_description = package.get("description", "")
    
    # Use package name if no formatted name provided
    if not formatted_name:
        formatted_name = package_name.replace("raild3x/", "")
        print(f"  No formatted name provided for {formatted_name}. Using package name.")
    
    full_docs_link = f"{docs_link}/api/{package_docs_link}"
    
    return f'| [{formatted_name}]({full_docs_link}) | `{formatted_name} = "{package_name}@{package_version}"` | {package_description} |'


def main():
    src_dir = Path("lib")
    
    # Find project root by looking for the lib directory
    current_dir = Path.cwd()
    while current_dir != current_dir.parent:
        if (current_dir / src_dir).is_dir():
            os.chdir(current_dir)
            break
        current_dir = current_dir.parent
    
    # Check if source directory exists
    if not src_dir.is_dir():
        print(f"Error: Source directory {src_dir} does not exist.")
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
    for package_dir in sorted(src_dir.iterdir()):
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
        if config.get("ignore", "").lower() == "true":
            print(f"  Ignoring package {config.get('name', 'unknown')}")
            continue
        
        # Generate table row
        table_row = generate_table_row(config, docs_link)
        
        # Sort into released or unreleased
        if config.get("unreleased", "").lower() == "true":
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
# Unreleased Packages

> ⚠️ **Warning:** The following packages are unreleased and have not been fully tested for production use. Use them at your own risk.

| Package | Latest Version | Description |
|---------|----------------|-------------|
"""
        readme_content += "\n".join(unreleased_packages) + "\n"
    
    # Write README file
    readme_file = Path("README.md")
    with open(readme_file, "w", encoding="utf-8") as f:
        f.write(readme_content)
    
    print("\nREADME.md has been generated successfully.")
    return 0


if __name__ == "__main__":
    exit(main())
