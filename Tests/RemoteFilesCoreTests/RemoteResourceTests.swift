import Foundation
import XCTest
import ImageIO
import CoreGraphics
import zlib
@testable import RemoteFilesCore

final class RemoteResourceTests: XCTestCase {
    private var location: RemoteDocumentLocation {
        .init(profile: .init(name: "Test", host: "mac", username: "reader", identityID: UUID()),
              path: "/Users/iris/wardrobe/data/ui-audit-2026-09-21/audit.md")
    }
    func testDecoderDownsamplesLargeDimensionsAndRejectsCorruptData() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 4096, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let source = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try await RemoteImageDecoder.shared.decode(file, maxPixel: 400)
        XCTAssertEqual(decoded.image.width, 400)
        XCTAssertEqual(decoded.image.height, 100)
        XCTAssertLessThanOrEqual(decoded.cost, 200_000)
        try Data("not an image".utf8).write(to: file)
        await RemoteImageDecoder.shared.clear()
        do { _ = try await RemoteImageDecoder.shared.decode(file, maxPixel: 400); XCTFail() }
        catch RemoteResourceError.notImage { }
    }

    /// Valid RGB PNG with uncompressed DEFLATE rows. The fixture has actual image
    /// bytes over 70 MB rather than padding, and generation retains only one row.
    private func largePNG(at file: URL) throws {
        let width = 7000, height = 3500
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        func bytes(_ value: UInt32) -> Data {
            var bigEndian = value.bigEndian
            return withUnsafeBytes(of: &bigEndian) { Data($0) }
        }
        func chunk(_ type: String, _ payload: Data) throws {
            let kind = Data(type.utf8)
            var checksum = kind.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(kind.count)) }
            if !payload.isEmpty {
                checksum = payload.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count)) }
            }
            var framed = bytes(UInt32(payload.count))
            framed.append(kind); framed.append(payload); framed.append(bytes(UInt32(checksum)))
            try handle.write(contentsOf: framed)
        }
        try handle.write(contentsOf: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        var header = bytes(UInt32(width)); header.append(bytes(UInt32(height)))
        header.append(contentsOf: [8, 2, 0, 0, 0])
        try chunk("IHDR", header)
        try chunk("IDAT", Data([0x78, 0x01])) // zlib header, no compression.
        var row = Data([0]) // PNG filter: none.
        for _ in 0..<width { row.append(contentsOf: [42, 125, 190]) }
        let length = UInt16(row.count)
        var checksum = adler32(0, nil, 0)
        for index in 0..<height {
            checksum = row.withUnsafeBytes { adler32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(row.count)) }
            var block = Data([index == height - 1 ? 1 : 0,
                              UInt8(truncatingIfNeeded: length), UInt8(truncatingIfNeeded: length >> 8),
                              UInt8(truncatingIfNeeded: ~length), UInt8(truncatingIfNeeded: ~length >> 8)])
            block.append(row)
            try chunk("IDAT", block)
        }
        try chunk("IDAT", bytes(UInt32(checksum)))
        try chunk("IEND", Data())
    }

    func testSeventyMegabyteImageUsesBoundedDisplayPixels() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try largePNG(at: file)
        let bytes = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(bytes, 70_000_000)
        let decoder = RemoteImageDecoder()
        let inline = try await decoder.decode(file, maxPixel: 1600)
        XCTAssertEqual(inline.image.width, 1600)
        XCTAssertEqual(inline.image.height, 800)
        XCTAssertLessThanOrEqual(inline.cost, 6 * 1024 * 1024)
        let viewer = try await decoder.decode(file, maxPixel: 3072)
        XCTAssertEqual(viewer.image.width, 3072)
        XCTAssertEqual(viewer.image.height, 1536)
        XCTAssertLessThanOrEqual(viewer.cost, 20 * 1024 * 1024)
        print("Large image: sourceBytes=\(bytes), inlineDecodedBytes=\(inline.cost), viewerDecodedBytes=\(viewer.cost), platform=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func testRelativePathsAndBoundary() throws {
        let doc = location, root = doc.resourceRoot
        for value in ["01-wardrobe-before.png", "./01-wardrobe-before.png", "images/../01-wardrobe-before.png", root + "/01-wardrobe-before.png"] {
            XCTAssertEqual(try RemoteResourcePath.resolve(value, relativeTo: doc), root + "/01-wardrobe-before.png")
        }
        XCTAssertEqual(try RemoteResourcePath.resolve("images/caf%C3%A9%20one.png", relativeTo: doc), root + "/images/café one.png")
        for value in ["../../secret.png", "../secret.png", "%2e%2e/secret.png", "images/../../secret.png", "/etc/a.png", "//host/a.png", "https://host/a.png", "file:///a", "data:image/png,a", "a.png?q=1", "a.png#x", "%00.png", "%2Fetc/a", "a%5Cb.png"] {
            XCTAssertThrowsError(try RemoteResourcePath.resolve(value, relativeTo: doc), value)
        }
        XCTAssertFalse(RemoteResourcePath.contains(root + "-other/a.png", in: root))
    }
    func testParsedImagesPreserveOrderAndKeepURLsOutOfTextual() throws {
        let parts = try DocumentPolicy.remoteMarkdownParts("# Heading\n\n![one](./foo.png)\n\nAfter **bold** ![two](images/bar.png) end.\n\n[unsafe](file:///secret)")
        let references = parts.compactMap { part -> String? in if case .image(let ref, _) = part.content { return ref }; return nil }
        XCTAssertEqual(references, ["./foo.png", "images/bar.png"])
        for part in parts {
            if case .text(let value) = part.content {
                XCTAssertFalse(value.runs.contains { $0.imageURL != nil || $0.link != nil })
            }
        }
    }
    func testDedupAndIndependentCancellationAndDiskHit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ImageTransportMock()
        let resolver = RemoteResourceResolver(service: service, directory: dir)
        let doc = location
        let first = Task { try await resolver.localFile(for: "a.png", in: doc) }
        let second = Task { try await resolver.localFile(for: "./a.png", in: doc) }
        try await Task.sleep(for: .milliseconds(50)); first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled subscriber must leave promptly") } catch is CancellationError { }
        let file = try await second.value
        XCTAssertEqual(try Data(contentsOf: file), Data("image bytes".utf8))
        _ = try await resolver.localFile(for: "a.png", in: doc)
        let count = await service.downloads
        XCTAssertEqual(count, 1)
        let listed = await service.listings
        XCTAssertEqual(listed, 0, "Image resolution must not download/list sibling directories")
    }
    func testLastWaiterCancelsTransferAndCanRetry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ImageTransportMock()
        let resolver = RemoteResourceResolver(service: service, directory: dir)
        let doc = location
        let task = Task { try await resolver.localFile(for: "a.png", in: doc) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError { }
        _ = try await resolver.localFile(for: "a.png", in: doc)
        let count = await service.downloads
        XCTAssertEqual(count, 2)
    }
    func testDiskBudgetAndProfileIsolation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ImageTransportMock()
        let resolver = RemoteResourceResolver(service: service, directory: dir, diskLimit: 15)
        let doc = location
        _ = try await resolver.localFile(for: "a.png", in: doc)
        _ = try await resolver.localFile(for: "b.png", in: doc)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "resource" }
        XCTAssertEqual(files.count, 1)
        _ = try await resolver.localFile(for: "b.png", in: location)
        let count = await service.downloads
        XCTAssertEqual(count, 3, "Different connection identities must never share cached bytes")
    }
}
private actor ImageTransportMock: RemoteFileService {
    var downloads = 0
    var listings = 0
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        downloads += 1
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        try Data("image bytes".utf8).write(to: destination)
        return .init(name: "a.png", path: path, kind: .file, size: 11)
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { listings += 1; throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}
