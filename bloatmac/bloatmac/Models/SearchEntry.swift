import Foundation

struct SearchEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let keywords: String
    let screen: String?
    let url: URL?

    static func matching(_ entries: [SearchEntry], query: String) -> [SearchEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        return entries.filter { entry in
            let text = "\(entry.title) \(entry.detail) \(entry.keywords)"
            return words.allSatisfy { text.localizedStandardContains($0) }
                && seen.insert(entry.id).inserted
        }.sorted { lhs, rhs in
            let left = lhs.title.localizedStandardContains(query)
            let right = rhs.title.localizedStandardContains(query)
            if left != right { return left }
            if (lhs.screen != nil) != (rhs.screen != nil) { return lhs.screen != nil }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
