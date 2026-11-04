#!/usr/bin/env python3
"""Choose CI lanes from the complete change list; unknown inputs get every lane."""
import argparse
from fnmatch import fnmatchcase
import json
import os
from pathlib import Path
import re
import subprocess

# Documentation and repository metadata: Repository checks only, no Mac runner.
REPOSITORY_ONLY = ("docs/*", "README.md", "AGENTS.md", "ROADMAP.md", "PREVIEW_STATUS.md",
                   "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", ".gitignore",
                   "Vendor/*/UPSTREAM.md", "Tests/LinuxSearchAcceptance/README.md", "design/*",
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
              "Tests/LinuxSearchAcceptance/*")
LANES = ("ui", "voiceover", "release")
# The evidence that lets a push to main skip the UI journeys.
CI_WORKFLOW = ".github/workflows/ci.yml"
UI_JOBS = ("Acceptance / simulator-ui",)


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


def ui_passed(jobs):
    # A skipped, cancelled or missing UI job is not evidence, and neither is one of two jobs sharing a name.
    return all({job.get("conclusion") for job in jobs if job.get("name") == name} == {"success"} for name in UI_JOBS)


def find_ui_evidence(repository, base, head, api):
    """Return the pull request run that already passed the UI journeys on head's tree, or None.

    A pull_request run tests a merge of the PR head into its base, whose commit the API does
    not report. That merge has the head's tree only when the head contains the base. Every main
    base the run can have used is at or before main's previous tip, so the head must contain it.
    Any error, missing data or doubt returns None, which runs the journeys.
    """
    try:
        if not repository:
            raise ValueError("GITHUB_REPOSITORY is not set")
        tree = tree_of(head)
        root = "repos/" + repository + "/"
        runs = api(root + "actions/workflows/" + Path(CI_WORKFLOW).name + "/runs?event=pull_request&status=success&per_page=50")
        for run in runs["workflow_runs"]:
            if ((run.get("head_commit") or {}).get("tree_id") == tree
                    and run["event"] == "pull_request" and run["conclusion"] == "success" and run["path"] == CI_WORKFLOW
                    and run["head_repository"]["full_name"] == repository  # A fork's run executes the fork's workflow.
                    and ui_passed(api(root + "actions/runs/" + str(run["id"]) + "/jobs?filter=latest&per_page=100")["jobs"])
                    and api(root + "compare/" + base + "..." + run["head_sha"] + "?per_page=1")["status"] in ("ahead", "identical")):
                return run
    except Exception as error:  # Deliberately broad: whatever went wrong, the journeys run.
        print("UI evidence check failed, so the UI journeys run: " + repr(error))
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("CI_BASE_SHA", ""))
    parser.add_argument("--head", default=os.environ.get("CI_HEAD_SHA", ""))
    parser.add_argument("--full", action="store_true", default=os.environ.get("CI_FORCE_ACCEPTANCE") == "true",
                        help="Run every lane (label, nightly schedule or manual dispatch)")
    parser.add_argument("--quick", action="store_true", default=os.environ.get("CI_FORCE_QUICK") == "true")
    parser.add_argument("--main-push", action="store_true", default=os.environ.get("CI_MAIN_PUSH") == "true",
                        help="Classify a push to main: merged code also runs the UI journeys, "
                             "unless a pull request run already passed them on the same tree")
    args = parser.parse_args()
    result = classify(changed_paths(args.base, args.head), args.full, args.quick, args.main_push)
    evidence = None
    if args.main_push and result["ui"] and not args.full:
        evidence = find_ui_evidence(os.environ.get("GITHUB_REPOSITORY", ""), args.base, args.head, gh_api)
        result["ui"] = evidence is None
    print("Quick validation: " + str(result["quick"]) + "; UI journeys: " + str(result["ui"]) +
          "; VoiceOver: " + str(result["voiceover"]) + "; Release compilation: " + str(result["release"]))
    if args.full:
        print("Every lane requested explicitly")
    if evidence:
        print("Push to main: UI journeys already passed on this tree in run " + str(evidence["id"]) +
              " at " + evidence["head_sha"])
    elif args.main_push and result["quick"]:
        print("Push to main: UI journeys run; no evidence that a pull request run already passed the UI journeys on this tree")
    for path, tier in sorted(result["reasons"].items()):
        print("Escalating change: " + path + " -> " + tier)
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            for key in ("quick",) + LANES:
                output.write(key + "=" + str(result[key]).lower() + "\n")


if __name__ == "__main__":
    main()
