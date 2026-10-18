#!/usr/bin/env python3
"""Failure-injection checks; no Xcode, Simulator, network, or build required."""
import ast
import datetime
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
from runner_finalization import finalize_report


class RunnerFinalizationTests(unittest.TestCase):
    def test_cleanup_continues_after_exception_and_keeps_original_failure(self):
        report = {"status": "failed", "blocker": "original failure", "lanes": [], "cleanup": {}}
        attempted = []

        def interrupted():
            attempted.append("first")
            raise KeyboardInterrupt("cleanup interrupted")

        def remaining():
            attempted.append("second")
            return True

        self.assertEqual(finalize_report(report, [("first", interrupted), ("second", remaining)]), 1)
        self.assertEqual(attempted, ["first", "second"])
        self.assertEqual(report["blocker"], "original failure")
        self.assertEqual(report["cleanup"], {"first": False, "second": True})
        self.assertIn("KeyboardInterrupt", report["cleanup_errors"]["first"])

    def test_only_explicit_success_counts_as_cleanup_success(self):
        for result in (False, None, "passed", 1):
            with self.subTest(result=result):
                report = {"status": "passed", "lanes": [], "cleanup": {}}
                self.assertEqual(finalize_report(report, [("check", lambda: result)]), 1)
                self.assertEqual(report["status"], "failed")

    def test_failed_lane_cannot_leave_a_passed_summary(self):
        report = {"status": "passed", "lanes": [{"status": "failed"}], "cleanup": {}}
        self.assertEqual(finalize_report(report, []), 1)
        self.assertEqual(report["status"], "failed")

    def test_both_runners_save_evidence_and_exit_for_injected_outcomes(self):
        # Execute each runner's actual exception/finalization/exit code. Replace
        # only its expensive test body, so integration wiring is also covered.
        for filename in ("test-reading-anchors.py", "test-small-features.py"):
            module = ast.parse(Path(__file__).with_name(filename).read_text())
            staged_run = next(node for node in reversed(module.body) if isinstance(node, ast.Try))
            exit_statement = module.body[-1]
            for outcome in ("passed", "test_failure", "blocked", "source_changed", "check_error", "delete_error"):
                with self.subTest(runner=filename, outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                    out = Path(temporary)
                    (out / "source-manifest.json").write_text("[]")
                    report = {"status": "running", "lanes": [], "cleanup": {}}
                    commands = []

                    def command(name, args, total):
                        commands.append(name)
                        if outcome == "delete_error" and name == "delete-owned-simulator":
                            raise OSError("injected delete failure")
                        lane = {"status": "passed"}
                        report["lanes"].append(lane)
                        return lane

                    def manifest(root, files):
                        if outcome == "check_error":
                            raise OSError("injected manifest failure")
                        return ["changed"] if outcome == "source_changed" else []

                    body = "report['status'] = 'passed'"
                    if outcome == "test_failure":
                        body = "raise RuntimeError('injected test failure')"
                    elif outcome == "blocked":
                        body = "report['lanes'].append({'status': 'blocked'}); raise RuntimeError('injected deadline')"
                    staged_run.body = ast.parse(body).body
                    tail = ast.fix_missing_locations(ast.Module(body=[staged_run, exit_statement], type_ignores=[]))
                    namespace = {
                        "report": report, "sim": "owned-test-device", "command": command,
                        "OUT": out, "ROOT": out / "source", "REPO": out / "repo",
                        "canonical": out / "canonical", "EXPECTED": "head", "canonical_head": "head",
                        "canonical_before": "", "json": json, "sys": sys, "datetime": datetime,
                        "subprocess": SimpleNamespace(check_output=lambda *args, **kwargs: ""),
                        "a": SimpleNamespace(manifest=manifest, source_files=lambda root: [], capture=lambda *args: "head"),
                        "finalize_report": finalize_report,
                        "save": lambda: (out / "summary.json").write_text(json.dumps(report)),
                    }
                    with patch("builtins.print"), self.assertRaises(SystemExit) as exited:
                        exec(compile(tail, filename, "exec"), namespace)
                    self.assertEqual(exited.exception.code, 0 if outcome == "passed" else 1)
                    saved = json.loads((out / "summary.json").read_text())
                    self.assertEqual(saved["status"], "passed" if outcome == "passed" else "blocked" if outcome == "blocked" else "failed")
                    self.assertIn("finished_utc", saved)
                    self.assertEqual(commands, ["shutdown-owned-simulator", "delete-owned-simulator"])
                    self.assertEqual(len(saved["cleanup"]), 6)
                    self.assertTrue(saved["cleanup"]["canonical_status_unchanged"])
                    if outcome in ("test_failure", "blocked"):
                        self.assertIn("injected", saved["blocker"])
                    if outcome in ("check_error", "delete_error"):
                        self.assertTrue(saved["cleanup_errors"])


if __name__ == "__main__":
    unittest.main()
