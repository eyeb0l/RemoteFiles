import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

import testflight_release as release

ROOT = Path(__file__).resolve().parent.parent
GUARD = ROOT / "ci_scripts" / "ci_post_clone.sh"


def check(name, conclusion="success", started="2026-11-04T01:00:00Z", app=release.GITHUB_ACTIONS_APP_ID):
    return {"name": name, "status": "completed", "conclusion": conclusion, "started_at": started, "app": {"id": app}}


class CheckGateTests(unittest.TestCase):
    def test_every_required_check_passing_is_accepted(self):
        self.assertEqual(release.unmet_checks([check(name) for name in release.REQUIRED_CHECKS]), [])

    def test_missing_failed_and_running_checks_are_rejected(self):
        running = {"name": "CI gate", "status": "in_progress", "conclusion": None,
                   "started_at": "2026-11-04T01:00:00Z", "app": {"id": release.GITHUB_ACTIONS_APP_ID}}
        self.assertEqual(release.unmet_checks([running]), ["Repository checks: missing", "CI gate: in_progress"])
        self.assertEqual(release.unmet_checks([check("Repository checks", "failure"), check("CI gate", "cancelled")]),
                         ["Repository checks: failure", "CI gate: cancelled"])

    def test_same_named_check_from_another_app_does_not_count(self):
        self.assertEqual(release.unmet_checks([check("Repository checks"), check("CI gate", app=1)]), ["CI gate: missing"])

    def test_newest_run_of_a_check_decides(self):
        older, newer = "2026-11-04T01:00:00Z", "2026-11-04T02:00:00Z"
        passed_later = [check("Repository checks"), check("CI gate", "failure", older), check("CI gate", "success", newer)]
        failed_later = [check("Repository checks"), check("CI gate", "success", older), check("CI gate", "failure", newer)]
        self.assertEqual(release.unmet_checks(passed_later), [])
        self.assertEqual(release.unmet_checks(failed_later), ["CI gate: failure"])


class VersionAndTagTests(unittest.TestCase):
    def test_marketing_version_must_be_single_and_valid(self):
        self.assertEqual(release.marketing_version("MARKETING_VERSION = 0.1.0; MARKETING_VERSION = 0.1.0;"), "0.1.0")
        for project in ("", "MARKETING_VERSION = 0.1.0; MARKETING_VERSION = 0.2.0;", "MARKETING_VERSION = 1.0-beta;"):
            with self.subTest(project=project), self.assertRaises(release.ReleaseError):
                release.marketing_version(project)

    def test_generated_project_has_a_releasable_version(self):
        release.marketing_version((ROOT / release.PROJECT).read_text())

    def test_tag_numbers_count_per_version(self):
        existing = ["testflight/0.1.0-1", "testflight/0.1.0-10", "testflight/0.1.0-9", "testflight/0.2.0-40", "testflight/0.1.0-x"]
        self.assertEqual(release.next_tag("0.1.0", existing), "testflight/0.1.0-11")
        self.assertEqual(release.next_tag("0.3.0", existing), "testflight/0.3.0-1")

    def test_remote_tags_are_parsed_from_ls_remote(self):
        self.assertEqual(release.remote_tags("abc\trefs/tags/testflight/0.1.0-1\ndef\trefs/tags/testflight/0.1.0-2\n"),
                         ["testflight/0.1.0-1", "testflight/0.1.0-2"])


class ReleaseFlowTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.root), "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        self.origin = self.root / "origin.git"
        self.git(self.root, "init", "--quiet", "--bare", "--initial-branch=main", str(self.origin))
        work = self.root / "work"
        self.git(self.root, "clone", "--quiet", str(self.origin), str(work))
        self.git(work, "symbolic-ref", "HEAD", "refs/heads/main")
        self.released = self.commit(work, "first")
        self.git(work, "tag", "testflight/0.1.0-1")
        (work / "RemoteFiles.xcodeproj").mkdir()
        (work / release.PROJECT).write_text("MARKETING_VERSION = 0.1.0;")
        self.git(work, "add", ".")
        self.tip = self.commit(work, "second")
        self.git(work, "push", "--quiet", "origin", "main", "--tags")
        self.git(work, "switch", "--quiet", "-c", "feature")
        self.unmerged = self.commit(work, "unmerged")
        self.git(work, "tag", "testflight/0.1.0-2")
        self.git(work, "push", "--quiet", "origin", "feature", "--tags")
        self.work = work

    def git(self, directory, *arguments):
        return subprocess.run(["git", *arguments], cwd=directory, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, directory, message):
        self.git(directory, "commit", "--quiet", "--allow-empty", "-m", message)
        return self.git(directory, "rev-parse", "HEAD")

    def clone(self, *arguments):
        target = self.root / "clone"
        self.git(self.root, "clone", "--quiet", *arguments, "file://" + str(self.origin), str(target))
        return target

    def guard(self, **variables):
        return subprocess.run([str(GUARD)], cwd=GUARD.parent, env={**self.env, **variables}, capture_output=True, text=True)

    def run_guard(self, clone, commit):
        return self.guard(CI_PRIMARY_REPOSITORY_PATH=str(clone), CI_COMMIT=commit)

    def test_commit_on_main_passes(self):
        self.assertEqual(self.run_guard(self.clone("--branch", "main"), self.tip).returncode, 0)

    def test_unmerged_commit_is_rejected(self):
        result = self.run_guard(self.clone("--branch", "feature"), self.unmerged)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not on main", result.stderr)

    def test_shallow_clone_of_an_older_tag_on_main_passes(self):
        clone = self.clone("--depth", "1", "--branch", "testflight/0.1.0-1")
        self.assertEqual(self.git(clone, "rev-parse", "--is-shallow-repository"), "true")
        self.assertEqual(self.run_guard(clone, self.released).returncode, 0)

    def test_shallow_clone_of_an_unmerged_tag_is_rejected(self):
        self.assertEqual(self.run_guard(self.clone("--depth", "1", "--branch", "testflight/0.1.0-2"), self.unmerged).returncode, 1)

    def test_missing_variables_and_unreachable_remote_fail_closed(self):
        clone = self.clone("--branch", "main")
        self.assertNotEqual(self.guard(CI_COMMIT=self.tip).returncode, 0)
        self.assertNotEqual(self.guard(CI_PRIMARY_REPOSITORY_PATH=str(clone)).returncode, 0)
        self.git(clone, "remote", "set-url", "origin", "file://" + str(self.root / "missing.git"))
        self.assertNotEqual(self.run_guard(clone, self.tip).returncode, 0)

    def deploy_key(self, passphrase="correct horse", name="remotefiles_testflight_deploy"):
        key = self.root / ".ssh" / name
        key.parent.mkdir(exist_ok=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", passphrase, "-f", str(key)], check=True,
                       capture_output=True)
        return key

    def record_checks(self, commit, names):
        """What `gh` reports for one commit; any other commit gets the default."""
        folder = self.root / "checks"
        folder.mkdir(exist_ok=True)
        (folder / (commit + ".json")).write_text(json.dumps({"check_runs": [check(name) for name in names]}))

    def release_command(self, *arguments, checks=release.REQUIRED_CHECKS + release.CODE_CHECKS):
        """Run the real command against the local origin, with `gh` replaced by recorded check runs.

        Only the push address differs: the local origin stands in for GitHub over SSH.
        """
        tools = self.root / "tools"
        tools.mkdir(exist_ok=True)
        (self.root / "checks.json").write_text(json.dumps({"check_runs": [check(name) for name in checks]}))
        gh = tools / "gh"
        # The commit is the path component after "commits/".
        gh.write_text('#!/bin/sh\ncommit=$(printf %s "$2" | sed -n "s|.*/commits/\\([0-9a-f]*\\)/.*|\\1|p")\n'
                      'if [ -f "' + str(self.root / "checks") + '/$commit.json" ]; then cat "' + str(self.root / "checks") + '/$commit.json"\n'
                      'else cat "' + str(self.root / "checks.json") + '"; fi\n')
        gh.chmod(0o755)
        env = {**self.env, "PATH": str(tools) + os.pathsep + self.env["PATH"]}
        launcher = ("import sys; sys.path.insert(0, sys.argv.pop(1)); import testflight_release as release; "
                    "release.PUSH_URL = sys.argv.pop(1); sys.exit(release.main(sys.argv[1:]))")
        return subprocess.run([sys.executable, "-B", "-c", launcher, str(ROOT / "scripts"), "file://" + str(self.origin),
                               *arguments], cwd=self.work, env=env, capture_output=True, text=True)

    def origin_tags(self):
        return self.git(self.origin, "tag", "--list", "testflight/*").split()

    def test_dry_run_pushes_nothing(self):
        result = self.release_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("testflight/0.1.0-3", result.stdout)
        self.assertEqual(self.origin_tags(), ["testflight/0.1.0-1", "testflight/0.1.0-2"])

    def test_dry_run_needs_no_deploy_key(self):
        self.assertFalse((self.root / ".ssh").exists())
        self.assertEqual(self.release_command().returncode, 0)

    def test_push_tags_the_tip_of_main_with_the_next_number(self):
        self.deploy_key()
        result = self.release_command("--push")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "testflight/0.1.0-3"), self.tip)

    def test_push_without_a_passphrase_protected_deploy_key_pushes_nothing(self):
        unprotected = self.deploy_key(passphrase="", name="unprotected")
        for arguments, message in ((("--push",), "No deploy key"),
                                   (("--push", "--key", str(unprotected)), "has no passphrase")):
            with self.subTest(message=message):
                result = self.release_command(*arguments)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.origin_tags(), ["testflight/0.1.0-1", "testflight/0.1.0-2"])

    def test_key_comes_from_the_option_then_the_environment_then_the_default(self):
        key = self.deploy_key(name="elsewhere")
        self.assertEqual(self.release_command("--push", "--key", str(key)).returncode, 0)
        self.assertEqual(self.git(self.origin, "rev-parse", "testflight/0.1.0-3"), self.tip)
        self.env[release.KEY_VARIABLE] = str(key)
        self.assertEqual(self.release_command("--push").returncode, 0)
        self.assertEqual(self.git(self.origin, "rev-parse", "testflight/0.1.0-4"), self.tip)

    def test_push_goes_to_github_over_ssh_with_only_the_deploy_key(self):
        command, env = release.push_command("/keys/deploy key", "abc123", "testflight/0.1.0-3", {"PATH": "/bin"})
        self.assertEqual(command, ["git", "push", "--quiet", "git@github.com:eyeb0l/RemoteFiles.git",
                                   "abc123:refs/tags/testflight/0.1.0-3"])
        self.assertEqual(env["PATH"], "/bin")
        ssh = env["GIT_SSH_COMMAND"]
        self.assertTrue(ssh.startswith("ssh "))
        # A saved passphrase or a loaded agent would let any process on the Mac release.
        for option in ("-F none", "-i '/keys/deploy key'", "-o IdentitiesOnly=yes", "-o IdentityAgent=none"):
            self.assertIn(option, ssh)

    def test_push_replaces_an_inherited_ssh_command(self):
        """Git prefers GIT_SSH_COMMAND to core.sshCommand, so a developer's wrapper would win."""
        fake = self.root / "fake-ssh"
        used = self.root / "used"
        fake.write_text('#!/bin/sh\necho "$0" >> "' + str(used) + '"\nexit 1\n')
        fake.chmod(0o755)
        tools = self.root / "tools"
        tools.mkdir(exist_ok=True)
        (tools / "ssh").symlink_to(fake)
        inherited = {**self.env, "PATH": str(tools) + os.pathsep + self.env["PATH"], "GIT_SSH_COMMAND": "inherited-ssh",
                     "GIT_SSH": "inherited-ssh", "GIT_SSH_VARIANT": "plink"}
        command, env = release.push_command(str(self.deploy_key()), self.tip, "testflight/0.1.0-3", inherited)
        self.assertEqual(env["GIT_SSH_VARIANT"], "ssh")
        self.assertNotEqual(subprocess.run(command, cwd=self.work, env=env, capture_output=True).returncode, 0)
        self.assertEqual(used.read_text().split(), [str(tools / "ssh")])

    def commit_on_main(self, path, message):
        self.git(self.work, "switch", "--quiet", "main")
        target = self.work / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(message)
        self.git(self.work, "add", ".")
        commit = self.commit(self.work, message)
        self.git(self.work, "push", "--quiet", "origin", "main")
        return commit

    def test_documentation_only_tip_is_released_on_the_strength_of_the_last_built_commit(self):
        self.deploy_key()
        docs = self.commit_on_main("docs/NOTES.md", "notes")
        # Its required checks passed with every lane that builds the app skipped.
        self.record_checks(docs, release.REQUIRED_CHECKS)
        result = self.release_command("--push")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Built:   " + self.tip, result.stdout)
        self.assertEqual(self.git(self.origin, "rev-parse", "testflight/0.1.0-3"), docs)

    def test_code_that_no_run_built_is_not_released_behind_a_documentation_commit(self):
        self.deploy_key()
        code = self.commit_on_main("Sources/RemoteFilesCore/Change.swift", "code")
        docs = self.commit_on_main("docs/NOTES.md", "notes")
        # The code commit's run was cancelled by the push after it, which changed only documentation.
        self.record_checks(code, ("Repository checks",))
        self.record_checks(docs, release.REQUIRED_CHECKS)
        result = self.release_command("--push")
        self.assertEqual(result.returncode, 1)
        self.assertIn("CI last built the app at " + self.tip, result.stderr)
        self.assertIn("Sources/RemoteFilesCore/Change.swift", result.stderr)
        self.assertNotIn("docs/NOTES.md", result.stderr)
        self.assertEqual(self.origin_tags(), ["testflight/0.1.0-1", "testflight/0.1.0-2"])

    def test_no_built_commit_in_history_pushes_nothing(self):
        self.deploy_key()
        result = self.release_command("--push", checks=release.REQUIRED_CHECKS)
        self.assertEqual(result.returncode, 1)
        self.assertIn("has passing Quick / macos-openssh and Quick / simulator-core runs", result.stderr)
        self.assertEqual(self.origin_tags(), ["testflight/0.1.0-1", "testflight/0.1.0-2"])

    def test_failed_checks_and_unmerged_commits_push_nothing(self):
        self.deploy_key()
        for arguments, checks, message in ((("--push",), ("Repository checks",), "CI gate: missing"),
                                           (("--push", "--commit", self.unmerged), release.REQUIRED_CHECKS, "not on main")):
            with self.subTest(message=message):
                result = self.release_command(*arguments, checks=checks)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.origin_tags(), ["testflight/0.1.0-1", "testflight/0.1.0-2"])


class ReleaseConfigurationTests(unittest.TestCase):
    def app_settings(self):
        project = (ROOT / release.PROJECT).read_text()
        return [line for line in project.splitlines()
                if "PRODUCT_BUNDLE_IDENTIFIER = dev.iris.RemoteFiles;" in line and "isa = XCBuildConfiguration" in line]

    def test_ci_script_is_executable_with_a_shebang(self):
        self.assertTrue(os.access(GUARD, os.X_OK))
        self.assertTrue(GUARD.read_text().startswith("#!/bin/sh\n"))

    def test_shipping_app_declares_all_ipad_orientations(self):
        # App Store validation rejects a multitasking iPad app without all four.
        settings = self.app_settings()
        self.assertEqual(len(settings), 2)
        for line in settings:
            value = re.search(r'UISupportedInterfaceOrientations_iPad = "([^"]+)"', line).group(1)
            self.assertEqual(set(value.split()), {"UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                                  "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"})

    def test_export_compliance_answer_is_declared_for_every_build(self):
        # Without this key, each uploaded build waits at App Store Connect's questionnaire.
        info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
        self.assertIs(info["ITSAppUsesNonExemptEncryption"], False)

    def test_privacy_manifest_is_copied_into_the_shipping_app_only(self):
        project = (ROOT / release.PROJECT).read_text()
        reference = re.search(r"(\w+) = \{ isa = PBXFileReference;[^}]*path = App/PrivacyInfo\.xcprivacy;", project).group(1)
        build = re.search(r"(\w+) = \{ isa = PBXBuildFile; fileRef = " + reference + r";", project).group(1)
        phases = re.findall(r"isa = PBXResourcesBuildPhase;[^}]*files = \(([^)]*)\)", project)
        self.assertEqual(sum(build in files for files in phases), 1)

    def test_privacy_manifest_declares_each_required_reason_category(self):
        manifest = plistlib.loads((ROOT / "App/PrivacyInfo.xcprivacy").read_bytes())
        self.assertIs(manifest["NSPrivacyTracking"], False)
        self.assertEqual(manifest["NSPrivacyCollectedDataTypes"], [])
        self.assertEqual({entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
                          for entry in manifest["NSPrivacyAccessedAPITypes"]},
                         {"NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
                          "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
                          "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]})


if __name__ == "__main__":
    unittest.main()
