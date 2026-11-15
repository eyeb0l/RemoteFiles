#if os(iOS)
import SwiftUI
import UIKit
import WebKit

extension View {
    /// Runs a UIKit scroll view to the bottom edge, under the reader's bottom bar and the home
    /// indicator, and lets the end of its content scroll clear of both.
    ///
    /// A hosted UIKit view's own safe area covers the home indicator but not SwiftUI's bottom bar,
    /// so its automatic content inset left the end of a document under the bar. The covered height
    /// reaches the view as `bottomEdgeInset`, for `UIScrollView.clearBottomEdge(_:)` to apply.
    func scrollsToBottomEdge() -> some View { modifier(BottomEdgeScrolling()) }
}

private struct BottomEdgeScrolling: ViewModifier {
    /// The bottom of the view as laid out, and of the safe frame it would otherwise have had.
    @State private var extendedBottom: CGFloat = 0
    @State private var safeBottom: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .environment(\.bottomEdgeInset, max(0, extendedBottom - safeBottom))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { extendedBottom = $0 }
            .ignoresSafeArea(.container, edges: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { safeBottom = $0 }
    }
}

extension EnvironmentValues {
    /// How much of a view that runs to the bottom edge the bottom bar and home indicator cover.
    @Entry var bottomEdgeInset: CGFloat = 0
}

extension UIScrollView {
    /// Leaves `inset`, or the bottom of `safeArea` if larger, below the end of the content, counting
    /// what UIKit's automatic adjustment already adds for that safe area. The scroll indicator ends
    /// with it. A web view's own scroll view reports no safe area, so its caller passes the web view's.
    func clearBottomEdge(_ inset: CGFloat, safeArea: UIEdgeInsets) {
        let automatic = contentInsetAdjustmentBehavior == .never ? 0 : safeArea.bottom
        let added = max(0, max(inset, safeArea.bottom) - automatic)
        if contentInset.bottom != added { contentInset.bottom = added }
        if verticalScrollIndicatorInsets.bottom != added { verticalScrollIndicatorInsets.bottom = added }
    }
}

/// A web view whose page scrolls clear of what covers the bottom edge.
class BottomEdgeWebView: WKWebView {
    var bottomEdgeInset: CGFloat = 0 {
        didSet { if bottomEdgeInset != oldValue { clearBottomEdge() } }
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        clearBottomEdge()
    }
    private func clearBottomEdge() { scrollView.clearBottomEdge(bottomEdgeInset, safeArea: safeAreaInsets) }
}
#endif
