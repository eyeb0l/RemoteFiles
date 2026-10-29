#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LocalAuthentication
import RemoteFilesCore

struct KeyManagerView: View {
    let model: AppModel
    @State private var creation: KeyCreationMode?
    @State private var createdIdentity: IdentityMetadata?
    @State private var selectedIdentity: IdentityMetadata?

    var body: some View {
        List {
            Section {
                Button { creation = .generate } label: { Label("Generate Key", systemImage: "key.fill") }.disabled(model.demo)
                Button { creation = .importKey } label: { Label("Import Key", systemImage: "square.and.arrow.down") }.disabled(model.demo)
            } footer: {
                Text(model.demo ? "Leave Demo to create or import an SSH identity." : "Create a dedicated identity for RemoteFiles, or import an existing OpenSSH Ed25519, RSA or ECDSA private key.")
            }
            Section("Saved identities") {
                if model.metadata.identities.isEmpty {
                    ContentUnavailableView("No SSH identities", systemImage: "key", description: Text("Generate a key to get started."))
                }
                ForEach(model.metadata.identities) { identity in
                    NavigationLink {
                        IdentityDetailsView(model: model, identity: identity)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(identity.name).font(.headline)
                            Text("\(identity.algorithmName) · \(identity.requiresPassphrase ? "Passphrase protected" : "Device Keychain")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            if case .keys = model.sheet {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { model.sheet = nil } }
            }
        }
        .sheet(item: $creation, onDismiss: {
            if let createdIdentity { selectedIdentity = createdIdentity; self.createdIdentity = nil }
        }) { mode in
            NavigationStack { KeyCreationView(model: model, mode: mode) { createdIdentity = $0 } }
        }
        .navigationDestination(item: $selectedIdentity) { IdentityDetailsView(model: model, identity: $0) }
    }
}

private struct IdentityDetailsView: View {
    let model: AppModel
    let identity: IdentityMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var confirmDeletion = false
    @State private var showInstallation = false
    @State private var showExport = false
    @State private var biometricUnlock = false
    @State private var biometricMessage: String?
    private var connections: [ConnectionProfile] { model.metadata.connections.filter { $0.identityIDs.contains(identity.id) } }
    private var biometryName: String { BiometricUnlock.name ?? "Face ID" }

    var body: some View {
        Form {
            Section {
                LabeledContent("Algorithm", value: identity.algorithmName)
                FingerprintView(value: identity.fingerprint)
                PublicKeyText(value: identity.publicKey)
                Button {
                    UIPasteboard.general.string = identity.publicKey
                    copied = true
                } label: { Label(copied ? "Public Key Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: identity.publicKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
                Button("Install Public Key on Server", systemImage: "server.rack") { showInstallation = true }.disabled(model.demo)
            } header: { Text("Public identity") } footer: {
                Text("Add this public key to the server account's ~/.ssh/authorized_keys file. The private key remains in this device's Keychain.")
            }
            if identity.requiresPassphrase, biometricUnlock || BiometricUnlock.name != nil {
                Section {
                    LabeledContent("\(biometryName) Unlock", value: biometricUnlock ? "On" : "Off")
                    if biometricUnlock {
                        Button("Turn Off \(biometryName) Unlock", role: .destructive) { turnOffBiometricUnlock() }
                    }
                    if let biometricMessage { Text(biometricMessage).foregroundStyle(.red) }
                } header: { Text("Unlock") } footer: {
                    Text(biometricUnlock
                         ? "An unlocked copy of this key is kept in this device's Keychain, readable only with \(biometryName) as enrolled when it was turned on. Turning it off deletes that copy; the passphrase still unlocks the key."
                         : "To turn it on, unlock this key with its passphrase when connecting and choose “Use \(biometryName) next time”.")
                }
            }
            if !connections.isEmpty {
                Section {
                    ForEach(connections) { connection in Text(connection.name) }
                } header: { Text("Used by") } footer: {
                    Text("Choose another identity for these connections before deleting this key.")
                }
            }
            Section {
                Button("Export Private Key", systemImage: "square.and.arrow.up") { showExport = true }
                    .disabled(model.demo)
            } footer: {
                Text("Save a copy to Files for backup or use on another device. Anyone with an unencrypted private key can use this identity.")
            }
            Section {
                Button("Delete Identity", role: .destructive) { confirmDeletion = true }.disabled(!connections.isEmpty)
            }
        }
        .navigationTitle(identity.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInstallation) {
            NavigationStack { PublicKeyInstallationView(model: model, identity: identity, connection: model.installationConnection(for: identity)) }
        }
        .sheet(isPresented: $showExport) {
            NavigationStack { PrivateKeyExportView(identities: model.identities, identity: identity) }
        }
        .task { biometricUnlock = await model.identities.hasBiometricUnlock(identity) }
        .confirmationDialog("Delete this SSH identity from this device?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete Identity", role: .destructive) {
                Task {
                    await model.deleteIdentity(identity)
                    if !model.metadata.identities.contains(where: { $0.id == identity.id }) { dismiss() }
                }
            }
        }
    }
}

private extension IdentityDetailsView {
    func turnOffBiometricUnlock() {
        biometricMessage = nil
        Task {
            do { try await model.identities.disableBiometricUnlock(identity) }
            catch { biometricMessage = error.localizedDescription }
            biometricUnlock = await model.identities.hasBiometricUnlock(identity)
        }
    }
}

private enum KeyCreationMode: String, Identifiable {
    case generate, importKey
    var id: String { rawValue }
    var title: String { self == .generate ? "Generate Key" : "Import Key" }
}

private struct KeyCreationView: View {
    let model: AppModel
    let mode: KeyCreationMode
    let onCreated: (IdentityMetadata) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var name = ""
    @State private var privateText = ""
    @State private var passphrase = ""
    @State private var selectedSource: String?
    @State private var showImporter = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("Identity name", text: $name).textContentType(.nickname)
            } footer: {
                Text("A name helps you choose the right identity when adding a connection.")
            }
            if mode == .importKey {
                Section {
                    Button { showImporter = true } label: { Label("Choose Key File", systemImage: "folder") }
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { pasteKey(value) }
                    }.accessibilityLabel("Paste Private Key")
                    if let source = selectedSource {
                        Label(source, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    SecureField("Passphrase, if encrypted", text: $passphrase)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                } header: { Text("OpenSSH private key") } footer: {
                    Text("Choose the private-key file, including extensionless files. Its passphrase is used only to unlock the key. Encrypted keys stay encrypted in Keychain.")
                }
            } else {
                Section {
                    Label("Ed25519", systemImage: "key.fill")
                    Text("The private key is generated on this device and kept in Keychain. After creating it, copy or share its public key to authorise access on the server.")
                        .foregroundStyle(.secondary)
                }
            }
            if let message { Section { Text(message).foregroundStyle(.red).accessibilityLabel("Error: \(message)") } }
            Section {
                Button(action: save) {
                    HStack {
                        Text(mode == .generate ? "Generate Key" : "Validate & Import")
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }.disabled(isWorking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == .importKey && privateText.isEmpty))
            }
        }
        .disabled(isWorking)
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { readFile(url) }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .onDisappear { clearSecrets(); operation?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
    }

    private func pasteKey(_ value: String) {
        // The native paste control supplies text only after an explicit user action.
        guard !value.isEmpty else {
            message = "The clipboard does not contain text."; return
        }
        guard value.utf8.count <= 256 * 1024 else {
            message = "This key is too large. Choose a private-key file below 256 KiB."; return
        }
        privateText = value
        selectedSource = "Private key pasted"
        message = nil
    }

    private func readFile(_ url: URL) {
        isWorking = true; message = nil
        operation = Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) { try KeyFileReader.read(url) }.value
                try Task.checkCancellation()
                privateText = text; selectedSource = url.lastPathComponent
                if name.isEmpty { name = url.lastPathComponent }
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
            isWorking = false
        }
    }

    private func save() {
        guard !model.demo else { message = "Leave Demo to create or import an SSH identity."; return }
        isWorking = true; message = nil
        operation = Task {
            do {
                let identity: IdentityMetadata
                if mode == .generate {
                    identity = try await model.identities.generate(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    identity = try await model.identities.importKey(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  openSSH: privateText, passphrase: passphrase.isEmpty ? nil : passphrase)
                }
                do {
                    try Task.checkCancellation()
                    try await model.addIdentity(identity)
                } catch {
                    // Metadata must be saved successfully before the new identity is considered usable.
                    try? await model.identities.delete(identity, referencedBy: [])
                    throw error
                }
                clearSecrets(); onCreated(identity); dismiss()
            } catch is CancellationError { clearSecrets() }
            catch { passphrase = ""; message = error.localizedDescription }
            isWorking = false
        }
    }

    private func clearSecrets() { privateText = ""; passphrase = ""; selectedSource = nil }
    private func cancel() { operation?.cancel(); clearSecrets(); dismiss() }
}

private enum KeyFileReader {
    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 256 * 1024 else { throw IdentityError.malformedKey }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Read one extra byte to enforce the bound even if the file grows after the size check.
        let data = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
        guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else { throw IdentityError.malformedKey }
        return text
    }
}

struct TrustView: View {
    let model: AppModel
    let endpoint: HostEndpoint
    let key: HostKeyDetails
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Host", value: endpoint.host)
                LabeledContent("Port", value: String(endpoint.port))
                LabeledContent("Algorithm", value: key.algorithm)
            }
            Section { FingerprintView(value: key.fingerprint) } header: { Text("Host fingerprint") } footer: {
                Text("Compare this fingerprint with one obtained directly from the server or its administrator. Trust it only when they match.")
            }
            if let message { Section { Text(message).foregroundStyle(.red) } }
            Section {
                Button("Trust & Connect") {
                    isWorking = true
                    Task {
                        do {
                            try await model.trust.trustUnknown(endpoint: endpoint, key: key)
                            model.sheet = nil; model.sessionRevision += 1
                        } catch { message = error.localizedDescription }
                        isWorking = false
                    }
                }.disabled(isWorking)
            }
        }
        .navigationTitle("Verify Host Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.sheet = nil } } }
    }
}

struct ChangedHostView: View {
    let model: AppModel
    let endpoint: HostEndpoint
    let previous: HostKeyDetails
    let current: HostKeyDetails
    @State private var showReset = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Label("Connection Blocked", systemImage: "exclamationmark.shield.fill").foregroundStyle(.red)
                Text("The host key for \(endpoint.host):\(endpoint.port) differs from the saved key. Verify the change directly with the server or its administrator before resetting trust.")
            }
            Section("Previously trusted · \(previous.algorithm)") { FingerprintView(value: previous.fingerprint) }
            Section("Presented now · \(current.algorithm)") { FingerprintView(value: current.fingerprint) }
            if let message { Section { Text(message).foregroundStyle(.red) } }
            Section {
                Button("Reset Saved Trust", role: .destructive) { showReset = true }
            } footer: {
                Text("Resetting removes the saved key. You must verify and accept the host key again before connecting.")
            }
        }
        .navigationTitle("Host Key Changed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.sheet = nil } } }
        .confirmationDialog("Remove saved trust for \(endpoint.host)?", isPresented: $showReset, titleVisibility: .visible) {
            Button("Reset Saved Trust", role: .destructive) {
                Task {
                    do {
                        try await model.trust.reset(endpoint: endpoint)
                        model.sheet = nil; model.sessionRevision += 1
                    } catch { message = error.localizedDescription }
                }
            }
        } message: {
            Text("Only continue after independently verifying why the host key changed.")
        }
    }
}

/// "Face ID" or "Touch ID" when biometrics can be used now, otherwise nil.
enum BiometricUnlock {
    static var name: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return nil
        }
    }
    static func symbol(for name: String) -> String { name == "Touch ID" ? "touchid" : "faceid" }
}

struct UnlockKeyView: View {
    let model: AppModel
    let identity: IdentityMetadata
    @Environment(\.scenePhase) private var scenePhase
    @State private var passphrase = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var operation: Task<Void, Never>?
    @State private var completedUnlock = false
    @State private var biometryName = BiometricUnlock.name
    @State private var hasBiometricUnlock = false
    @State private var rememberWithBiometrics = false

    var body: some View {
        Form {
            if hasBiometricUnlock, let biometryName {
                Section {
                    Button(action: unlockWithBiometrics) {
                        Label("Unlock with \(biometryName)", systemImage: BiometricUnlock.symbol(for: biometryName))
                    }.disabled(isWorking)
                }
            }
            Section {
                SecureField("Private-key passphrase", text: $passphrase)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .onSubmit(unlock)
            } header: { Text(identity.name) } footer: {
                Text("The identity stays unlocked only for this foreground connection session. The passphrase is never saved.")
            }
            if !hasBiometricUnlock, let biometryName, identity.requiresPassphrase {
                Section {
                    Toggle("Use \(biometryName) next time", isOn: $rememberWithBiometrics)
                } footer: {
                    Text("Keeps an unlocked copy of this key in this device's Keychain, readable only with \(biometryName) as enrolled now. The passphrase is still never saved. Turn it off in SSH Keys.")
                }
            }
            if let message { Section { Text(message).foregroundStyle(.red) } }
            Section {
                Button(action: unlock) {
                    HStack { Text("Unlock & Connect"); Spacer(); if isWorking { ProgressView() } }
                }.disabled(passphrase.isEmpty || isWorking)
            }
        }
        .navigationTitle("Unlock SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } } }
        .onDisappear {
            passphrase = ""; operation?.cancel()
            if !completedUnlock { Task { await model.identities.clearSession() } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .task {
            hasBiometricUnlock = await model.identities.hasBiometricUnlock(identity)
            if hasBiometricUnlock, biometryName != nil { unlockWithBiometrics() }
        }
    }

    private func unlock() {
        guard !isWorking, !passphrase.isEmpty else { return }
        isWorking = true; message = nil
        let remember = rememberWithBiometrics && !hasBiometricUnlock ? biometryName : nil
        operation = Task {
            do {
                try await model.unlockAndConnect(identity, passphrase: passphrase, rememberWith: remember)
                completedUnlock = true; passphrase = ""
            } catch is CancellationError { passphrase = "" }
            catch { passphrase = ""; message = error.localizedDescription }
            isWorking = false
        }
    }

    private func unlockWithBiometrics() {
        guard !isWorking, let biometryName else { return }
        isWorking = true; message = nil
        operation = Task {
            do {
                _ = try await model.identities.unlockWithBiometrics(identity, reason: "Unlock “\(identity.name)” to connect.")
                try Task.checkCancellation()
                completedUnlock = true
                model.sheet = nil; model.sessionRevision += 1
            } catch is CancellationError {
            } catch IdentityError.biometricsDeclined {
                // Cancelled or not recognised: the passphrase field stays available.
            } catch IdentityError.biometricsUnavailable {
                hasBiometricUnlock = false
                message = "\(biometryName) unlock is no longer available for this key, for example because \(biometryName) changed. Enter its passphrase; you can turn \(biometryName) unlock on again below."
            } catch { message = error.localizedDescription }
            isWorking = false
        }
    }

    private func cancel() {
        operation?.cancel(); passphrase = ""; model.sheet = nil
        Task { await model.identities.clearSession() }
    }
}

struct FingerprintView: View {
    let value: String
    var body: some View {
        Text(verbatim: value).font(.footnote.monospaced()).keyMaterialTypesetting().textSelection(.enabled)
            .accessibilityLabel("SHA-256 fingerprint, \(value)")
    }
}

struct PublicKeyText: View {
    let value: String
    var body: some View {
        Text(verbatim: value).font(.caption.monospaced()).keyMaterialTypesetting().textSelection(.enabled)
            .accessibilityLabel(Text(verbatim: value))
    }
}

extension Text {
    /// Key material is not language. iOS hyphenates English text that wraps inside a long token,
    /// drawing a "-" that is not part of the fingerprint or key. Typesetting it as "no linguistic
    /// content" (ISO 639-2 `zxx`) disables hyphenation, so lines break between any two characters
    /// without adding glyphs. The string, copied text and accessibility label are unchanged.
    func keyMaterialTypesetting() -> Text { typesettingLanguage(Locale.Language(identifier: "zxx")) }
}
#endif
