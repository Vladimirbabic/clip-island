import Foundation

/// Minimal Open Graph extraction for link previews: finds the page's
/// `og:image` (or `twitter:image`) URL in raw HTML. Used as a fallback when
/// LinkPresentation returns metadata without an image provider.
enum OpenGraphParser {
    /// Meta keys that may carry the preview image, in preference order.
    private static let imageKeys = "og:image(?::secure_url)?|twitter:image(?::src)?"

    /// `<meta property="og:image" content="...">` in either attribute order.
    private static let patterns: [NSRegularExpression] = {
        let attribute = "(?:property|name)\\s*=\\s*[\"'](?:\(imageKeys))[\"']"
        let content = "content\\s*=\\s*[\"']([^\"']+)[\"']"
        return [
            "<meta[^>]+\(attribute)[^>]*\(content)",
            "<meta[^>]+\(content)[^>]*\(attribute)",
        ].compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    static func imageURL(inHTML html: String, baseURL: URL) -> URL? {
        let range = NSRange(html.startIndex..., in: html)
        for pattern in patterns {
            guard
                let match = pattern.firstMatch(in: html, options: [], range: range),
                match.numberOfRanges > 1,
                let contentRange = Range(match.range(at: 1), in: html)
            else { continue }
            let raw = String(html[contentRange])
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let url = URL(string: raw, relativeTo: baseURL) else { continue }
            return url.absoluteURL
        }
        return nil
    }
}
