import Foundation
import Crypto

/// Coordinates belong to one exact document revision. Rendered and source layouts are independent.
public struct SavedReadingPosition: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
        fileprivate var isValid: Bool { x.isFinite && y.isFinite && x >= 0 && y >= 0 && x <= 100_000_000 && y <= 100_000_000 }
    }
    /// Content-free UTF-16 location, or a proportional position within a rendered block.
    public struct Anchor: Codable, Equatable, Sendable {
        public var kind: String
        public var ordinal: Int
        public var character: Int
        public var fraction: Double
        public var viewportY: Double
        public init(kind: String, ordinal: Int = 0, character: Int = 0, fraction: Double = 0, viewportY: Double = 0) {
            self.kind = kind; self.ordinal = ordinal; self.character = character
            self.fraction = fraction; self.viewportY = viewportY
        }
        fileprivate var isValid: Bool {
            ["prose", "image", "overflow", "source", "html-text", "html-block"].contains(kind) && ordinal >= 0 && ordinal <= 2_097_152 &&
            character >= 0 && character <= 2_097_152 && fraction.isFinite && (0...1).contains(fraction) &&
            viewportY.isFinite && abs(viewportY) <= 100_000
        }
    }
    public var renderedAnchor: Anchor?
    public var sourceAnchor: Anchor?
    public var revision: String
    public var rendered: Point
    public var source: Point
    public init(revision: String, rendered: Point = .init(), source: Point = .init(), renderedAnchor: Anchor? = nil, sourceAnchor: Anchor? = nil) {
        self.revision = revision; self.rendered = rendered; self.source = source
        self.renderedAnchor = renderedAnchor; self.sourceAnchor = sourceAnchor
    }
    public static func revision(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    fileprivate var isValid: Bool { revision.utf8.count == 64 && revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && rendered.isValid && source.isValid && (renderedAnchor?.isValid ?? true) && (sourceAnchor?.isValid ?? true) }
}

/// Ancillary reading history is kept separate from the connection library so corrupt history
/// cannot prevent launch or change the library's backwards-compatible format.
public actor ReadingPositionStore {
    private struct Record: Codable {
        var connectionID: UUID
        // Data preserves distinctions which Swift String's canonical Unicode equality merges.
        var pathBytes: Data
        var position: SavedReadingPosition
        var updatedAt: Date
    }
    private struct File: Codable { var version = 1; var records: [Record] }
    private let fileURL: URL
    private let capacity: Int
    private var records: [Record]
    private var deletedConnections: Set<UUID> = []

    public init(fileURL: URL, capacity: Int = 200) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        if let data = try? Data(contentsOf: fileURL), data.count <= 2 * 1024 * 1024,
           let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 {
            records = Array(file.records.filter { $0.position.isValid && !$0.pathBytes.isEmpty && $0.pathBytes.count <= 16_384 && $0.updatedAt.timeIntervalSince1970.isFinite }
                .sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, capacity)))
        } else { records = [] }
    }

    public func restore(connectionID: UUID, path: String, revision: String) -> SavedReadingPosition? {
        let bytes = Data(path.utf8)
        return records.first { $0.connectionID == connectionID && $0.pathBytes == bytes && $0.position.revision == revision }?.position
    }

    public func save(_ position: SavedReadingPosition, connectionID: UUID, path: String) throws {
        guard !deletedConnections.contains(connectionID), position.isValid else { return }
        let bytes = Data(path.utf8)
        guard !bytes.isEmpty, bytes.count <= 16_384 else { return }
        var candidate = records.filter { !($0.connectionID == connectionID && $0.pathBytes == bytes) }
        candidate.insert(Record(connectionID: connectionID, pathBytes: bytes, position: position, updatedAt: .now), at: 0)
        candidate = Array(candidate.prefix(capacity))
        try write(candidate)
        records = candidate
    }

    /// Ignore late debounced saves from a reader that was open when its connection was deleted.
    public func remove(connectionID: UUID) throws {
        deletedConnections.insert(connectionID)
        let candidate = records.filter { $0.connectionID != connectionID }
        try write(candidate)
        records = candidate
    }

    private func write(_ candidate: [Record]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(File(records: candidate))
        #if os(iOS)
        try bytes.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: fileURL, options: .atomic)
        #endif
    }
}
