#!/usr/bin/env python3
"""Choose PR validation from the complete change list; unknown inputs get acceptance."""
import argparse
from fnmatch import fnmatchcase
import os
from pathlib import Path
import re
import subprocess

REPOSITORY_ONLY = ("docs/*", "README.md", "AGENTS.md", "ROADMAP.md", "PREVIEW_STATUS.md",
                   "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", ".gitignore")
QUICK = ("Sources/*", "Tests/RemoteFilesCoreTests/*")
ACCEPTANCE = (
    "Vendor/*", "App/*", "Fixtures/*", "Package.*", "RemoteFiles.xcodeproj/*", ".github/*", "scripts/*",
    "Tests/RemoteFilesUITests/*", "Tests/VoiceOverFixtures/*", "Tests/SmallFeatureFixtures/*",
    "Sources/RemoteFilesUI/Reader*", "Sources/RemoteFilesUI/Document*",
    "Sources/RemoteFilesUI/RemoteFilesRootView.swift", "Sources/RemoteFilesUI/FolderView.swift",
    "Sources/RemoteFilesUI/*Image*", "Sources/RemoteFilesUI/*Playback*",
    "Sources/RemoteFilesUI/*HTML*", "Sources/RemoteFilesUI/*SVG*", "Sources/RemoteFilesUI/Source*",
    "Sources/RemoteFilesCore/Resources/*",
    "Sources/RemoteFilesUI/*Key*", "Sources/RemoteFilesUI/*Connection*",
    "Sources/RemoteFilesCore/SFTP*", "Sources/RemoteFilesCore/*Trust*",
    "Sources/RemoteFilesCore/Identity*", "Sources/RemoteFilesCore/MetadataStore.swift",
    "Sources/RemoteFilesCore/*Bound*", "Sources/RemoteFilesCore/DocumentPolicy.swift",
    "Sources/RemoteFilesCore/*Resource*", "Sources/RemoteFilesCore/*Export*",
    "Tests/RemoteFilesCoreTests/*Overflow*", "Tests/RemoteFilesCoreTests/*Reading*",
    "Tests/RemoteFilesCoreTests/*Identity*", "Tests/RemoteFilesCoreTests/*SFTP*",
)


def classify(paths, force_acceptance=False, force_quick=False):
    full = bool(force_acceptance)
    quick = full or bool(force_quick)
    reasons = []
    for path in paths:
        if any(fnmatchcase(path, pattern) for pattern in REPOSITORY_ONLY):
            continue
        quick = True
        if any(fnmatchcase(path, pattern) for pattern in ACCEPTANCE) or not any(fnmatchcase(path, pattern) for pattern in QUICK):
            full = True
            reasons.append(path)
    return {"quick": quick, "acceptance": full, "reasons": sorted(reasons)}


def changed_paths(base, head):
    # Treat an initial push or an absent event base conservatively.
    if not base or set(base) == {"0"}:
        return subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")[:-1]
    if not all(re.fullmatch(r"[0-9a-fA-F]{40,64}", value) for value in (base, head)):
        raise ValueError("Expected commit object IDs for base and head")
    # No rename collapsing: both sides of a move must be classified, including deletions.
    return subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", base, head]).decode().split("\0")[:-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("CI_BASE_SHA", ""))
    parser.add_argument("--head", default=os.environ.get("CI_HEAD_SHA", ""))
    parser.add_argument("--full", action="store_true", default=os.environ.get("CI_FORCE_ACCEPTANCE") == "true")
    parser.add_argument("--quick", action="store_true", default=os.environ.get("CI_FORCE_QUICK") == "true")
    args = parser.parse_args()
    result = classify(changed_paths(args.base, args.head), args.full, args.quick)
    print("Quick validation: " + str(result["quick"]) + "; full acceptance: " + str(result["acceptance"]))
    if args.full:
        print("Full acceptance requested explicitly")
    for reason in result["reasons"]:
        print("Acceptance-sensitive change: " + reason)
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            for key in ("quick", "acceptance"):
                output.write(key + "=" + str(result[key]).lower() + "\n")


if __name__ == "__main__":
    main()
