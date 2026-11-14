import Foundation

/// When to show where a link leads before leaving the app.
///
/// A document chooses its links' text, so the text can name one site while the link goes to
/// another: `[https://bank.example](https://evil.example/)`. Most links are honest and open on one
/// tap. One is confirmed first when its text shows an address on a different host, or when it
/// is plain `http`, which anyone on the network can read and change.
public enum ExternalLinkPolicy {
    public struct Destination: Equatable, Sendable {
        public let host: String
        /// The whole address, clipped for display.
        public let address: String
        public let isUnencrypted: Bool
    }

    public static func destination(of url: URL) -> Destination {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let address = url.absoluteString
        return Destination(host: parts?.host ?? "", address: address.count > 300 ? String(address.prefix(300)) + "…" : address,
                           isUnencrypted: parts?.scheme?.lowercased() != "https")
    }

    public static func needsConfirmation(_ url: URL, visibleText: String?) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.scheme?.lowercased() == "https" else { return true }
        guard let visibleText else { return false }
        let shown = hostsShown(in: visibleText)
        guard !shown.isEmpty else { return false }
        func plain(_ name: String) -> String { name.hasPrefix("www.") ? String(name.dropFirst(4)) : name }
        return !shown.contains { plain($0) == plain(host) }
    }

    /// What reads as a web address in a link's text: `https://bank.example/login`,
    /// `www.bank.example` or a bare `bank.example`. A bare name ending like a file, such as
    /// `README.md`, is a file name, which links are often labelled with.
    static func hostsShown(in text: String) -> [String] {
        let lowered = String(text.prefix(2_000)).lowercased()
        let range = NSRange(lowered.startIndex..., in: lowered)
        return pattern.matches(in: lowered, range: range).compactMap { match in
            guard let hostRange = Range(match.range(at: 2), in: lowered) else { return nil }
            let host = String(lowered[hostRange])
            let hasScheme = match.range(at: 1).location != NSNotFound
            if hasScheme || host.hasPrefix("www.") { return host }
            guard let ending = host.split(separator: ".").last, !fileEndings.contains(String(ending)) else { return nil }
            return host
        }
    }

    // Letters of any script: a name written to look like another is not the host the link goes to
    // either, since that host is in its ASCII form.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(https?://)?(?<![\p{L}\p{N}@.-])((?:[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+\p{L}{2,24})(?![\p{L}\p{N}-])"#)
    private static let fileEndings: Set<String> = [
        "md", "markdown", "txt", "pdf", "html", "htm", "json", "yaml", "yml", "toml", "xml", "csv", "log", "conf", "cfg", "ini",
        "swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "cs", "sh", "zsh", "css",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "zip", "gz", "tar", "lock", "plist", "pem", "crt", "key"
    ]

    /// The links in prepared Markdown that should be confirmed, by the text each is shown with.
    public static func linksNeedingConfirmation(in parts: [MarkdownPart]) -> Set<URL> {
        var result = Set<URL>()
        for part in parts {
            guard case .text(let text) = part.content else { continue }
            var current: URL?, shown = ""
            func finish() {
                if let current, DocumentPolicy.allowsExternalLink(current), needsConfirmation(current, visibleText: shown) { result.insert(current) }
            }
            for run in text.runs {
                if run.link != current { finish(); current = run.link; shown = "" }
                if current != nil { shown += String(text[run.range].characters) }
            }
            finish()
        }
        return result
    }
}
