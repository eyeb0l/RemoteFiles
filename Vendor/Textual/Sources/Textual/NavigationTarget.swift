import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Marks a range for a one-shot reveal in the enclosing reader scroll views.
public enum TextualNavigationTarget: AttributedStringKey {
  public typealias Value = UUID
  public static let name = "Textual.NavigationTarget"
}

extension TextualNamespace where Base: View {
  /// Reveals the marked range once for each request UUID without taking over gestures.
  @MainActor public func revealNavigationTarget(_ id: UUID?, onReveal: ((UUID) -> Void)? = nil) -> some View {
    base.modifier(NavigationRevealRequest(id: id, onReveal: onReveal))
  }
}

private struct NavigationRevealRequest: ViewModifier {
  let id: UUID?
  let onReveal: ((UUID) -> Void)?
  @Environment(\.overflowViewport) private var viewport
  @State private var coordinator = NavigationRevealCoordinator()
  func body(content: Content) -> some View {
    content.environment(\.navigationRevealID, id)
      .environment(\.navigationRevealCoordinator, coordinator)
      .onChange(of: id, initial: true) { _, id in
        coordinator.onReveal = onReveal
        if id != nil { viewport?.cache?.cancelAnchor() }
      }
  }
}

extension EnvironmentValues {
  @Entry var navigationRevealID: UUID?
  @Entry var navigationRevealCoordinator: NavigationRevealCoordinator?
  @Entry var navigationRevealGeometryReady = true
}

@MainActor final class NavigationRevealCoordinator {
  private var completed: UUID?
  private var staged: UUID?
  var onReveal: ((UUID) -> Void)?
  func isPending(_ id: UUID) -> Bool { completed != id }
  func canStage(_ id: UUID) -> Bool { isPending(id) && staged != id }
  func finish(_ id: UUID) {
    guard isPending(id) else { return }
    completed = id
    onReveal?(id)
  }
  func stage(_ id: UUID) { staged = id }
}

struct NavigationTargetAttribute: TextAttribute {
  let id: UUID
}

struct NavigationTargetOverlay: ViewModifier {
  @Environment(\.navigationRevealID) private var id
  @Environment(\.navigationRevealCoordinator) private var coordinator
  @Environment(\.navigationRevealGeometryReady) private var ready
  @Environment(\.overflowViewport) private var viewport
  func body(content: Content) -> some View {
    #if os(iOS)
    content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
      if let id, let coordinator, ready, coordinator.isPending(id) {
        GeometryReader { geometry in
          if let target = layouts.compactMap({ anchored -> CGRect? in
            for line in anchored.layout {
              if let run = line.first(where: { $0[NavigationTargetAttribute.self]?.id == id }) {
                let origin = geometry[anchored.origin]
                var rect = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                // A newline/caret run can have real line geometry but no width.
                rect.size.width = max(1, rect.width)
                return rect
              }
            }
            return nil
          }).first {
            NavigationRevealBridge(id: id, rect: target, coordinator: coordinator,
                                   geometryCache: viewport?.cache, stageOnly: false)
          }
        }.allowsHitTesting(false)
      }
    }
    #else
    content
    #endif
  }
}

/// A block can be retired outside the viewport; first bring its placeholder into
/// view, then let the real text layout reveal the exact range after it mounts.
struct NavigationBlockReveal: ViewModifier {
  let target: UUID?
  let isFinal: Bool
  @Environment(\.navigationRevealID) private var id
  @Environment(\.navigationRevealCoordinator) private var coordinator
  @Environment(\.overflowViewport) private var viewport
  func body(content: Content) -> some View {
    content.background {
      #if os(iOS)
      if let id, target == id, let coordinator, coordinator.isPending(id) {
        GeometryReader { geometry in
          NavigationRevealBridge(id: id, rect: CGRect(origin: .zero, size: CGSize(width: min(geometry.size.width, 40), height: min(geometry.size.height, 40))),
                                 coordinator: coordinator, geometryCache: viewport?.cache, stageOnly: !isFinal)
        }.allowsHitTesting(false)
      }
      #endif
    }
  }
}

#if os(iOS)
struct NavigationRevealBridge: UIViewRepresentable {
  let id: UUID
  let rect: CGRect
  let coordinator: NavigationRevealCoordinator
  let geometryCache: OverflowGeometryCache?
  let stageOnly: Bool
  func makeUIView(context: Context) -> Probe { Probe() }
  func updateUIView(_ view: Probe, context: Context) {
    view.id = id; view.target = rect; view.coordinator = coordinator; view.stageOnly = stageOnly
    view.geometryCache = geometryCache
    view.schedule()
  }
  static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }
  final class Probe: UIView {
    var id: UUID?
    var target = CGRect.zero
    var coordinator: NavigationRevealCoordinator?
    weak var geometryCache: OverflowGeometryCache?
    var stageOnly = false
    private var displayLink: CADisplayLink?
    private var deadline: CFTimeInterval = 0
    private(set) var failedID: UUID?
    var isWaitingForGeometry: Bool { displayLink != nil }
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false; isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stop() } else { schedule() } }
    override func layoutSubviews() { super.layoutSubviews(); schedule() }
    func stop() { displayLink?.invalidate(); displayLink = nil }
    func schedule() {
      guard window != nil, let id, let coordinator, coordinator.isPending(id),
            failedID != id, !stageOnly || coordinator.canStage(id), displayLink == nil else { return }
      // Geometry drives success. This deadline only bounds an unavailable target
      // and prevents a display link retaining a permanently unresolvable probe.
      deadline = CACurrentMediaTime() + 5
      let link = CADisplayLink(target: self, selector: #selector(reveal))
      link.add(to: .main, forMode: .common); displayLink = link
    }
    @objc private func reveal() {
      guard let id, let coordinator, coordinator.isPending(id),
            !stageOnly || coordinator.canStage(id) else { stop(); return }
      guard CACurrentMediaTime() < deadline else { failedID = id; stop(); return }
      guard window != nil, bounds.width > 0, bounds.height > 0,
            target.width > 0, target.height > 0 else { return }
      var ancestors: [UIScrollView] = []
      var ancestor = superview
      while let value = ancestor {
        if let scroll = value as? UIScrollView { ancestors.append(scroll) }
        ancestor = value.superview
      }
      guard !ancestors.isEmpty, ancestors.allSatisfy({ $0.bounds.width > 0 && $0.bounds.height > 0 && $0.contentSize.height > 0 }) else { return }
      geometryCache?.cancelAnchor()
      // Work from the innermost horizontal viewport to the outer document.
      for scroll in ancestors {
        let rect = convert(target, to: scroll).insetBy(dx: -12, dy: -20)
        scroll.scrollRectToVisible(rect, animated: false)
      }
      if stageOnly { coordinator.stage(id) } else { coordinator.finish(id) }
      stop()
    }
  }
}
#endif
