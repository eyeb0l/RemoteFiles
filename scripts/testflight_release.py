#!/usr/bin/env python3
"""Tag a commit on main whose CI passed, which starts the Xcode Cloud TestFlight workflow.

Prints the plan unless --push is given. See docs/TESTFLIGHT.md.
"""
import argparse
import json
import re
import subprocess
import sys

REPOSITORY = "eyeb0l/RemoteFiles"
GITHUB_ACTIONS_APP_ID = 15368
REQUIRED_CHECKS = ("Repository checks", "CI gate")
TAG_PREFIX = "testflight/"
PROJECT = "RemoteFiles.xcodeproj/project.pbxproj"


class ReleaseError(Exception):
    pass


def capture(*command):
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as error:
        raise ReleaseError(" ".join(command) + " failed: " + error.stderr.strip()) from error


def unmet_checks(check_runs):
    """Name each required check whose newest GitHub Actions run did not succeed."""
    unmet = []
    for name in REQUIRED_CHECKS:
        # A nightly run or a rerun can report the same check twice on one commit.
        runs = [run for run in check_runs
                if run.get("name") == name and run.get("app", {}).get("id") == GITHUB_ACTIONS_APP_ID]
        newest = max(runs, key=lambda run: run.get("started_at") or "", default=None)
        if newest is None:
            unmet.append(name + ": missing")
        elif newest.get("conclusion") != "success":
            unmet.append(name + ": " + str(newest.get("conclusion") or newest.get("status")))
    return unmet


def marketing_version(project):
    versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project))
    if len(versions) != 1:
        raise ReleaseError("Expected one MARKETING_VERSION, found " + (", ".join(sorted(versions)) or "none"))
    version = versions.pop()
    # App Store Connect requires one to three period-separated integers.
    if not re.fullmatch(r"\d+(\.\d+){0,2}", version):
        raise ReleaseError("MARKETING_VERSION is not a valid App Store version: " + version)
    return version


def next_tag(version, existing):
    """Number releases per version. Xcode Cloud assigns the build number separately."""
    prefix = TAG_PREFIX + version + "-"
    used = [int(tag[len(prefix):]) for tag in existing
            if tag.startswith(prefix) and tag[len(prefix):].isdecimal()]
    return prefix + str(max(used, default=0) + 1)


def remote_tags(ls_remote):
    return [line.split("refs/tags/", 1)[1] for line in ls_remote.splitlines() if "refs/tags/" in line]


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", default="refs/remotes/origin/main", help="Commit on main; defaults to its tip")
    parser.add_argument("--push", action="store_true", help="Push the tag, which starts the TestFlight build")
    args = parser.parse_args(arguments)
    try:
        capture("git", "fetch", "--quiet", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
        commit = capture("git", "rev-parse", "--verify", args.commit + "^{commit}").strip()
        if subprocess.run(["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"]).returncode != 0:
            raise ReleaseError(commit + " is not on main")
        response = json.loads(capture("gh", "api", "repos/" + REPOSITORY + "/commits/" + commit +
                                      "/check-runs?per_page=100&app_id=" + str(GITHUB_ACTIONS_APP_ID)))
        unmet = unmet_checks(response["check_runs"])
        if unmet:
            raise ReleaseError("CI has not passed on " + commit + ": " + "; ".join(unmet))
        version = marketing_version(capture("git", "show", commit + ":" + PROJECT))
        existing = remote_tags(capture("git", "ls-remote", "--tags", "--refs", "origin", "refs/tags/" + TAG_PREFIX + "*"))
        tag = next_tag(version, existing)
        print("Commit:  " + commit)
        print("Version: " + version)
        print("Tag:     " + tag)
        if not args.push:
            print("Dry run. Repeat with --push to start the TestFlight build.")
            return 0
        capture("git", "push", "--quiet", "origin", commit + ":refs/tags/" + tag)
        print("Pushed. Xcode Cloud assigns the build number; follow it in App Store Connect.")
        return 0
    except ReleaseError as error:
        print("error: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
