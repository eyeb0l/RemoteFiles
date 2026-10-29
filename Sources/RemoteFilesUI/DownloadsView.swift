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
            Section {
                Text(model.backgroundDownloads.status).font(.footnote).foregroundStyle(.secondary)
                Text("Up to 128 MiB per file and 512 MiB total. Downloads keep original bytes. Interrupted downloads restart from the beginning.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let manager = model.downloads {
                if let error = manager.persistenceError { Text(error).foregroundStyle(.red) }
                if manager.items.isEmpty { ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Touch and hold a file in a remote folder, then choose Download.")) }
                ForEach(manager.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.filename).font(.headline)
                        Text(item.profile.name).font(.caption).foregroundStyle(.secondary)
                        if item.state == .downloading {
                            ProgressView(value: item.progress.fraction)
                            Text(item.progress.sizeLabel()).font(.caption.monospacedDigit())
                        } else if item.state == .pendingFinalization {
                            Text("Waiting for Unlock").font(.caption)
                        } else { Text(item.state.rawValue.capitalized).font(.caption) }
                        if let message = item.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            if item.state == .completed {
                                Button("Save to Files", systemImage: "square.and.arrow.down") {
                                    do { saving = .init(url: try manager.completedURL(item.id)) }
                                    catch { model.errorMessage = error.localizedDescription }
                                }
                            } else if item.state == .pendingFinalization {
                                Button("Finish Download", systemImage: "lock.open") { manager.finalizePendingDownloads() }
                                    .disabled(!model.isForeground)
                            } else if item.state == .queued || item.state == .downloading {
                                Button("Cancel", role: .destructive) { manager.cancel(item.id) }
                            } else {
                                Button("Retry", systemImage: "arrow.clockwise") { model.retryDownload(item) }
                                    .disabled(!model.isForeground || manager.activeID == item.id)
                            }
                            Spacer()
                            if manager.activeID != item.id {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    do { try manager.remove(item.id) } catch { model.errorMessage = error.localizedDescription }
                                }
                            }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
            } else if let error = model.downloadError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Downloads")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(item: $saving) { value in DownloadSavePicker(url: value.url) }
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
