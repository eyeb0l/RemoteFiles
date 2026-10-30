#!/usr/bin/env swift
// Run from the repository root: swift Fixtures/generate-search-fixtures.swift
// All content is synthetic. These small fixtures exercise real PDFKit and Vision paths.
import Foundation
import CoreGraphics
import CoreText
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Sources/RemoteFilesCore/Resources", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(_ text: String, in context: CGContext, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ]
    context.textPosition = CGPoint(x: 40, y: 150)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
}

func raster() -> CGImage {
    let context = CGContext(data: nil, width: 1400, height: 600, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1400, height: 600))
    draw("SEARCHABLE INVOICE", in: context, size: 64)
    return context.makeImage()!
}

func pdf(scanned: Bool, image: CGImage) -> Data {
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data)!
    var box = CGRect(x: 0, y: 0, width: 700, height: 300)
    let context = CGContext(consumer: consumer, mediaBox: &box, [
        kCGPDFContextTitle: "RemoteFiles synthetic search sample",
        kCGPDFContextCreator: "Fixtures/generate-search-fixtures.swift"
    ] as CFDictionary)!
    if !scanned {
        context.beginPDFPage(nil)
        draw("RemoteFiles sample cover", in: context, size: 32)
        context.endPDFPage()
    }
    context.beginPDFPage(nil)
    if scanned { context.draw(image, in: box) }
    else { draw("SEARCHABLE INVOICE", in: context, size: 32) }
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

func write(_ data: Data, named name: String) throws {
    precondition(data.count < 2 * 1_024 * 1_024, "Search samples must fit the bounded read limit")
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
    print("Generated \(name): \(data.count) bytes")
}

let image = raster()
let png = NSMutableData()
let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
try write(png as Data, named: "search-image.png")
try write(pdf(scanned: false, image: image), named: "search-sample.pdf")
try write(pdf(scanned: true, image: image), named: "search-scan.pdf")
