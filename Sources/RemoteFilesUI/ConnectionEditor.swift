#if os(iOS)
import SwiftUI
import RemoteFilesCore

struct ConnectionEditor: View {
    @Bindable var model: AppModel
    let existing: ConnectionProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var directory = ""
    @State private var tailscale = false
    @State private var identityID: UUID?
    @State private var resetTrust = false
    @State private var saving = false
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.contains(where: \.isWhitespace) && !host.contains("/") &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...65535).contains(Int(port) ?? 0) && identityID != nil
    }
    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $name).textContentType(.nickname)
                TextField("Hostname or IP address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Mac account username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Your Mac") } footer: { Text("Connect using macOS Remote Login (SFTP). All remote operations are read only.") }
            Section("SSH identity") {
                if model.metadata.identities.isEmpty {
                    Text("Generate a dedicated key or import an OpenSSH Ed25519 private key.").foregroundStyle(.secondary)
                } else {
                    Picker("Choose Existing Key", selection: $identityID) {
                        Text("Choose a key").tag(nil as UUID?)
                        ForEach(model.metadata.identities) { key in Text(key.name).tag(Optional(key.id)) }
                    }
                }
                NavigationLink("Generate or Import Key", destination: KeyManagerView(model: model))
            }
            Section {
                TextField("Starting directory (optional)", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Connect through Tailscale", isOn: $tailscale)
            } footer: {
                Text("Leave the directory blank for the server’s home directory. Use an absolute path for a project folder; tilde expansion is not assumed.")
            }
            Section("Advanced") {
                TextField("SSH port", text: $port).keyboardType(.numberPad)
                if existing != nil { Button("Reset Trusted Host Key", role: .destructive) { resetTrust = true } }
            }
            Section("Before you connect") {
                Text("Your Mac must be awake and reachable, with Remote Login enabled for this account. Add the identity’s public key to that account’s authorized_keys file.")
                if tailscale {
                    Text("Enable Tailscale on both devices and use the Mac’s MagicDNS name or Tailscale IP. Your tailnet must permit the SSH connection. Tailscale SSH is not required.")
                }
                Text("The app does not change your Mac’s settings or install keys. Verify the server fingerprint when connecting for the first time.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(existing == nil ? "Add Connection" : "Edit Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let identityID else { return }
                    saving = true
                    Task {
                        let value = ConnectionProfile(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 22, username: username.trimmingCharacters(in: .whitespacesAndNewlines), identityID: identityID, startingDirectory: directory, usesTailscale: tailscale)
                        await model.saveConnection(value)
                        saving = false
                        if model.errorMessage == nil { dismiss() }
                    }
                }.disabled(!valid || saving)
            }
        }
        .onAppear {
            if name.isEmpty, let existing {
                name = existing.name; host = existing.host; username = existing.username
                port = String(existing.port); directory = existing.startingDirectory; tailscale = existing.usesTailscale; identityID = existing.identityID
            }
            if identityID == nil { identityID = model.metadata.identities.first?.id }
        }
        .confirmationDialog("Forget this host’s trusted key?", isPresented: $resetTrust, titleVisibility: .visible) {
            Button("Reset Host Trust", role: .destructive) {
                Task {
                    do {
                        await model.disconnect()
                        try await model.trust.reset(endpoint: HostEndpoint(host: host, port: Int(port) ?? 22))
                    } catch { model.errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("The next connection will require you to verify the server fingerprint again.") }
    }
}
#endif
