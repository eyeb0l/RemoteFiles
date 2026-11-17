#!/usr/bin/env python3
"""Choose CI lanes from the complete change list; unknown inputs get every lane."""
import argparse
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote

# Documentation and repository metadata: Repository checks only, no Mac runner.
REPOSITORY_ONLY = ("docs/*", "README.md", "AGENTS.md", "ROADMAP.md", "PREVIEW_STATUS.md",
                   "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", ".gitignore",
                   "Vendor/*/UPSTREAM.md", "Tests/LinuxSearchAcceptance/README.md",
                   "Tests/ServerCompatibilityAcceptance/README.md", "design/*",
                   # Runs only in Xcode Cloud; scripts/test_testflight_release.py covers it in Repository checks.
                   "ci_scripts/*")
# A change to the workflow, the runner or its launchers must prove every lane.
INFRASTRUCTURE = (".github/*", "scripts/ci_scope.py", "scripts/ci_gate.py", "scripts/test-acceptance.py", "scripts/runner_finalization.py",
                  "scripts/test-openssh.sh", "scripts/generate-project.py")
# Only the VoiceOver lane executes these.
VOICEOVER = ("Tests/VoiceOverFixtures/*",)
# Only the UI lane builds the app target, runs these journeys or exercises these inputs.
UI = ("Tests/RemoteFilesUITests/*", "App/*", "Package.swift", "Package.resolved", "*/Package.resolved",
      "Vendor/*", "Fixtures/*", "Sources/RemoteFilesCore/Resources/*")
# Covered by the hosted core and macOS lanes, or not executed by CI at all.
QUICK_ONLY = ("Sources/*", "Tests/RemoteFilesCoreTests/*", "RemoteFiles.xcodeproj/*", "scripts/*",
              "Tests/SmallFeatureFixtures/*", "Tests/ImageOpenFixtures/*", "Tests/ReadingAnchorFixtures/*",
              "Tests/LinuxSearchAcceptance/*", "Tests/ServerCompatibilityAcceptance/*")
LANES = ("ui", "voiceover", "release")
CI_WORKFLOW = ".github/workflows/ci.yml"
# The jobs that prove each lane. A push to main skips a lane when a pull request run already
# passed every one of its jobs on the same tree.
LANE_JOBS = {"quick": ("Quick / macos-openssh", "Quick / simulator-core"),
             "ui": ("Acceptance / simulator-ui",),
             "voiceover": ("Acceptance / voiceover",),
             "release": ("Acceptance / release-device-compile",)}


def matches(path, patterns):
    return any(fnmatchcase(path, pattern) for pattern in patterns)


def classify(paths, force_acceptance=False, force_quick=False, main_push=False):
    quick = bool(force_acceptance or force_quick)
    lanes = dict.fromkeys(LANES, bool(force_acceptance))
    reasons = {}

    def escalate(path, *names):
        for name in names:
            lanes[name] = True
        reasons[path] = ", ".join(names)

    for path in paths:
        if matches(path, REPOSITORY_ONLY):
            continue
        quick = True
        if matches(path, INFRASTRUCTURE):
            escalate(path, *LANES)
        elif matches(path, VOICEOVER):
            escalate(path, "voiceover")
        elif matches(path, UI):
            escalate(path, "ui")
        elif not matches(path, QUICK_ONLY):
            escalate(path, *LANES)  # Unknown input: fail closed.
    if main_push and quick:
        lanes["ui"] = True  # Merged code runs the UI journeys once; VoiceOver and Release follow the nightly run.
    return {"quick": quick, **lanes, "reasons": reasons}


def changed_paths(base, head):
    # Treat an initial push or an absent event base conservatively.
    if not base or set(base) == {"0"}:
        return subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")[:-1]
    if not all(re.fullmatch(r"[0-9a-fA-F]{40,64}", value) for value in (base, head)):
        raise ValueError("Expected commit object IDs for base and head")
    # No rename collapsing: both sides of a move must be classified, including deletions.
    return subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z", base, head]).decode().split("\0")[:-1]


def gh_api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], timeout=30))


def tree_of(commit):
    return subprocess.check_output(["git", "rev-parse", "--verify", commit + "^{tree}"], text=True).strip()


def passed_lanes(jobs, wanted):
    """The wanted lanes whose every job succeeded in this attempt.

    A skipped, cancelled or missing job is not evidence, and neither is one of two jobs sharing a name.
    """
    return {lane for lane in wanted
            if all({job.get("conclusion") for job in jobs if job.get("name") == name} == {"success"} for name in LANE_JOBS[lane])}


def find_evidence(repository, base, head, api, wanted, created_before=None):
    """Return {lane: pull request run} for each wanted lane already passed on head's tree.

    A pull_request run tests a merge of the PR head into its base, whose commit the API does
    not report. That merge has the head's tree only when the head contains the base. Every main
    base the run can have used is at or before main's previous tip, so the head must contain it.
    Lanes may be proved by different runs. Any error, missing data or doubt returns no evidence
    at all, which runs every selected lane. `created_before` (ISO 8601) looks back from a past merge.
    """
    wanted = [lane for lane in LANE_JOBS if lane in wanted]
    found = {}
    try:
        if not wanted:
            return found
        if not repository:
            raise ValueError("GITHUB_REPOSITORY is not set")
        tree = tree_of(head)
        root = "repos/" + repository + "/"
        query = "event=pull_request&status=success&per_page=50"
        if created_before:
            query += "&created=" + quote("<=" + created_before)
        runs = api(root + "actions/workflows/" + Path(CI_WORKFLOW).name + "/runs?" + query)
        for run in runs["workflow_runs"]:
            missing = [lane for lane in wanted if lane not in found]
            if not missing:
                break
            if not ((run.get("head_commit") or {}).get("tree_id") == tree
                    and run["event"] == "pull_request" and run["conclusion"] == "success" and run["path"] == CI_WORKFLOW
                    and run["head_repository"]["full_name"] == repository):  # A fork's run executes the fork's workflow.
                continue
            passed = passed_lanes(api(root + "actions/runs/" + str(run["id"]) + "/jobs?filter=latest&per_page=100")["jobs"], missing)
            if passed and api(root + "compare/" + base + "..." + run["head_sha"] + "?per_page=1")["status"] in ("ahead", "identical"):
                found.update(dict.fromkeys(passed, run))
    except Exception as error:  # Deliberately broad: whatever went wrong, every selected lane runs.
        print("Evidence check failed, so every selected lane runs: " + repr(error))
        return {}
    return found


def is_ancestor(commit, head):
    return subprocess.run(["git", "merge-base", "--is-ancestor", commit, head], capture_output=True).returncode == 0


def distance(commit, head):
    return int(subprocess.check_output(["git", "rev-list", "--count", commit + ".." + head], text=True))


def find_validated_base(repository, head, api):
    """Return the nearest earlier commit on main whose push or nightly run of this workflow succeeded, or None.

    Each push cancels the previous push's run, and its own diff from github.event.before would leave
    the cancelled commits to the nightly run: a code merge followed by a documentation merge would run
    nothing on main. Classifying from the last successful run covers them. Any doubt returns None,
    which classifies every file.
    """
    try:
        if not repository:
            raise ValueError("GITHUB_REPOSITORY is not set")
        runs = api("repos/" + repository + "/actions/workflows/" + Path(CI_WORKFLOW).name +
                   "/runs?branch=main&status=success&per_page=50")["workflow_runs"]
        candidates = {run["head_sha"] for run in runs
                      if run["event"] in ("push", "schedule") and run["conclusion"] == "success" and run["path"] == CI_WORKFLOW
                      and run["head_branch"] == "main" and run["head_repository"]["full_name"] == repository}
        candidates = [commit for commit in candidates
                      if re.fullmatch(r"[0-9a-f]{40,64}", commit) and commit != head and is_ancestor(commit, head)]
        if candidates:
            return min(candidates, key=lambda commit: distance(commit, head))
        print("No earlier commit on main has a successful run, so every file is classified")
    except Exception as error:  # Deliberately broad: whatever went wrong, every file is classified.
        print("Validated base check failed, so every file is classified: " + repr(error))
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("CI_BASE_SHA", ""))
    parser.add_argument("--head", default=os.environ.get("CI_HEAD_SHA", ""))
    parser.add_argument("--full", action="store_true", default=os.environ.get("CI_FORCE_ACCEPTANCE") == "true",
                        help="Run every lane (label, nightly schedule or manual dispatch)")
    parser.add_argument("--quick", action="store_true", default=os.environ.get("CI_FORCE_QUICK") == "true")
    parser.add_argument("--main-push", action="store_true", default=os.environ.get("CI_MAIN_PUSH") == "true",
                        help="Classify a push to main: merged code also runs the UI journeys, and any lane "
                             "a pull request run already passed on the same tree is skipped")
    args = parser.parse_args()
    base = args.base
    if args.main_push and not args.full:
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        if repository:
            # An empty base classifies every file.
            base = find_validated_base(repository, args.head, gh_api) or ""
            if base and base != args.base:
                print("Push to main: classifying from " + base + ", the last commit whose run on main passed, not " + args.base)
        else:
            print("GITHUB_REPOSITORY is not set, so this preview classifies from --base without checking earlier runs")
    result = classify(changed_paths(base, args.head), args.full, args.quick, args.main_push)
    evidence = {}
    if args.main_push and not args.full:
        evidence = find_evidence(os.environ.get("GITHUB_REPOSITORY", ""), args.base, args.head, gh_api,
                                 [lane for lane in LANE_JOBS if result[lane]])
        for lane in evidence:
            result[lane] = False
    print("Quick validation: " + str(result["quick"]) + "; UI journeys: " + str(result["ui"]) +
          "; VoiceOver: " + str(result["voiceover"]) + "; Release compilation: " + str(result["release"]))
    if args.full:
        print("Every lane requested explicitly")
    for lane, run in sorted(evidence.items(), key=lambda item: list(LANE_JOBS).index(item[0])):
        print("Push to main: " + ", ".join(LANE_JOBS[lane]) + " already passed on this tree in run " + str(run["id"]) +
              " at " + run["head_sha"])
    if args.main_push and not args.full and any(result[lane] for lane in LANE_JOBS):
        print("Push to main: no evidence that a pull request run already passed " +
              ", ".join(name for lane in LANE_JOBS if result[lane] for name in LANE_JOBS[lane]) + " on this tree")
    for path, tier in sorted(result["reasons"].items()):
        print("Escalating change: " + path + " -> " + tier)
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            for key in ("quick",) + LANES:
                output.write(key + "=" + str(result[key]).lower() + "\n")


if __name__ == "__main__":
    main()
