#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(UIKit)
  import SwiftUI

  // MARK: - Overview
  //
  // `UIKitTextInteractionOverlay` bridges the shared `TextSelectionModel` into a `UIView`.
  //
  // The overlay reads exclusion rectangles for hit-testing. This allows embedded scrollable regions (like
  // code blocks) to receive touch events while the parent handles text selection. The view hosts
  // a `UITextInteraction` configured for selection and implements the `UITextInput` surface that
  // UIKit uses for selection behavior.

  struct UIKitTextInteractionOverlay: UIViewRepresentable {
    private let model: TextSelectionModel
    private let layoutCollection: any TextLayoutCollection
    private let coordinator: TextSelectionCoordinator?
    private let overflowFrames: [CGRect]

    init(model: TextSelectionModel, layoutCollection: any TextLayoutCollection,
         coordinator: TextSelectionCoordinator?, overflowFrames: [CGRect]) {
      self.model = model
      self.layoutCollection = layoutCollection
      self.coordinator = coordinator
      self.overflowFrames = overflowFrames
    }

    func makeUIView(context: Context) -> UITextInteractionView {
      updateModel()
      return UITextInteractionView(
        model: model,
        exclusionRects: overflowFrames,
        openURL: context.environment.openURL
      )
    }

    func updateUIView(_ uiView: UITextInteractionView, context: Context) {
      updateModel()
      uiView.model = model
      uiView.exclusionRects = overflowFrames
      uiView.openURL = context.environment.openURL
    }

    private func updateModel() {
      // Keep hit testing and selection reconciliation in the model, but hand it the
      // current resolved collection whenever SwiftUI updates this native overlay.
      model.setCoordinator(coordinator)
      model.setLayoutCollection(layoutCollection)
    }
  }
#endif
