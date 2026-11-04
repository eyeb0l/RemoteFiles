import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest import mock

import ci_gate
import ci_scope


def context(paths=(), **selection):
    outputs = {name: str(value).lower() for name, value in ci_scope.classify(paths).items() if name != "reasons"}
    outputs.update(selection)
    return {
        "repository-checks": {"result": "success", "outputs": outputs},
        **{job: {"result": "success" if outputs[output] == "true" else "skipped"}
           for job, output in ci_gate.LANE_OUTPUTS.items()},
    }


class CIGateTests(unittest.TestCase):
    def test_documentation_only_accepts_intentionally_skipped_mac_jobs(self):
        self.assertEqual(ci_gate.validate(context(["docs/CI.md"])), [])

    def test_ordinary_code_requires_quick_success(self):
        needs = context(["Sources/RemoteFilesUI/FolderView.swift"])
        self.assertEqual(ci_gate.validate(needs), [])
        needs["quick"]["result"] = "skipped"
        self.assertTrue(ci_gate.validate(needs))

    def test_ui_change_requires_ui_success(self):
        needs = context(["App/Info.plist"])
        self.assertEqual(ci_gate.validate(needs), [])
        needs["simulator-ui"]["result"] = "skipped"
        self.assertTrue(ci_gate.validate(needs))

    def test_every_selected_lane_rejects_failure_cancellation_skip_and_unknown(self):
        for job in ci_gate.LANE_OUTPUTS:
            for result in ("failure", "cancelled", "skipped", "", None, "neutral"):
                with self.subTest(job=job, result=result):
                    needs = context([".github/workflows/ci.yml"])
                    needs[job]["result"] = result
                    self.assertTrue(ci_gate.validate(needs))

    def test_nightly_and_full_acceptance_require_all_lanes(self):
        needs = context(**{output: "true" for output in ci_gate.LANE_OUTPUTS.values()})
        self.assertEqual(ci_gate.validate(needs), [])
        for job in ci_gate.LANE_OUTPUTS:
            with self.subTest(job=job):
                changed = json.loads(json.dumps(needs))
                changed[job]["result"] = "skipped"
                self.assertTrue(ci_gate.validate(changed))

    def test_unselected_lane_accepts_success_but_rejects_failure_or_cancellation(self):
        for job in ci_gate.LANE_OUTPUTS:
            for result in ("success", "failure", "cancelled"):
                with self.subTest(job=job, result=result):
                    needs = context()
                    needs[job]["result"] = result
                    self.assertEqual(bool(ci_gate.validate(needs)), result != "success")

    def test_repository_checks_must_succeed_even_when_all_lanes_skip(self):
        for result in ("failure", "cancelled", "skipped", "", None):
            with self.subTest(result=result):
                needs = context()
                needs["repository-checks"]["result"] = result
                self.assertTrue(ci_gate.validate(needs))

    def test_missing_or_malformed_selection_never_means_intentional_skip(self):
        for output in ci_gate.LANE_OUTPUTS.values():
            for value in (None, "", "TRUE", True, False, 0, [], {}):
                with self.subTest(output=output, value=value):
                    needs = context()
                    needs["repository-checks"]["outputs"][output] = value
                    self.assertTrue(ci_gate.validate(needs))
            needs = context()
            del needs["repository-checks"]["outputs"][output]
            self.assertTrue(ci_gate.validate(needs))

    def test_missing_dependencies_or_outputs_fail_closed(self):
        for job in context():
            for value in (None, "", {}, []):
                with self.subTest(job=job, value=value):
                    needs = context()
                    needs[job] = value
                    self.assertTrue(ci_gate.validate(needs))
            needs = context()
            del needs[job]
            self.assertTrue(ci_gate.validate(needs))
        for needs in (None, [], "", {}, {**context(), "new-job": {"result": "failure"}}):
            self.assertTrue(ci_gate.validate(needs))

    def test_missing_or_invalid_json_returns_failure(self):
        for env in ({}, {"CI_NEEDS": "{"}, {"CI_NEEDS": "null"}):
            with self.subTest(env=env), mock.patch.dict(os.environ, env, clear=True), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ci_gate.main(), 1)

    def test_workflow_command_exits_nonzero_on_failed_or_skipped_required_job(self):
        script = Path(ci_gate.__file__)
        for result in ("success", "failure", "skipped", "cancelled"):
            needs = context(["Sources/RemoteFilesCore/HostTrustStore.swift"])
            needs["quick"]["result"] = result
            run = subprocess.run([sys.executable, "-B", str(script)], env={**os.environ, "CI_NEEDS": json.dumps(needs)},
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0 if result == "success" else 1, run.stderr)


class WorkflowGateContractTests(unittest.TestCase):
    workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()

    def test_gate_always_runs_on_linux_with_all_job_results(self):
        blocks = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:|\Z)", self.workflow.split("\njobs:\n")[1], re.M | re.S))
        gate = blocks.pop("ci-gate")
        needs = re.search(r"^    needs: \[(.*?)\]$", gate, re.M).group(1).split(", ")
        self.assertEqual(set(needs), set(blocks))
        self.assertEqual(set(needs), {"repository-checks", *ci_gate.LANE_OUTPUTS})
        for line in ("name: CI gate", "if: ${{ always() }}", "runs-on: ubuntu-24.04",
                     "CI_NEEDS: ${{ toJSON(needs) }}", "run: python3 -B scripts/ci_gate.py"):
            self.assertIn(line, gate)
        # A failed matrix child must propagate to the aggregate quick result.
        self.assertIn("fail-fast: false", blocks["quick"])
        self.assertNotIn("continue-on-error:", self.workflow)


if __name__ == "__main__":
    unittest.main()
