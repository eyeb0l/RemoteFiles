import unittest
from ci_scope import classify

NOTHING = {"quick": False, "ui": False, "voiceover": False, "release": False}
QUICK_ONLY = {"quick": True, "ui": False, "voiceover": False, "release": False}
QUICK_AND_UI = {"quick": True, "ui": True, "voiceover": False, "release": False}
EVERYTHING = {"quick": True, "ui": True, "voiceover": True, "release": True}


def lanes(result):
    return {key: result[key] for key in NOTHING}


class CIScopeTests(unittest.TestCase):
    def test_documentation_only_avoids_mac_runners(self):
        result = classify(["docs/DEVELOPMENT.md", "README.md", "Vendor/Citadel/UPSTREAM.md", "design/icon-options/a.png"])
        self.assertEqual(lanes(result), NOTHING)
        self.assertEqual(result["reasons"], {})

    def test_ordinary_code_unit_tests_and_generated_project_use_quick_validation_only(self):
        for path in ("Sources/RemoteFilesUI/FolderView.swift", "Sources/RemoteFilesCore/SFTPRemoteFileService.swift",
                     "Sources/RemoteFilesCore/HostTrustStore.swift", "Tests/RemoteFilesCoreTests/SFTPIntegrationTests.swift",
                     "RemoteFiles.xcodeproj/project.pbxproj", "scripts/test_runner_finalization.py",
                     "Tests/SmallFeatureFixtures/SmallFeaturesUITests.swift"):
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

    def test_voiceover_fixtures_and_launcher_add_only_the_voiceover_lane(self):
        for path in ("Tests/VoiceOverFixtures/VoiceOverUITests.swift", "Tests/VoiceOverFixtures/RemoteFilesAccessibilityApp.swift",
                     "scripts/test-voiceover.sh"):
            with self.subTest(path=path):
                result = classify([path])
                self.assertEqual(lanes(result), {"quick": True, "ui": False, "voiceover": True, "release": False})
                self.assertEqual(result["reasons"], {path: "voiceover"})

    def test_ci_infrastructure_and_unknown_paths_run_every_lane(self):
        for path in (".github/workflows/ci.yml", ".github/actions/validate/action.yml", "scripts/ci_scope.py",
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


if __name__ == "__main__":
    unittest.main()
