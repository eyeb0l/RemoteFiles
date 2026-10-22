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
    @State private var useJumpHost = false
    @State private var jumpHost = ""
    @State private var jumpPort = "22"
    @State private var jumpUsername = ""
    @State private var jumpIdentityID: UUID?
    @State private var resetJumpTrust = false
    private var connection: ConnectionProfile? {
        guard let identityID, let targetPort = Int(port) else { return nil }
        let hop: JumpHost?
        if useJumpHost {
            guard let jumpIdentityID, let hopPort = Int(jumpPort) else { return nil }
            hop = JumpHost(host: jumpHost.trimmingCharacters(in: .whitespacesAndNewlines), port: hopPort,
                           username: jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines), identityID: jumpIdentityID)
        } else { hop = nil }
        return ConnectionProfile(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: targetPort,
                                 username: username.trimmingCharacters(in: .whitespacesAndNewlines), identityID: identityID,
                                 startingDirectory: directory, usesTailscale: tailscale, jumpHost: hop)
    }
    private var valid: Bool {
        guard let connection else { return false }
        return !connection.name.isEmpty && connection.hasValidSSHEndpoints
    }
    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $name).textContentType(.nickname)
                TextField("Hostname or IP address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Account username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Server") } footer: { Text("Connect to a Unix system over SFTP. Browsing and previews are read only.") }
            Section("SSH identity") {
                if model.metadata.identities.isEmpty {
                    Text("Generate a dedicated key or import an OpenSSH Ed25519, RSA or ECDSA private key.").foregroundStyle(.secondary)
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
                Toggle("Show Tailscale Setup Tips", isOn: $tailscale)
            } footer: {
                Text("Leave blank to use the server’s default directory, or enter an absolute path. Paths starting with ~ are not expanded. Tailscale tips do not change how the app connects.")
            }
            Section {
                Toggle("Use Jump Host", isOn: $useJumpHost)
                if useJumpHost {
                    TextField("Jump hostname or IP address", text: $jumpHost).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Jump account username", text: $jumpUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("Jump SSH port") {
                        TextField("22", text: $jumpPort).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).accessibilityLabel("Jump SSH port")
                    }
                    Picker("Jump Host Identity", selection: $jumpIdentityID) {
                        Text("Choose a key").tag(nil as UUID?)
                        ForEach(model.metadata.identities) { key in Text(key.name).tag(Optional(key.id)) }
                    }
                    if existing?.jumpHost != nil {
                        Button("Reset Trusted Jump Host Key", role: .destructive) { resetJumpTrust = true }
                    }
                }
            } header: { Text("Jump host") } footer: {
                Text("Connect through one SSH server to reach the destination. The jump host must allow TCP forwarding. Each server’s fingerprint is verified separately; private keys stay on this device. The destination hostname is resolved from the jump host.")
            }
            Section("Advanced") {
                LabeledContent("Destination SSH port") {
                    TextField("22", text: $port).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing).accessibilityLabel("SSH port")
                }
                if existing != nil { Button("Reset Trusted Host Key", role: .destructive) { resetTrust = true } }
            }
            Section("Before you connect") {
                Text("The server must be reachable, with SSH and SFTP enabled for this account. Add the identity’s public key to the account’s ~/.ssh/authorized_keys file.")
                if tailscale {
                    Text("Enable Tailscale on both devices and use the server’s MagicDNS name or Tailscale IP. Your tailnet must permit the SSH connection. Tailscale SSH is not required.")
                }
                Text("To install a public key using password login, open the identity in SSH Keys and choose Install Public Key on Server. The app does not configure server services. Verify its fingerprint when connecting for the first time.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(existing == nil ? "Add Connection" : "Edit Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let value = connection, valid else { return }
                    saving = true
                    Task {
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
                if let jump = existing.jumpHost {
                    useJumpHost = true; jumpHost = jump.host; jumpPort = String(jump.port)
                    jumpUsername = jump.username; jumpIdentityID = jump.identityID
                }
                port = String(existing.port); directory = existing.startingDirectory; tailscale = existing.usesTailscale; identityID = existing.identityID
            }
            if identityID == nil { identityID = model.metadata.identities.first?.id }
            if jumpIdentityID == nil { jumpIdentityID = identityID }
        }
        .confirmationDialog("Forget this jump host’s trusted key?", isPresented: $resetJumpTrust, titleVisibility: .visible) {
            Button("Reset Jump Host Trust", role: .destructive) {
                guard let existing else { return }
                Task { await model.resetJumpHostTrust(for: existing) }
            }
        } message: {
            if let jump = existing?.jumpHost {
                Text("The next connection through \(jump.host):\(String(jump.port)) will require you to verify the jump host fingerprint again.")
            }
        }

        .confirmationDialog("Forget this host’s trusted key?", isPresented: $resetTrust, titleVisibility: .visible) {
            Button("Reset Host Trust", role: .destructive) {
                guard let existing else { return }
                Task { await model.resetTrust(for: existing) }
            }
        } message: {
            if let existing {
                Text("The next connection to \(existing.host):\(String(existing.port)) will require you to verify the server fingerprint again.")
            }
        }
    }
}
#endif
