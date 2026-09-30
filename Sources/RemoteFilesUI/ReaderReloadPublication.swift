#if os(iOS)
import Foundation

/// Keeps cache clearing and publication under the same request validity checks.
@MainActor enum ReaderReloadPublication {
    static func perform(
        clearImages: Bool,
        isCurrent: () -> Bool,
        clearResources: @MainActor () async -> Void,
        clearDecoded: @MainActor () async -> Void,
        publish: @MainActor () async -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard isCurrent() else { return false }
        if clearImages {
            await clearResources()
            try Task.checkCancellation()
            guard isCurrent() else { return false }
            await clearDecoded()
        }
        try Task.checkCancellation()
        guard isCurrent() else { return false }
        await publish()
        return true
    }
}
#endif
