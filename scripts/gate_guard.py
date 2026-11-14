#!/usr/bin/env python3
"""Fail when a pull request changes the files that decide whether it may merge.

Run by .github/workflows/gate-guard.yml from the base branch's checkout, never the pull request's,
so a pull request cannot change what this reports about it.
"""
import json
import os
import subprocess
import sys

from ci_scope import INFRASTRUCTURE, matches

# The workflow and its actions, the scripts that choose and judge the lanes, this check, and the
# Xcode Cloud scripts, which run with signing access and start no lane at all.
GATE = INFRASTRUCTURE + ("scripts/gate_guard.py", "ci_scripts/*")
# GitHub lists at most this many files for a pull request; beyond it some would go unseen.
LISTING_LIMIT = 3000


def gate_paths(files):
    """Paths among a pull request's changed files that belong to the gate. A rename counts under both names."""
    names = {name for item in files for name in (item["filename"], item.get("previous_filename")) if name}
    return sorted(name for name in names if matches(name, GATE))


def changed_files(repository, number):
    output = subprocess.run(["gh", "api", "--paginate", "--slurp", f"repos/{repository}/pulls/{number}/files?per_page=100"],
                            check=True, capture_output=True, text=True).stdout
    return [item for page in json.loads(output) for item in page]


def main():
    files = changed_files(os.environ["GITHUB_REPOSITORY"], int(os.environ["PR_NUMBER"]))
    if len(files) >= LISTING_LIMIT:
        print(f"::error::This pull request changes {len(files)} files or more, too many to list in full, so it is treated as changing the gate.")
        return 1
    touched = gate_paths(files)
    if not touched:
        print(f"None of the {len(files)} changed files belongs to the gate.")
        return 0
    for path in touched:
        print(f"::error file={path}::{path} decides which checks run or what they accept.")
    print("This pull request changes the checks that gate it, so its other checks passing shows less than usual. "
          "Someone must read these changes before it merges; see docs/CI.md, \"Gate guard\".")
    return 1


if __name__ == "__main__":
    sys.exit(main())
