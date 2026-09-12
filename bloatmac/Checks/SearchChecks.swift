import Foundation

@main
enum SearchChecks {
    static func main() {
        let memory = SearchEntry(id: "memory", title: "Memory", detail: "Screen", keywords: "RAM processes", screen: "memory", url: nil)
        let file = SearchEntry(id: "file", title: "Memory notes.txt", detail: "Downloads", keywords: "", screen: nil, url: URL(fileURLWithPath: "/tmp/Memory notes.txt"))
        precondition(SearchEntry.matching([file, memory, file], query: "memory").map(\.id) == ["memory", "file"])
        precondition(SearchEntry.matching([memory], query: "RAM processes").count == 1)
        precondition(SearchEntry.matching([memory], query: "   ").isEmpty)
        precondition(SearchEntry.matching([memory], query: "disk").isEmpty)
        print("Search checks passed")
    }
}
