#if os(iOS)
import SwiftUI
import RemoteFilesCore

/// Above a document whose text is displayed in a different order from the one it is stored in,
/// because of characters that show nothing themselves. The text is shown as it is; this says so.
struct DirectionCharacterNotice: View {
    let text: String
    @State private var count = 0

    var body: some View {
        // One container whichever way it goes, so the count's task belongs to a view that is always there.
        VStack(spacing: 0) {
            if count > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Label(count == 1 ? "A Hidden Character Reorders Text" : "\(count) Hidden Characters Reorder Text",
                          systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text("Part of this file is displayed in a different order from the one it is stored in. A line, especially of code, may not say what it appears to.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("direction-character-notice")
            }
        }
        // Up to 2 MiB of text: counted off the main actor, once for each text.
        .task(id: text) {
            let text = text
            count = await Task.detached { TextDirectionOverrides.count(in: text) }.value
        }
    }
}
#endif
