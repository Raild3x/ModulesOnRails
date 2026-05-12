#!/usr/bin/env python3
"""Resolve semantic version bump type from workflow context."""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path


MAJOR_PATTERN = re.compile(r"(^|:|/|-)major$|^major$|semver:major|release:major")
MINOR_PATTERN = re.compile(r"(^|:|/|-)minor$|^minor$|semver:minor|release:minor")
PATCH_PATTERN = re.compile(r"(^|:|/|-)patch$|^patch$|semver:patch|release:patch")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve version change for package publishing.")
    parser.add_argument("--event-name", required=True, help="GitHub event name (workflow_dispatch, pull_request, etc.).")
    parser.add_argument("--event-path", required=True, help="Path to GitHub event payload JSON.")
    parser.add_argument(
        "--dispatch-version-change",
        default="patch",
        choices=["major", "minor", "patch", "none"],
        help="Version change requested for workflow_dispatch.",
    )
    return parser.parse_args()


def load_event(event_path: str) -> dict:
    return json.loads(Path(event_path).read_text(encoding="utf-8"))


def resolve_from_labels(labels: list[str]) -> str:
    for label in labels:
        if MAJOR_PATTERN.search(label):
            return "major"
    for label in labels:
        if MINOR_PATTERN.search(label):
            return "minor"
    for label in labels:
        if PATCH_PATTERN.search(label):
            return "patch"
    return "none"


def write_output(name: str, value: str) -> None:
    github_output = os.getenv("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"{name}={value}\n")


def main() -> int:
    args = parse_args()

    if args.event_name == "workflow_dispatch":
        version_change = args.dispatch_version_change
    else:
        event = load_event(args.event_path)
        labels = [
            str(label.get("name", "")).strip().lower()
            for label in event.get("pull_request", {}).get("labels", [])
            if isinstance(label, dict)
        ]
        version_change = resolve_from_labels(labels)

    write_output("version_change", version_change)
    print(f"Selected version change: {version_change}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
