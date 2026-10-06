import SwiftUI
import Textual

enum SourceLanguage {
    private static let extensions: [String: String] = [
        "md": "markdown", "markdown": "markdown", "swift": "swift",
        "js": "javascript", "jsx": "jsx", "ts": "typescript", "tsx": "tsx",
        "json": "json", "jsonl": "json", "ndjson": "json", "ipynb": "json",
        "yaml": "yaml", "yml": "yaml", "toml": "toml", "py": "python", "rb": "ruby",
        "sh": "bash", "bash": "bash", "zsh": "bash", "env": "bash", "ps1": "powershell",
        "html": "markup", "htm": "markup", "xml": "markup", "svg": "markup",
        "vue": "markup", "svelte": "markup", "css": "css", "scss": "scss", "less": "less",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "hpp": "cpp", "m": "objectivec", "mm": "objectivec",
        "rs": "rust", "go": "go", "java": "java", "kt": "kotlin", "kts": "kotlin",
        "php": "php", "sql": "sql", "lua": "lua", "dart": "dart", "graphql": "graphql", "gql": "graphql",
        "diff": "diff", "patch": "diff",
    ]
    static func forFilename(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let name = filename.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "docker" }
        if [".bashrc", ".bash_profile", ".zshrc", ".zprofile"].contains(name) { return "bash" }
        if ["cargo.lock", "poetry.lock"].contains(name) { return "toml" }
        return extensions[name.split(separator: ".").last.map(String.init) ?? ""]
    }
}

/// All tokenization, styling and cache bookkeeping are isolated away from MainActor.
actor SourceHighlighting {
    static let shared = SourceHighlighting()
    static let byteLimit = 256 * 1024
    static let tokenLimit = 16_000
    // String equality folds canonically equivalent Unicode. Source bytes must remain exact.
    private struct Key: Hashable { let source: Data; let language: String }
    private struct Cached { let tokens: [SourceCodeToken]; let cost: Int }
    private var cache: [Key: Cached] = [:]
    private var order: [Key] = []
    private var generation = 0
    typealias Tokenizer = @Sendable (String, String) async -> [SourceCodeToken]
    private let tokenize: Tokenizer

    init(tokenize: @escaping Tokenizer = { source, language in
        await SourceCodeTokenization.tokens(for: source, language: language)
    }) {
        self.tokenize = tokenize
    }

    func clear() { generation += 1; cache.removeAll(); order.removeAll() }

    func highlight(_ source: String, language: String?, dark: Bool) async throws -> AttributedString? {
        try Task.checkCancellation()
        guard let language, !source.isEmpty, source.utf8.count <= Self.byteLimit else { return nil }
        let epoch = generation
        let key = Key(source: Data(source.utf8), language: language)
        let tokens: [SourceCodeToken]
        var pendingCache: Cached?
        if let cached = cache[key] {
            tokens = cached.tokens
            order.removeAll { $0 == key }; order.append(key)
        } else {
            tokens = await tokenize(source, language)
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            // Never replace the source with incomplete tokens, and bound attributed-text complexity.
            guard tokens.count <= Self.tokenLimit,
                  tokens.map(\.content).joined().utf8.elementsEqual(source.utf8) else { return nil }
            pendingCache = Cached(tokens: tokens, cost: source.utf8.count * 2 + tokens.count * 80)
        }
        guard tokens.contains(where: { $0.type != .plain }) else { return nil }
        var result = AttributedString()
        for token in tokens {
            try Task.checkCancellation()
            var run = AttributedString(token.content)
            run.foregroundColor = Self.color(token.type.rawValue, dark: dark)
            result.append(run)
        }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        // A request may be cancelled while styling its tokens. Cache only after all
        // publication checks, so discarded work cannot repopulate the token cache.
        if let pendingCache, pendingCache.cost <= 2 * 1024 * 1024 {
            while !order.isEmpty && (order.count >= 2 || cache.values.reduce(pendingCache.cost, { $0 + $1.cost }) > 2 * 1024 * 1024) {
                cache.removeValue(forKey: order.removeFirst())
            }
            cache[key] = pendingCache; order.append(key)
        }
        return result
    }

    private static func color(_ type: String, dark: Bool) -> Color? {
        switch type {
        case "keyword", "builtin", "boolean", "nil", "literal", "atrule", "important":
            return dark ? Color(red: 1, green: 0.48, blue: 0.72) : Color(red: 0.58, green: 0.12, blue: 0.55)
        case "string", "char", "regex", "attr-value", "deleted":
            return dark ? Color(red: 1, green: 0.57, blue: 0.48) : Color(red: 0.68, green: 0.14, blue: 0.09)
        case "number", "constant", "symbol":
            return dark ? Color(red: 0.9, green: 0.8, blue: 0.48) : Color(red: 0.31, green: 0.21, blue: 0.7)
        case "comment", "block-comment", "doc-comment", "prolog", "doctype":
            return dark ? Color(red: 0.62, green: 0.68, blue: 0.72) : Color(red: 0.35, green: 0.4, blue: 0.45)
        case "function", "function-name", "class-name", "tag", "selector", "property", "inserted":
            return dark ? Color(red: 0.48, green: 0.84, blue: 0.77) : Color(red: 0.06, green: 0.4, blue: 0.38)
        case "attr-name", "attribute", "directive", "preprocessor", "url", "title", "bold", "italic":
            return dark ? Color(red: 0.63, green: 0.73, blue: 1) : Color(red: 0.18, green: 0.33, blue: 0.68)
        default: return nil
        }
    }
}

struct SourceCodeView: View {
    let text: String
    let language: String?
    var bounded = false
    var readingPosition: DocumentReadingPosition? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var highlighted: AttributedString?
    @State private var highlightedRequest: Request?
    private struct Request: Equatable {
        let text: String; let language: String?; let dark: Bool
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.language == rhs.language && lhs.dark == rhs.dark && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
    }
    private struct Work: Equatable { let request: Request; let phase: ScenePhase }
    private var request: Request { .init(text: text, language: language, dark: colorScheme == .dark) }

    var body: some View {
        Group {
            #if os(iOS)
            if bounded {
                BoundedSourceTextView(text: text,
                    highlighted: highlightedRequest == request ? highlighted : nil,
                    readingPosition: readingPosition)
            } else { ordinaryText }
            #else
            ordinaryText
            #endif
        }
        .task(id: Work(request: request, phase: scenePhase)) {
            guard scenePhase == .active else { return }
            let input = request
            do {
                let result = try await SourceHighlighting.shared.highlight(input.text, language: input.language, dark: input.dark)
                try Task.checkCancellation()
                highlighted = result; highlightedRequest = input
            } catch is CancellationError { }
            catch { highlighted = nil }
        }
    }

    private var ordinaryText: some View {
        Group {
            if let highlighted, highlightedRequest == request {
                Text(highlighted).accessibilityIdentifier("Syntax highlighted source")
            } else { Text(verbatim: text).accessibilityIdentifier("Source text") }
        }
        .font(.body.monospaced()).foregroundStyle(.primary)
        .textSelection(.enabled).padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
