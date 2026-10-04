#if os(iOS)
import SwiftUI
import UIKit
import RemoteFilesCore

/// The reader root owns preparation and presentation. Only the toolbar button is
/// disabled while a prepared file is presented; native picker controls stay enabled.
struct OriginalFileExportControl: ViewModifier {
    let profile: ConnectionProfile
    let entry: RemoteEntry
    let allowedRoot: String
    let exporter: RemoteOriginalExporter
    var isEnabled = true
    /// Return true when the owner presents its own trust/unlock/error UI.
    var onError: (Error) -> Bool = { _ in false }
    @Environment(\.scenePhase) private var scenePhase
    @State private var preparation: Task<Void, Never>?
    @State private var preparing = false
    @State private var requestID = UUID()
    @State private var file: PreparedOriginalFile?
    @State private var ownedFileID: UUID?
    @State private var lease = OriginalFileExportLease()
    @State private var errorMessage: String?

    private struct Request: Equatable {
        let profile: ConnectionProfile
        let entry: RemoteEntry
        let root: String
    }
    private var request: Request { .init(profile: profile, entry: entry, root: allowedRoot) }

    func body(content: Content) -> some View {
        content
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if preparing { cancel() } else { start() }
                } label: {
                    Label(preparing ? "Cancel Export Preparation" : "Save Original to Files",
                          systemImage: preparing ? "xmark.circle" : "square.and.arrow.down")
                }
                .disabled(!preparing && (!isEnabled || ownedFileID != nil || scenePhase != .active))
                .accessibilityHint(preparing ? "Stops downloading the original file for export."
                                   : "Downloads the unmodified file, then lets you choose where to save it.")
            }
        }
        .background {
            OriginalFileSavePresenter(file: file, lease: lease, onDismiss: presentationDismissed)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .alert("Couldn’t Export File", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        .onChange(of: request) { _, _ in cancel() }
        .onChange(of: ObjectIdentifier(exporter)) { _, _ in cancel() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancel() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        .onDisappear(perform: cancel)
        .task(id: file?.id) {
            guard let value = file else { return }
            do { try await Task.sleep(for: .seconds(max(0, value.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            guard file?.id == value.id else { return }
            cancel()
        }
    }

    private func start() {
        guard isEnabled, scenePhase == .active, preparation == nil, file == nil, ownedFileID == nil else { return }
        let token = UUID(); requestID = token
        let selected = request
        let selectedExporter = exporter
        preparing = true; errorMessage = nil
        preparation = Task { @MainActor in
            defer {
                if requestID == token { preparation = nil; preparing = false }
            }
            do {
                let value = try await selectedExporter.prepare(profile: selected.profile, entry: selected.entry,
                                                       allowedRoot: selected.root)
                guard !Task.isCancelled, requestID == token else {
                    await selectedExporter.release(value.id)
                    return
                }
                lease.own(value, exporter: selectedExporter)
                ownedFileID = value.id; file = value
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, requestID == token else { return }
                if !onError(error), requestID == token { errorMessage = error.localizedDescription }
            }
        }
    }

    private func cancel() {
        requestID = UUID()
        preparation?.cancel(); preparation = nil; preparing = false
        lease.cancelPresentation()
        file = nil; errorMessage = nil

        // The presenter releases the lease after native dismissal, or immediately
        // when cancellation arrived before the picker could be presented.
    }

    private func presentationDismissed(_ id: UUID) {
        guard ownedFileID == id else { return }
        file = nil
        ownedFileID = nil
    }
}

/// Shared before SwiftUI observes a prepared file, so teardown also owns cleanup.
@MainActor
private final class OriginalFileExportLease {
    private(set) var id: UUID?
    private(set) var requestedFile: PreparedOriginalFile?
    var onChange: (() -> Void)?
    private var exporter: RemoteOriginalExporter?

    func own(_ file: PreparedOriginalFile, exporter: RemoteOriginalExporter) {
        id = file.id
        requestedFile = file
        self.exporter = exporter
        onChange?()
    }

    func cancelPresentation() {
        guard requestedFile != nil else { return }
        requestedFile = nil
        onChange?()
    }

    func release(_ id: UUID) async {
        guard self.id == id, let exporter else { return }
        self.id = nil
        requestedFile = nil
        self.exporter = nil
        await exporter.release(id)
    }
}

/// Present the document picker itself so UIKit owns its native navigation controls.
/// Keep the source copy leased until native dismissal has completed.
@MainActor
private struct OriginalFileSavePresenter: UIViewControllerRepresentable {
    let file: PreparedOriginalFile?
    let lease: OriginalFileExportLease
    let onDismiss: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(lease: lease, onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> AnchorController {
        let anchor = AnchorController()
        context.coordinator.anchor = anchor
        anchor.onReady = { [weak coordinator = context.coordinator] in coordinator?.scheduleUpdate() }
        return anchor
    }

    func updateUIViewController(_ anchor: AnchorController, context: Context) {
        context.coordinator.update(file: file, onDismiss: onDismiss)
    }

    static func dismantleUIViewController(_ anchor: AnchorController, coordinator: Coordinator) {
        anchor.onReady = nil
        coordinator.stop()
    }

    final class AnchorController: UIViewController {
        var onReady: (() -> Void)?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onReady?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        weak var anchor: AnchorController?
        private let lease: OriginalFileExportLease
        private var onDismiss: (UUID) -> Void
        private var requestedFile: PreparedOriginalFile? { lease.requestedFile }
        private var picker: UIDocumentPickerViewController?
        private var presentedID: UUID?
        private var completedID: UUID?
        private var presenting = false
        private var dismissing = false
        private var stopped = false
        private var updateScheduled = false

        init(lease: OriginalFileExportLease, onDismiss: @escaping (UUID) -> Void) {
            self.lease = lease
            self.onDismiss = onDismiss
            super.init()
            lease.onChange = { [weak self] in self?.scheduleUpdate() }
        }

        func update(file: PreparedOriginalFile?, onDismiss: @escaping (UUID) -> Void) {
            // The value invalidates SwiftUI; the synchronous shared lease is authoritative.
            // A queued layout update must not mistake an unobserved file for cancellation.
            self.onDismiss = onDismiss
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [self] in
                updateScheduled = false
                reconcile()
            }
        }

        func stop() {
            stopped = true
            lease.cancelPresentation()
            scheduleUpdate()
        }

        private func reconcile() {
            if let picker {
                if stopped || requestedFile?.id != presentedID { dismiss(picker) }
                return
            }
            guard !stopped, let value = requestedFile else {
                if let id = lease.id { finish(id) }
                return
            }
            guard value.id != completedID,
                  let anchor, anchor.parent != nil, anchor.viewIfLoaded?.window != nil,
                  anchor.presentedViewController == nil else { return }
            let picker = UIDocumentPickerViewController(forExporting: [value.url], asCopy: true)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            picker.modalPresentationStyle = .pageSheet
            picker.presentationController?.delegate = self
            self.picker = picker
            presentedID = value.id
            presenting = true
            anchor.present(picker, animated: true) { [self] in
                presenting = false
                scheduleUpdate()
            }
            picker.presentationController?.delegate = self
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            dismiss(controller)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss(controller)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === picker,
                  let id = presentedID else { return }
            finish(id)
        }

        private func dismiss(_ controller: UIDocumentPickerViewController) {
            guard controller === picker, !dismissing else { return }
            lease.cancelPresentation()
            guard !presenting else { return }
            guard let id = presentedID else { return }
            dismissing = true
            if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { [self] context in
                    if context.isCancelled {
                        dismissing = false
                        scheduleUpdate()
                    } else {
                        finish(id)
                    }
                }
            } else if controller.presentingViewController == nil {
                finish(id)
            } else {
                controller.dismiss(animated: true) { [self] in finish(id) }
            }
        }

        private func finish(_ id: UUID) {
            guard completedID != id else { return }
            completedID = id
            if presentedID == id {
                picker = nil
                presentedID = nil
                presenting = false
                dismissing = false
            }
            Task { @MainActor [lease, onDismiss] in
                await lease.release(id)
                onDismiss(id)
            }
        }
    }
}
#endif
