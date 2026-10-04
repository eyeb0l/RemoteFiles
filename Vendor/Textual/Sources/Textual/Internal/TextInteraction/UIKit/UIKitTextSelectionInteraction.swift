#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(UIKit)
  import SwiftUI

  // MARK: - Overview
  //
  // `UIKitTextSelectionInteraction` presents the platform-specific text selection overlay for iOS.
  //
  // The modifier receives a `TextSelectionModel` from `TextSelectionInteraction` and overlays
  // `UIKitTextInteractionOverlay`, which wraps a `UIView` that handles selection gestures and
  // integrates with system edit actions (copy/share). SwiftUI continues to render the text while
  // UIKit manages the selection interaction.

  typealias PlatformTextSelectionInteraction = UIKitTextSelectionInteraction

  struct UIKitTextSelectionInteraction: ViewModifier {
    private let model: TextSelectionModel
    private let coordinator: TextSelectionCoordinator?
    @State private var overflowFrames: [CGRect] = []

    init(model: TextSelectionModel, coordinator: TextSelectionCoordinator?) {
      self.model = model
      self.coordinator = coordinator
    }

    func body(content: Content) -> some View {
      content
        .onPreferenceChange(OverflowFrameKey.self) { @MainActor frames in
          overflowFrames = frames
        }
        .overlayTextLayoutCollection { layoutCollection in
          UIKitTextInteractionOverlay(model: model, layoutCollection: layoutCollection,
                                      coordinator: coordinator, overflowFrames: overflowFrames)
            .accessibilityHidden(true)
        }
    }
  }
#endif
