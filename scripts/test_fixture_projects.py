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
        for filename in ("test-image-open.sh", "test-small-features.py", "test-reading-anchors.py"):
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
                self.assertEqual(len(settings), 4, "Only the app's and fixture's Debug and Release configurations use this plist")
                for setting in settings:
                    path = Path(json.loads(setting) if setting.startswith('"') else setting)
                    if not path.is_absolute():
                        path = project.parent / path
                    self.assertTrue(path.is_file(), str(path))
                    self.assertEqual(path.read_bytes(), (repository / "App" / "Info.plist").read_bytes())
                # The fixture targets stay in each copy, unused, and must not point back at a relative path.
                for relative in ("Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift", "Tests/VoiceOverFixtures/VoiceOverUITests.swift"):
                    self.assertNotIn("path = " + relative + ";", (project / "project.pbxproj").read_text())


class AccessibilityTargetTests(unittest.TestCase):
    """The generated fixture targets, read from the committed project."""
    repository = Path(__file__).resolve().parents[1]
    project = repository / "RemoteFiles.xcodeproj"

    def objects(self):
        return re.findall(r"^(\w{24}) = \{ (.*) \};$", (self.project / "project.pbxproj").read_text(), re.M)

    def target(self, name):
        return next((i, v) for i, v in self.objects() if "isa = PBXNativeTarget;" in v and "name = " + name + ";" in v)

    def settings(self, target_body):
        configs = dict(self.objects())[re.search(r"buildConfigurationList = (\w+);", target_body)[1]]
        bodies = [dict(self.objects())[i] for i in re.search(r"buildConfigurations = \((\w+), (\w+),\)", configs).groups()]
        self.assertEqual(len(bodies), 2)
        return bodies

    def test_fixture_app_compiles_only_the_fixture_entry_point(self):
        objects = dict(self.objects())
        _, app = self.target("RemoteFilesAccessibility")
        self.assertIn('productType = "com.apple.product-type.application"', app)
        phases = re.search(r"buildPhases = \((.*?)\);", app)[1]
        sources = next(objects[i] for i in re.findall(r"\w{24}", phases) if "PBXSourcesBuildPhase" in objects[i])
        build_files = re.findall(r"\w{24}", re.search(r"files = \((.*?)\);", sources)[1])
        self.assertEqual(len(build_files), 1)
        reference = objects[re.search(r"fileRef = (\w+);", objects[build_files[0]])[1]]
        self.assertIn("path = Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift;", reference)
        self.assertTrue((self.repository / "Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift").is_file())

    def test_ui_tests_are_hosted_by_the_fixture_app_and_not_the_app(self):
        objects = dict(self.objects())
        app_id, _ = self.target("RemoteFilesAccessibility")
        _, tests = self.target("RemoteFilesAccessibilityUITests")
        self.assertIn('productType = "com.apple.product-type.bundle.ui-testing"', tests)
        dependencies = re.findall(r"\w{24}", re.search(r"dependencies = \((.*?)\);", tests)[1])
        self.assertEqual([re.search(r"target = (\w+);", objects[i])[1] for i in dependencies], [app_id])
        for body in self.settings(tests):
            self.assertIn("TEST_TARGET_NAME = RemoteFilesAccessibility;", body)
        phases = re.findall(r"\w{24}", re.search(r"buildPhases = \((.*?)\);", tests)[1])
        sources = next(objects[i] for i in phases if "PBXSourcesBuildPhase" in objects[i])
        build_files = re.findall(r"\w{24}", re.search(r"files = \((.*?)\);", sources)[1])
        self.assertEqual(len(build_files), 1)
        self.assertIn("path = Tests/VoiceOverFixtures/VoiceOverUITests.swift;", objects[re.search(r"fileRef = (\w+);", objects[build_files[0]])[1]])

    def test_fixture_targets_sign_like_the_app_under_their_own_identifiers(self):
        signing = re.compile(r"\b(DEVELOPMENT_TEAM|CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|CODE_SIGN_ENTITLEMENTS) = ([^;]+);")
        expected = [set(signing.findall(body)) for body in self.settings(self.target("RemoteFiles")[1])]
        self.assertTrue(all(expected))
        for name in ("RemoteFilesAccessibility", "RemoteFilesAccessibilityUITests"):
            with self.subTest(target=name):
                bodies = self.settings(self.target(name)[1])
                self.assertEqual([set(signing.findall(body)) for body in bodies], expected)
                for body in bodies:
                    self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = dev.iris." + name + ";", body)
        for body in self.settings(self.target("RemoteFilesAccessibility")[1]):
            self.assertIn("INFOPLIST_FILE = App/Info.plist;", body)

    def test_each_scheme_builds_only_its_own_tests(self):
        schemes = self.project / "xcshareddata/xcschemes"
        fixture = (schemes / "RemoteFilesAccessibility.xcscheme").read_text()
        self.assertIn('BuildableName="RemoteFilesAccessibilityUITests.xctest"', fixture)
        self.assertIn(self.target("RemoteFilesAccessibilityUITests")[0], fixture)
        self.assertIn(self.target("RemoteFilesAccessibility")[0], fixture)
        self.assertNotIn('BuildableName="RemoteFilesUITests.xctest"', fixture)
        for name in ("RemoteFiles", "RemoteFilesCoreCI"):
            with self.subTest(scheme=name):
                self.assertNotIn("RemoteFilesAccessibility", (schemes / (name + ".xcscheme")).read_text())
