#if os(iOS)
import SwiftUI
import RemoteFilesCore

/// Reads a connected file for the certificate preview. Unlike a text document these bytes go
/// straight to the parser and are dropped: they never enter the reader's text state, its document
/// cache or the on-disk resource cache, because a `.pem` can hold a private key. Only the summary,
/// which has no secret in it, is kept.
struct RemoteCertificateView: View {
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let entry: RemoteEntry
    let refreshID: Int
    @State private var result: CertificatePreviewResult?
    @State private var version: RemoteFileVersion?
    @State private var failure: String?
    @State private var loading = true
    @State private var retryID = 0
    @State private var lastRefreshID = 0
    @State private var requestID = UUID()

    var body: some View {
        // One view, not a Group: a Group's lifecycle modifiers would run per branch.
        VStack(spacing: 0) {
            if let result, model.isForeground {
                CertificateResultView(result: result, filename: entry.name, saveAction: "Save Original to Files")
            } else if loading || result != nil {
                LoadingPlaceholder(label: "Reading certificate…", shape: .list)
            } else {
                ContentUnavailableView {
                    Label("Couldn’t read certificate", systemImage: "doc.badge.ellipsis")
                } description: { Text(failure ?? "You can return to the folder or try again.") }
                actions: { Button("Try Again") { retryID += 1 }.buttonStyle(.bordered) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentStatus(progress: result != nil && loading ? "Updating…" : nil,
                       failure: result != nil ? failure.map { "Previously loaded copy · \($0)" } : nil,
                       retry: { retryID += 1 })
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)-\(retryID)") { await load() }
        .onDisappear { requestID = UUID() }
    }

    private func load() async {
        guard !model.isDisconnecting else { loading = false; return }
        guard model.isForeground else {
            loading = false
            if result == nil { failure = "Connection paused while the app is in the background." }
            return
        }
        model.noteForegroundConnection(profile.id)
        let explicitRefresh = refreshID != lastRefreshID
        lastRefreshID = refreshID
        let token = UUID(); requestID = token
        let revision = model.sessionRevision
        let generation = model.listingGeneration(profile.id)
        func isCurrent() -> Bool {
            token == requestID && !model.isDisconnecting && model.isForeground && model.sessionRevision == revision
                && model.listingGeneration(profile.id) == generation
        }
        loading = true; failure = nil
        defer { if requestID == token { loading = false } }
        do {
            let read = try await model.service.readFileIfChanged(profile: profile, entry: entry, limit: CertificatePreview.maximumFileBytes,
                                                                 since: explicitRefresh || result == nil ? nil : version)
            if case .contents(let bytes, let newVersion) = read {
                let parsed = try await CertificatePreview.summarize(bytes)
                try Task.checkCancellation()
                guard isCurrent() else { return }
                result = parsed; version = newVersion
            } else {
                try Task.checkCancellation()
                guard isCurrent() else { return }
            }
            model.connectionStates[profile.id] = "Connected"
            await model.recordRecent(profile: profile, entry: entry)
        } catch is CancellationError {
        } catch RemoteFileError.tooLarge {
            guard !Task.isCancelled, isCurrent() else { return }
            result = .tooLarge; version = nil
        } catch {
            guard !Task.isCancelled, requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
            failure = error.localizedDescription
            if model.isSecurityError(error) { result = nil; version = nil }
            model.handle(error, profile: profile)
        }
    }
}

/// The saved copy's reader holds the lease on this file for as long as this view is shown.
struct OfflineCertificateView: View {
    let url: URL
    let filename: String
    @State private var result: CertificatePreviewResult?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                CertificateResultView(result: result, filename: filename, saveAction: "Share Original")
            } else if let failure {
                ContentUnavailableView("Couldn’t open saved copy", systemImage: "exclamationmark.doc", description: Text(failure))
            } else {
                LoadingPlaceholder(label: "Reading certificate…", shape: .list)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            do {
                let parsed = try await CertificatePreview.summarize(fileAt: url)
                try Task.checkCancellation()
                result = parsed
            } catch is CancellationError {
            } catch { failure = error.localizedDescription }
        }
    }
}

/// A PKCS #12 file is encrypted with a password and usually holds a private key. It isn't read,
/// and no password is asked for, so nothing here depends on its contents.
struct ProtectedCertificateView: View {
    let filename: String
    let saveAction: String
    var body: some View {
        ContentUnavailableView {
            Label("Protected Certificate File", systemImage: "lock.doc")
        } description: {
            Text("\(filename) is a password-protected container, which usually holds a private key with its certificates. RemoteFiles doesn’t open these files or ask for their passwords. You can still use \(saveAction) to keep a copy of the file.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CertificateResultView: View {
    let result: CertificatePreviewResult
    let filename: String
    let saveAction: String

    var body: some View {
        switch result {
        case .contents(let contents):
            CertificateContentView(contents: contents, saveAction: saveAction)
        case .empty:
            ContentUnavailableView("This file is empty", systemImage: "doc", description: Text("Refresh after it has been updated on the server."))
        case .tooLarge:
            ContentUnavailableView("Too Large to Preview", systemImage: "doc",
                                   description: Text("Certificate previews are limited to 2 MiB. You can still use \(saveAction) to keep a copy of the file."))
        case .unrecognized:
            ContentUnavailableView("No Certificate Found", systemImage: "doc.questionmark",
                                   description: Text("\(filename) doesn’t contain a certificate RemoteFiles can read. It may be damaged or in another format. You can still use \(saveAction) to keep a copy of the file."))
        }
    }
}

/// A Settings-style summary of a file's certificates. It states what the file says and never
/// whether to trust it, so it has no seal, no green state and no way to install a certificate.
struct CertificateContentView: View {
    let contents: CertificateFileContents
    let saveAction: String
    @State private var shown: CertificateSummary?

    var body: some View {
        Form {
            if contents.privateKeys > 0 { privateKeySection }
            if let first = contents.certificates.first {
                CertificateOverviewSection(summary: first, position: position(of: first))
                if contents.certificates.count > 1 || contents.omittedCertificates > 0 { otherCertificates }
                CertificateDetailSections(summary: first)
            } else {
                Section {
                    Text("No certificates were found in this file.").foregroundStyle(.secondary)
                }
            }
            if contents.unreadableBlocks > 0 || contents.otherBlocks > 0 { fileNotes }
            Section {} footer: { Text(Self.disclaimer) }
        }
        .sheet(item: $shown) { summary in
            NavigationStack {
                Form {
                    CertificateOverviewSection(summary: summary, position: position(of: summary))
                    CertificateDetailSections(summary: summary)
                    Section {} footer: { Text(Self.disclaimer) }
                }
                .navigationTitle(summary.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { shown = nil } } }
            }
            .coversKeyboardCommands()
        }
    }

    static let disclaimer = "RemoteFiles reads what this file states. It doesn’t verify signatures, build a chain or check revocation, so nothing here means a certificate is trusted. Self-signed means the issuer and subject names match."

    private func position(of summary: CertificateSummary) -> String? {
        let total = contents.certificates.count + contents.omittedCertificates
        return total > 1 ? "\(summary.id + 1) of \(total)" : nil
    }

    private var privateKeySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(contents.privateKeys == 1 ? "Contains a Private Key" : "Contains \(contents.privateKeys) Private Keys", systemImage: "key.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("RemoteFiles doesn’t display, copy or search private keys. \(saveAction) copies the whole file, including anything secret in it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }

    private var otherCertificates: some View {
        Section("Also in This File") {
            ForEach(contents.certificates.dropFirst()) { summary in
                Button { shown = summary } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title).foregroundStyle(.primary)
                            Text(CertificateDescriptions.role(of: summary)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows this certificate’s details")
            }
            if contents.omittedCertificates > 0 {
                Text("\(contents.omittedCertificates) more not shown. Previews read the first \(CertificatePreview.maximumCertificates).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var fileNotes: some View {
        Section("Not Shown") {
            if contents.unreadableBlocks > 0 {
                Text(contents.unreadableBlocks == 1 ? "1 certificate block couldn’t be read." : "\(contents.unreadableBlocks) certificate blocks couldn’t be read.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if contents.otherBlocks > 0 {
                Text(contents.otherBlocks == 1 ? "1 other block, such as a public key, isn’t shown." : "\(contents.otherBlocks) other blocks, such as public keys, aren’t shown.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

enum CertificateDescriptions {
    /// How a certificate describes itself: a fact, not a judgement of its place in any chain.
    static func role(of summary: CertificateSummary) -> String {
        guard summary.role == .certificate else { return "Certificate signing request" }
        guard let constraints = summary.basicConstraints else { return "Basic constraints not stated" }
        return constraints.isCA ? "Certificate authority" : "Not a certificate authority (leaf)"
    }

    static func basicConstraints(_ constraints: CertificateBasicConstraints?) -> String {
        guard let constraints else { return "Not stated" }
        guard constraints.isCA else { return "Not a certificate authority (leaf)" }
        return constraints.pathLength.map { "Certificate authority, path length \($0)" } ?? "Certificate authority"
    }

    static func publicKey(_ key: CertificatePublicKey?) -> (algorithm: String, size: String?) {
        guard let key else { return ("Unreadable", nil) }
        return (key.algorithm, key.bits.map { "\($0) bits" })
    }

    struct Validity {
        let title: String
        let detail: String?
        let symbol: String
        let color: Color
    }

    /// Never green or sealed: being within its dates says nothing about whether it can be trusted.
    static func validity(_ state: CertificateValidityState) -> Validity {
        switch state {
        case .expired(let date):
            return .init(title: "Expired", detail: "Ended \(date.formatted(date: .abbreviated, time: .omitted))", symbol: "calendar.badge.exclamationmark", color: .red)
        case .notYetValid(let date):
            return .init(title: "Not Yet Valid", detail: "Starts \(date.formatted(date: .abbreviated, time: .omitted))", symbol: "calendar.badge.clock", color: .orange)
        case .withinDates(let date):
            return .init(title: "Within Its Dates", detail: "Ends \(date.formatted(date: .abbreviated, time: .omitted))", symbol: "calendar", color: .primary)
        case .unknown:
            return .init(title: "Dates Unreadable", detail: nil, symbol: "calendar", color: .secondary)
        }
    }
}

/// What the certificate is called, who issued it, and whether its dates cover today.
private struct CertificateOverviewSection: View {
    let summary: CertificateSummary
    let position: String?
    @ScaledMetric(relativeTo: .body) private var iconColumn = RemoteFilesStyle.iconColumn

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.headline)
                Text(CertificateDescriptions.role(of: summary)).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            if summary.role == .certificate {
                // Compared when shown, so a preview left open still tells the truth.
                let validity = CertificateDescriptions.validity(summary.validity(at: .now))
                HStack(spacing: 12) {
                    Image(systemName: validity.symbol).foregroundStyle(validity.color)
                        .frame(width: iconColumn).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(validity.title).foregroundStyle(validity.color)
                        if let detail = validity.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Validity")
                .accessibilityValue([validity.title, validity.detail].compactMap { $0 }.joined(separator: ", "))
            }
        } header: {
            if let position { Text("Certificate \(position)") }
        } footer: {
            if summary.role == .certificate { Text("Compared with this device’s clock.") }
            else { Text("A request asks a certificate authority for a certificate. It isn’t a certificate itself.") }
        }
    }
}

private struct CertificateDetailSections: View {
    let summary: CertificateSummary

    var body: some View {
        Section("Subject") { nameRows(summary.subject) }
        if let issuer = summary.issuer {
            Section("Issuer") {
                nameRows(issuer)
                CertificateRow("Self-Signed", summary.isSelfSigned ? "Yes" : "No")
            }
        }
        if summary.role == .certificate {
            Section("Validity") {
                CertificateRow("Not Before", summary.notBefore.map(Self.dateText) ?? "Unreadable")
                CertificateRow("Not After", summary.notAfter.map(Self.dateText) ?? "Unreadable")
            }
        }
        if !summary.alternativeNames.isEmpty {
            Section("Subject Alternative Names") {
                ForEach(Array(summary.alternativeNames.enumerated()), id: \.offset) { _, name in
                    CertificateRow(name.kind.rawValue, name.value, stacked: name.value.count > 24)
                }
                if summary.omittedAlternativeNames > 0 {
                    Text("\(summary.omittedAlternativeNames) more not shown.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        let key = CertificateDescriptions.publicKey(summary.publicKey)
        Section("Public Key") {
            CertificateRow("Algorithm", key.algorithm)
            if let size = key.size { CertificateRow("Size", size) }
        }
        Section {
            CertificateRow("Basic Constraints", CertificateDescriptions.basicConstraints(summary.basicConstraints), stacked: true)
            if !summary.keyUsage.isEmpty {
                CertificateRow("Key Usage", summary.keyUsage.joined(separator: ", "), stacked: true)
            }
            if !summary.extendedKeyUsage.isEmpty {
                CertificateRow("Extended Key Usage", summary.extendedKeyUsage.joined(separator: ", "), stacked: true)
            }
        } header: {
            Text("Constraints and Usage")
        } footer: {
            if summary.unreadableExtensions > 0 {
                Text(summary.unreadableExtensions == 1 ? "1 extension couldn’t be read." : "\(summary.unreadableExtensions) extensions couldn’t be read.")
            }
        }
        Section("Details") {
            if let version = summary.version { CertificateRow("Version", "\(version)") }
            if let serial = summary.serialNumber { CertificateRow("Serial Number", serial, stacked: serial.count > 16, monospaced: true, spokenAsHex: true) }
            CertificateRow("Signature Algorithm", summary.signatureAlgorithm, stacked: summary.signatureAlgorithm.count > 24)
        }
        if let sha256 = summary.sha256Fingerprint, let sha1 = summary.sha1Fingerprint {
            Section {
                CertificateRow("SHA-256", sha256, stacked: true, monospaced: true, spokenAsHex: true)
                CertificateRow("SHA-1", sha1, stacked: true, monospaced: true, spokenAsHex: true)
            } header: {
                Text("Fingerprints")
            } footer: {
                Text("Hold a row to copy it.")
            }
        }
    }

    @ViewBuilder private func nameRows(_ name: CertificateName) -> some View {
        if name.attributes.isEmpty {
            Text("Empty").foregroundStyle(.secondary)
        }
        ForEach(Array(name.attributes.enumerated()), id: \.offset) { _, attribute in
            CertificateRow(attribute.name, attribute.value, stacked: attribute.value.count > 24)
        }
        if name.omittedAttributes > 0 {
            Text("\(name.omittedAttributes) more not shown.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private static func dateText(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

/// One label and one value, read by VoiceOver as such. Every value here is public and bounded, so
/// copying goes through a menu rather than a selectable view of the file.
private struct CertificateRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let label: String
    let value: String
    var stacked = false
    var monospaced = false
    var spokenAsHex = false

    init(_ label: String, _ value: String, stacked: Bool = false, monospaced: Bool = false, spokenAsHex: Bool = false) {
        self.label = label; self.value = value; self.stacked = stacked
        self.monospaced = monospaced; self.spokenAsHex = spokenAsHex
    }

    var body: some View {
        let stacks = stacked || dynamicTypeSize.isAccessibilitySize
        let layout = stacks ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(label)
                .font(stacks ? .footnote : .body)
                .foregroundStyle(stacks ? .secondary : .primary)
            if !stacks { Spacer(minLength: 8) }
            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .foregroundStyle(stacks ? .primary : .secondary)
                .multilineTextAlignment(stacks ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy \(label)", systemImage: "doc.on.doc") { SourceClipboard.copy(value) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenAsHex ? value.replacingOccurrences(of: ":", with: " ") : value)
        .accessibilityAction(named: "Copy") { SourceClipboard.copy(value) }
    }
}
#endif
