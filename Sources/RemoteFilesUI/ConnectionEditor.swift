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
    /// No longer shown, but kept so saving an older connection doesn't change it.
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
    @State private var installWhenSaving = false
    @State private var installation: ConnectionKeySetup?
    @State private var advancedExpanded = false

    private struct ConnectionKeySetup: Identifiable {
        let profile: ConnectionProfile
        let identity: IdentityMetadata
        var id: UUID { profile.id }
    }
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
                TextField("Starting directory (optional)", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Server") } footer: {
                Text("Leave the directory blank to start in the account’s home folder, or enter a full path such as /srv/files.")
            }
            Section("SSH identity") {
                if model.metadata.identities.isEmpty {
                    Text("Generate a new key, or import one you already use.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker("Choose Existing Key", selection: $identityID) {
                        Text("Choose a key").tag(nil as UUID?)
                        ForEach(model.metadata.identities) { key in Text(key.name).tag(Optional(key.id)) }
                    }
                }
                NavigationLink("Generate or Import Key", destination: KeyManagerView(model: model))
                if !useJumpHost {
                    Toggle("Install Public Key When Saving", isOn: $installWhenSaving)
                    if installWhenSaving {
                        Text("You’ll enter the account’s password once to add the key to the server. The connection is saved after that.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    LabeledContent("SSH port") {
                        TextField("22", text: $port).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).frame(maxWidth: 80).accessibilityLabel("SSH port")
                    }
                    Toggle("Use Jump Host", isOn: $useJumpHost)
                    if useJumpHost {
                        TextField("Jump hostname or IP address", text: $jumpHost).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("Jump account username", text: $jumpUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                        LabeledContent("Jump SSH port") {
                            TextField("22", text: $jumpPort).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).frame(maxWidth: 80).accessibilityLabel("Jump SSH port")
                        }
                        Picker("Jump Host Identity", selection: $jumpIdentityID) {
                            Text("Choose a key").tag(nil as UUID?)
                            ForEach(model.metadata.identities) { key in Text(key.name).tag(Optional(key.id)) }
                        }
                        Text("Connects through another SSH server first. It must allow TCP forwarding and look up the hostname above.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if existing?.jumpHost != nil {
                            Button("Reset Trusted Jump Host Key", role: .destructive) { resetJumpTrust = true }
                        }
                    }
                    if existing != nil { Button("Reset Trusted Host Key", role: .destructive) { resetTrust = true } }
                }
            }
            Section {
                DisclosureGroup("Before you connect") {
                    Group {
                        Text("The account needs SSH access with SFTP. RemoteFiles signs in with a key and only reads files.")
                        Text(useJumpHost
                             ? "Add the key to each server from SSH Keys → Install Public Key on Server."
                             : "To set up the key, turn on Install Public Key When Saving, or add the public key to the account’s ~/.ssh/authorized_keys yourself.")
                        Text("Using Tailscale? Enter the server’s MagicDNS name or Tailscale IP address.")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(existing == nil ? "Add Connection" : "Edit Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let value = connection, valid else { return }
                    if installWhenSaving && !useJumpHost,
                       let identity = model.metadata.identities.first(where: { $0.id == value.identityID }) {
                        installation = ConnectionKeySetup(profile: value, identity: identity)
                    } else {
                        save(value)
                    }
                }.disabled(!valid || saving)
            }
        }
        .sheet(item: $installation) { setup in
            NavigationStack {
                PublicKeyInstallationView(model: model, identity: setup.identity, connection: setup.profile) {
                    installation = nil
                    save(setup.profile)
                }
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
                // Anything set here shouldn't be hidden from whoever is editing it.
                advancedExpanded = existing.port != 22 || existing.jumpHost != nil
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

    private func save(_ value: ConnectionProfile) {
        saving = true
        Task {
            await model.saveConnection(value)
            saving = false
            if model.errorMessage == nil { dismiss() }
        }
    }
}
#endif
