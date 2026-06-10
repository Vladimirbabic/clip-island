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
            item.customTitle,
            item.text,
            item.fileName,
            item.linkTitle,
            item.recognizedText,
            item.sourceAppName,
            item.kind.displayName,
        ].compactMap { $0 }

        return tokens.allSatisfy { token in
            haystacks.contains { haystack in
                haystack.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    static func filter(
        items: [ClipItem],
        query: String,
        filters: ClipSearchFilters = .none,
        now: Date = Date()
    ) -> [ClipItem] {
        let tokens = tokens(from: query)
        guard !tokens.isEmpty || filters.isActive else { return items }
        return items.filter { item in
            (tokens.isEmpty || matches(item: item, query: query))
                && matches(item: item, filters: filters, now: now)
        }
    }

    static func matches(item: ClipItem, filters: ClipSearchFilters, now: Date = Date()) -> Bool {
        if let kind = filters.kind, item.kind != kind { return false }
        if let source = filters.sourceAppName, item.sourceAppName != source { return false }
        if filters.savedOnly, !(item.isPinned || item.pinboard != nil) { return false }
        if filters.pinnedOnly, !item.isPinned { return false }
        if filters.withRecognizedTextOnly {
            let text = item.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { return false }
        }
        return filters.date.contains(item.createdAt, now: now)
    }

    private static func tokens(from query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
