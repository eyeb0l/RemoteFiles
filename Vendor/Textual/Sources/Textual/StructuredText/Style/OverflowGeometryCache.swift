import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Reader-owned measured extents. This cache stores geometry, never rendered text or views.
@MainActor public final class OverflowGeometryCache: NSObject {
  struct Key: Hashable {
    let revision: AttributedString
    let environment: TextEnvironmentValues
    let width: CGFloat
  }
  struct Extent {
    let size: CGSize
    let spacing: StructuredText.TableCell.Spacing
  }
  private var extents: [Key: Extent] = [:]

  public override init() { super.init() }

  func extent(for key: Key) -> Extent? { extents[key] }
  func record(_ extent: Extent, for key: Key) {
    guard extent.size.width > 0, extent.size.height > 0 else { return }
    if extents.count >= 512, extents[key] == nil { extents.removeAll() }
    extents[key] = extent
  }

  #if os(iOS) && TEXTUAL_ENABLE_TEXT_SELECTION
  enum RegionID: Hashable { case image(String), overflow(Key) }
  private final class WeakRegion {
    weak var view: ReadingAnchorRegionBridge.Probe?
    init(_ view: ReadingAnchorRegionBridge.Probe) { self.view = view }
  }
  private enum ReadingAnchor {
    case prose(ordinal: Int, character: Int, viewportY: CGFloat)
    case region(id: RegionID, occurrence: Int, localY: CGFloat, viewportY: CGFloat)
    var viewportY: CGFloat {
      switch self {
      case .prose(_, _, let y), .region(_, _, _, let y): return y
      }
    }
  }
  private weak var scroll: UIScrollView?
  private weak var reader: UIView?
  private var regions: [ObjectIdentifier: WeakRegion] = [:]
  private var geometryAnchor: ReadingAnchor?
  private var readingAnchor: ReadingAnchor?
  private var documentY: CGFloat = 0
  private var until: CFTimeInterval = 0
  private var geometryDeadline: CFTimeInterval = 0
  private var link: CADisplayLink?
  private var document: String?
  private var tracksDeferredGeometry = false
  private var restoring = false
  private var restorationDeadline: CFTimeInterval = 0
  private var restorationCompletion: ((CGPoint) -> Void)?

  public var isRestoringReadingAnchor: Bool { restoring }
  public var hasReadingAnchor: Bool { readingAnchor != nil }

  public func documentDidChange(_ text: String) {
    guard document != text else { return }
    cancelAnchor(); readingAnchor = nil; tracksDeferredGeometry = false; document = text
  }

  func attach(_ view: UIView, deferring: Bool) {
    guard view.window != nil else { return }
    tracksDeferredGeometry = tracksDeferredGeometry || deferring
    var ancestor = view.superview
    while let value = ancestor {
      if let value = value as? UIScrollView { reader = view; scroll = value; return }
      ancestor = value.superview
    }
  }

  func detach(_ view: UIView) {
    guard reader === view else { return }
    // Teardown may already have removed the visible regions; keep the last live snapshot.
    cancelAnchor(); reader = nil; scroll = nil
  }

  func register(_ view: ReadingAnchorRegionBridge.Probe) {
    regions[ObjectIdentifier(view)] = WeakRegion(view)
    geometryDidChange()
  }

  func unregister(_ view: ReadingAnchorRegionBridge.Probe) {
    regions.removeValue(forKey: ObjectIdentifier(view))
  }

  private func visibleRegions(in scroll: UIScrollView) -> [ReadingAnchorRegionBridge.Probe] {
    regions = regions.filter { $0.value.view != nil }
    return regions.values.compactMap { $0.view }.filter {
      $0.window === scroll.window && $0.isDescendant(of: scroll) && $0.bounds.height > 0
    }.sorted {
      let lhs = $0.convert($0.bounds, to: scroll), rhs = $1.convert($1.bounds, to: scroll)
      return lhs.minY == rhs.minY ? lhs.minX < rhs.minX : lhs.minY < rhs.minY
    }
  }

  private func prose(in scroll: UIScrollView) -> [UITextInteractionView] {
    var result: [UITextInteractionView] = []
    func visit(_ root: UIView) {
      if root !== scroll, root is UIScrollView { return }
      if let value = root as? UITextInteractionView { result.append(value) }
      for child in root.subviews { visit(child) }
    }
    visit(scroll); return result
  }

  private func visibleAnchor() -> ReadingAnchor? {
    guard let scroll, let window = scroll.window else { return nil }
    let viewport = scroll.convert(scroll.bounds, to: window)
    let point = CGPoint(x: viewport.minX + 30, y: viewport.minY + min(60, viewport.height / 4))
    let candidates = visibleRegions(in: scroll)
    // Block geometry takes precedence over the enclosing prose selection model,
    // which can represent a code/table attachment with only one logical character.
    for value in candidates where value.ready {
      let frame = value.convert(value.bounds, to: window)
      guard frame.contains(point) else { continue }
      let matching = candidates.filter { $0.id == value.id }
      guard let occurrence = matching.firstIndex(where: { $0 === value }) else { continue }
      return .region(id: value.id, occurrence: occurrence,
                     localY: point.y - frame.minY, viewportY: point.y - viewport.minY)
    }
    for (ordinal, value) in prose(in: scroll).enumerated() {
      guard value.model.hasText, value.convert(value.bounds, to: window).contains(point),
            let position = value.model.closestPosition(to: value.convert(point, from: window)) else { continue }
      let caret = value.convert(value.model.caretRect(for: position), to: window)
      guard abs(caret.minY - point.y) < 160 else { continue }
      return .prose(ordinal: ordinal,
                    character: value.model.offset(from: value.model.startPosition, to: position),
                    viewportY: caret.minY - viewport.minY)
    }
    return nil
  }

  public func recordReadingAnchor() {
    guard tracksDeferredGeometry, !restoring, let scroll, scroll.window != nil else { return }
    // A gap or an unavailable block must invalidate an earlier prose anchor.
    // The caller can then use its saved native coordinate instead of stale content.
    readingAnchor = scroll.contentOffset.y > 1 ? visibleAnchor() : nil
  }

  public func restoreReadingAnchor(completion: @escaping (CGPoint) -> Void) {
    guard readingAnchor != nil else { return }
    cancelAnchor(); restoring = true; restorationCompletion = completion
    restorationDeadline = CACurrentMediaTime() + 5
    until = restorationDeadline
    startLink()
  }

  private func resolve(_ saved: ReadingAnchor, in scroll: UIScrollView) -> (y: CGFloat, ready: Bool)? {
    guard let window = scroll.window else { return nil }
    switch saved {
    case .prose(let ordinal, let character, _):
      let models = prose(in: scroll)
      guard models.indices.contains(ordinal), models[ordinal].model.hasText,
            let position = models[ordinal].model.position(from: models[ordinal].model.startPosition, offset: character) else { return nil }
      return (models[ordinal].convert(models[ordinal].model.caretRect(for: position), to: window).minY, true)
    case .region(let id, let occurrence, let localY, _):
      let matching = visibleRegions(in: scroll).filter { $0.id == id }
      guard matching.indices.contains(occurrence) else { return nil }
      let value = matching[occurrence], frame = value.convert(value.bounds, to: window)
      // Move toward an unloaded image/overflow region to trigger its viewport load,
      // then wait for its real geometry before completing restoration.
      return (frame.minY + min(localY, frame.height), value.ready)
    }
  }

  private func startLink() {
    guard link == nil else { return }
    let display = CADisplayLink(target: self, selector: #selector(correctAnchor))
    display.add(to: .main, forMode: .common); link = display
  }

  func captureAnchor() {
    guard !restoring, geometryAnchor == nil, let scroll, scroll.contentOffset.y > 1,
          let saved = visibleAnchor(), resolve(saved, in: scroll) != nil else { return }
    geometryAnchor = saved; readingAnchor = saved
    documentY = saved.viewportY + scroll.contentOffset.y
    geometryDeadline = CACurrentMediaTime() + 2
    until = min(geometryDeadline, CACurrentMediaTime() + 1)
    startLink()
  }

  func geometryDidChange() {
    if geometryAnchor != nil { until = min(geometryDeadline, CACurrentMediaTime() + 0.3) }
    if restoring { until = min(restorationDeadline, CACurrentMediaTime() + 0.3) }
  }

  @objc private func correctAnchor() {
    if restoring { restoreFrame(); return }
    guard let saved = geometryAnchor, let scroll, let window = scroll.window,
          let point = resolve(saved, in: scroll), CACurrentMediaTime() < until else {
      cancelAnchor(); recordReadingAnchor(); return
    }
    let viewport = scroll.convert(scroll.bounds, to: window)
    let currentY = point.y - viewport.minY + scroll.contentOffset.y
    let delta = currentY - documentY
    if abs(delta) > 0.5 {
      scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                                     y: max(0, scroll.contentOffset.y + delta)), animated: false)
      documentY = currentY
    }
  }

  private func restoreFrame() {
    guard let saved = readingAnchor else { cancelAnchor(); return }
    guard let scroll, let window = scroll.window else {
      if CACurrentMediaTime() >= restorationDeadline { cancelAnchor() }
      return
    }
    if scroll.isTracking || scroll.isDragging {
      finishRestoration(scroll); recordReadingAnchor(); return
    }
    guard let point = resolve(saved, in: scroll) else {
      if CACurrentMediaTime() >= restorationDeadline { finishRestoration(scroll) }
      return
    }
    let viewport = scroll.convert(scroll.bounds, to: window)
    let delta = point.y - viewport.minY - saved.viewportY
    if abs(delta) > 0.5 {
      scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                                     y: max(0, scroll.contentOffset.y + delta)), animated: false)
    }
    if (point.ready && CACurrentMediaTime() >= until) || CACurrentMediaTime() >= restorationDeadline {
      finishRestoration(scroll)
    }
  }

  private func finishRestoration(_ scroll: UIScrollView) {
    let completed = restorationCompletion
    let point = CGPoint(x: max(0, scroll.contentOffset.x + scroll.adjustedContentInset.left),
                        y: max(0, scroll.contentOffset.y + scroll.adjustedContentInset.top))
    cancelAnchor(); completed?(point); recordReadingAnchor()
  }

  func cancelAnchor() {
    link?.invalidate(); link = nil; geometryAnchor = nil
    restoring = false; restorationCompletion = nil
  }
  func cancelGeometryAnchor() { if !restoring { cancelAnchor() } }
  #else
  func captureAnchor() {}
  func geometryDidChange() {}
  func cancelAnchor() {}
  func cancelGeometryAnchor() {}
  public var isRestoringReadingAnchor: Bool { false }
  public var hasReadingAnchor: Bool { false }
  public func documentDidChange(_ text: String) {}
  public func recordReadingAnchor() {}
  public func restoreReadingAnchor(completion: @escaping (CGPoint) -> Void) {}
  #endif
}

#if os(iOS) && TEXTUAL_ENABLE_TEXT_SELECTION
struct OverflowAnchorBridge: UIViewRepresentable {
  let cache: OverflowGeometryCache
  let deferring: Bool
  func makeUIView(context: Context) -> Probe { Probe(cache, deferring: deferring) }
  func updateUIView(_ view: Probe, context: Context) {
    view.cache = cache; view.deferring = deferring; cache.attach(view, deferring: deferring)
  }
  final class Probe: UIView {
    var cache: OverflowGeometryCache
    var deferring: Bool
    init(_ cache: OverflowGeometryCache, deferring: Bool) {
      self.cache = cache; self.deferring = deferring; super.init(frame: .zero)
      isUserInteractionEnabled = false; isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { cache.detach(self) } else { cache.attach(self, deferring: deferring) }
    }
    override func layoutSubviews() { super.layoutSubviews(); cache.attach(self, deferring: deferring) }
  }
}
#endif

#if os(iOS) && TEXTUAL_ENABLE_TEXT_SELECTION
struct ReadingAnchorRegionBridge: UIViewRepresentable {
  let cache: OverflowGeometryCache
  let id: OverflowGeometryCache.RegionID
  let ready: Bool
  func makeUIView(context: Context) -> Probe { Probe(cache, id: id, ready: ready) }
  func updateUIView(_ view: Probe, context: Context) {
    view.id = id; view.ready = ready
    if view.window != nil { cache.register(view) }
  }
  final class Probe: UIView {
    let cache: OverflowGeometryCache
    var id: OverflowGeometryCache.RegionID
    var ready: Bool
    init(_ cache: OverflowGeometryCache, id: OverflowGeometryCache.RegionID, ready: Bool) {
      self.cache = cache; self.id = id; self.ready = ready; super.init(frame: .zero)
      isUserInteractionEnabled = false; isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { cache.unregister(self) } else { cache.register(self) }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      if window != nil { cache.register(self) }
    }
  }
}
#endif

extension TextualNamespace where Base: View {
  /// Identifies an inline image across reader subtree replacement without retaining its pixels.
  public func readingAnchorRegion(id: String, geometryCache: OverflowGeometryCache?, ready: Bool) -> some View {
    base.background {
      #if os(iOS) && TEXTUAL_ENABLE_TEXT_SELECTION
      if let geometryCache {
        ReadingAnchorRegionBridge(cache: geometryCache, id: .image(id), ready: ready)
      }
      #endif
    }
  }
}
