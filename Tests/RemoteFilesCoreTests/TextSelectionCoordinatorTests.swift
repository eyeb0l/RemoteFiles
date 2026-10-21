import XCTest
import Observation
@testable import Textual

/// Overflow regions keep offscreen content mounted while any selection is active, and observe
/// `hasActiveSelection` to retire it afterwards. Selection models register during SwiftUI updates,
/// so registration must not fire that one-shot observation, or the later deselection goes unseen.
@MainActor final class TextSelectionCoordinatorTests: XCTestCase {
    private final class Notifications: @unchecked Sendable { var count = 0 }
    @MainActor private final class Ended { var value = false }

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

    /// An offscreen region retained for a selection waits for it to end rather than relying on SwiftUI
    /// restarting its retention task, which CI showed can be coalesced away under load.
    func testSelectionEndedReturnsOnDeselectionReleaseAndCancellation() async {
        let coordinator = TextSelectionCoordinator()
        await coordinator.selectionEnded() // Nothing selected: returns at once.

        let model = TextSelectionModel(coordinator: coordinator), other = TextSelectionModel(coordinator: coordinator)
        select(model)
        let ended = Ended()
        let deselected = Task { await coordinator.selectionEnded(); ended.value = true }
        await Task.yield()
        select(other) // Moving the selection to another region keeps it active.
        await Task.yield()
        XCTAssertFalse(ended.value, "Moving a selection must not end the wait")
        other.selectedRange = nil
        await deselected.value
        XCTAssertTrue(ended.value)

        var released: TextSelectionModel? = TextSelectionModel(coordinator: coordinator)
        select(released!)
        let afterRelease = Task { await coordinator.selectionEnded() }
        await Task.yield()
        released = nil
        await afterRelease.value

        let kept = TextSelectionModel(coordinator: coordinator)
        select(kept)
        let cancelled = Task { await coordinator.selectionEnded() }
        await Task.yield()
        cancelled.cancel()
        await cancelled.value
        XCTAssertTrue(coordinator.hasActiveSelection, "Cancellation ends the wait without ending the selection")
        XCTAssertEqual(coordinator.pendingSelectionEndWaits, 0)

        // Many offscreen regions wait at once; deselection releases them all together.
        let many = (0..<200).map { _ in Task { await coordinator.selectionEnded() } }
        await Task.yield()
        XCTAssertEqual(coordinator.pendingSelectionEndWaits, 200)
        kept.selectedRange = nil
        XCTAssertEqual(coordinator.pendingSelectionEndWaits, 0, "Deselection releases every waiter in one pass")
        for wait in many { await wait.value }

        // A replacement selection needs a new wait, which a later deselection ends again.
        select(kept)
        let rearmed = Task { await coordinator.selectionEnded() }
        await Task.yield()
        XCTAssertEqual(coordinator.pendingSelectionEndWaits, 1)
        kept.selectedRange = nil
        await rearmed.value
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
