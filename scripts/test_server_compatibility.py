import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("server_compatibility", Path(__file__).with_name("test-server-compatibility.py"))
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)

SOURCE = """final class ServerCompatibilityTests: XCTestCase {
    func testBytes() async throws {}
    func testBoundary() async throws {}
}
final class ChannelDrainCompatibilityTests: XCTestCase {
    func testDrain() async throws {}
}
"""


def outcome(name, method, result="passed"):
    return f"Test Case '-[RemoteFilesCoreTests.{name} {method}]' {result} (0.123 seconds).\n"


class CompatibilityInventoryTests(unittest.TestCase):
    def testRequiresEverySelectedMethodAndAddsDrainOnlyForItsScenario(self):
        ordinary = outcome("ServerCompatibilityTests", "testBytes") + outcome("ServerCompatibilityTests", "testBoundary")
        self.assertEqual(compatibility.test_results(ordinary, SOURCE, False), 2)
        with self.assertRaises(ValueError):
            compatibility.test_results(ordinary, SOURCE, True)
        self.assertEqual(compatibility.test_results(ordinary + outcome("ChannelDrainCompatibilityTests", "testDrain"), SOURCE, True), 3)

    def testRejectsMissingDuplicateUnexpectedFailedAndSkippedResults(self):
        first = outcome("ServerCompatibilityTests", "testBytes")
        second = outcome("ServerCompatibilityTests", "testBoundary")
        for log in ("", first, first + first + second, first + second + outcome("OtherTests", "testOther"),
                    first + outcome("ServerCompatibilityTests", "testBoundary", "failed"),
                    first + outcome("ServerCompatibilityTests", "testBoundary", "skipped")):
            with self.subTest(log=log), self.assertRaises(ValueError):
                compatibility.test_results(log, SOURCE, False)

    def testRejectsEmptySourceInventory(self):
        with self.assertRaises(ValueError):
            compatibility.test_results("", "", False)


class ScenarioSelectionTests(unittest.TestCase):
    def testDefaultsToLocalServersAndToCompatibleContainersOnADockerHost(self):
        self.assertEqual(compatibility.selected_scenarios(None, None, None), compatibility.SCENARIOS)
        containers = compatibility.selected_scenarios(None, "host", "100.64.0.1")
        self.assertTrue(containers and all(name in compatibility.DOCKER_SCENARIOS for name in containers))
        self.assertFalse(set(containers) & set(compatibility.KNOWN_INCOMPATIBLE))

    def testNamedIncompatibilitiesRunOnlyWhenRequestedAndNeedADockerHost(self):
        self.assertEqual(compatibility.selected_scenarios(["dropbear-default"], "host", "100.64.0.1"), ("dropbear-default",))
        for host, address in ((None, None), ("host", None)):
            with self.subTest(host=host), self.assertRaises(ValueError):
                compatibility.selected_scenarios(["proftpd-10"], host, address)


if __name__ == "__main__":
    unittest.main()
