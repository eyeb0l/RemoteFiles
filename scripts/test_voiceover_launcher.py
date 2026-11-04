"""Exercise the real Bash launcher without running Xcode or touching a Simulator."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class VoiceOverLauncherTests(unittest.TestCase):
    def launch(self, directory, packages=False, status=0, extra=()):
        root = Path(directory)
        scripts = root / "repo with spaces" / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(Path(__file__).with_name("test-voiceover.sh"), scripts)
        binary = root / "bin"
        binary.mkdir()
        xcode = binary / "xcodebuild"
        xcode.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                         "open(os.environ['CAPTURED_ARGUMENTS'], 'w').write(json.dumps(sys.argv[1:]))\n"
                         "sys.exit(int(os.environ['STUB_XCODE_STATUS']))\n")
        xcode.chmod(0o755)
        xcrun = binary / "xcrun"
        xcrun.write_text("#!/bin/sh\necho lifecycle-log\n")
        xcrun.chmod(0o755)
        args_file = root / "arguments.json"
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                   CAPTURED_ARGUMENTS=str(args_file), STUB_XCODE_STATUS=str(status))
        env.pop("REMOTEFILES_SOURCE_PACKAGES_DIR", None)
        if packages:
            env["REMOTEFILES_SOURCE_PACKAGES_DIR"] = str(root / "packages with spaces")
        output = root / "output"
        result = subprocess.run(["/bin/bash", str(scripts / "test-voiceover.sh"), "owned-simulator",
                                 str(output), str(root / "derived data"), *extra], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertTrue(args_file.exists(), result.stderr)
        return result, json.loads(args_file.read_text()), output

    def test_empty_optional_arrays_and_paths_with_spaces_reach_xcode(self):
        for packages in (False, True):
            with self.subTest(packages=packages), tempfile.TemporaryDirectory() as directory:
                result, args, output = self.launch(directory, packages)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("", args)
                self.assertEqual("-clonedSourcePackagesDirPath" in args, packages)
                if packages:
                    index = args.index("-clonedSourcePackagesDirPath")
                    self.assertEqual(args[index + 1], str(Path(directory) / "packages with spaces"))
                self.assertEqual(args[args.index("-derivedDataPath") + 1], str(Path(directory) / "derived data"))
                self.assertIn("-collect-test-diagnostics", args)
                self.assertTrue((output / "voiceover.log").exists())

    def test_runs_the_generated_scheme_in_the_real_project_without_a_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            _, args, output = self.launch(directory)
            repository = Path(directory).resolve() / "repo with spaces"
            self.assertEqual(Path(args[args.index("-project") + 1]).resolve(), repository / "RemoteFiles.xcodeproj")
            self.assertEqual(args[args.index("-scheme") + 1], "RemoteFilesAccessibility")
            self.assertIn("-only-testing:RemoteFilesAccessibilityUITests/VoiceOverChecks", args)
            self.assertEqual(args[-1], "test")
            self.assertFalse((output / "fixture").exists())

    def test_a_single_journey_can_be_selected(self):
        identifier = "RemoteFilesAccessibilityUITests/VoiceOverChecks/testDemoReaderVoiceOverJourney"
        with tempfile.TemporaryDirectory() as directory:
            _, args, _ = self.launch(directory, extra=[identifier])
            self.assertIn("-only-testing:" + identifier, args)

    def test_xcode_failure_remains_a_failure_after_lifecycle_log_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _, output = self.launch(directory, status=19)
            self.assertEqual(result.returncode, 19)
            self.assertIn("lifecycle-log", (output / "svg-rendering.log").read_text())
