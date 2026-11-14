#!/usr/bin/env python3
"""Acceptance environment and skip-policy regressions; no builds or server needed."""
import importlib.util
import contextlib
import inspect
import io
import json
import os
import re
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


class HostLoadSamplerTests(unittest.TestCase):
    def test_ps_rows_are_parsed_and_summarized_by_average_process_share(self):
        rows = acceptance.parse_ps_cpu(" 95.0 /usr/libexec/backboardd\n 40.5 RemoteFiles\nbad line\n 12.0 /a/b/testmanagerd\n")
        self.assertEqual(rows, [(95.0, "backboardd"), (40.5, "RemoteFiles"), (12.0, "testmanagerd")])
        summary = acceptance.summarize_load([rows, [(5.0, "backboardd"), (30.0, "SimRenderServer")]])
        self.assertEqual(summary[0], ["backboardd", 50.0])
        self.assertEqual([name for name, _ in summary], ["backboardd", "RemoteFiles", "SimRenderServer", "testmanagerd"])

    def test_sampler_records_load_while_running_and_survives_ps_failures(self):
        calls = []
        def read_ps():
            calls.append(1)
            if len(calls) == 2:
                raise OSError("ps unavailable")
            return " 80.0 /System/SimRenderServer\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lane-load.log"
            with acceptance.LoadSampler(path, interval=0.01, read_ps=read_ps) as sampler:
                while len(calls) < 3:
                    pass
            summary = sampler.summary()
            self.assertGreaterEqual(summary["samples"], 3)
            self.assertEqual(summary["busiest_processes"][0][0], "SimRenderServer")
            self.assertIsNotNone(summary["load_1m_max"])
            self.assertIn("load ", path.read_text())
            self.assertIn("SimRenderServer 80%", path.read_text())


class SimulatorSettleTests(unittest.TestCase):
    def test_waits_until_load_falls_below_threshold(self):
        loads = iter([520.0, 300.0, 110.0, 90.0])
        sleeps = []
        result = acceptance.settle_after_boot(threshold=120, limit=480, interval=15,
                                              load=lambda: (next(loads), 0, 0), sleep=sleeps.append)
        self.assertTrue(result["settled"])
        self.assertEqual(result["waited_seconds"], 30)
        self.assertEqual(sleeps, [15, 15])
        self.assertEqual(result["samples"], [[0, 520.0], [15, 300.0], [30, 110.0]])

    def test_gives_up_at_the_limit_without_failing(self):
        sleeps = []
        result = acceptance.settle_after_boot(threshold=120, limit=45, interval=15,
                                              load=lambda: (400.0, 0, 0), sleep=sleeps.append)
        self.assertFalse(result["settled"])
        self.assertEqual(result["waited_seconds"], 45)
        self.assertEqual(len(sleeps), 3)

    def test_boot_allows_for_the_slowest_healthy_first_boots(self):
        with tempfile.TemporaryDirectory() as directory:
            run = acceptance.Run(Path(directory), Path(directory), {"phases": []})
            with patch.object(acceptance.subprocess, "run") as command, \
                 patch.object(acceptance, "capture", return_value='{"devices": {}}'):
                acceptance.boot_selected_simulator(run, "UDID")
            self.assertEqual([(call.args[0][2], call.kwargs["timeout"]) for call in command.call_args_list],
                             [("boot", 60), ("bootstatus", 600)])
            # The slowest boot that finished took 298 seconds in all; one stopped at 300 was still working.
            self.assertGreaterEqual(acceptance.BOOT_STATUS_SECONDS, 2 * 298)

    def test_settle_runs_only_for_measured_ci_boots(self):
        with tempfile.TemporaryDirectory() as directory:
            run = acceptance.Run(Path(directory), Path(directory), {"phases": []})
            calls = []
            with patch.object(acceptance.subprocess, "run"), \
                 patch.object(acceptance, "capture", return_value='{"devices": {}}'), \
                 patch.object(acceptance, "settle_after_boot", side_effect=lambda: calls.append(1) or {"settled": True}):
                acceptance.boot_selected_simulator(run, "UDID")
                self.assertEqual(calls, [])
                run.measure_resources = True
                acceptance.boot_selected_simulator(run, "UDID")
            self.assertEqual(calls, [1])
            self.assertEqual([phase["name"] for phase in run.metadata["phases"]],
                             ["simulator-boot", "simulator-boot", "simulator-settle"])


class LogResultTests(unittest.TestCase):
    def test_xcresult_timeout_is_reported_when_the_log_has_no_completed_result(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "test.log"
            log.write_text("Test Case '-[ExampleTests testHung]' started.\n")
            run = acceptance.Run(root, root, {"commit": "fixture", "mode": "test", "source_tree_sha256": "fixture"})
            lane = {"name": "fixture", "status": "failed", "errors": [], "log": str(log)}
            run.lanes.append(lane)
            def export(command, stdout, **kwargs):
                summary = {"passedTests": 0, "failedTests": 1, "skippedTests": 0, "expectedFailures": 0,
                           "testFailures": [{"testIdentifierString": "ExampleTests/testHung()",
                                             "failureText": "Test exceeded execution time allowance of 3 minutes"}]}
                json.dump(summary if "summary" in command else {}, stdout)
            with patch.object(acceptance.subprocess, "run", side_effect=export), contextlib.redirect_stdout(io.StringIO()) as console:
                run.tests(lane, {"ExampleTests/testHung"}, xcresult=root / "fixture.xcresult")
            self.assertEqual(lane["status"], "failed")
            self.assertIn("Missing results: ExampleTests/testHung", console.getvalue())
            self.assertIn("ExampleTests/testHung(): Test exceeded execution time allowance of 3 minutes", console.getvalue())

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

    def test_structured_diagnostic_between_identifier_and_outcome_preserves_the_result(self):
        # Verbatim from simulator-core.log of run 43538623080, attempt 1.
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text(
                "Test Case '-[RemoteFilesTests.PlaybackTests testCorruptRefreshPreservesPreviousPlayerAndReportsCodecError]' started.\n"
                "2026-11-14 01:24:21.103006+0000 RemoteFilesTestHost[35848:128801] [] <<<< FFR_Common >>>> signalled err=-12848 at <>:4132\n"
                "Test Case '-[RemoteFilesTests.PlaybackTests testCorruptRefreshPreservesPreviousPlayerAndReportsCodecError]'"
                "2026-11-14 01:24:21.111681+0000 RemoteFilesTestHost[35848:128845] [AQ]        LoudnessManager.mm:1222  "
                "IsHardwareSupported: no plist loaded, returning false\n"
                " passed (0.014 seconds).\n")
            self.assertEqual(acceptance.log_tests(log),
                             {"PlaybackTests/testCorruptRefreshPreservesPreviousPlayerAndReportsCodecError": "passed"})

    def test_structured_diagnostics_at_any_offset_of_a_result_line_preserve_every_outcome(self):
        diagnostic = "2026-11-14 01:24:21.111681+0000 RemoteFilesTestHost[35848:128845] [AQ] diagnostic\n"
        for outcome in ("passed", "failed", "skipped"):
            line = f"Test Case '-[RemoteFilesTests.PlaybackTests testCodec]' {outcome} (0.014 seconds).\n"
            for offset in range(1, len(line)):
                with self.subTest(outcome=outcome, offset=offset), tempfile.TemporaryDirectory() as directory:
                    log = Path(directory) / "test.log"
                    log.write_text(line[:offset] + diagnostic + diagnostic + line[offset:])
                    self.assertEqual(acceptance.log_tests(log), {"PlaybackTests/testCodec": outcome})

    def test_unknown_unterminated_or_line_start_interruptions_before_the_outcome_create_no_result(self):
        # Only a complete record that begins mid-line was spliced in. A line break of XCTest's own
        # before the outcome leaves the result ambiguous, whatever follows it.
        for interruption in ("unknown diagnostic\n", "2026-11-14 01:24:21 TestHost diagnostic\n",
                             "2026-11-14 01:24:21.111681+0000 TestHost[1:2] [AQ] missing newline",
                             "\n2026-11-14 01:24:21.111681+0000 TestHost[1:2] [AQ] diagnostic\n"):
            with self.subTest(interruption=interruption), tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "test.log"
                log.write_text(f"Test Case '-[ExampleTests testOne]'{interruption} passed (0.001 seconds).\n")
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


class VoiceOverLaneTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[1]

    def run_lane_ending(self, status, directory):
        class Lane:
            root = self.root
            output = Path(directory)
            commands = []
            def command(self, name, command, timeout=None):
                self.commands.append((name, command))
                return {"status": "passed" if name.endswith("-build") else status}
            def tests(self, *args, **kwargs):
                pass
        run = Lane(); run.commands = []
        acceptance.execute_lanes(run, ["voiceover"], Path("packages"), Path("scratch"), Path("derived"), "owned-simulator")
        return run

    def test_failed_lane_collects_only_the_svg_lifecycle_category_from_its_own_simulator(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(acceptance.subprocess, "run") as collect:
            self.run_lane_ending("failed", directory)
        command = collect.call_args.args[0]
        self.assertEqual(command[:4], ["xcrun", "simctl", "spawn", "owned-simulator"])
        self.assertIn('subsystem == "dev.iris.RemoteFiles" AND category == "SVGPreview"', command)
        self.assertIsNotNone(collect.call_args.kwargs.get("timeout"), "A stalled log query must not hold the lane")

    def test_passing_lane_collects_no_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(acceptance.subprocess, "run") as collect:
            self.run_lane_ending("passed", directory)
            self.assertFalse((Path(directory) / "svg-rendering.log").exists())
        collect.assert_not_called()

    def test_diagnostic_failure_leaves_the_lane_failure_as_the_report(self):
        for error in (subprocess.TimeoutExpired("log", 120), OSError("no simctl")):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory, \
                 patch.object(acceptance.subprocess, "run", side_effect=error), \
                 contextlib.redirect_stdout(io.StringIO()) as printed:
                self.run_lane_ending("failed", directory)
                self.assertIn("SVG lifecycle log collection failed", printed.getvalue())


class LaneSelectionTests(unittest.TestCase):
    def test_default_keeps_full_acceptance_and_rejects_overlapping_inventories(self):
        self.assertEqual(acceptance.selected_lanes(None), acceptance.DEFAULT_LANES)
        with self.assertRaises(ValueError):
            acceptance.selected_lanes(["simulator", "simulator-core"])

    def run_lane(self, lane, ui_shard=None):
        class Recorder:
            root = Path(__file__).resolve().parents[1]
            output = Path("/tmp/unused-evidence")
            env = {}
            commands = []
            inventories = []
            deadlines = {}
            skips = []
            def command(self, name, command, timeout=None):
                self.commands.append((name, command))
                self.deadlines[name] = timeout
                return {"name": name, "log": "unused", "status": "passed"}
            def tests(self, lane, expected, allowed_skips=(), xcresult=None):
                self.inventories.append(expected)
                self.skips.append(allowed_skips)
        run = Recorder(); run.commands = []; run.inventories = []; run.deadlines = {}; run.skips = []
        acceptance.execute_lanes(run, [lane], Path("packages"), Path("scratch"), Path("derived"), "simulator-id", ui_shard=ui_shard)
        return run

    def test_ui_shards_cover_every_inventoried_method_exactly_once(self):
        root = Path(__file__).resolve().parents[1]
        expected = acceptance.expected_tests(root, "iOS", ["Tests/RemoteFilesUITests"])
        for inventory in (expected, expected | {"RemoteFilesUITests/testFutureJourney"}):
            first = acceptance.ui_shard_tests(inventory, 1)
            second = acceptance.ui_shard_tests(inventory, 2)
            self.assertEqual(first | second, inventory)
            self.assertFalse(first & second)
            self.assertLessEqual(abs(len(first) - len(second)), 1)
            self.assertEqual(first, acceptance.ui_shard_tests(set(reversed(sorted(inventory))), 1))
        with self.assertRaisesRegex(ValueError, "empty"):
            acceptance.ui_shard_tests({"RemoteFilesUITests/testOnly"}, 2)

    def test_ui_shard_execution_selects_exact_expected_methods_and_builds_full_target(self):
        for shard in (1, 2):
            with self.subTest(shard=shard):
                run = self.run_lane("simulator-ui", shard)
                build, execution = run.commands[0][1], run.commands[1][1]
                self.assertEqual([arg for arg in build if str(arg).startswith("-only-testing:")],
                                 ["-only-testing:RemoteFilesUITests"])
                actual = {arg.removeprefix("-only-testing:RemoteFilesUITests/")
                          for arg in execution if str(arg).startswith("-only-testing:")}
                self.assertEqual(actual, run.inventories[0])
                self.assertEqual(execution[-1], "test-without-building")
                self.assertNotIn("-only-testing:RemoteFilesUITests", execution)
                self.assertEqual(execution[execution.index("-default-test-execution-time-allowance") + 1], "180")
                self.assertEqual(execution[execution.index("-maximum-test-execution-time-allowance") + 1], "240")

    def test_ui_shard_cli_rejects_other_lanes_and_invalid_shards_before_creating_evidence(self):
        script = Path(__file__).with_name("test-acceptance.py")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "must-not-exist"
            cases = (["--ui-shard", "1"], ["--lane", "simulator", "--ui-shard", "1"],
                     ["--lane", "simulator-core", "--ui-shard", "1"],
                     ["--lane", "simulator-ui", "--lane", "voiceover", "--ui-shard", "1"],
                     ["--lane", "simulator-ui", "--ui-shard", "0"])
            for args in cases:
                with self.subTest(args=args):
                    result = subprocess.run([sys.executable, "-B", str(script), *args,
                                             "--output", str(output)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("--ui-shard", result.stderr)
                    self.assertNotIn("unrecognized arguments", result.stderr)
                    self.assertFalse(output.exists())

    def test_shard_validation_still_rejects_missing_extra_repeated_failed_and_unexpected_skipped_methods(self):
        inventory = {"RemoteFilesUITests/testOne", "RemoteFilesUITests/testTwo", "RemoteFilesUITests/testThree"}
        expected = acceptance.ui_shard_tests(inventory, 1)
        selected = sorted(expected)
        unselected = next(iter(inventory - expected))
        cases = ([ (name, "passed") for name in selected[:-1] ],
                 [ (name, "passed") for name in selected + [unselected] ],
                 [ (name, "passed") for name in selected + [selected[0]] ],
                 [(selected[0], "failed"), (selected[1], "passed")],
                 [(selected[0], "skipped"), (selected[1], "passed")])
        for records in cases:
            with self.subTest(records=records), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                log = root / "shard.log"
                log.write_text("".join(f"Test Case '-[{name.replace('/', ' ')}]' {outcome} (0.001 seconds).\n"
                                       for name, outcome in records))
                run = acceptance.Run(root, root, {"commit": "fixture", "mode": "test", "source_tree_sha256": "fixture"})
                lane = {"name": "simulator-ui-shard-1", "status": "passed", "errors": [], "log": str(log)}
                run.lanes.append(lane)
                with contextlib.redirect_stdout(io.StringIO()):
                    run.tests(lane, expected)
                self.assertEqual(lane["status"], "failed", lane)

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

    def check_failed_build_never_boots_or_runs_cached_tests(self, lane, ui_shard=None):
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
            acceptance.execute_lanes(run, [lane], Path("packages"), Path("scratch"), Path("derived"), "sim", True, ui_shard=ui_shard)
            boot.assert_not_called()
        self.assertEqual(run.commands, [lane + "-build"])

    def test_failed_build_never_boots_or_runs_cached_tests(self):
        for lane, shard in (("simulator-core", None), ("simulator-ui", None), ("simulator-ui", 1), ("simulator-ui", 2), ("voiceover", None)):
            with self.subTest(lane=lane, shard=shard):
                self.check_failed_build_never_boots_or_runs_cached_tests(lane, shard)

    def check_boot_follows_build_and_precedes_same_inventory_execution(self, lane, directory):
        events = []
        class OrderedRun:
            root = Path(__file__).resolve().parents[1]
            output = Path("/tmp/unused-evidence")
            env = {}
            def command(self, name, command, timeout=None):
                events.append(name)
                return {"status": "passed"}
            def tests(self, lane, expected, allowed_skips=(), xcresult=None):
                self.expected = expected
        run = OrderedRun()
        with patch.object(acceptance, "boot_selected_simulator", side_effect=lambda *args: events.append("boot")):
            acceptance.execute_lanes(run, [lane], Path("packages"), Path("scratch"), Path("derived"), "sim", True)
        self.assertEqual(events, [lane + "-build", "boot", lane])
        self.assertEqual(run.expected, acceptance.expected_tests(run.root, "iOS", [directory]))

    def test_boot_follows_build_and_precedes_same_inventory_execution(self):
        for lane, directory in (("simulator-core", "Tests/RemoteFilesCoreTests"),
                                ("simulator-ui", "Tests/RemoteFilesUITests"),
                                ("voiceover", "Tests/VoiceOverFixtures")):
            with self.subTest(lane=lane):
                self.check_boot_follows_build_and_precedes_same_inventory_execution(lane, directory)

    def test_ui_acceptance_does_not_repeat_the_core_tests(self):
        run = self.run_lane("simulator-ui")
        self.assertEqual(len(run.commands), 2, "Build and test need independent command deadlines")
        build, execution = run.commands[0][1], run.commands[1][1]
        self.assertEqual(build[build.index("-scheme") + 1], "RemoteFiles")
        self.assertIn("generic/platform=iOS Simulator", build)
        self.assertEqual(build[-1], "build-for-testing")
        self.assertEqual(execution[-1], "test-without-building")
        self.assertIn("-only-testing:RemoteFilesUITests", build)
        self.assertIn("-only-testing:RemoteFilesUITests", execution)
        self.assertEqual(build[build.index("-derivedDataPath") + 1],
                         execution[execution.index("-derivedDataPath") + 1])
        self.assertEqual(execution[0], "scripts/test-openssh.sh")
        self.assertTrue(any(name.startswith("RealServerUITests/") for name in run.inventories[0]))
        self.assertFalse(any(name.startswith("IdentityTests/") for name in run.inventories[0]))

    def test_voiceover_builds_its_generated_targets_in_the_real_project_and_shared_caches(self):
        run = self.run_lane("voiceover")
        self.assertEqual([name for name, _ in run.commands], ["voiceover-build", "voiceover"])
        build, execution = run.commands[0][1], run.commands[1][1]
        for command in (build, execution):
            self.assertEqual(command[0], "xcodebuild", "The journeys use local fixtures only")
            self.assertEqual(command[command.index("-project") + 1], "RemoteFiles.xcodeproj")
            self.assertEqual(command[command.index("-scheme") + 1], "RemoteFilesAccessibility")
            self.assertEqual(command[command.index("-derivedDataPath") + 1], Path("derived"))
            self.assertEqual(command[command.index("-clonedSourcePackagesDirPath") + 1], Path("packages"))
            self.assertIn("-only-testing:RemoteFilesAccessibilityUITests", command)
        self.assertIn("generic/platform=iOS Simulator", build)
        self.assertEqual(build[-1], "build-for-testing")
        self.assertEqual(execution[-1], "test-without-building")
        self.assertEqual(execution[execution.index("-default-test-execution-time-allowance") + 1], "180")
        self.assertEqual(execution[execution.index("-maximum-test-execution-time-allowance") + 1], "240")
        self.assertEqual(execution[execution.index("-resultBundlePath") + 1], run.output / "voiceover.xcresult")
        self.assertEqual(run.inventories[0], acceptance.expected_tests(run.root, "iOS", ["Tests/VoiceOverFixtures"]))
        self.assertEqual(len(run.inventories[0]), 11)
        self.assertEqual(run.skips[0], set(), "No VoiceOver method may skip")

    def test_voiceover_shares_the_compilation_cache_with_the_other_lanes(self):
        class Recorder:
            root = Path(__file__).resolve().parents[1]
            output = Path("/tmp/unused-evidence")
            commands = []
            def command(self, name, command, timeout=None):
                self.commands.append(command)
                return {"status": "passed"}
            def tests(self, *args, **kwargs):
                pass
        run = Recorder(); run.commands = []
        acceptance.execute_lanes(run, ["voiceover"], Path("p"), Path("s"), Path("d"), "sim", compilation_cache=Path("cas"))
        for command in run.commands:
            self.assertIn("COMPILATION_CACHE_CAS_PATH=cas", command)

    def test_only_ui_test_execution_receives_the_longer_deadline(self):
        ui = self.run_lane("simulator-ui")
        self.assertEqual(ui.deadlines, {"simulator-ui-build": None, "simulator-ui": 3600})
        for lane in ("simulator-core", "voiceover"):
            with self.subTest(lane=lane):
                self.assertEqual(self.run_lane(lane).deadlines, {lane + "-build": None, lane: None})
        self.assertEqual(self.run_lane("simulator").deadlines, {"simulator": None})
        self.assertEqual(self.run_lane("simulator-ui", 1).deadlines["simulator-ui-shard-1"], 3600)

    def test_ui_journeys_keep_their_per_method_allowances_inventory_and_skips(self):
        run = self.run_lane("simulator-ui")
        execution = run.commands[1][1]
        self.assertEqual(execution[execution.index("-default-test-execution-time-allowance") + 1], "180")
        self.assertEqual(execution[execution.index("-maximum-test-execution-time-allowance") + 1], "240")
        self.assertEqual(run.inventories[0], acceptance.expected_tests(run.root, "iOS", ["Tests/RemoteFilesUITests"]))
        self.assertEqual(run.skips[0], acceptance.SIMULATOR_ALLOWED_SKIPS | {name for name in run.inventories[0] if name.startswith("RealServerUITests/")})

    def check_main_deadlines(self, extra, command_seconds, overrides):
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            metadata = {"commit": "fixture", "mode": "test", "source_tree_sha256": "fixture"}
            argv = ["test-acceptance.py", "--lane", "macos-openssh", *extra, "--output", str(Path(directory) / "evidence")]
            with patch.object(acceptance, "execute_lanes", side_effect=lambda run, *args: calls.append((run.timeout, args[-1]))), \
                 patch.object(acceptance, "capture", return_value="fixture toolchain"), \
                 patch.object(acceptance, "snapshot", return_value=(Path(directory), metadata)), \
                 patch.object(sys, "argv", argv), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                acceptance.main()  # Stops after the lanes: the stubbed snapshot wrote no source manifest.
        self.assertEqual(calls, [(command_seconds, overrides)])

    def test_default_timeouts_are_thirty_minutes_with_the_ui_override(self):
        self.check_main_deadlines([], 30 * 60, {"simulator-ui": 60 * 60})

    def test_explicit_timeout_bounds_ui_execution_as_well(self):
        self.check_main_deadlines(["--timeout-minutes", "5"], 5 * 60, {})

    def test_command_deadline_override_interrupts_and_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            root = Path(directory)
            run = acceptance.Run(root, root, {"commit": "fixture", "mode": "test", "source_tree_sha256": "fixture"})
            lane = run.command("override", ["sleep", "30"], timeout=1)
            self.assertEqual(lane["status"], "failed")
            self.assertEqual(lane["deadline_seconds"], 1)
            self.assertIn("exceeded 1 seconds", lane["errors"][0])
            self.assertEqual(run.command("default", ["true"])["deadline_seconds"], 1800)

    def test_boot_flag_accepts_each_staged_lane_alone_before_creating_evidence(self):
        script = Path(__file__).with_name("test-acceptance.py")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "must-not-exist"
            for args, message in ((["--lane", "macos-openssh"], "--boot-simulator"),
                                  (["--lane", "simulator"], "--boot-simulator"),
                                  (["--lane", "voiceover", "--lane", "simulator-ui"], "--boot-simulator"),
                                  (["--lane", "voiceover"], "--simulator is required"),
                                  (["--lane", "simulator-core"], "--simulator is required"),
                                  (["--lane", "simulator-ui"], "--simulator is required")):
                with self.subTest(args=args):
                    result = subprocess.run([sys.executable, "-B", str(script), *args, "--boot-simulator",
                                             "--output", str(output)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn(message, result.stderr)
                    self.assertFalse(output.exists())

    def test_mac_lane_never_invokes_xcode_or_a_simulator(self):
        run = self.run_lane("macos-openssh")
        self.assertEqual(len(run.commands), 1)
        self.assertEqual(run.commands[0][1][:3], ["scripts/test-openssh.sh", "swift", "test"])


class WorkflowShapeTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[1]

    def job(self, name):
        workflow = (self.root / ".github/workflows/ci.yml").read_text()
        return workflow.split("\n  " + name + ":\n", 1)[1].split("\n\n  ", 1)[0]

    def test_ui_journeys_run_in_one_job_that_fits_their_deadlines(self):
        workflow = (self.root / ".github/workflows/ci.yml").read_text()
        action = (self.root / ".github/actions/validate/action.yml").read_text()
        job = self.job("simulator-ui")
        self.assertIn("name: Acceptance / simulator-ui\n", job)
        self.assertIn("lane: simulator-ui", job)
        self.assertNotIn("continue-on-error", job)
        for text in (workflow, action):
            self.assertNotIn("matrix.shard", text)
            self.assertNotIn("ui-shard", text)
            self.assertNotIn("UI_SHARD", text)
        settle = inspect.signature(acceptance.settle_after_boot).parameters["limit"].default
        boot = acceptance.BOOT_COMMAND_SECONDS + acceptance.BOOT_STATUS_SECONDS
        needed = acceptance.DEFAULT_COMMAND_MINUTES * 60 + boot + settle + acceptance.EXECUTION_DEADLINE_SECONDS["simulator-ui"]
        ceiling = int(re.search(r"timeout-minutes: (\d+)", job)[1]) * 60
        self.assertGreater(ceiling - needed, 5 * 60, "Leave time for checkout, caches and evidence upload")

    def test_every_ci_simulator_lane_boots_inside_the_runner_after_building(self):
        action = (self.root / ".github/actions/validate/action.yml").read_text()
        self.assertNotIn("simctl boot", action)
        self.assertIn('--simulator "$SIMULATOR_UDID" --boot-simulator', action)
        self.assertNotIn("${{ env.EVIDENCE }}/voiceover/", action)
        self.assertEqual(acceptance.STAGED_LANES, ("simulator-core", "simulator-ui", "voiceover"))

    def test_ui_voiceover_and_release_are_gated_on_their_own_selector_outputs(self):
        workflow = (self.root / ".github/workflows/ci.yml").read_text()
        for name, lane in (("simulator-ui", "ui"), ("voiceover", "voiceover"), ("release-device-compile", "release")):
            with self.subTest(job=name):
                job = self.job(name)
                self.assertIn("needs: [repository-checks, quick]", job)
                self.assertIn("if: needs.repository-checks.outputs." + lane + " == 'true'", job)
                self.assertIn("      " + lane + ": ${{ steps.scope.outputs." + lane + " }}", self.job("repository-checks"))
        self.assertIn("lane: voiceover", self.job("voiceover"))
        self.assertIn("lane: release-device-compile", self.job("release-device-compile"))
        self.assertNotIn("simulator-ui-check", workflow)
        self.assertNotIn("outputs.acceptance", workflow)

    def test_nightly_schedule_runs_every_lane_in_its_own_concurrency_group(self):
        workflow = (self.root / ".github/workflows/ci.yml").read_text()
        self.assertIn("  schedule:\n", workflow)
        self.assertIn("    - cron: ", workflow)
        self.assertIn("github.event_name == 'schedule' && 'nightly' ||", workflow)
        checks = self.job("repository-checks")
        self.assertIn("CI_MAIN_PUSH: ${{ github.event_name == 'push' }}", checks)
        self.assertIn("CI_FORCE_ACCEPTANCE: ${{ github.event_name == 'schedule' || inputs.full_acceptance == true ||", checks)

    def test_a_failed_evidence_upload_is_tried_again_before_it_fails_the_lane(self):
        action = (self.root / ".github/actions/validate/action.yml").read_text()
        first, second = action.split("- name: Retain lane logs and result bundles")[1:]
        self.assertIn("id: evidence\n", first)
        self.assertIn("continue-on-error: true\n", first)
        self.assertIn("if: always() && steps.evidence.outcome == 'failure'\n", second)
        self.assertIn("overwrite: true\n", second)
        # Only the first attempt may fail quietly, and both retain the same evidence under one name.
        self.assertEqual(action.count("continue-on-error"), 1)
        def retained(step):
            return [line for line in step.split("\n    - name:", 1)[0].splitlines() if "env.EVIDENCE" in line or " name: " in line]
        self.assertEqual(retained(first), retained(second))
        self.assertEqual(len(retained(first)), 11)

    def test_build_caches_are_lane_scoped_and_saved_only_from_main(self):
        action = (self.root / ".github/actions/validate/action.yml").read_text()
        key = next(line for line in action.splitlines() if line.strip().startswith("key: "))
        self.assertIn("steps.build.outputs.prefix", key)
        self.assertIn('echo "prefix=v3-xcode-$toolchain-${{ runner.arch }}-$family-$LANE"', action)
        save = action.split("- name: Save build progress", 1)[1]
        self.assertIn("github.ref == 'refs/heads/main'", save.split("uses:", 1)[0])


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
