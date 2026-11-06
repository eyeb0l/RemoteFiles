#if os(iOS)
import SwiftUI

/// Shown instead of a file that holds nothing but private keys, which has no text to read.
struct PrivateKeyFileView: View {
    let filename: String
    let saveAction: String
    var body: some View {
        ContentUnavailableView {
            Label("Contains a Private Key", systemImage: "key.fill")
        } description: {
            Text("\(filename) is a private key. RemoteFiles doesn’t display, copy or search private keys. \(saveAction) copies the whole file, including the key.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Above a document whose keys are hidden, so that the dots, and what Copy Source copies, explain themselves.
struct HiddenPrivateKeyNotice: View {
    let count: Int
    let saveAction: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(count == 1 ? "A Private Key Is Hidden" : "\(count) Private Keys Are Hidden", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text("Find, Copy Source and search skip \(count == 1 ? "it" : "them"). \(saveAction) copies the whole file, including anything secret in it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hidden-private-key-notice")
    }
}
#endif
