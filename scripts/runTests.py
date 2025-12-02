#!/usr/bin/env python3
"""
Run tests for the project.
Initializes submodules, creates test place if needed, and optionally opens Roblox Studio.
"""

import os
import sys
import subprocess
from pathlib import Path


SRC_DIR = Path("lib")
TEST_PLACE = "TestEz Companion.rbxl"


def find_project_root() -> Path:
    """Find and change to the project root directory."""
    current_dir = Path.cwd()
    while current_dir != current_dir.parent:
        if (current_dir / SRC_DIR).is_dir():
            os.chdir(current_dir)
            return current_dir
        current_dir = current_dir.parent
    return Path.cwd()


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
    find_project_root()

    print("Initializing submodules...")
    run_command(["git", "submodule", "init"])
    run_command(["git", "submodule", "update"])

    # Check if test place exists, create if not
    test_place = Path(TEST_PLACE)
    if not test_place.is_file():
        print("Test place not found, creating it...")
        run_command(["rojo", "build", "-o", TEST_PLACE])

    # Ask about opening Roblox Studio
    user_input = input("Do you want to open Roblox Studio? (y/n): ").strip().lower()
    
    if user_input == "y":
        # Get username for path
        username = os.environ.get("USERNAME") or os.environ.get("USER")
        
        # Find Roblox Studio - check common locations
        roblox_versions_dir = Path(f"C:/Users/{username}/AppData/Local/Roblox/Versions")
        
        roblox_studio_path = None
        if roblox_versions_dir.is_dir():
            # Find the most recent version folder containing RobloxStudioBeta.exe
            for version_dir in roblox_versions_dir.iterdir():
                if version_dir.is_dir():
                    studio_exe = version_dir / "RobloxStudioBeta.exe"
                    if studio_exe.is_file():
                        roblox_studio_path = studio_exe
                        break

        if roblox_studio_path:
            print("Opening Roblox Studio...")
            # Use subprocess.Popen to open without waiting
            subprocess.Popen([str(roblox_studio_path), str(test_place.absolute())])
        else:
            print("Error: Could not find Roblox Studio installation.")
            print("Please open the test place manually.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
