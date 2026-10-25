import Foundation

public enum OfflineDocumentLinkError: LocalizedError, Sendable {
    case sourceChanged, outsideFolder, notSaved

    public var errorDescription: String? {
        switch self {
        case .sourceChanged:
            return "This saved document was updated or removed. Reopen it from Offline Files before following its links."
        case .outsideFolder:
            return "This link leaves the saved folder. Open another saved copy from Offline Files."
        case .notSaved:
            return "This linked file isn’t saved here. Save it with the same connection, or include it in this saved folder, then try again."
        }
    }
}
