#if os(iOS)
import SwiftUI
import UIKit
import RemoteFilesCore

struct DownloadsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving: DownloadSaveFile?
    var body: some View {
        List {
            if let manager = model.downloads {
                if let error = manager.persistenceError { Text(error).foregroundStyle(.red) }
                if manager.items.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Touch and hold a file in a remote folder, then choose Download."))
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(manager.items) { item in
                        DownloadRow(item: item, isActive: manager.activeID == item.id, canRetry: model.isForeground,
                                    save: {
                                        do { saving = .init(url: try manager.completedURL(item.id)) }
                                        catch { model.errorMessage = error.localizedDescription }
                                    },
                                    finish: { manager.finalizePendingDownloads() },
                                    cancel: { manager.cancel(item.id) },
                                    retry: { model.retryDownload(item) },
                                    remove: {
                                        do { try manager.remove(item.id) } catch { model.errorMessage = error.localizedDescription }
                                    })
                    }
                } footer: {
                    Text(model.backgroundDownloads.status)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
            } else if let error = model.downloadError { Text(error).foregroundStyle(.red) }
        }
        .listStyle(.plain)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(item: $saving) { value in DownloadSavePicker(url: value.url) }
    }
}
private struct DownloadRow: View {
    @ScaledMetric(relativeTo: .body) private var iconColumn = RemoteFilesStyle.iconColumn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: ManagedDownload
    let isActive: Bool
    let canRetry: Bool
    let save: () -> Void
    let finish: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let remove: () -> Void
    private var stateText: String {
        switch item.state {
        case .downloading: return item.progress.sizeLabel()
        case .pendingFinalization: return "Waiting for Unlock"
        default: return item.state.rawValue.capitalized
        }
    }
    private var symbol: String {
        switch item.state {
        case .completed: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .queued: return "clock"
        case .pendingFinalization: return "lock"
        default: return "exclamationmark.circle"
        }
    }
    private var symbolColor: Color {
        switch item.state {
        case .completed: return .green
        case .downloading, .queued, .pendingFinalization: return .secondary
        default: return .orange
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(symbolColor)
                    .frame(width: iconColumn).accessibilityHidden(true)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text("\(stateText) · \(item.profile.name)")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                trailingAction
            }
            if item.state == .downloading { ThinProgress(fraction: item.progress.fraction) }
            if item.keepsPartialBytes {
                Text("\(item.progress.sizeLabel()) kept. Retry continues from there.")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let message = item.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isActive { Button("Remove", systemImage: "trash", role: .destructive, action: remove) }
        }
        .contextMenu {
            if !isActive { Button("Remove", systemImage: "trash", role: .destructive, action: remove) }
        }
        .accessibilityActions {
            if !isActive { Button("Remove", action: remove) }
        }
        .sensoryFeedback(.success, trigger: item.state) { _, new in new == .completed }
    }
    @ViewBuilder private var trailingAction: some View {
        Group {
            if item.state == .completed {
                Button(action: save) { IconTarget(symbol: "square.and.arrow.down") }.accessibilityLabel("Save to Files")
            } else if item.state == .pendingFinalization {
                Button(action: finish) { IconTarget(symbol: "lock.open") }.accessibilityLabel("Finish Download").disabled(!canRetry)
            } else if item.state == .queued || item.state == .downloading {
                Button(role: .destructive, action: cancel) { IconTarget(symbol: "xmark.circle") }.accessibilityLabel("Cancel")
            } else {
                Button(action: retry) { IconTarget(symbol: "arrow.clockwise") }.accessibilityLabel("Retry").disabled(!canRetry || isActive)
            }
        }
        .buttonStyle(.borderless)
    }
}
private struct DownloadSaveFile: Identifiable { let id = UUID(); let url: URL }
private struct DownloadSavePicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.shouldShowFileExtensions = true
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
#endif
