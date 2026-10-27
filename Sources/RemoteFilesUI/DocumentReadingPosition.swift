import SwiftUI
import Textual
import RemoteFilesCore
#if os(iOS)
import UIKit
#endif

/// Owned by each reader route, rather than the content subtree that refresh/mode changes replace.
/// Rendered and source coordinates remain independent when switching reading modes.
@MainActor @Observable public final class DocumentReadingPosition {
    public var rendered: CGPoint = .zero { didSet { if rendered != oldValue { scheduleSave() } } }
    public var sourceAnchor: SavedReadingPosition.Anchor? { didSet { if sourceAnchor != oldValue { scheduleSave() } } }
    public var source: CGPoint = .zero { didSet { if source != oldValue { scheduleSave() } } }
    @ObservationIgnored private var store: ReadingPositionStore?
    @ObservationIgnored private var connectionID: UUID?
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var preparationID = UUID()
    public private(set) var persistenceError: String?
    /// Geometry belongs to the reader route, surviving rendered/source subtree replacement.
    public let overflowGeometry = OverflowGeometryCache()
    public init() {}

    /// Call before publishing the decoded preview. Changed server content starts at the top;
    /// applying old pixel coordinates to a different revision could skip unrelated content.
    public func prepare(text: String, store: ReadingPositionStore?, connectionID: UUID, path: String) async {
        let token = UUID(); preparationID = token
        let nextRevision = await Task.detached(priority: .utility) { SavedReadingPosition.revision(for: text) }.value
        guard preparationID == token, !Task.isCancelled else { return }
        if self.revision == nextRevision, self.connectionID == connectionID,
           self.path.map({ Data($0.utf8) == Data(path.utf8) }) == true { return }
        await flush()
        guard preparationID == token, !Task.isCancelled else { return }
        preparing = true
        defer { preparing = false }
        let restored = await store?.restore(connectionID: connectionID, path: path, revision: nextRevision)
        guard preparationID == token, !Task.isCancelled else { return }
        self.store = store; self.connectionID = connectionID; self.path = path; revision = nextRevision
        overflowGeometry.documentDidChange(text)
        overflowGeometry.snapshot = restored?.renderedAnchor.map {
            .init(kind: $0.kind, ordinal: $0.ordinal, character: $0.character, fraction: $0.fraction, viewportY: $0.viewportY)
        }
        sourceAnchor = restored?.sourceAnchor
        rendered = restored.map { CGPoint(x: $0.rendered.x, y: $0.rendered.y) } ?? .zero
        source = restored.map { CGPoint(x: $0.source.x, y: $0.source.y) } ?? .zero
    }

    /// Flush on leaving the reader and before background suspension; ordinary scroll updates debounce.
    public func flush() async {
        pendingSave?.cancel(); pendingSave = nil
        guard let store, let connectionID, let path, let revision else { return }
        let snapshot = SavedReadingPosition(revision: revision,
            rendered: .init(x: Double(rendered.x), y: Double(rendered.y)),
            source: .init(x: Double(source.x), y: Double(source.y)),
            renderedAnchor: overflowGeometry.snapshot.map {
                .init(kind: $0.kind, ordinal: $0.ordinal, character: $0.character, fraction: $0.fraction, viewportY: $0.viewportY)
            }, sourceAnchor: sourceAnchor)
        do {
            try await store.save(snapshot, connectionID: connectionID, path: path)
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    private func scheduleSave() {
        guard !preparing, store != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            await self?.flush()
        }
    }
}

struct DocumentScrollPreservation: ViewModifier {
    private enum Phase: Equatable { case awaitingContent, awaitingOffset, tracking }
    private struct RestorationCommand: Equatable {
        let id = UUID()
        let point: CGPoint
    }
    @Binding var saved: CGPoint
    let ready: Bool
    var overflowGeometry: OverflowGeometryCache? = nil
    var navigationID: UUID? = nil
    @State private var position = ScrollPosition(point: .zero)
    @State private var target = CGPoint.zero
    @State private var phase = Phase.tracking
    @State private var appeared = false
    @State private var geometry: ScrollGeometry?
    @State private var command: RestorationCommand?
    @State private var restorationAttempts = 0
    @State private var restorationID = UUID()
    @State private var lastRestorationGeometry: ScrollGeometry?
    @State private var userInteracting = false

    init(saved: Binding<CGPoint>, ready: Bool, overflowGeometry: OverflowGeometryCache? = nil, navigationID: UUID? = nil) {
        _saved = saved; self.ready = ready; self.overflowGeometry = overflowGeometry; self.navigationID = navigationID
        // Seed SwiftUI with the saved coordinate while its viewport attaches.
        _position = State(initialValue: ScrollPosition(point: navigationID == nil ? saved.wrappedValue : .zero))
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, value in
                // Offset tracking must not feed a new geometry state back into every
                // scroll frame. Restoration only needs changes to the viewport's layout.
                let resized = geometry.map { $0.containerSize.width != value.containerSize.width } ?? false
                if geometry.map({ !sameLayout($0, value) }) ?? true { geometry = value }
                if resized, appeared, ready, navigationID == nil, !userInteracting,
                   overflowGeometry?.hasReadingAnchor == true {
                    overflowGeometry?.restoreReadingAnchor { saved = $0 }
                    return
                }
                guard appeared, ready else { return }
                let offset = CGPoint(x: max(0, value.contentOffset.x + value.contentInsets.leading),
                                     y: max(0, value.contentOffset.y + value.contentInsets.top))
                if phase != .tracking {
                    // A user scroll takes over, including when updated content is shorter.
                    if userInteracting { phase = .tracking; command = nil }
                    else if phase == .awaitingOffset {
                        guard near(offset, target) else {
                            // A cold NavigationStack changes its insets/container after the
                            // first command. Reissue once for each new layout, with a cap.
                            requestRestoration(in: value)
                            return
                        }
                        phase = .tracking
                        command = nil
                    } else {
                        requestRestoration(in: value)
                        return
                    }
                }
                guard overflowGeometry?.isRestoringReadingAnchor != true else { return }
                if !near(saved, offset) { saved = offset }
                overflowGeometry?.recordReadingAnchor()
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
                guard !Task.isCancelled, appeared, ready, navigationID == nil, !userInteracting, self.command == command else { return }
                position.scrollTo(point: command.point)
            }
            .onScrollPhaseChange { _, newPhase in
                // ScrollPosition.isPositionedByUser can also become true during cold
                // safe-area attachment. Only an actual interaction takes over restoration.
                userInteracting = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                if userInteracting, phase != .tracking { phase = .tracking; command = nil }
            }
            .onChange(of: navigationID) { _, value in
                guard value != nil else { return }
                phase = .tracking; command = nil
            }
            .onDisappear { appeared = false; command = nil; userInteracting = false }
            .background {
                #if os(iOS)
                NativeReadingRestorationProbe(commandID: restorationID,
                    target: target, active: appeared && ready && navigationID == nil && !userInteracting && phase != .tracking)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                #endif
            }
    }

    private func beginRestoration() {
        guard navigationID == nil else { phase = .tracking; command = nil; return }
        target = saved
        restorationID = UUID()
        command = nil
        restorationAttempts = 0
        lastRestorationGeometry = nil
        guard ready else { phase = .awaitingContent; return }
        if !near(target, .zero), let overflowGeometry, overflowGeometry.hasReadingAnchor {
            phase = .tracking
            overflowGeometry.restoreReadingAnchor { saved = $0 }
            return
        }
        // A synchronously laid-out Source view can emit its first geometry before onAppear.
        // There is no restoration to wait for at zero; its next scroll must be tracked.
        phase = near(target, .zero) ? .tracking : .awaitingContent
        if ready, let geometry, phase == .awaitingContent { requestRestoration(in: geometry) }
    }

    private func requestRestoration(in value: ScrollGeometry) {
        guard navigationID == nil, !userInteracting else { return }
        // Textual installs its prepared text after the initial zero-height layout. Preserve
        // the saved coordinate until enough content exists, then schedule one restoration.
        let maxY = max(0, value.contentSize.height + value.contentInsets.bottom - value.containerSize.height)
        let maxX = max(0, value.contentSize.width + value.contentInsets.trailing - value.containerSize.width)
        guard target.y <= maxY + 1, target.x <= maxX + 1, restorationAttempts < 8 else { return }
        guard lastRestorationGeometry.map({ !sameLayout($0, value) }) ?? true else { return }
        lastRestorationGeometry = value
        restorationAttempts += 1
        phase = .awaitingOffset
        command = RestorationCommand(point: target)
    }

    private func sameLayout(_ lhs: ScrollGeometry, _ rhs: ScrollGeometry) -> Bool {
        lhs.contentSize == rhs.contentSize && lhs.containerSize == rhs.containerSize && lhs.contentInsets == rhs.contentInsets
    }

    private func near(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
    }
}

#if os(iOS)
/// SwiftUI can ignore a cold point command while a NavigationStack attaches its safe-area
/// viewport. This probe has no scroll ownership: it supplies the one initial native offset,
/// then the ordinary geometry callback resumes tracking and removes the pending command.
private struct NativeReadingRestorationProbe: UIViewRepresentable {
    let commandID: UUID?
    let target: CGPoint?
    let active: Bool
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.configure(id: commandID, target: target, active: active)
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: UIView {
        private var requestID: UUID?
        private var work: Task<Void, Never>?
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func stop() { work?.cancel(); work = nil; requestID = nil }
        func configure(id: UUID?, target: CGPoint?, active: Bool) {
            guard active, let id, let target else { stop(); return }
            guard requestID != id else { return }
            stop(); requestID = id
            work = Task { [weak self] in
                var writes = 0
                for _ in 0..<100 {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, !Task.isCancelled, self.requestID == id else { return }
                    guard let scroll = self.scopedScrollView(allowHorizontal: target.x > 0), !scroll.isDragging, !scroll.isDecelerating,
                          scroll.bounds.width > 0, scroll.bounds.height > 0 else { continue }
                    let maxY = max(0, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
                    let maxX = max(0, scroll.contentSize.width + scroll.adjustedContentInset.right - scroll.bounds.width)
                    guard target.y <= maxY + 1, target.x <= maxX + 1 else { continue }
                    let desired = CGPoint(x: target.x - scroll.adjustedContentInset.left,
                                          y: target.y - scroll.adjustedContentInset.top)
                    if abs(scroll.contentOffset.x - desired.x) < 0.5 && abs(scroll.contentOffset.y - desired.y) < 0.5 { return }
                    guard writes < 3 else { return }
                    writes += 1
                    scroll.setContentOffset(desired, animated: false)
                }
            }
        }
        private func scopedScrollView(allowHorizontal: Bool) -> UIScrollView? {
            guard let window, bounds.width > 0, bounds.height > 0 else { return nil }
            let viewport = convert(bounds, to: window).intersection(window.bounds)
            guard viewport.width > 100, viewport.height > 100 else { return nil }
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            var ancestor = superview
            // A background is sometimes a sibling of HostingScrollView rather than its
            // descendant. Search only the nearest local wrapper with an overlapping viewport.
            for _ in 0..<6 {
                guard let container = ancestor else { return nil }
                let candidates = descendants(container).compactMap { $0 as? UIScrollView }.filter { scroll in
                    guard !(scroll is UITextView), scroll.window === window, scroll.isScrollEnabled,
                          !scroll.isHidden, scroll.alpha > 0.01,
                          (allowHorizontal || scroll.contentSize.width <= scroll.bounds.width + 2) else { return false }
                    let frame = scroll.convert(scroll.bounds, to: window)
                    let overlap = frame.intersection(viewport)
                    return overlap.width >= viewport.width * 0.9 && overlap.height >= viewport.height * 0.9
                }
                if candidates.count == 1 { return candidates[0] }
                if let scroll = container as? UIScrollView, candidates.contains(where: { $0 === scroll }) { return scroll }
                ancestor = container.superview
            }
            return nil
        }
    }
}
#endif
