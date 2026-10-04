import SwiftUI
import UIKit
import RemoteFilesCore
import RemoteFilesUI
private actor FixtureImageResolver: RemoteResourceResolving {
 let file: URL
 init(_ file: URL) { self.file=file }
 func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL { file }
}
private struct FixtureView: View {
 @State private var source=false
 @State private var position=DocumentReadingPosition()
 let text: String
 let resolver: FixtureImageResolver
 let location: RemoteDocumentLocation
 init() {
  let tall = ProcessInfo.processInfo.arguments.contains("--tall-image")
  let size=CGSize(width:600,height:tall ? 1600 : 300)
  let renderer=UIGraphicsImageRenderer(size:size)
  let bytes=renderer.pngData { c in UIColor.systemPurple.setFill(); c.fill(CGRect(origin:.zero,size:size)) }
  let file=FileManager.default.temporaryDirectory.appendingPathComponent("reading-anchor-fixture.png")
  try! bytes.write(to:file);resolver=FixtureImageResolver(file)
  let tail=String(repeating:"After the image, selectable report prose. ",count:1700)+"\n\n```swift\nlet overflow = String(repeating: \"wide\", count: 200)\n```\n\n| Heading | Value |\n| --- | --- |\n| Ready | Cell |\n"
  let preceding = ProcessInfo.processInfo.arguments.contains("--preceding-overflow") ? (0..<4).map { i in "\n\n```text\n"+(0..<24).map { "before_image_\(i)_\($0) "+String(repeating:"wide_",count:40) }.joined(separator:"\n")+"\n```\n\n" }.joined() : ""
  text="# Image anchor fixture\n\n"+String(repeating:"Before the image, readable selectable prose. ",count:6)+preceding+"\n\n![Owned rectangle](anchor.png)\n\n"+tail
  precondition(text.utf8.count>65536)
  let profile=ConnectionProfile(name:"Owned image fixture",host:"fixture.invalid",username:"fixture",identityID:UUID(),startingDirectory:"/Fixture")
  location = .init(profile:profile,path:"/Fixture/image-report.md")
 }
 var body: some View { NavigationStack { VStack {
  Picker("Reading mode",selection:$source) { Text("Rendered").tag(false);Text("Source").tag(true) }.pickerStyle(.segmented)
  DocumentContentView(text:text,markdown:true,source:source,location:location,resolver:resolver,readingPosition:position)
 }.navigationTitle("Image anchor fixture") } }
}
@main struct RemoteFilesApp: App { var body:some Scene { WindowGroup { FixtureView() } } }
