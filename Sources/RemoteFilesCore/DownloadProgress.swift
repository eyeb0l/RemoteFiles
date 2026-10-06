import Foundation

/// Bytes successfully written locally, with the server's size when it is available.
public struct DownloadProgress: Equatable, Sendable {
    public let receivedBytes: UInt64
    public let totalBytes: UInt64?
    public let isComplete: Bool
    public init(receivedBytes: UInt64 = 0, totalBytes: UInt64? = nil, isComplete: Bool = false) {
        self.receivedBytes = receivedBytes
        // A growing file can outstrip its initial stat; don't display a misleading total.
        self.totalBytes = totalBytes.flatMap { $0 >= receivedBytes ? $0 : nil }
        self.isComplete = isComplete
    }
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return isComplete ? 1 : nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
    public func sizeLabel(locale: Locale = .current) -> String {
        let largest = max(receivedBytes, totalBytes ?? 0)
        let units: [(UInt64, String)] = [(1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB")]
        let unit = units.first { largest >= $0.0 } ?? (1, "bytes")
        func size(_ bytes: UInt64) -> String {
            let digits = unit.0 == 1 ? 0 : 1
            return (Double(bytes) / Double(unit.0)).formatted(.number.locale(locale).precision(.fractionLength(digits))) + " " + unit.1
        }
        if let totalBytes { return size(receivedBytes) + " / " + size(totalBytes) }
        return size(receivedBytes) + " downloaded"
    }
}

public typealias DownloadProgressHandler = @Sendable (DownloadProgress) async -> Void
