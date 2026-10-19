import unittest
from ci_scope import classify


class CIScopeTests(unittest.TestCase):
    def test_documentation_only_avoids_mac_runners(self):
        self.assertEqual(classify(["docs/DEVELOPMENT.md", "README.md"]),
                         {"quick": False, "acceptance": False, "reasons": []})

    def test_ordinary_code_and_unit_tests_use_quick_validation(self):
        result = classify(["Sources/RemoteFilesUI/StatusBanner.swift", "Tests/RemoteFilesCoreTests/SourceHighlightingTests.swift"])
        self.assertTrue(result["quick"])
        self.assertFalse(result["acceptance"])

    def test_reader_security_dependencies_and_workflows_require_acceptance(self):
        for path in ("Vendor/Textual/Package.swift", "Package.resolved", ".github/workflows/ci.yml",
                     "Sources/RemoteFilesUI/DocumentReadingPosition.swift", "Sources/RemoteFilesCore/HostTrustStore.swift",
                     "Tests/RemoteFilesCoreTests/OverflowViewportTests.swift", "Tests/VoiceOverFixtures/VoiceOverUITests.swift"):
            with self.subTest(path=path):
                self.assertTrue(classify([path])["acceptance"])

    def test_manual_or_label_request_runs_acceptance_even_for_docs(self):
        result = classify(["README.md"], force_acceptance=True)
        self.assertTrue(result["quick"])
        self.assertTrue(result["acceptance"])

    def test_manual_quick_request_runs_tests_without_forcing_ui_acceptance(self):
        self.assertEqual(classify([], force_quick=True),
                         {"quick": True, "acceptance": False, "reasons": []})

    def test_source_disguised_as_a_license_is_not_documentation(self):
        self.assertTrue(classify(["LICENSE.swift"])["acceptance"])

    def test_unknown_or_deleted_code_is_not_silently_skipped(self):
        self.assertTrue(classify(["NewModule/entry.swift"])["acceptance"])
        self.assertTrue(classify(["Sources/RemoteFilesCore/SFTPRemoteFileService.swift"])["acceptance"])
