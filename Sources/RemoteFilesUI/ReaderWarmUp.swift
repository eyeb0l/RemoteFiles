#if os(iOS)
import SwiftUI
import Textual
import RemoteFilesCore
import os

/// Moves the reader's one-time Swift runtime type and conformance lookups off the main actor.
///
/// SwiftUI resolves each view's body type and checks its conformances the first time it is
/// displayed. The runtime caches the results process-wide, so resolving the same types earlier
/// on a background thread leaves cache hits for the first reader layout. No view is created,
/// no body is evaluated, and nothing is read from disk or the network. Loading another image
/// with Swift conformances clears the runtime cache, so folders request warm-up each time they
/// appear; a repeated run is cheap and an in-flight run is shared.
enum ReaderWarmUp {
    struct Outcome: Equatable, Sendable {
        /// View and modifier types prepared, including Textual's renderer types.
        var preparedTypes: Int
        var completed: Bool
        var ranOnMainThread: Bool
    }

    private static let current = OSAllocatedUnfairLock<Task<Outcome, Never>?>(initialState: nil)

    /// Starts warm-up at utility priority unless a run is already in flight.
    @discardableResult
    static func start() -> Task<Outcome, Never> {
        current.withLock { task in
            if let task { return task }
            let started = Task.detached(priority: .utility) {
                let outcome = perform(shouldContinue: { !Task.isCancelled })
                current.withLock { $0 = nil }
                return outcome
            }
            task = started
            return started
        }
    }

    /// Cancels an in-flight run between types; completed lookups stay cached.
    static func cancel() {
        current.withLock { $0?.cancel() }
    }

    nonisolated static func perform(shouldContinue: () -> Bool) -> Outcome {
        var prepared = 0
        var outcome: Outcome { .init(preparedTypes: prepared, completed: false, ranOnMainThread: Thread.isMainThread) }
        for type in viewTypes {
            guard shouldContinue() else { return outcome }
            _ = isView(type); _ = isView(bodyType(type)); prepared += 1
        }
        for type in modifierTypes {
            guard shouldContinue() else { return outcome }
            _ = isViewModifier(type); _ = isView(bodyType(type)); prepared += 1
        }
        guard shouldContinue() else { return outcome }
        for type in storedPropertyTypes { _ = isDynamicProperty(type) }
        let textual = StructuredText.prepareRendering(shouldContinue: shouldContinue)
        prepared += textual
        return .init(preparedTypes: prepared, completed: shouldContinue(), ranOnMainThread: Thread.isMainThread)
    }

    // Body types of these views contain the reader chrome, document switch and source views;
    // their generic wrappers' conditional conformances check every nested type. Home is
    // included because opening a document adds its Recents section.
    private static var viewTypes: [any View.Type] {
        [ReaderView.self, DocumentContentView.self, SourceCodeView.self, RemoteInlineImage.self,
         ReaderFindBar.self, ReaderHeadingsView.self, HomeView.self]
    }
    /// Stored property types of the reader views, which SwiftUI checks for `DynamicProperty`.
    private static var storedPropertyTypes: [Any.Type] {
        [RemoteEntry.self, ConnectionProfile.self, RemoteOriginalExporter.self, PreparedOriginalFile?.self,
         RemoteDocumentLocation.self, RemoteDocumentLocation?.self, (any RemoteResourceResolving).self,
         (any RemoteResourceResolving)?.self, DocumentReadingPosition?.self, ReaderNavigationState?.self,
         ((URL) -> Void)?.self, ((UUID) -> Void)?.self, ((any Error) -> Bool).self,
         String?.self, Bool?.self, UUID?.self, CGPoint?.self]
    }
    private static var modifierTypes: [any ViewModifier.Type] {
        [DocumentScrollPreservation.self, OriginalFileExportControl.self]
    }

    // Opened through existentials so lookups use the runtime, not specialized static metadata.
    @inline(never) private static func bodyType<V: View>(_: V.Type) -> Any.Type { V.Body.self }
    @inline(never) private static func bodyType<M: ViewModifier>(_: M.Type) -> Any.Type { M.Body.self }
    @inline(never) private static func isView(_ type: Any.Type) -> Bool { type is any View.Type }
    @inline(never) private static func isDynamicProperty(_ type: Any.Type) -> Bool { type is any DynamicProperty.Type }
    @inline(never) private static func isViewModifier(_ type: Any.Type) -> Bool { type is any ViewModifier.Type }
}
#endif
