"""Validate relocated fixture build inputs without starting Xcode or a Simulator."""
import ast
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch


class FixtureProjectTests(unittest.TestCase):
    def test_relocated_projects_keep_the_app_plist_resolvable(self):
        repository = Path(__file__).resolve().parents[1]
        for filename in ("test-voiceover.sh", "test-image-open.sh",
                         "test-small-features.py", "test-reading-anchors.py"):
            with self.subTest(launcher=filename), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "source checkout"
                root.symlink_to(repository, target_is_directory=True)
                output = Path(temporary) / "fixture output"
                output.mkdir()
                source = (repository / "scripts" / filename).read_text()
                if filename.endswith(".sh"):
                    # Run the launcher's actual Python project-preparation block.
                    preparation = source.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
                    with patch.object(sys, "argv", [filename, str(root), str(output)]):
                        exec(compile(preparation, filename, "exec"), {})
                    project = output / "RemoteFiles.xcodeproj"
                else:
                    # Isolate preparation from the runner's Simulator lifecycle.
                    run = next(node for node in reversed(ast.parse(source).body) if isinstance(node, ast.Try))
                    start = next(i for i, node in enumerate(run.body) if isinstance(node, ast.Assign)
                                 and any(isinstance(t, ast.Name) and t.id == "private_project" for t in node.targets))
                    end = next(i for i in range(start, len(run.body)) if isinstance(run.body[i], ast.Expr)
                               and isinstance(run.body[i].value, ast.Call)
                               and isinstance(run.body[i].value.func, ast.Attribute)
                               and run.body[i].value.func.attr == "write_text")
                    preparation = ast.Module(body=run.body[start:end + 1], type_ignores=[])
                    exec(compile(preparation, filename, "exec"),
                         {"ROOT": root, "OUT": output, "shutil": shutil, "json": json, "re": re})
                    project = output / "fixture-project" / "RemoteFiles.xcodeproj"
                settings = re.findall(r"\bINFOPLIST_FILE = (.*?);", (project / "project.pbxproj").read_text())
                self.assertEqual(len(settings), 2, "Only the app's Debug and Release configurations use this plist")
                for setting in settings:
                    path = Path(json.loads(setting) if setting.startswith('"') else setting)
                    if not path.is_absolute():
                        path = project.parent / path
                    self.assertTrue(path.is_file(), str(path))
                    self.assertEqual(path.read_bytes(), (repository / "App" / "Info.plist").read_bytes())
