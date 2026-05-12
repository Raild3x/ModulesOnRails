#!/usr/bin/env python3
"""Detect changed lib packages for publish workflow."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import urllib.request
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Detect changed packages under lib/.")
    parser.add_argument("--event-name", required=True, help="GitHub event name.")
    parser.add_argument("--repository", required=True, help="GitHub repository in owner/name format.")
    parser.add_argument("--pr-number", type=int, default=0, help="Pull request number for PR events.")
    parser.add_argument(
        "--changed-packages-file",
        default="changed-packages.txt",
        help="Output file path for newline-delimited package names.",
    )
    return parser.parse_args()


def run_git_changed_files() -> list[str]:
    completed = subprocess.run(
        ["git", "diff", "--name-only", "HEAD~1", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return []
    return [line.strip() for line in completed.stdout.splitlines() if line.strip()]


def parse_next_link(link_header: str) -> str | None:
    for part in link_header.split(","):
        if 'rel="next"' in part:
            start = part.find("<")
            end = part.find(">")
            if start != -1 and end != -1 and end > start:
                return part[start + 1 : end]
    return None


def fetch_pr_changed_files(repository: str, pr_number: int, token: str) -> list[str]:
    if pr_number <= 0:
        raise ValueError("A positive --pr-number is required for non-dispatch events.")

    url = f"https://api.github.com/repos/{repository}/pulls/{pr_number}/files?per_page=100"
    changed_files: list[str] = []

    while url:
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
            },
        )
        with urllib.request.urlopen(request) as response:
            payload = json.load(response)
            changed_files.extend(str(item.get("filename", "")).strip() for item in payload)
            url = parse_next_link(response.headers.get("Link", ""))

    return [path for path in changed_files if path]


def extract_changed_packages(changed_files: list[str]) -> list[str]:
    packages = set()
    for path in changed_files:
        parts = path.split("/")
        if len(parts) >= 3 and parts[0] == "lib":
            packages.add(parts[1])
    return sorted(packages)


def write_output(name: str, value: str) -> None:
    github_output = os.getenv("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"{name}={value}\n")


def main() -> int:
    args = parse_args()

    if args.event_name == "workflow_dispatch":
        changed_files = run_git_changed_files()
    else:
        token = os.getenv("GITHUB_TOKEN", "")
        if not token:
            raise RuntimeError("GITHUB_TOKEN is required for PR file detection.")
        changed_files = fetch_pr_changed_files(args.repository, args.pr_number, token)

    changed_packages = extract_changed_packages(changed_files)
    out_path = Path(args.changed_packages_file)

    if not changed_packages:
        write_output("has_changes", "false")
        print("No changed packages under lib/.")
        if out_path.exists():
            out_path.unlink()
        return 0

    out_path.write_text("\n".join(changed_packages) + "\n", encoding="utf-8")
    write_output("has_changes", "true")
    print(f"Changed packages: {' '.join(changed_packages)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
