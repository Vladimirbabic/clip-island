import Foundation

/// Pure, testable search/filter logic shared by both apps.
enum ClipSearch {
    /// Returns true when every whitespace-separated token of `query` matches
    /// the item's text, file name, source app name, or kind display name.
    /// Matching is case- and diacritic-insensitive. An empty query matches all.
    static func matches(item: ClipItem, query: String) -> Bool {
        let tokens = tokens(from: query)
        guard !tokens.isEmpty else { return true }

        let haystacks = [
            item.text,
            item.fileName,
            item.sourceAppName,
            item.kind.displayName,
        ].compactMap { $0 }

        return tokens.allSatisfy { token in
            haystacks.contains { haystack in
                haystack.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    static func filter(items: [ClipItem], query: String) -> [ClipItem] {
        let tokens = tokens(from: query)
        guard !tokens.isEmpty else { return items }
        return items.filter { matches(item: $0, query: query) }
    }

    private static func tokens(from query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
