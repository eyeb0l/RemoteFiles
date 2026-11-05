#if os(iOS)
import SwiftUI

/// The app's few shared decisions: one accent, one row, quiet status, and motion that respects
/// Reduce Motion. Everything else is the system's own material, type and spacing.
enum RemoteFilesStyle {
    static let accent = Color.indigo
    static let iconColumn: CGFloat = 26
    static let contentFade = Animation.easeOut(duration: 0.18)
    static let statusSpring = Animation.snappy(duration: 0.28)
}

/// One line of a list: an icon, a name and at most one quiet line beneath it. The spoken label can
/// say more than the row shows, such as "Folder", which every folder's icon already says by sight.
struct LocationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconColumn = RemoteFilesStyle.iconColumn
    let name: String
    let subtitle: String
    let symbol: String
    var color: Color = .secondary
    /// Shown instead of `subtitle`, or nil to show none.
    var visibleSubtitle: String?? = nil
    /// A small mark over the icon's corner, such as a connection's state.
    var statusColor: Color? = nil
    private var shownSubtitle: String? { visibleSubtitle ?? subtitle }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: iconColumn)
                .overlay(alignment: .bottomTrailing) {
                    if let statusColor {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                            .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                            .offset(x: 2, y: 2)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let shownSubtitle, !shownSubtitle.isEmpty {
                    Text(shownSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(subtitle)")
    }
}

/// Work under way on content already on screen. It floats and ignores touches, so appearing and
/// leaving never moves or blocks what someone is reading.
struct StatusPill: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "arrow.triangle.2.circlepath")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 14).padding(.vertical, 8)
            // Glass would let a large heading show through this small text.
            .background(.regularMaterial, in: .capsule)
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilitySortPriority(1)
    }
}

/// A failure while showing older content. It needs reading, so it takes its own place above the
/// content instead of covering it, offers another try, and can be put away.
struct FailureBar: View {
    let message: String
    let retry: () -> Void
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        // Large text gives the message the whole width, with its actions beneath.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(message).font(.footnote).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                Button(action: retry) {
                    Text("Retry").font(.footnote.weight(.medium))
                        .frame(minHeight: 44).padding(.horizontal, 6).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                Button(action: dismiss) { IconTarget(symbol: "xmark").font(.footnote) }
                    .accessibilityLabel("Dismiss")
                    .buttonStyle(.borderless)
                    .tint(.secondary)
            }
        }
        .padding(.leading, 20).padding(.trailing, 8)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Shows `failure` above the content at once, or `progress` floating over it once the work has
    /// taken long enough to be worth mentioning. VoiceOver users hear about progress at once, since
    /// they can't see that nothing has changed yet, and failures are announced.
    func contentStatus(progress: String?, failure: String?, retry: @escaping () -> Void, delay: Duration = .milliseconds(450)) -> some View {
        modifier(ContentStatusModifier(progress: progress, failure: failure, retry: retry, delay: delay))
    }
}

private struct ContentStatusModifier: ViewModifier {
    let progress: String?
    let failure: String?
    let retry: () -> Void
    let delay: Duration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownProgress: String?
    @State private var dismissedFailure: String?
    private var shownFailure: String? { failure == dismissedFailure ? nil : failure }
    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top, spacing: 0) {
                if let shownFailure {
                    FailureBar(message: shownFailure, retry: retry, dismiss: { dismissedFailure = shownFailure })
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if let shownProgress, shownFailure == nil {
                    StatusPill(message: shownProgress)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(RemoteFilesStyle.statusSpring, value: shownProgress)
            .animation(RemoteFilesStyle.statusSpring, value: shownFailure)
            .task(id: progress) {
                guard let progress else { shownProgress = nil; return }
                if shownProgress == nil, !UIAccessibility.isVoiceOverRunning {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                shownProgress = progress
            }
            .onChange(of: failure) { _, new in
                dismissedFailure = nil
                if let new { UIAccessibility.post(notification: .announcement, argument: new) }
            }
    }
}

/// Stands in for a list or document while its first load runs. Nearly invisible at first, so a load
/// that finishes quickly never flashes, and still spoken at once so VoiceOver knows what's going on.
struct LoadingPlaceholder: View {
    enum Shape { case list, document }
    let label: String
    var shape: Shape = .list
    @State private var visible = false
    /// A wait this long deserves saying what's going on, as connecting can take many seconds.
    @State private var explains = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // VoiceOver's cursor stays where this element was when the content replaces it, so this
            // small line at the top is what it reads, rather than a full-screen element that would
            // leave it in the middle of the document, past the title.
            HStack(spacing: 8) {
                if explains { ProgressView().controlSize(.small).accessibilityHidden(true) }
                Text(label).font(.footnote).foregroundStyle(.secondary)
                    .opacity(explains ? 1 : 0.01)
                    .accessibilityIdentifier(label)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .padding(.horizontal, 20).padding(.top, explains ? 12 : 0)
            .frame(height: explains ? nil : 1, alignment: .top)
            .clipped()
            Group {
                switch shape {
                case .list: listRows
                case .document: documentLines
                }
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .opacity(visible ? 1 : 0.01)
        .animation(.easeIn(duration: 0.2).delay(0.14), value: visible)
        .animation(RemoteFilesStyle.contentFade, value: explains)
        .onAppear { visible = true }
        .task {
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { explains = true }
        }
    }
    private var listRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<10, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: RemoteFilesStyle.iconColumn - 4, height: 20)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(.quaternary).frame(width: Self.width(index), height: 11)
                        if index % 3 != 0 { Capsule().fill(.quinary).frame(width: 96, height: 9) }
                    }
                }
                .padding(.horizontal, 20).frame(height: 56, alignment: .leading)
            }
        }
    }
    private var documentLines: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(.quaternary).frame(width: 220, height: 22).padding(.bottom, 10)
            ForEach(0..<9, id: \.self) { index in
                Capsule().fill(.quinary).frame(maxWidth: index % 4 == 3 ? 200 : .infinity).frame(height: 12)
            }
        }
        .padding(20)
    }
    private static func width(_ index: Int) -> CGFloat { [168, 124, 196, 142, 108, 176][index % 6] }
}

/// The current page, floating over a PDF rather than taking a row from it.
struct PDFPageBadge: View {
    let page: Int
    let count: Int
    var body: some View {
        Text("Page \(page) of \(count)")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityIdentifier("PDF page indicator")
    }
}

/// A title and an icon that a bottom bar shows together, rather than reducing to an icon alone.
struct BarLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).monospacedDigit().lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 6)
    }
}

/// A square tap target for an icon button, whatever size the icon itself is.
struct IconTarget: View {
    let symbol: String
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: symbol).frame(width: size, height: size).contentShape(Rectangle())
    }
}

/// A thin determinate or indeterminate progress line.
struct ThinProgress: View {
    let fraction: Double?
    var body: some View {
        Group {
            if let fraction { ProgressView(value: min(max(fraction, 0), 1)) } else { ProgressView().progressViewStyle(.linear) }
        }
        .tint(RemoteFilesStyle.accent)
        .controlSize(.mini)
    }
}

/// A date that matters only to the day, in the shortest form people read without thinking.
enum QuietDate {
    static func saved(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today, " + date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
#endif
