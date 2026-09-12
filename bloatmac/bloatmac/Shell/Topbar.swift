import SwiftUI

struct Topbar: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Bool = false
    @FocusState private var searchFocused: Bool
    @State private var highlighted = 0
    @ObservedObject private var storage = LiveStorage.shared
    @ObservedObject private var dashboard = LiveDashboard.shared
    @ObservedObject private var files = LiveLargeFiles.shared
    @ObservedObject private var downloads = LiveDownloadsCache.shared
    @ObservedObject private var applications = LiveUninstaller.shared

    private var results: [SearchEntry] {
        let aliases: [Screen: String] = [
            .memory: "RAM processes pressure quit", .startup: "login agents launch daemons",
            .downloads: "downloads cache installers OCR", .duplicates: "similar photos copies",
            .settings: "appearance theme accent permissions", .dashboard: "health briefing intelligence AI",
            .analytics: "history charts trends intelligence AI", .maintenance: "DNS Spotlight disk repair",
            .diskHealth: "SMART volumes APFS", .smartcare: "scan cleanup recommendations"
        ]
        var entries = Screen.allCases.map {
            SearchEntry(id: "screen-\($0.rawValue)", title: $0.title, detail: "Open screen",
                        keywords: aliases[$0] ?? "", screen: $0.rawValue, url: nil)
        }
        entries += files.items.map { SearchEntry(id: $0.id.path, title: $0.name, detail: $0.parent, keywords: "file", screen: nil, url: $0.id) }
        entries += downloads.downloads.map { SearchEntry(id: $0.id.path, title: $0.name, detail: "Downloads · Reveal in Finder", keywords: $0.kind, screen: nil, url: $0.id) }
        entries += applications.apps.map { SearchEntry(id: $0.id.path, title: $0.displayName, detail: "Application · Reveal in Finder", keywords: $0.bundleID, screen: nil, url: $0.id) }
        return Array(SearchEntry.matching(entries, query: state.searchQuery).prefix(12))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(state.current.title).font(.system(size: 13.5, weight: .semibold)).tracking(-0.1).foregroundStyle(Tokens.text)
            Rectangle().fill(Tokens.border).frame(width: 1, height: 16)
            Text("Macintosh HD").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.text3)
            Spacer()

            searchBar

            Button { state.toggleWidget() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive").font(.system(size: 11, weight: .semibold))
                    Text(storage.usedPctText)
                        .font(.system(size: 11, weight: .bold)).monospacedDigit()
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
                .foregroundStyle(Tokens.text2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Storage widget")

            Button { state.toggleNotif() } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell").font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
                        .foregroundStyle(Tokens.text2)
                    let count = dashboard.recommendations.filter { $0.priority > 0 }.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Tokens.danger))
                            .offset(x: 6, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recommendations")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Tokens.bgWindow)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Tokens.border), alignment: .bottom)
        .onChange(of: state.searchFocusToken) { _, _ in
            editing = true
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: state.searchQuery) { _, _ in highlighted = 0 }
        .onChange(of: state.current) { _, _ in closeSearch() }
    }

    @ViewBuilder
    private var searchBar: some View {
        Group {
            if editing { activeField } else { placeholder }
        }
        .overlay(alignment: .topLeading) {
            if editing && !state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if results.isEmpty {
                        Text("No matching screens or scanned items")
                            .font(.system(size: 12, weight: .medium)).padding(8)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            Button { openResult(entry) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.screen == nil ? "doc" : "rectangle.grid.1x2")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        Text(entry.detail).font(.system(size: 10.5)).foregroundStyle(Tokens.text3).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: entry.screen == nil ? "arrow.up.right.square" : "arrow.right")
                                }
                                .padding(8).contentShape(Rectangle())
                                .background(index == highlighted ? Tokens.bgSelected : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(entry.title), \(entry.detail)")
                        }
                    }
                    Divider()
                    Text("Screens and already-scanned items · ↑↓ select · Return open · Esc close")
                        .font(.system(size: 10)).foregroundStyle(Tokens.text3).padding(6)
                }
                .padding(6).foregroundStyle(Tokens.text)
                .background(Tokens.bgPanel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tokens.border))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .offset(y: 34)
            }
        }
    }

    private var placeholder: some View {
        Button {
            editing = true
            DispatchQueue.main.async { searchFocused = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                Text(state.searchQuery.isEmpty ? "Search screens and scanned items…" : state.searchQuery)
                    .font(.system(size: 12))
                    .foregroundStyle(state.searchQuery.isEmpty ? Tokens.text3 : Tokens.text)
                    .lineLimit(1)
                Spacer()
                Text("⌘K").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Tokens.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minWidth: 220)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open search")
    }

    private var activeField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
            TextField("Search screens and scanned items…", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .accessibilityLabel("Search")
                .onSubmit {
                    if !results.isEmpty { openResult(results[min(highlighted, results.count - 1)]) }
                }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, results.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                .onExitCommand {
                    state.searchQuery = ""
                    searchFocused = false
                    editing = false
                }
            if !state.searchQuery.isEmpty {
                Button {
                    state.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(minWidth: 220)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(state.accent.value, lineWidth: 1))
    }

    private func closeSearch() {
        searchFocused = false
        editing = false
        state.searchQuery = ""
    }

    private func openResult(_ entry: SearchEntry) {
        closeSearch()
        if let raw = entry.screen, let screen = Screen(rawValue: raw) { state.goto(screen) }
        else if let url = entry.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
