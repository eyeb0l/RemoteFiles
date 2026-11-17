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
from ci_scope import classify, find_evidence

NOTHING = {"quick": False, "ui": False, "voiceover": False, "release": False}
QUICK_ONLY = {"quick": True, "ui": False, "voiceover": False, "release": False}
QUICK_AND_UI = {"quick": True, "ui": True, "voiceover": False, "release": False}
EVERYTHING = {"quick": True, "ui": True, "voiceover": True, "release": True}


def lanes(result):
    return {key: result[key] for key in NOTHING}


class CIScopeTests(unittest.TestCase):
    def test_documentation_only_avoids_mac_runners(self):
        result = classify(["docs/DEVELOPMENT.md", "README.md", "Vendor/Citadel/UPSTREAM.md", "design/icon-options/a.png",
                           "ci_scripts/ci_post_clone.sh"])
        self.assertEqual(lanes(result), NOTHING)
        self.assertEqual(result["reasons"], {})

    def test_ordinary_code_unit_tests_and_generated_project_use_quick_validation_only(self):
        for path in ("Sources/RemoteFilesUI/FolderView.swift", "Sources/RemoteFilesCore/SFTPRemoteFileService.swift",
                     "Sources/RemoteFilesCore/HostTrustStore.swift", "Tests/RemoteFilesCoreTests/SFTPIntegrationTests.swift",
                     "RemoteFiles.xcodeproj/project.pbxproj", "scripts/test_runner_finalization.py",
                     "scripts/test-voiceover.sh",  # A local launcher now; no CI lane executes it.
                     "Tests/SmallFeatureFixtures/SmallFeaturesUITests.swift"):
            with self.subTest(path=path):
                result = classify([path])
                self.assertEqual(lanes(result), QUICK_ONLY)
                self.assertEqual(result["reasons"], {})

    def test_opt_in_server_acceptance_suites_never_select_acceptance_lanes(self):
        # Their launchers copy them into isolated snapshots; no CI target compiles them.
        for readme in ("Tests/LinuxSearchAcceptance/README.md", "Tests/ServerCompatibilityAcceptance/README.md"):
            with self.subTest(path=readme):
                self.assertEqual(lanes(classify([readme])), NOTHING)
        for path in ("Tests/LinuxSearchAcceptance/LinuxServerSearchAcceptanceTests.swift",
                     "Tests/ServerCompatibilityAcceptance/ServerCompatibilityTests.swift"):
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

    def test_voiceover_fixtures_add_only_the_voiceover_lane(self):
        for path in ("Tests/VoiceOverFixtures/VoiceOverUITests.swift", "Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift"):
            with self.subTest(path=path):
                result = classify([path])
                self.assertEqual(lanes(result), {"quick": True, "ui": False, "voiceover": True, "release": False})
                self.assertEqual(result["reasons"], {path: "voiceover"})

    def test_ci_infrastructure_and_unknown_paths_run_every_lane(self):
        for path in (".github/workflows/ci.yml", ".github/actions/validate/action.yml", "scripts/ci_scope.py", "scripts/ci_gate.py",
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
UI_JOB, = ci_scope.LANE_JOBS["ui"]
QUICK_JOBS = ci_scope.LANE_JOBS["quick"]
VOICEOVER_JOB, = ci_scope.LANE_JOBS["voiceover"]
RELEASE_JOB, = ci_scope.LANE_JOBS["release"]


def pull_request_run(**overrides):
    return {"id": 7, "event": "pull_request", "conclusion": "success", "path": ci_scope.CI_WORKFLOW, "head_sha": PR_HEAD,
            "head_commit": {"tree_id": TREE}, "head_repository": {"full_name": REPOSITORY}, **overrides}


def jobs(ui="success", quick="success", voiceover="skipped", release="skipped"):
    return [{"name": "Repository checks", "conclusion": "success"}, {"name": UI_JOB, "conclusion": ui},
            *({"name": name, "conclusion": quick} for name in QUICK_JOBS),
            {"name": VOICEOVER_JOB, "conclusion": voiceover}, {"name": RELEASE_JOB, "conclusion": release}]


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


class EvidenceTests(unittest.TestCase):
    def evidence(self, api, wanted=("ui",), repository=REPOSITORY, base=BASE, tree=TREE, **options):
        with mock.patch.object(ci_scope, "tree_of", return_value=tree), contextlib.redirect_stdout(io.StringIO()) as output:
            self.output = output
            return find_evidence(repository, base, MERGED, api, wanted, **options)

    def find(self, api, **options):
        """The UI journeys' evidence alone."""
        return self.evidence(api, **options).get("ui")

    def test_matching_tree_with_both_shards_green_skips(self):
        api = FakeAPI()
        self.assertEqual(self.find(api)["id"], 7)
        self.assertEqual(api.paths, [
            "repos/owner/repo/actions/workflows/ci.yml/runs?event=pull_request&status=success&per_page=50",
            "repos/owner/repo/actions/runs/7/jobs?filter=latest&per_page=100",
            "repos/owner/repo/compare/" + BASE + "..." + PR_HEAD + "?per_page=1"])

    def test_head_identical_to_previous_main_tip_is_evidence(self):
        self.assertIsNotNone(self.find(FakeAPI(compare="identical")))

    def test_ui_job_short_of_success_does_not_skip(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", None):
            with self.subTest(conclusion=conclusion):
                self.assertIsNone(self.find(FakeAPI(run_jobs=jobs(ui=conclusion))))

    def test_missing_ui_job_does_not_skip(self):
        self.assertIsNone(self.find(FakeAPI(run_jobs=[job for job in jobs() if job["name"] != UI_JOB])))

    def test_failed_job_sharing_the_ui_job_name_does_not_skip(self):
        self.assertIsNone(self.find(FakeAPI(run_jobs=jobs() + [{"name": UI_JOB, "conclusion": "failure"}])))

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
                self.assertIn("Evidence check failed", self.output.getvalue())

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
            self.assertEqual(find_evidence(REPOSITORY, BASE, MERGED, api, ["ui"]), {})
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
        responses = {"8": jobs(ui="skipped"), "7": jobs()}
        api = FakeAPI(runs=[quick_only, passing])

        def respond(path):
            if "/jobs?" in path:
                api.run_jobs = responses[path.split("/runs/")[1].split("/")[0]]
            return api(path)

        self.assertEqual(self.find(respond)["id"], 7)

    def test_each_lane_needs_every_one_of_its_jobs(self):
        self.assertEqual(set(self.evidence(FakeAPI(), wanted=ci_scope.LANE_JOBS)), {"quick", "ui"})
        self.assertEqual(set(self.evidence(FakeAPI(run_jobs=jobs(voiceover="success", release="success")),
                                           wanted=ci_scope.LANE_JOBS)), set(ci_scope.LANE_JOBS))
        one_quick_lane_failed = jobs()
        one_quick_lane_failed[2]["conclusion"] = "failure"
        self.assertEqual(set(self.evidence(FakeAPI(run_jobs=one_quick_lane_failed), wanted=["quick", "ui"])), {"ui"})
        missing_quick_lane = [job for job in jobs() if job["name"] != QUICK_JOBS[1]]
        self.assertEqual(self.evidence(FakeAPI(run_jobs=missing_quick_lane), wanted=["quick"]), {})

    def test_only_the_wanted_lanes_are_reported(self):
        self.assertEqual(set(self.evidence(FakeAPI(), wanted=["quick"])), {"quick"})
        api = FakeAPI()
        self.assertEqual(self.evidence(api, wanted=[]), {})
        self.assertEqual(api.paths, [])

    def test_lanes_may_be_proved_by_different_runs_and_the_search_stops_once_all_are(self):
        runs = [pull_request_run(id=9), pull_request_run(id=8), pull_request_run(id=7)]
        responses = {"9": jobs(ui="skipped"), "8": jobs(quick="failure"), "7": jobs()}
        api = FakeAPI(runs=runs)

        def respond(path):
            if "/jobs?" in path:
                api.run_jobs = responses[path.split("/runs/")[1].split("/")[0]]
            return api(path)

        found = self.evidence(respond, wanted=["quick", "ui"])
        self.assertEqual({lane: run["id"] for lane, run in found.items()}, {"quick": 9, "ui": 8})
        self.assertFalse(any("/runs/7/" in path for path in api.paths))

    def test_a_failure_after_some_lanes_were_proved_discards_all_evidence(self):
        api = FakeAPI(runs=[pull_request_run(id=8), pull_request_run(id=7)])

        def respond(path):
            if "/runs/7/" in path:
                raise subprocess.CalledProcessError(1, "gh")
            if "/runs/8/" in path:
                api.run_jobs = jobs(ui="skipped")
            return api(path)

        self.assertEqual(self.evidence(respond, wanted=["quick", "ui"]), {})

    def test_a_past_merge_looks_back_from_its_own_time(self):
        api = FakeAPI()
        self.evidence(api, wanted=["quick"], created_before="2026-11-16T12:30:00Z")
        self.assertEqual(api.paths[0], "repos/owner/repo/actions/workflows/ci.yml/runs?event=pull_request&status=success"
                                       "&per_page=50&created=%3C%3D2026-11-16T12%3A30%3A00Z")


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

    def test_main_push_with_evidence_skips_every_lane_already_passed_on_its_tree(self):
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push"),
                         {"quick": "false", "ui": "false", "voiceover": "false", "release": "false"})
        self.assertIn("Quick / macos-openssh, Quick / simulator-core already passed on this tree in run 7 at " + PR_HEAD, self.log)
        self.assertIn("Acceptance / simulator-ui already passed on this tree in run 7 at " + PR_HEAD, self.log)
        self.assertNotIn("no evidence", self.log)

    def test_main_push_runs_the_lanes_the_pull_request_did_not_pass(self):
        self.assertEqual(self.select([".github/workflows/ci.yml"], "--main-push"),
                         {"quick": "false", "ui": "false", "voiceover": "true", "release": "true"})
        self.assertIn("no evidence that a pull request run already passed Acceptance / voiceover, "
                      "Acceptance / release-device-compile on this tree", self.log)
        self.assertEqual(self.select(["Tests/VoiceOverFixtures/VoiceOverUITests.swift"], "--main-push",
                                     api=FakeAPI(run_jobs=jobs(voiceover="success"))),
                         {"quick": "false", "ui": "false", "voiceover": "false", "release": "false"})
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push", api=FakeAPI(run_jobs=jobs(ui="skipped"))),
                         {"quick": "false", "ui": "true", "voiceover": "false", "release": "false"})

    def test_main_push_without_evidence_runs_every_selected_lane(self):
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push", api=FakeAPI(runs=[])),
                         {"quick": "true", "ui": "true", "voiceover": "false", "release": "false"})
        self.assertIn("no evidence that a pull request run already passed Quick / macos-openssh, Quick / simulator-core, "
                      "Acceptance / simulator-ui on this tree", self.log)

    def test_main_push_with_an_api_failure_runs_every_selected_lane(self):
        api = mock.Mock(side_effect=subprocess.CalledProcessError(1, "gh"))
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push", api=api),
                         {"quick": "true", "ui": "true", "voiceover": "false", "release": "false"})
        self.assertIn("Evidence check failed", self.log)

    def test_pull_request_selection_never_reads_the_api(self):
        self.assertEqual(self.select(["App/Info.plist"])["ui"], "true")
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"])["ui"], "false")
        self.assertEqual(self.api.paths, [])

    def test_documentation_push_to_main_never_reads_the_api(self):
        self.assertEqual(self.select(["docs/CI.md"], "--main-push")["ui"], "false")
        self.assertEqual(self.api.paths, [])

    def test_explicit_full_run_ignores_evidence(self):
        self.assertEqual(self.select(["Sources/RemoteFilesUI/FolderView.swift"], "--main-push", "--full"),
                         {"quick": "true", "ui": "true", "voiceover": "true", "release": "true"})
        self.assertEqual(self.api.paths, [])


class WorkflowContractTests(unittest.TestCase):
    """A renamed job or a missing permission would silently end the skip, so the names stay pinned."""

    workflow = (Path(__file__).resolve().parents[1] / ci_scope.CI_WORKFLOW).read_text()

    def test_lane_job_names_are_the_ones_the_workflow_produces(self):
        self.assertEqual(ci_scope.LANE_JOBS, {"quick": ("Quick / macos-openssh", "Quick / simulator-core"),
                                              "ui": ("Acceptance / simulator-ui",), "voiceover": ("Acceptance / voiceover",),
                                              "release": ("Acceptance / release-device-compile",)})
        self.assertIn("name: Quick / ${{ matrix.lane }}\n", self.workflow)
        self.assertIn("lane: [macos-openssh, simulator-core]\n", self.workflow)
        for name in ("Acceptance / simulator-ui", "Acceptance / voiceover", "Acceptance / release-device-compile"):
            self.assertIn("name: " + name + "\n", self.workflow)
        self.assertNotIn("shard:", self.workflow)

    def test_selector_can_read_run_results_and_nothing_can_write(self):
        permissions = self.workflow.split("\npermissions:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual([line.split("#")[0].strip() for line in permissions.splitlines()], ["contents: read", "actions: read"])
        self.assertIn("GH_TOKEN: ${{ github.token }}\n        run: python3 -B scripts/ci_scope.py", self.workflow)


if __name__ == "__main__":
    unittest.main()
