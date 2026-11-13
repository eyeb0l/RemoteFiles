#if os(iOS)
import SwiftUI
import RemoteFilesCore

/// App-wide settings, kept apart from the library so Home shows only places to browse.
struct SettingsView: View {
    let model: AppModel
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
    var body: some View {
        Form {
            if !model.demo {
                Section {
                    NavigationLink { KeyManagerView(model: model) } label: { Label("SSH Keys", systemImage: "key") }
                } footer: {
                    Text("Keys this device uses to sign in to your servers.")
                }
            }
            Section {
                Button(model.demo ? "Leave Demo" : "Explore Demo", systemImage: "sparkles") {
                    // Close Settings so the library that was switched to is what's shown.
                    Task { await model.setDemo(!model.demo); model.sheet = nil }
                }
            } footer: {
                Text(model.demo ? "Return to your own connections." : "Try RemoteFiles with sample files, without connecting to a server.")
            }
            Section("About") {
                LabeledContent("Version", value: version)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.sheet = nil } } }
    }
}
#endif
