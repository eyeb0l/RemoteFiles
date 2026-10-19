#!/usr/bin/env python3
"""Acceptance environment and skip-policy regressions; no builds or server needed."""
import importlib.util
import os
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
            run.tests(lane, {identifier}, allowed_skips)
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


if __name__ == "__main__":
    unittest.main()
