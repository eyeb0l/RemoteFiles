import SwiftUI

// MARK: - Overview
//
// `TextSelectionCoordinator` ensures there’s at most one active selection across a view subtree.
//
// Selection can be driven by multiple independent overlays. For example, `Overflow`-backed
// scrollable regions install their own interaction views so selection works locally inside the
// scroll view, while the surrounding content can still be selectable.
//
// Each `TextSelectionModel` registers with a shared coordinator. When one model becomes selected,
// the coordinator clears selection in the others, preventing multiple active selections across
// local and non-scrollable regions.

#if TEXTUAL_ENABLE_TEXT_SELECTION
  @Observable
  final class TextSelectionCoordinator {
    // RemoteFiles: models register from UIKit representable updates, in the middle of SwiftUI
    // updates. When this list was observed, a registration could fire an Overflow's one-shot
    // observation during an update; SwiftUI dropped that invalidation, so the later deselection
    // went unobserved and the offscreen region never retired. Only the flag below is observed.
    @ObservationIgnored private var models: [WeakBox<TextSelectionModel>] = []

    /// Whether any registered model has a selection. Changes only when a selection starts or ends.
    private(set) var hasActiveSelection = false

    func register(_ model: TextSelectionModel) {
      models.append(WeakBox(model))
      compact()
      selectionDidChange()
    }

    /// Forgets a model that moved to another coordinator, so its selection stops counting here.
    func unregister(_ model: TextSelectionModel) {
      models.removeAll { $0.wrapped == nil || $0.wrapped === model }
      selectionDidChange()
    }

    func modelDidSelectText(_ model: TextSelectionModel) {
      // Clear selection in the other models
      for weakModel in models where weakModel.wrapped !== model {
        weakModel.wrapped?.selectedRange = nil
      }
      compact()
    }

    /// Recomputes the observed flag after a registered model's selection changes or it is released.
    func selectionDidChange() {
      let active = models.contains { $0.wrapped?.selectedRange != nil }
      if active != hasActiveSelection { hasActiveSelection = active }
    }

    private func compact() {
      models.removeAll {
        $0.wrapped == nil
      }
    }
  }
#endif

struct TextSelectionCoordination: ViewModifier {
  #if TEXTUAL_ENABLE_TEXT_SELECTION
    @State private var coordinator = TextSelectionCoordinator()
  #endif

  func body(content: Content) -> some View {
    #if TEXTUAL_ENABLE_TEXT_SELECTION
      content.environment(coordinator)
    #else
      content
    #endif
  }
}
