#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication
import RemoteFilesCore

/// The native Files exporter owns the save destination. Private bytes are never copied to the
/// clipboard, logged, or put in a ShareLink; SwiftUI receives them only after explicit approval.
struct PrivateKeyExportView: View {
    let identities: IdentityStore
    let identity: IdentityMetadata
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmed = false
    @State private var exporting = false
    @State private var document: PrivateKeyDocument?
    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var working = false

    var body: some View {
        Form {
            Section("Identity") {
                Text(identity.name)
                FingerprintView(value: identity.fingerprint)
            }
            Section {
                Text(identity.requiresPassphrase
                     ? "The exported OpenSSH file keeps its original encryption and passphrase. Keep the file and passphrase safe."
                     : "This OpenSSH private-key file has no passphrase. Anyone who obtains it can use this identity. Save it only to a location you trust.")
                Text("The destination may sync to cloud storage. The exported copy is outside RemoteFiles’ Keychain protection and remains there if you delete this identity from the app.")
                Toggle("I understand and want to export this private key", isOn: $confirmed)
            }
            Section {
                Button("Authenticate & Save to Files", action: prepare)
                    .disabled(!confirmed || working || exporting || scenePhase != .active)
                if working { ProgressView("Authenticating…") }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Export Private Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { clear(); dismiss() } } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                      defaultFilename: "id_" + (identity.algorithm == "ssh-ed25519" ? "ed25519" : identity.algorithm == "ssh-rsa" ? "rsa" : "ecdsa")) { result in
            document = nil
            confirmed = false
            switch result {
            case .success: message = "Private key saved. Protect the exported copy."
            case .failure: message = "The private key was not saved. Try again if needed."
            }
        }
        .onChange(of: exporting) { _, presented in
            if !presented { document = nil; confirmed = false }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { clear() } }
        .onDisappear { clear() }
        .privacySensitive()
    }

    private func prepare() {
        guard confirmed, !working, !exporting, scenePhase == .active else { return }
        working = true; message = nil
        operation = Task { @MainActor in
            defer { working = false; operation = nil }
            let context = LAContext()
            do {
                let authenticated = try await withTaskCancellationHandler {
                    try await context.evaluatePolicy(.deviceOwnerAuthentication,
                        localizedReason: "Export the private SSH key for “\(identity.name)”.")
                } onCancel: { context.invalidate() }
                guard authenticated else { throw LAError(.authenticationFailed) }
                try Task.checkCancellation()
                let bytes = try await identities.exportOpenSSH(identity)
                try Task.checkCancellation()
                guard scenePhase == .active, confirmed else { return }
                document = PrivateKeyDocument(bytes: bytes)
                exporting = true
            } catch is CancellationError {
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func clear() {
        operation?.cancel(); operation = nil
        document = nil; exporting = false; confirmed = false
    }
}

struct PrivateKeyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadNoPermission)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        makeFileWrapper()
    }
    func makeFileWrapper() -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: bytes)
        var attributes = wrapper.fileAttributes
        attributes[FileAttributeKey.posixPermissions.rawValue] = 0o600
        attributes[FileAttributeKey.protectionKey.rawValue] = FileProtectionType.complete.rawValue
        wrapper.fileAttributes = attributes
        return wrapper
    }
}
#endif
