import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Controls how content behaves when it overflows horizontally.
public enum OverflowMode: Hashable {
  /// Wraps content to fit the available width.
  case wrap
  /// Allows horizontal scrolling.
  case scroll
}

/// Describes the current overflow behavior and available layout metrics.
public enum OverflowState: Hashable {
  /// Wraps content to fit the available width.
  case wrap
  /// Scrolls horizontally. The container width is provided when available.
  case scroll(containerWidth: CGFloat?)

  /// The scroll container width when available; otherwise `nil`.
  public var containerWidth: CGFloat? {
    guard case .scroll(let containerWidth) = self else {
      return nil
    }
    return containerWidth
  }
}

/// A container that adapts to the current ``OverflowMode``.
///
/// `Overflow` handles content that overflows horizontally. It can switch
/// between wrapping and horizontal scrolling based on an environment value.
///
/// You can set the mode using the ``TextualNamespace/overflowMode(_:)`` modifier. The default is
/// ``OverflowMode/scroll``.
///
/// - Note: You should always use `Overflow` if your custom style needs horizontal scrolling.
///   Using a horizontal `ScrollView` directly will interfere with text selection gestures.
public struct Overflow<Content: View>: View {
  @Environment(\.overflowMode) private var mode
  @State private var containerWidth: CGFloat?
  @Environment(\.overflowViewport) private var viewport
  @Environment(\.overflowContentRevision) private var contentRevision
  @Environment(\.textEnvironment) private var textEnvironment
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  #if TEXTUAL_ENABLE_TEXT_SELECTION
  @Environment(TextSelectionCoordinator.self) private var selectionCoordinator: TextSelectionCoordinator?
  #endif
  @State private var contentSize: CGSize?
  @State private var tableSpacing = StructuredText.TableCell.Spacing()
  @State private var isNearViewport = false
  @State private var contentIsMounted = true
  @State private var hasRetiredContent = false
  @State private var contentIsReady = false
  @State private var assistiveContentRequired = Self.assistiveContentRequired

  private static var assistiveContentRequired: Bool {
    #if os(iOS)
    UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning ||
      UIAccessibility.isSpeakScreenEnabled || UIAccessibility.isAssistiveTouchRunning
    #else
    false
    #endif
  }

  private var retainContent: Bool {
    #if TEXTUAL_ENABLE_TEXT_SELECTION
    viewport == nil || voiceOverEnabled || assistiveContentRequired ||
      (selectionCoordinator?.hasActiveSelection ?? false)
    #else
    viewport == nil || voiceOverEnabled || assistiveContentRequired
    #endif
  }

  private struct ContentMeasurement: Equatable {
    let size: CGSize
    let ready: Bool
  }

  private struct RetentionWork: Equatable {
    let viewport: OverflowViewport?
    let environment: TextEnvironmentValues
    let revision: AttributedString?
    let size: CGSize?
    let width: CGFloat?
    let ready: Bool
    let near: Bool
    let retain: Bool
  }

  private let content: (OverflowState) -> Content

  private var defersInitialContent: Bool { viewport?.defersInitialContent == true }
  private var cacheKey: OverflowGeometryCache.Key? {
    guard let contentRevision, let containerWidth else { return nil }
    return .init(revision: contentRevision, environment: textEnvironment, width: containerWidth)
  }
  private func rememberExtent() {
    guard contentIsReady, let contentSize, let cacheKey else { return }
    viewport?.cache?.record(.init(size: contentSize, spacing: tableSpacing), for: cacheKey)
  }

  /// Creates an overflow container.
  public init(@ViewBuilder content: @escaping () -> Content) {
    self.init { _ in
      content()
    }
  }

  /// Creates an overflow container that exposes the current overflow state.
  public init(@ViewBuilder content: @escaping (_ state: OverflowState) -> Content) {
    self.content = content
  }

  public var body: some View {
    switch mode {
    case .wrap:
      content(.wrap)
        .frame(maxWidth: .infinity, alignment: .leading)

    case .scroll:
      ScrollView(.horizontal) {
        ZStack {
          // Update the scroll view height when the content height changes
          Color.clear
            .frame(minWidth: viewport == nil ? nil : contentSize?.width,
                   minHeight: contentSize?.height ?? (defersInitialContent ? 120 : nil))
          if (contentIsMounted && (!defersInitialContent || contentSize != nil)) || retainContent || isNearViewport || (!defersInitialContent && contentSize == nil) {
            content(.scroll(containerWidth: containerWidth))
              .environment(\.overflowReadinessTracking, viewport != nil)
              .onGeometryChange(for: ContentMeasurement.self) {
                ContentMeasurement(size: $0.size, ready: contentIsReady)
              } action: {
                if $0.ready || (!defersInitialContent && !hasRetiredContent) {
                  contentSize = $0.size
                  rememberExtent()
                  viewport?.cache?.geometryDidChange()
                }
              }
              .onPreferenceChange(StructuredText.TableCell.SpacingKey.self) { tableSpacing = $0; rememberExtent() }
              .onPreferenceChange(OverflowContentReadyKey.self) {
                contentIsReady = $0.hasReport && $0.allReady
              }
              // Keep selection local to this scroll region, as before.
              .modifier(TextSelectionInteraction())
              .transformPreference(Text.LayoutKey.self) { $0 = [] }
          } else if let contentSize {
            // Preserve both axes so retiring a label cannot collapse document
            // height or reset this existing scroll container's horizontal offset.
            Color.clear.frame(width: contentSize.width, height: contentSize.height)
              .accessibilityHidden(true)
              .preference(key: StructuredText.TableCell.SpacingKey.self, value: tableSpacing)
          }
        }
      }
      .background {
        #if os(iOS) && TEXTUAL_ENABLE_TEXT_SELECTION
        if let cache = viewport?.cache, let cacheKey {
          ReadingAnchorRegionBridge(cache: cache, id: .overflow(cacheKey),
                                    ready: contentIsReady || (hasRetiredContent && contentSize != nil))
        }
        #endif
      }
      .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.width) {
        containerWidth = $1
      }
      .onGeometryChange(for: Bool.self) { geometry in
        guard let viewport else { return true }
        let frame = geometry.frame(in: .named(viewport.coordinateSpaceName))
        return frame.maxY >= -viewport.height && frame.minY <= viewport.height * 2
      } action: {
        if $0, !isNearViewport, defersInitialContent, contentSize == nil { viewport?.cache?.captureAnchor() }
        isNearViewport = $0
      }
      .task(id: RetentionWork(viewport: viewport, environment: textEnvironment, revision: contentRevision,
                             size: contentSize, width: containerWidth,
                             ready: contentIsReady, near: isNearViewport, retain: retainContent)) {
        if retainContent || isNearViewport || (!defersInitialContent && contentSize == nil) {
          if defersInitialContent, contentSize == nil { viewport?.cache?.captureAnchor() }
          contentIsMounted = true
          return
        }
        guard contentIsReady else { return }
        // Textual prepares text and highlighting in successive updates. Only
        // retire after their ready preference and geometry have stayed stable.
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard !Task.isCancelled else { return }
        hasRetiredContent = true
        contentIsReady = false
        contentIsMounted = false
      }
      .onChange(of: contentRevision) { viewport?.cache?.cancelGeometryAnchor(); contentIsMounted = true }
      .onChange(of: textEnvironment) { viewport?.cache?.cancelGeometryAnchor(); contentIsMounted = true }
      .onChange(of: containerWidth) {
        if defersInitialContent, contentSize == nil, !isNearViewport, !retainContent {
          if let cacheKey, let extent = viewport?.cache?.extent(for: cacheKey) {
            contentIsMounted = false; hasRetiredContent = true
            contentSize = extent.size; tableSpacing = extent.spacing
          }
        } else { contentIsMounted = true }
      }
      #if os(iOS)
      .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in assistiveContentRequired = Self.assistiveContentRequired }
      .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.switchControlStatusDidChangeNotification)) { _ in assistiveContentRequired = Self.assistiveContentRequired }
      .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.speakScreenStatusDidChangeNotification)) { _ in assistiveContentRequired = Self.assistiveContentRequired }
      .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.assistiveTouchStatusDidChangeNotification)) { _ in assistiveContentRequired = Self.assistiveContentRequired }
      #endif
      // Propagate gesture exclusion area
      .background(
        GeometryReader { geometry in
          Color.clear
            .preference(
              key: OverflowFrameKey.self,
              value: [geometry.frame(in: .textContainer)]
            )
        }
      )
    }
  }
}

extension EnvironmentValues {
  @usableFromInline
  @Entry var overflowMode = OverflowMode.scroll
}


struct OverflowContentReadiness: Equatable, Sendable {
  var hasReport = false
  var allReady = true

  init() {}

  init(ready: Bool) {
    hasReport = true
    allReady = ready
  }

  mutating func merge(_ other: Self) {
    hasReport = hasReport || other.hasReport
    allReady = allReady && other.allReady
  }
}

struct OverflowContentReadyKey: PreferenceKey {
  static let defaultValue = OverflowContentReadiness()
  static func reduce(value: inout OverflowContentReadiness, nextValue: () -> OverflowContentReadiness) {
    value.merge(nextValue())
  }
}

struct OverflowViewport: Hashable, Sendable {
  let coordinateSpaceName: String
  let height: CGFloat
  var defersInitialContent = false
  var cache: OverflowGeometryCache? = nil
}

extension EnvironmentValues {
  @Entry var overflowViewport: OverflowViewport? = nil
  @Entry var overflowReadinessTracking = false
  @Entry var overflowContentRevision: AttributedString? = nil
}

extension TextualNamespace where Base: View {
  /// Retains settled geometry while retiring offscreen horizontal code/table labels.
  /// Selection and active assistive technologies retain the complete content.
  public func viewportOverflowRendering(in coordinateSpaceName: String, viewportHeight: CGFloat,
                                       deferInitialOffscreenContent: Bool = false,
                                       geometryCache: OverflowGeometryCache? = nil) -> some View {
    base.environment(\.overflowViewport, OverflowViewport(coordinateSpaceName: coordinateSpaceName, height: viewportHeight,
                                                         defersInitialContent: deferInitialOffscreenContent, cache: geometryCache))
      .background {
        #if os(iOS) && TEXTUAL_ENABLE_TEXT_SELECTION
        if let geometryCache {
          OverflowAnchorBridge(cache: geometryCache, deferring: deferInitialOffscreenContent)
        }
        #endif
      }
  }
}
