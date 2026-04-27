import SwiftUI

struct Topbar: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Bool = false
    @FocusState private var searchFocused: Bool

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
                    Text(LiveStorage.shared.usedPctText)
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
                    let unread = MockData.shared.notifications.filter { $0.actionable }.count
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Tokens.danger))
                            .offset(x: 6, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Notifications")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Tokens.bgWindow)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Tokens.border), alignment: .bottom)
        .onChange(of: state.searchFocusToken) { _, _ in
            editing = true
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        if editing {
            activeField
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Button {
            editing = true
            DispatchQueue.main.async { searchFocused = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                Text(state.searchQuery.isEmpty ? "Search files, apps, settings…" : state.searchQuery)
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
            TextField("Search files, apps, settings…", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .accessibilityLabel("Search")
                .onSubmit {
                    searchFocused = false
                    editing = false
                }
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
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(minWidth: 220)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(state.accent.value, lineWidth: 1))
        .onChange(of: searchFocused) { _, focused in
            if !focused { editing = false }
        }
    }
}
