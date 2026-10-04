import SwiftUI

/// Owned by each reader route, rather than the content subtree that refresh/mode changes replace.
/// Rendered and source coordinates remain independent when switching reading modes.
@MainActor @Observable public final class DocumentReadingPosition {
    public var rendered: CGPoint = .zero
    public var source: CGPoint = .zero
    public init() {}
}

struct DocumentScrollPreservation: ViewModifier {
    private enum Phase: Equatable { case awaitingContent, awaitingOffset, tracking }
    @Binding var saved: CGPoint
    let ready: Bool
    @State private var position = ScrollPosition(point: .zero)
    @State private var target = CGPoint.zero
    @State private var phase = Phase.tracking
    @State private var appeared = false
    @State private var geometry: ScrollGeometry?
    @State private var command: CGPoint?

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, value in
                geometry = value
                guard appeared, ready else { return }
                let offset = CGPoint(x: max(0, value.contentOffset.x + value.contentInsets.leading),
                                     y: max(0, value.contentOffset.y + value.contentInsets.top))
                if phase != .tracking {
                    // A user scroll takes over, including when updated content is shorter.
                    if position.isPositionedByUser { phase = .tracking; command = nil }
                    else if phase == .awaitingOffset {
                        guard near(offset, target) else { return }
                        phase = .tracking
                    } else {
                        requestRestoration(in: value)
                        return
                    }
                }
                if !near(saved, offset) { saved = offset }
            }
            .onAppear {
                appeared = true
                beginRestoration()
            }
            .onChange(of: ready) { _, value in
                if value, appeared { beginRestoration() }
            }
            .task(id: command) {
                guard let command else { return }
                // Issue one position command outside the geometry callback. Reissuing it
                // during every layout can feed geometry changes back into the same frame.
                await Task.yield()
                guard !Task.isCancelled, appeared, ready, self.command == command else { return }
                position.scrollTo(point: command)
            }
            .onDisappear { appeared = false; command = nil }
    }

    private func beginRestoration() {
        target = saved
        command = nil
        // A synchronously laid-out Source view can emit its first geometry before onAppear.
        // There is no restoration to wait for at zero; its next scroll must be tracked.
        phase = near(target, .zero) ? .tracking : .awaitingContent
        if ready, let geometry, phase == .awaitingContent { requestRestoration(in: geometry) }
    }

    private func requestRestoration(in value: ScrollGeometry) {
        // Textual installs its prepared text after the initial zero-height layout. Preserve
        // the saved coordinate until enough content exists, then schedule one restoration.
        let maxY = max(0, value.contentSize.height + value.contentInsets.bottom - value.containerSize.height)
        let maxX = max(0, value.contentSize.width + value.contentInsets.trailing - value.containerSize.width)
        guard target.y <= maxY + 1, target.x <= maxX + 1 else { return }
        phase = .awaitingOffset
        command = target
    }

    private func near(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
    }
}
