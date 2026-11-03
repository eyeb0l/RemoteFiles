import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import ci_scope
from ci_scope import classify, find_ui_evidence

NOTHING = {"quick": False, "ui": False, "voiceover": False, "release": False}
QUICK_ONLY = {"quick": True, "ui": False, "voiceover": False, "release": False}
QUICK_AND_UI = {"quick": True, "ui": True, "voiceover": False, "release": False}
EVERYTHING = {"quick": True, "ui": True, "voiceover": True, "release": True}


def lanes(result):
    return {key: result[key] for key in NOTHING}


class CIScopeTests(unittest.TestCase):
    def test_documentation_only_avoids_mac_runners(self):
        result = classify(["docs/DEVELOPMENT.md", "README.md", "Vendor/Citadel/UPSTREAM.md", "design/icon-options/a.png"])
        self.assertEqual(lanes(result), NOTHING)
        self.assertEqual(result["reasons"], {})

    def test_ordinary_code_unit_tests_and_generated_project_use_quick_validation_only(self):
        for path in ("Sources/RemoteFilesUI/FolderView.swift", "Sources/RemoteFilesCore/SFTPRemoteFileService.swift",
                     "Sources/RemoteFilesCore/HostTrustStore.swift", "Tests/RemoteFilesCoreTests/SFTPIntegrationTests.swift",
                     "RemoteFiles.xcodeproj/project.pbxproj", "scripts/test_runner_finalization.py",
                     "Tests/SmallFeatureFixtures/SmallFeaturesUITests.swift"):
            with self.subTest(path=path):
                result = classify([path])
                self.assertEqual(lanes(result), QUICK_ONLY)
                self.assertEqual(result["reasons"], {})

    def test_ui_journeys_app_target_packages_vendored_code_and_demo_resources_add_the_ui_tier(self):
        for path in ("Tests/RemoteFilesUITests/RemoteFilesUITests.swift", "App/Info.plist", "Package.swift", "Package.resolved",
                     "RemoteFiles.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                     "Vendor/Textual/Sources/Textual/StructuredText/Style/Overflow.swift",
                     "Sources/RemoteFilesCore/Resources/Demo/Projects/Weekly review.md", "Fixtures/generate-fixtures.py"):
            with self.subTest(path=path):
                result = classify([path])
                self.assertEqual(lanes(result), QUICK_AND_UI)
                self.assertEqual(result["reasons"], {path: "ui"})

    def test_voiceover_fixtures_and_launcher_add_only_the_voiceover_lane(self):
        for path in ("Tests/VoiceOverFixtures/VoiceOverUITests.swift", "Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift",
                     "scripts/test-voiceover.sh"):
            with self.subTest(path=path):
                result = classify([path])
                self.assertEqual(lanes(result), {"quick": True, "ui": False, "voiceover": True, "release": False})
                self.assertEqual(result["reasons"], {path: "voiceover"})

    def test_ci_infrastructure_and_unknown_paths_run_every_lane(self):
        for path in (".github/workflows/ci.yml", ".github/actions/validate/action.yml", "scripts/ci_scope.py",
                     "scripts/test-acceptance.py", "scripts/test-openssh.sh", "scripts/generate-project.py",
                     "NewModule/entry.swift", "LICENSE.swift", ".gitattributes"):
            with self.subTest(path=path):
                result = classify([path])
                self.assertEqual(lanes(result), EVERYTHING)
                self.assertEqual(result["reasons"], {path: "ui, voiceover, release"})

    def test_mixed_change_takes_the_broadest_tier_of_any_path(self):
        result = classify(["docs/CI.md", "Sources/RemoteFilesUI/ReaderView.swift", "Tests/RemoteFilesUITests/RemoteFilesUITests.swift"])
        self.assertEqual(lanes(result), QUICK_AND_UI)
        self.assertEqual(list(result["reasons"]), ["Tests/RemoteFilesUITests/RemoteFilesUITests.swift"])

    def test_main_push_adds_ui_journeys_to_merged_code_only(self):
        self.assertEqual(lanes(classify(["Sources/RemoteFilesUI/FolderView.swift"], main_push=True)), QUICK_AND_UI)
        self.assertEqual(lanes(classify(["Tests/VoiceOverFixtures/VoiceOverUITests.swift"], main_push=True)),
                         {"quick": True, "ui": True, "voiceover": True, "release": False})
        self.assertEqual(lanes(classify(["docs/CI.md"], main_push=True)), NOTHING)

    def test_label_schedule_or_full_dispatch_runs_every_lane_even_for_docs(self):
        self.assertEqual(lanes(classify(["README.md"], force_acceptance=True)), EVERYTHING)
        self.assertEqual(lanes(classify([], force_acceptance=True)), EVERYTHING)

    def test_manual_quick_request_runs_tests_without_forcing_acceptance(self):
        self.assertEqual(lanes(classify([], force_quick=True)), QUICK_ONLY)


REPOSITORY = "owner/repo"
TREE = "a" * 40
BASE = "b" * 40
PR_HEAD = "c" * 40
MERGED = "d" * 40
SHARD_1, SHARD_2 = ci_scope.UI_SHARD_JOBS


def pull_request_run(**overrides):
    return {"id": 7, "event": "pull_request", "conclusion": "success", "path": ci_scope.CI_WORKFLOW, "head_sha": PR_HEAD,
            "head_commit": {"tree_id": TREE}, "head_repository": {"full_name": REPOSITORY}, **overrides}


def jobs(shard_1="success", shard_2="success"):
    return [{"name": "Repository checks", "conclusion": "success"}, {"name": SHARD_1, "conclusion": shard_1},
            {"name": SHARD_2, "conclusion": shard_2}]


class FakeAPI:
    """Answers the three requests the check makes and records them."""

    def __init__(self, runs=None, run_jobs=None, compare="ahead"):
        self.runs = [pull_request_run()] if runs is None else runs
        self.run_jobs = jobs() if run_jobs is None else run_jobs
        self.compare = compare
        self.paths = []

    def __call__(self, path):
        self.paths.append(path)
        if "/runs?" in path:
            return {"workflow_runs": self.runs}
        if "/jobs?" in path:
            return {"jobs": self.run_jobs}
        if "/compare/" in path:
            return {"status": self.compare}
        raise AssertionError("Unexpected request: " + path)


class UIEvidenceTests(unittest.TestCase):
    def find(self, api, repository=REPOSITORY, base=BASE, tree=TREE):
        with mock.patch.object(ci_scope, "tree_of", return_value=tree), contextlib.redirect_stdout(io.StringIO()) as output:
            self.output = output
            return find_ui_evidence(repository, base, MERGED, api)

    def test_matching_tree_with_both_shards_green_skips(self):
        api = FakeAPI()
        self.assertEqual(self.find(api)["id"], 7)
        self.assertEqual(api.paths, [
            "repos/owner/repo/actions/workflows/ci.yml/runs?event=pull_request&status=success&per_page=50",
            "repos/owner/repo/actions/runs/7/jobs?filter=latest&per_page=100",
            "repos/owner/repo/compare/" + BASE + "..." + PR_HEAD + "?per_page=1"])

    def test_head_identical_to_previous_main_tip_is_evidence(self):
        self.assertIsNotNone(self.find(FakeAPI(compare="identical")))

    def test_any_shard_short_of_success_does_not_skip(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", None):
            for run_jobs in (jobs(shard_1=conclusion), jobs(shard_2=conclusion)):
                with self.subTest(conclusion=conclusion, jobs=run_jobs):
                    self.assertIsNone(self.find(FakeAPI(run_jobs=run_jobs)))

    def test_missing_shard_does_not_skip(self):
        for name in ci_scope.UI_SHARD_JOBS:
            with self.subTest(missing=name):
                self.assertIsNone(self.find(FakeAPI(run_jobs=[job for job in jobs() if job["name"] != name])))

    def test_shards_the_run_skipped_do_not_skip(self):
        # GitHub reports a skipped matrix job once, under its unexpanded name; PR #67's run looks like this.
        run_jobs = [{"name": "Repository checks", "conclusion": "success"},
                    {"name": "Acceptance / simulator-ui-shard-${{ matrix.shard }}", "conclusion": "skipped"}]
        self.assertIsNone(self.find(FakeAPI(run_jobs=run_jobs)))

    def test_failed_job_sharing_a_shard_name_does_not_skip(self):
        self.assertIsNone(self.find(FakeAPI(run_jobs=jobs() + [{"name": SHARD_1, "conclusion": "failure"}])))

    def test_different_tree_does_not_skip_or_read_that_runs_jobs(self):
        api = FakeAPI(runs=[pull_request_run(head_commit={"tree_id": "e" * 40})])
        self.assertIsNone(self.find(api))
        self.assertEqual(len(api.paths), 1)

    def test_run_without_a_head_commit_is_not_a_match(self):
        self.assertIsNone(self.find(FakeAPI(runs=[pull_request_run(head_commit=None)])))

    def test_no_recent_runs_does_not_skip(self):
        self.assertIsNone(self.find(FakeAPI(runs=[])))

    def test_api_failures_do_not_skip(self):
        for error in (subprocess.CalledProcessError(1, "gh"), subprocess.TimeoutExpired("gh", 30), FileNotFoundError("gh"),
                      json.JSONDecodeError("Expecting value", "", 0)):
            with self.subTest(error=error):
                self.assertIsNone(self.find(mock.Mock(side_effect=error)))
                self.assertIn("UI evidence check failed", self.output.getvalue())

    def test_failure_after_a_matching_run_does_not_skip(self):
        for failing in ("/jobs?", "/compare/"):
            api = FakeAPI()

            def respond(path, failing=failing, api=api):
                if failing in path:
                    raise subprocess.CalledProcessError(1, "gh")
                return api(path)

            with self.subTest(failing=failing):
                self.assertIsNone(self.find(respond))

    def test_malformed_payloads_do_not_skip(self):
        for payload in ({}, {"workflow_runs": None}, {"message": "API rate limit exceeded"}, [], None):
            with self.subTest(payload=payload):
                self.assertIsNone(self.find(lambda path, payload=payload: payload))
        for run in ({"head_commit": {"tree_id": TREE}}, pull_request_run(head_repository=None)):
            with self.subTest(run=run):
                self.assertIsNone(self.find(FakeAPI(runs=[run])))
        self.assertIsNone(self.find(lambda path: {"workflow_runs": [pull_request_run()]} if "/runs?" in path else {}))

    def test_failed_tree_lookup_does_not_skip_or_call_the_api(self):
        api = FakeAPI()
        with mock.patch.object(ci_scope, "tree_of", side_effect=subprocess.CalledProcessError(128, "git")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(find_ui_evidence(REPOSITORY, BASE, MERGED, api))
        self.assertEqual(api.paths, [])

    def test_absent_repository_does_not_skip_or_call_the_api(self):
        api = FakeAPI()
        self.assertIsNone(self.find(api, repository=""))
        self.assertEqual(api.paths, [])

    def test_run_from_a_fork_does_not_skip(self):
        api = FakeAPI(runs=[pull_request_run(head_repository={"full_name": "someone/repo"})])
        self.assertIsNone(self.find(api))
        self.assertEqual(len(api.paths), 1)

    def test_other_workflows_events_and_conclusions_do_not_skip_even_if_the_filters_are_ignored(self):
        for overrides in ({"path": ".github/workflows/other.yml"}, {"event": "workflow_dispatch"}, {"event": "push"},
                          {"conclusion": "failure"}, {"conclusion": None}):
            with self.subTest(overrides=overrides):
                self.assertIsNone(self.find(FakeAPI(runs=[pull_request_run(**overrides)])))

    def test_head_that_does_not_contain_previous_main_tip_does_not_skip(self):
        # The run tested a merge with a base the head lacks, so its head tree was not the tree tested.
        for status in ("behind", "diverged"):
            with self.subTest(status=status):
                self.assertIsNone(self.find(FakeAPI(compare=status)))

    def test_earlier_listed_run_without_the_shards_does_not_hide_a_later_one_that_passed(self):
        quick_only = pull_request_run(id=8)
        passing = pull_request_run(id=7)
        responses = {"8": jobs(shard_1="skipped", shard_2="skipped"), "7": jobs()}
        api = FakeAPI(runs=[quick_only, passing])

        def respond(path):
            if "/jobs?" in path:
                api.run_jobs = responses[path.split("/runs/")[1].split("/")[0]]
            return api(path)

        self.assertEqual(self.find(respond)["id"], 7)


class MainPushSelectionTests(unittest.TestCase):
    def select(self, paths, *arguments, api=None, repository=REPOSITORY):
        api = api or FakeAPI()
        with tempfile.TemporaryDirectory() as directory:
            output_path = Path(directory) / "output"
            environment = {"GITHUB_OUTPUT": str(output_path), "GITHUB_REPOSITORY": repository}
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch("sys.argv", ["ci_scope.py", "--base", BASE, "--head", MERGED, *arguments]), \
                    mock.patch.object(ci_scope, "changed_paths", return_value=paths), \
                    mock.patch.object(ci_scope, "tree_of", return_value=TREE), \
                    mock.patch.object(ci_scope, "gh_api", api), \
                    contextlib.redirect_stdout(io.StringIO()) as log:
                ci_scope.main()
            self.log = log.getvalue()
            self.api = api
            return dict(line.split("=") for line in output_path.read_text().splitlines())

    def test_main_push_with_evidence_skips_only_the_ui_shards(self):
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push"),
                         {"quick": "true", "ui": "false", "voiceover": "false", "release": "false"})
        self.assertIn("already passed on this tree in run 7 at " + PR_HEAD, self.log)

    def test_main_push_with_evidence_keeps_the_voiceover_and_release_selection(self):
        self.assertEqual(self.select([".github/workflows/ci.yml"], "--main-push"),
                         {"quick": "true", "ui": "false", "voiceover": "true", "release": "true"})
        self.assertEqual(self.select(["Tests/VoiceOverFixtures/VoiceOverUITests.swift"], "--main-push"),
                         {"quick": "true", "ui": "false", "voiceover": "true", "release": "false"})

    def test_main_push_without_evidence_runs_the_ui_shards(self):
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push", api=FakeAPI(runs=[]))["ui"], "true")
        self.assertIn("no evidence that a pull request run already passed both shards", self.log)

    def test_main_push_with_an_api_failure_runs_the_ui_shards(self):
        api = mock.Mock(side_effect=subprocess.CalledProcessError(1, "gh"))
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push", api=api)["ui"], "true")
        self.assertIn("UI evidence check failed", self.log)

    def test_pull_request_selection_never_reads_the_api(self):
        self.assertEqual(self.select(["App/Info.plist"])["ui"], "true")
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"])["ui"], "false")
        self.assertEqual(self.api.paths, [])

    def test_documentation_push_to_main_never_reads_the_api(self):
        self.assertEqual(self.select(["docs/CI.md"], "--main-push")["ui"], "false")
        self.assertEqual(self.api.paths, [])

    def test_explicit_full_run_ignores_evidence(self):
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push", "--full")["ui"], "true")
        self.assertEqual(self.api.paths, [])


class WorkflowContractTests(unittest.TestCase):
    """A renamed job or a missing permission would silently end the skip, so the names stay pinned."""

    workflow = (Path(__file__).resolve().parents[1] / ci_scope.CI_WORKFLOW).read_text()

    def test_shard_job_names_are_the_ones_the_workflow_produces(self):
        self.assertEqual(ci_scope.UI_SHARD_JOBS, ("Acceptance / simulator-ui-shard-1", "Acceptance / simulator-ui-shard-2"))
        self.assertIn("name: Acceptance / simulator-ui-shard-${{ matrix.shard }}", self.workflow)
        self.assertIn("shard: [1, 2]", self.workflow)

    def test_selector_can_read_run_results_and_nothing_can_write(self):
        permissions = self.workflow.split("\npermissions:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual([line.split("#")[0].strip() for line in permissions.splitlines()], ["contents: read", "actions: read"])
        self.assertIn("GH_TOKEN: ${{ github.token }}\n        run: python3 -B scripts/ci_scope.py", self.workflow)


if __name__ == "__main__":
    unittest.main()
