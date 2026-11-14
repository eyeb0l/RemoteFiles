import contextlib
import io
import json
import os
import unittest
from unittest import mock

import gate_guard


def files(*names):
    return [{"filename": name} for name in names]


class GateGuardTests(unittest.TestCase):
    def test_ordinary_changes_are_not_the_gate(self):
        self.assertEqual(gate_guard.gate_paths(files("Sources/RemoteFilesCore/RemotePath.swift", "docs/CI.md",
                                                     "scripts/testflight_release.py", "scripts/test_ci_scope.py")), [])

    def test_the_workflow_its_actions_and_the_deciding_scripts_are_the_gate(self):
        gate = [".github/actions/validate/action.yml", ".github/workflows/ci.yml", ".github/workflows/gate-guard.yml",
                "ci_scripts/ci_post_clone.sh", "scripts/ci_gate.py", "scripts/ci_scope.py", "scripts/gate_guard.py",
                "scripts/generate-project.py", "scripts/runner_finalization.py", "scripts/test-acceptance.py", "scripts/test-openssh.sh"]
        self.assertEqual(gate_guard.gate_paths(files("README.md", *gate)), gate)

    def test_a_file_renamed_out_of_the_gate_still_counts(self):
        moved = [{"filename": "scripts/old_gate.py", "previous_filename": "scripts/ci_gate.py", "status": "renamed"}]
        self.assertEqual(gate_guard.gate_paths(moved), ["scripts/ci_gate.py"])

    def run_main(self, listed):
        pages = json.dumps([listed[:100], listed[100:]])
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repository", "PR_NUMBER": "7"}), \
             mock.patch("gate_guard.subprocess.run", return_value=mock.Mock(stdout=pages)) as run, \
             contextlib.redirect_stdout(output):
            status = gate_guard.main()
        self.assertEqual(run.call_args.args[0][:4], ["gh", "api", "--paginate", "--slurp"])
        self.assertIn("repos/owner/repository/pulls/7/files", run.call_args.args[0][4])
        return status, output.getvalue()

    def test_passes_when_no_changed_file_is_the_gate(self):
        status, output = self.run_main(files("Sources/a.swift", "docs/b.md"))
        self.assertEqual(status, 0)
        self.assertIn("None of the 2 changed files", output)

    def test_fails_and_names_each_gate_file_wherever_it_is_listed(self):
        listed = files(*[f"Sources/{index}.swift" for index in range(150)], "scripts/ci_scope.py")
        status, output = self.run_main(listed)
        self.assertEqual(status, 1)
        self.assertIn("::error file=scripts/ci_scope.py::", output)

    def test_fails_closed_when_the_listing_may_be_incomplete(self):
        status, output = self.run_main(files(*[f"Sources/{index}.swift" for index in range(gate_guard.LISTING_LIMIT)]))
        self.assertEqual(status, 1)
        self.assertIn("too many to list", output)


if __name__ == "__main__":
    unittest.main()
