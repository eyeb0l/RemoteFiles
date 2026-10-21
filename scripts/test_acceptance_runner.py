#!/usr/bin/env python3
"""Acceptance environment and skip-policy regressions; no builds or server needed."""
import importlib.util
import contextlib
import io
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("acceptance", Path(__file__).with_name("test-acceptance.py"))
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


class AcceptanceRunnerTests(unittest.TestCase):
    def test_benchmark_runs_once_on_host_and_simulator_and_real_server_is_disabled(self):
        inherited = {"REMOTEFILES_REAL_HOST": "must-not-connect", "TEST_RUNNER_REMOTEFILES_REAL_KEY": "unused",
                     "REMOTEFILES_BENCHMARK_RUNS": "100"}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, inherited):
            run = acceptance.Run(Path(directory), Path(directory), {})
        for prefix in ("", "TEST_RUNNER_"):
            self.assertEqual(run.env[prefix + "REMOTEFILES_REAL_SERVER"], "0")
            self.assertEqual(run.env[prefix + "REMOTEFILES_BENCHMARK"], "1")
            self.assertEqual(run.env[prefix + "REMOTEFILES_BENCHMARK_RUNS"], "1")
            self.assertEqual(run.env[prefix + "REMOTEFILES_BENCHMARK_LABEL"], "acceptance-loopback")
        self.assertNotIn("REMOTEFILES_REAL_HOST", run.env)
        self.assertNotIn("TEST_RUNNER_REMOTEFILES_REAL_KEY", run.env)

    def check_skipped_result(self, identifier, allowed_skips, expected_status):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "test.log"
            cls, method = identifier.split("/")
            log.write_text(f"Test Case '-[{cls} {method}]' skipped (0.001 seconds).\n")
            run = acceptance.Run(root, root, {"commit": "fixture", "mode": "test", "source_tree_sha256": "fixture"})
            lane = {"name": "fixture", "status": "passed", "errors": [], "log": str(log)}
            run.lanes.append(lane)
            with contextlib.redirect_stdout(io.StringIO()) as console:
                run.tests(lane, {identifier}, allowed_skips)
            if expected_status == "failed":
                self.assertIn("ERROR: Unexpected skips:", console.getvalue())
            self.assertEqual(lane["status"], expected_status, lane["errors"])
            self.assertEqual(lane["counts"], {"skipped": 1})

    def test_simulator_data_protection_skip_is_reported_and_allowed(self):
        self.check_skipped_result("IdentityTests/testTrustStoreWritesUseCompleteFileProtection",
                                  acceptance.SIMULATOR_ALLOWED_SKIPS, "passed")

    def test_keychain_skip_still_fails_simulator_acceptance(self):
        self.check_skipped_result("IdentityTests/testDeviceKeychainPersistenceAndAccessibility",
                                  acceptance.SIMULATOR_ALLOWED_SKIPS, "failed")

    def test_benchmark_skip_still_fails_host_acceptance(self):
        self.check_skipped_result("LatencyBenchmarkTests/testRoundTripSensitiveOperations", (), "failed")


class LogResultTests(unittest.TestCase):
    def test_interleaved_system_diagnostics_do_not_hide_completed_results(self):
        for outcome in ("passed", "failed", "skipped"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "test.log"
                log.write_text(
                    f"Test Case '-[RemoteFilesTests.PlaybackTests testCodec]' {outcome}"
                    "2026-10-19 17:02:35.586656+0000 TestHost[8471:44930] [AQ] diagnostic\n"
                    " (0.050 seconds).\n")
                self.assertEqual(acceptance.log_tests(log), {"PlaybackTests/testCodec": outcome})

    def test_structured_diagnostics_inside_identifiers_preserve_every_outcome(self):
        diagnostic = "2026-10-20 07:46:30.173137+0000 RemoteFilesTestHost[11686:48841] [player] codec diagnostic\n"
        for prefix, suffix in (("Remote", "FilesTests.PlaybackTests testCodec"),
                               ("RemoteFilesTests.Playback", "Tests testCodec"),
                               ("RemoteFilesTests.PlaybackTests testCo", "dec")):
            for outcome in ("passed", "failed", "skipped"):
                with self.subTest(prefix=prefix, outcome=outcome), tempfile.TemporaryDirectory() as directory:
                    log = Path(directory) / "test.log"
                    log.write_text(f"Test Case '-[{prefix}{diagnostic}{suffix}]' {outcome} (0.644 seconds).\n")
                    self.assertEqual(acceptance.log_tests(log), {"PlaybackTests/testCodec": outcome})

    def test_structured_diagnostics_inside_result_prefix_preserve_every_outcome(self):
        diagnostic = ("2026-10-21 01:23:18.442121+0000 RemoteFilesTestHost[11405:46073] [player] "
                      "<<<< FigFilePlayer >>>> signalled err=-12864 at <>:10684\n")
        prefix = "Test Case '-["
        for offset in range(1, len(prefix)):
            for outcome in ("passed", "failed", "skipped"):
                with self.subTest(offset=offset, outcome=outcome), tempfile.TemporaryDirectory() as directory:
                    log = Path(directory) / "test.log"
                    log.write_text("Test Case '-[ExampleTests testOne]' passed (0.001 seconds).\n"
                                   f"{prefix[:offset]}{diagnostic}{prefix[offset:]}"
                                   f"RemoteFilesTests.PlaybackTests testM4AAudioPlaybackSeekingAndCleanup]' {outcome} (0.848 seconds).\n")
                    self.assertEqual(acceptance.log_tests(log),
                                     {"ExampleTests/testOne": "passed",
                                      "PlaybackTests/testM4AAudioPlaybackSeekingAndCleanup": outcome})

    def test_result_prefix_interruptions_still_reject_duplicates_and_unknown_records(self):
        diagnostic = "2026-10-21 01:23:18.442121+0000 TestHost[1:2] [player] diagnostic\n"
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text("Test Case '-[ExampleTests testOne]' passed (0.001 seconds).\n"
                           f"Test Ca{diagnostic}{diagnostic}se '-[ExampleTests testOne]' failed (0.001 seconds).\n")
            with self.assertRaisesRegex(RuntimeError, "Repeated result"):
                acceptance.log_tests(log)
        for interruption in ("unknown diagnostic\n", "2026-10-21 01:23:18 TestHost diagnostic\n",
                             "2026-10-21 01:23:18.442121+0000 TestHost[1:2] [player] missing newline"):
            with self.subTest(interruption=interruption), tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "test.log"
                log.write_text(f"Test Ca{interruption}se '-[ExampleTests testOne]' passed (0.001 seconds).\n")
                self.assertEqual(acceptance.log_tests(log), {})

    def test_interrupted_identifier_duplicates_are_still_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text("Test Case '-[ExampleTests testOne]' passed (0.001 seconds).\n"
                           "Test Case '-[Exam2026-10-20 07:46:30.173137+0000 TestHost[1:2] [player] diagnostic\n"
                           "pleTests testOne]' failed (0.001 seconds).\n")
            with self.assertRaisesRegex(RuntimeError, "Repeated result"):
                acceptance.log_tests(log)

    def test_unknown_or_unterminated_identifier_interruptions_do_not_create_results(self):
        for interruption in ("unknown diagnostic\n", "2026-10-20 07:46:30 TestHost diagnostic\n",
                             "2026-10-20 07:46:30.173137+0000 TestHost[1:2] [player] missing newline"):
            with self.subTest(interruption=interruption), tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "test.log"
                log.write_text(f"Test Case '-[Exam{interruption}pleTests testOne]' passed (0.001 seconds).\n")
                self.assertEqual(acceptance.log_tests(log), {})

    def test_recovered_identifiers_keep_xcresult_and_outcome_validation(self):
        cases = (("passed", (1, 0, 0), "passed"),
                 ("passed", (0, 1, 0), "failed"),
                 ("failed", (0, 1, 0), "failed"),
                 ("skipped", (0, 0, 1), "failed"))
        for outcome, actual, expected_status in cases:
            with self.subTest(outcome=outcome, actual=actual), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                log = root / "test.log"
                log.write_text("Test Case '-[Exam2026-10-20 07:46:30.173137+0000 TestHost[1:2] [player] diagnostic\n"
                               f"pleTests testOne]' {outcome} (0.001 seconds).\n")
                run = acceptance.Run(root, root, {"commit": "fixture", "mode": "test", "source_tree_sha256": "fixture"})
                lane = {"name": "fixture", "status": "passed", "errors": [], "log": str(log)}
                run.lanes.append(lane)
                def export(command, stdout, **kwargs):
                    summary = dict(zip(("passedTests", "failedTests", "skippedTests"), actual))
                    summary["expectedFailures"] = 0
                    json.dump(summary if "summary" in command else {}, stdout)
                with patch.object(acceptance.subprocess, "run", side_effect=export), contextlib.redirect_stdout(io.StringIO()):
                    run.tests(lane, {"ExampleTests/testOne"}, xcresult=root / "fixture.xcresult")
                self.assertEqual(lane["status"], expected_status, lane["errors"])
                if actual != (1, 0, 0) and outcome == "passed":
                    self.assertTrue(any("xcresult/log count mismatch" in error for error in lane["errors"]))

    def test_interleaved_repeated_results_still_fail_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text("Test Case '-[ExampleTests testOne]' passed (0.001 seconds).\n"
                           "Test Case '-[ExampleTests testOne]' passed2026-10-19 17:02:35 diagnostic\n"
                           " (0.001 seconds).\n")
            with self.assertRaisesRegex(RuntimeError, "Repeated result"):
                acceptance.log_tests(log)

    def test_started_and_incomplete_outcome_names_are_not_results(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text("Test Case '-[ExampleTests testOne]' started.\n"
                           "Test Case '-[ExampleTests testTwo]' passedSomething (0.001 seconds).\n")
            self.assertEqual(acceptance.log_tests(log), {})


class VoiceOverDiagnosticsTests(unittest.TestCase):
    def test_launcher_preserves_xctest_status_when_diagnostic_collection_fails(self):
        script = Path(__file__).with_name("test-voiceover.sh")
        for test_status, trace_status in ((0, 0), (65, 0), (65, 9)):
            with self.subTest(test_status=test_status, trace_status=trace_status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); tools = root / "tools"; tools.mkdir()
                for name, status, output in (("xcodebuild", test_status, "Injected XCTest outcome"),
                                             ("xcrun", trace_status, "Injected SVG diagnostics")):
                    tool = tools / name
                    tool.write_text(f"#!/bin/sh\necho '{output}'\nexit {status}\n")
                    tool.chmod(0o755)
                env = dict(os.environ); env["PATH"] = str(tools) + os.pathsep + env["PATH"]
                output = root / "evidence"
                result = subprocess.run(["bash", str(script), "owned-fixture-simulator", str(output)],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, test_status, result.stderr)
                self.assertIn("Injected XCTest outcome", (output / "voiceover.log").read_text())
                if test_status:
                    self.assertIn("Injected SVG diagnostics", (output / "svg-rendering.log").read_text())
                else:
                    self.assertFalse((output / "svg-rendering.log").exists())


class LaneSelectionTests(unittest.TestCase):
    def test_default_keeps_full_acceptance_and_rejects_overlapping_inventories(self):
        self.assertEqual(acceptance.selected_lanes(None), acceptance.DEFAULT_LANES)
        with self.assertRaises(ValueError):
            acceptance.selected_lanes(["simulator", "simulator-core"])

    def run_lane(self, lane):
        class Recorder:
            root = Path(__file__).resolve().parents[1]
            output = Path("/tmp/unused-evidence")
            env = {}
            commands = []
            inventories = []
            def command(self, name, command):
                self.commands.append((name, command))
                return {"name": name, "log": "unused", "status": "passed"}
            def tests(self, lane, expected, allowed_skips=(), xcresult=None):
                self.inventories.append(expected)
        run = Recorder(); run.commands = []; run.inventories = []
        acceptance.execute_lanes(run, [lane], Path("packages"), Path("scratch"), Path("derived"), "simulator-id")
        return run

    def test_quick_ios_runs_the_complete_hosted_core_inventory_without_ui_journeys(self):
        run = self.run_lane("simulator-core")
        self.assertEqual(len(run.commands), 2)
        build, execution = run.commands[0][1], run.commands[1][1]
        self.assertEqual(build[build.index("-scheme") + 1], "RemoteFilesCoreCI")
        self.assertIn("generic/platform=iOS Simulator", build)
        self.assertEqual(build[-1], "build-for-testing")
        self.assertEqual(execution[-1], "test-without-building")
        self.assertIn("-only-testing:RemoteFilesTests", execution)
        expected = run.inventories[0]
        self.assertIn("OverflowViewportTests/testLargeFastJumpKeepsVisibleProseAnchorAndSourceReturnRestoresSameCharacter", expected)
        self.assertIn("IdentityTests/testDeviceKeychainPersistenceAndAccessibility", expected)
        self.assertFalse(any(name.startswith(("RealServerUITests/", "RemoteFilesUITests/")) for name in expected))

    def test_failed_core_build_never_boots_or_runs_cached_tests(self):
        class FailedBuild:
            root = Path(__file__).resolve().parents[1]
            output = Path("/tmp/unused-evidence")
            env = {}
            def command(self, name, command):
                self.commands.append(name)
                return {"status": "failed"}
            def tests(self, *args, **kwargs):
                raise AssertionError("Failed builds cannot validate stale test products")
        run = FailedBuild(); run.commands = []
        with patch.object(acceptance, "boot_selected_simulator") as boot:
            acceptance.execute_lanes(run, ["simulator-core"], Path("packages"), Path("scratch"), Path("derived"), "sim", True)
            boot.assert_not_called()
        self.assertEqual(run.commands, ["simulator-core-build"])

    def test_core_boot_follows_build_and_precedes_same_inventory_execution(self):
        events = []
        class OrderedRun:
            root = Path(__file__).resolve().parents[1]
            output = Path("/tmp/unused-evidence")
            env = {}
            def command(self, name, command):
                events.append(name)
                return {"status": "passed"}
            def tests(self, lane, expected, allowed_skips=(), xcresult=None):
                self.expected = expected
        run = OrderedRun()
        with patch.object(acceptance, "boot_selected_simulator", side_effect=lambda *args: events.append("boot")):
            acceptance.execute_lanes(run, ["simulator-core"], Path("packages"), Path("scratch"), Path("derived"), "sim", True)
        self.assertEqual(events, ["simulator-core-build", "boot", "simulator-core"])
        self.assertEqual(run.expected, acceptance.expected_tests(run.root, "iOS", ["Tests/RemoteFilesCoreTests"]))

    def test_ui_acceptance_does_not_repeat_the_core_tests(self):
        run = self.run_lane("simulator-ui")
        self.assertIn("-only-testing:RemoteFilesUITests", run.commands[0][1])
        self.assertTrue(any(name.startswith("RealServerUITests/") for name in run.inventories[0]))
        self.assertFalse(any(name.startswith("IdentityTests/") for name in run.inventories[0]))

    def test_mac_lane_never_invokes_xcode_or_a_simulator(self):
        run = self.run_lane("macos-openssh")
        self.assertEqual(len(run.commands), 1)
        self.assertEqual(run.commands[0][1][:3], ["scripts/test-openssh.sh", "swift", "test"])


class DedicatedCheckoutTests(unittest.TestCase):
    def check_build_mutation(self, mutate, dirty=False, escape=False, changed_head=False):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            repo = parent / "repo"
            repo.mkdir()
            source = repo / "input.swift"
            source.write_text("original")
            def git(*args):
                return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
            git("init", "-q")
            if escape:
                (parent / "outside.swift").write_text("outside input")
                (repo / "link.swift").symlink_to(parent / "outside.swift")
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture")
            if dirty:
                source.write_text("uncommitted")
            output = parent / "evidence"
            original_capture = acceptance.capture
            def capture(command, cwd=None):
                if command[0] in ("xcodebuild", "swift"):
                    return "fixture toolchain"
                return original_capture(command, cwd)
            def build(run, *args):
                self.assertEqual(run.root, repo)
                self.assertFalse((output / "source").exists(), "CI must not recopy thousands of source files")
                if mutate:
                    source.write_text("unexpected build mutation")
                if changed_head:
                    git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Unexpected commit")
            argv = ["test-acceptance.py", "--lane", "macos-openssh", "--use-checkout", "--output", str(output)]
            with patch.object(acceptance, "__file__", str(repo / "scripts/test-acceptance.py")), \
                 patch.object(acceptance, "capture", side_effect=capture), \
                 patch.object(acceptance, "execute_lanes", side_effect=build), \
                 patch.object(sys, "argv", argv):
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(acceptance.main(), 1 if mutate or dirty or escape or changed_head else 0)
            if not dirty and not escape:
                self.assertTrue((output / "source-manifest.json").exists())
            if dirty:
                self.assertIn("clean, dedicated checkout", (output / "BLOCKER.txt").read_text())
            if escape:
                self.assertIn("symlink escapes", (output / "BLOCKER.txt").read_text())
            if changed_head:
                self.assertIn("Git state", (output / "BLOCKER.txt").read_text())
            if mutate:
                self.assertIn("changed captured source", (output / "BLOCKER.txt").read_text())

    def test_dirty_dedicated_checkout_is_rejected(self):
        self.check_build_mutation(False, dirty=True)

    def test_source_symlink_cannot_escape_direct_checkout(self):
        self.check_build_mutation(False, escape=True)

    def test_same_source_with_changed_commit_still_fails_identity_validation(self):
        self.check_build_mutation(False, changed_head=True)

    def test_clean_dedicated_checkout_keeps_source_identity_without_copying(self):
        self.check_build_mutation(False)

    def test_build_mutation_still_fails_direct_checkout_validation(self):
        self.check_build_mutation(True)


if __name__ == "__main__":
    unittest.main()
