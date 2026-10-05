#if os(iOS)
import SwiftUI
import RemoteFilesCore

@MainActor @Observable
final class PublicKeyInstallationFlow {
    private let installer: any PublicKeyInstalling
    private var operation: Task<Void, Never>?
    private var token = UUID()
    var review: PublicKeyInstallationRequest?
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var result: PublicKeyInstallationResult?
    private(set) var unverifiedHost: (HostEndpoint, HostKeyDetails)?

    init(installer: any PublicKeyInstalling) { self.installer = installer }
    func prepare(host: String, port: Int, username: String, identity: IdentityMetadata) {
        guard !isWorking else { return }
        do {
            review = try PublicKeyInstallationRequest(host: host, port: port, username: username, identity: identity)
            message = nil; result = nil; unverifiedHost = nil
        } catch { message = error.localizedDescription }
    }
    /// The only path to a server write. Review is immutable while its confirmation is shown.
    func confirm(password: String) {
        guard let request = review, !isWorking else { return }
        guard !password.isEmpty else { message = PublicKeyInstallationError.passwordRequired.localizedDescription; return }
        let current = UUID(); token = current
        isWorking = true; message = nil; result = nil; unverifiedHost = nil
        operation = Task {
            defer { if token == current { isWorking = false; operation = nil } }
            do {
                let installed = try await installer.install(request, password: password)
                try Task.checkCancellation()
                guard token == current else { return }
                result = installed; review = nil
                message = installed == .installed ? "Public key installed for \(request.account)." : "This public key is already listed for \(request.account). Existing options are unchanged."
            } catch {
                guard token == current, !Task.isCancelled else { return }
                review = nil
                if case HostTrustError.unknown(let endpoint, let key) = error {
                    unverifiedHost = (endpoint, key)
                }
                message = error.localizedDescription
            }
        }
    }
    func cancel() {
        token = UUID(); operation?.cancel(); operation = nil
        review = nil; isWorking = false
    }
    func hostAccepted() { unverifiedHost = nil; message = "Host verified. Enter the password and review the installation again." }
}

struct PublicKeyInstallationView: View {
    let model: AppModel
    let identity: IdentityMetadata
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var host: String
    @State private var username: String
    @State private var port: String
    @State private var password = ""
    @State private var flow: PublicKeyInstallationFlow
    @State private var trustError: String?
    @AccessibilityFocusState private var statusFocused: Bool

    init(model: AppModel, identity: IdentityMetadata, connection: ConnectionProfile? = nil) {
        self.model = model; self.identity = identity
        _host = State(initialValue: connection?.host ?? "")
        _username = State(initialValue: connection?.username ?? "")
        _port = State(initialValue: String(connection?.port ?? 22))
        _flow = State(initialValue: PublicKeyInstallationFlow(installer: model.publicKeyInstaller))
    }
    var body: some View {
        Form {
            Section("Server account") {
                TextField("Hostname or IP address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Account username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("SSH port", text: $port).keyboardType(.numberPad)
                SecureField("Account password", text: $password).textContentType(.password).privacySensitive()
            }.disabled(flow.isWorking)
            Section {
                Text(identity.name)
                FingerprintView(value: identity.fingerprint)
                Text(identity.publicKey).font(.caption.monospaced()).textSelection(.enabled)
            } header: { Text("Public key") } footer: { Text("Only the public key is sent. The private key stays in this device’s Keychain.") }
            Section {
                Text("Adds this public key to the account’s ~/.ssh/authorized_keys, enabling key login for this identity. Existing keys stay in place. Password login must already be enabled; the app does not change server settings.")
                Text("The password is used only for this attempt and is not saved.")
            }
            if let (endpoint, key) = flow.unverifiedHost {
                Section("Verify this host") {
                    Text("\(endpoint.host):\(endpoint.port)")
                    FingerprintView(value: key.fingerprint)
                    Text("Compare this fingerprint with the server through a trusted source before accepting it.")
                    Button("Trust This Host") {
                        Task {
                            do { try await model.trust.trustUnknown(endpoint: endpoint, key: key); flow.hostAccepted() }
                            catch { trustError = error.localizedDescription }
                        }
                    }
                }
            }
            if let message = trustError ?? flow.message {
                Section { Text(message).foregroundStyle(flow.result == nil ? Color.secondary : Color.primary)
                    .accessibilityFocused($statusFocused)
                    .accessibilityLabel(flow.result == nil ? "Installation status: \(message)" : message) }
            }
            Section {
                Button("Review Installation") {
                    flow.prepare(host: host, port: Int(port) ?? 0, username: username, identity: identity)
                }.disabled(password.isEmpty || flow.isWorking || model.demo || !model.isForeground)
                if flow.isWorking {
                    ProgressView("Installing public key…")
                    Text("Cancelling closes the connection. The server may already have added the key; retry safely to check.").font(.footnote)
                }
            }
        }
        .navigationTitle("Install Public Key")
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(flow.result == nil ? "Cancel" : "Done") { cancel(); dismiss() } } }
        .sheet(item: $flow.review) { request in
            PublicKeyInstallationConfirmation(request: request, flow: flow, password: $password)
        }
        .onDisappear { cancel() }
        .onChange(of: flow.message) { _, value in if value != nil { statusFocused = true } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
    }
    private func cancel() { flow.cancel(); password = "" }
}
private struct PublicKeyInstallationConfirmation: View {
    let request: PublicKeyInstallationRequest
    let flow: PublicKeyInstallationFlow
    @Binding var password: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Install for this account") { Text(request.account).textSelection(.enabled) }
                Section("Public key to install") {
                    Text(request.identityName)
                    FingerprintView(value: request.fingerprint)
                    Text(request.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                }
                Section {
                    Text("This adds the public key to this account’s authorized_keys. It grants access using this identity and preserves existing entries. Your private key is never sent.")
                    Button("Install Public Key") { flow.confirm(password: password); password = ""; dismiss() }
                }
            }
            .navigationTitle("Confirm Installation")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
#endif
