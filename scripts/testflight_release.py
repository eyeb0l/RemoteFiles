#!/usr/bin/env python3
"""Tag a commit on main whose CI passed, which starts the Xcode Cloud TestFlight workflow.

Prints the plan unless --push is given. The tag is pushed with a deploy key, the only
credential a repository ruleset lets create `testflight/*` tags. See docs/TESTFLIGHT.md.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys

import ci_scope

REPOSITORY = "eyeb0l/RemoteFiles"
GITHUB_ACTIONS_APP_ID = 15368
REQUIRED_CHECKS = ("Repository checks", "CI gate")
# The lanes that build and test the app. A change to documentation alone starts neither, and
# still passes the two required checks.
CODE_CHECKS = ("Quick / macos-openssh", "Quick / simulator-core")
# How far back on main to look for a commit those lanes passed on.
HISTORY_LIMIT = 50
TAG_PREFIX = "testflight/"
PUSH_URL = "git@github.com:" + REPOSITORY + ".git"
KEY_VARIABLE = "REMOTEFILES_TESTFLIGHT_KEY"
DEFAULT_KEY = "~/.ssh/remotefiles_testflight_deploy"
PROJECT = "RemoteFiles.xcodeproj/project.pbxproj"


class ReleaseError(Exception):
    pass


def capture(*command, env=None):
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True, env=env).stdout
    except subprocess.CalledProcessError as error:
        raise ReleaseError(" ".join(command) + " failed: " + error.stderr.strip()) from error


def unmet_checks(check_runs, names=REQUIRED_CHECKS):
    """Name each of the given checks whose newest GitHub Actions run did not succeed."""
    unmet = []
    for name in names:
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


def checked_key(path):
    """The deploy key, which must need a passphrase: other tools on this Mac can read the file."""
    key = os.path.expanduser(path)
    if not os.path.isfile(key):
        raise ReleaseError("No deploy key at " + key + "; docs/TESTFLIGHT.md explains how to create one")
    # Exporting the public half with an empty passphrase works only for an unprotected key.
    unprotected = subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", key], stdin=subprocess.DEVNULL,
                                 capture_output=True).returncode == 0
    if unprotected:
        raise ReleaseError("The deploy key at " + key + " has no passphrase; add one with ssh-keygen -p -f " + shlex.quote(key))
    return key


def push_command(key, commit, tag, environ=None):
    """The push and its environment.

    No ssh configuration, agent or other identity: ssh asks for this key's passphrase on the
    terminal every time, and cannot save it to the Keychain or leave the key loaded in an agent.
    The command goes in GIT_SSH_COMMAND, which outranks an inherited one, GIT_SSH and
    core.sshCommand; GIT_SSH_VARIANT stops ssh.variant changing the arguments git passes it.
    """
    ssh = "ssh -F none -i " + shlex.quote(key) + " -o IdentitiesOnly=yes -o IdentityAgent=none"
    env = {**(os.environ if environ is None else environ), "GIT_SSH_COMMAND": ssh, "GIT_SSH_VARIANT": "ssh"}
    return ["git", "push", "--quiet", PUSH_URL, commit + ":refs/tags/" + tag], env


def check_runs(commit):
    return json.loads(capture("gh", "api", "repos/" + REPOSITORY + "/commits/" + commit +
                              "/check-runs?per_page=100&app_id=" + str(GITHUB_ACTIONS_APP_ID)))["check_runs"]


def tested_commit(commit, runs):
    """The newest commit on main, at or before `commit`, that the app's lanes passed on.

    The required checks pass on a commit that changes only documentation, with every lane that
    builds the app skipped. So they say nothing about the code that commit carries: an earlier
    commit's run may have failed, or been cancelled by the push after it. Nothing between the
    tested commit and the released one may be something CI would have built.
    """
    history = capture("git", "rev-list", "--first-parent", "--max-count=" + str(HISTORY_LIMIT), commit).split()
    for candidate in history:
        if not unmet_checks(runs if candidate == commit else check_runs(candidate), CODE_CHECKS):
            if candidate != commit:
                untested = ci_scope.classify(ci_scope.changed_paths(candidate, commit))
                if untested["quick"]:
                    paths = [path for path in ci_scope.changed_paths(candidate, commit)
                             if not ci_scope.matches(path, ci_scope.REPOSITORY_ONLY)]
                    raise ReleaseError("CI last built the app at " + candidate + ", and these have changed since without a passing build: " +
                                       ", ".join(paths[:5]) + (" and " + str(len(paths) - 5) + " more" if len(paths) > 5 else ""))
            return candidate
    raise ReleaseError("None of the last " + str(len(history)) + " commits on main has passing " + " and ".join(CODE_CHECKS) + " runs")


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", default="refs/remotes/origin/main", help="Commit on main; defaults to its tip")
    parser.add_argument("--push", action="store_true", help="Push the tag, which starts the TestFlight build")
    parser.add_argument("--key", default=os.environ.get(KEY_VARIABLE, DEFAULT_KEY),
                        help="Deploy key that may create TestFlight tags; defaults to $" + KEY_VARIABLE + " or " + DEFAULT_KEY)
    args = parser.parse_args(arguments)
    try:
        key = checked_key(args.key) if args.push else None
        capture("git", "fetch", "--quiet", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
        commit = capture("git", "rev-parse", "--verify", args.commit + "^{commit}").strip()
        if subprocess.run(["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"]).returncode != 0:
            raise ReleaseError(commit + " is not on main")
        runs = check_runs(commit)
        unmet = unmet_checks(runs)
        if unmet:
            raise ReleaseError("CI has not passed on " + commit + ": " + "; ".join(unmet))
        tested = tested_commit(commit, runs)
        version = marketing_version(capture("git", "show", commit + ":" + PROJECT))
        existing = remote_tags(capture("git", "ls-remote", "--tags", "--refs", "origin", "refs/tags/" + TAG_PREFIX + "*"))
        tag = next_tag(version, existing)
        print("Commit:  " + commit)
        if tested != commit:
            print("Built:   " + tested + " (only documentation has changed since)")
        print("Version: " + version)
        print("Tag:     " + tag)
        if not args.push:
            print("Dry run. Repeat with --push to start the TestFlight build.")
            return 0
        command, env = push_command(key, commit, tag)
        capture(*command, env=env)
        print("Pushed. Xcode Cloud assigns the build number; follow it in App Store Connect.")
        return 0
    except ReleaseError as error:
        print("error: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
