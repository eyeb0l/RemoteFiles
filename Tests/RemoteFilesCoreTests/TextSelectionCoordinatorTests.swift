import XCTest
import Observation
@testable import Textual

/// Overflow regions keep offscreen content mounted while any selection is active, and observe
/// `hasActiveSelection` to retire it afterwards. Selection models register during SwiftUI updates,
/// so registration must not fire that one-shot observation, or the later deselection goes unseen.
@MainActor final class TextSelectionCoordinatorTests: XCTestCase {
    private final class Notifications: @unchecked Sendable { var count = 0 }

    private func select(_ model: TextSelectionModel) {
        model.selectedRange = TextRange(start: model.startPosition, end: model.startPosition)
    }

    private func observe(_ coordinator: TextSelectionCoordinator) -> Notifications {
        let notifications = Notifications()
        withObservationTracking { _ = coordinator.hasActiveSelection } onChange: { notifications.count += 1 }
        return notifications
    }

    func testRegistrationDoesNotConsumeTheSelectionObservation() {
        let coordinator = TextSelectionCoordinator()
        let selected = TextSelectionModel(coordinator: coordinator)
        select(selected)
        XCTAssertTrue(coordinator.hasActiveSelection)
        let notifications = observe(coordinator)
        let registered = (0..<3).map { _ in TextSelectionModel(coordinator: coordinator) }
        XCTAssertEqual(notifications.count, 0, "Registering other regions must not fire the retaining region's observation")
        selected.selectedRange = nil
        XCTAssertEqual(notifications.count, 1, "Clearing the selection must notify the retaining region")
        XCTAssertFalse(coordinator.hasActiveSelection)
        withExtendedLifetime(registered) {}
    }

    func testMovingSelectionStaysActiveAndReleasingItEndsIt() {
        let coordinator = TextSelectionCoordinator()
        let first = TextSelectionModel(coordinator: coordinator)
        var second: TextSelectionModel? = TextSelectionModel(coordinator: coordinator)
        select(first)
        let moved = observe(coordinator)
        select(second!)
        XCTAssertNil(first.selectedRange, "Only one region keeps a selection")
        XCTAssertTrue(coordinator.hasActiveSelection)
        XCTAssertEqual(moved.count, 0, "Moving the selection between regions keeps it active")
        let released = observe(coordinator)
        second = nil
        XCTAssertEqual(released.count, 1)
        XCTAssertFalse(coordinator.hasActiveSelection, "A released selection must not keep offscreen regions retained")
    }

    func testMovingASelectedModelToAnotherCoordinatorReleasesThePreviousOne() {
        let first = TextSelectionCoordinator(), second = TextSelectionCoordinator()
        let model = TextSelectionModel(coordinator: first)
        select(model)
        let left = observe(first)
        model.setCoordinator(second)
        XCTAssertEqual(left.count, 1)
        XCTAssertFalse(first.hasActiveSelection, "The previous coordinator must not keep its regions retained")
        XCTAssertTrue(second.hasActiveSelection)
        model.selectedRange = nil
        XCTAssertFalse(second.hasActiveSelection)
        select(model)
        model.setCoordinator(nil)
        XCTAssertFalse(second.hasActiveSelection, "Leaving every coordinator releases the selection too")
    }
}
