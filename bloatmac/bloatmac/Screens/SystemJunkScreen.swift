import SwiftUI

struct SystemJunkScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var j = LiveSystemJunk.shared
    @State private var selection: Set<String> = []
    @State private var expanded: Set<JunkKind> = [.xcode, .iosBackup]
    @State private var showConfirm = false

    private var totalSelected: Int64 {
        var b: Int64 = 0
        for cat in j.categories {
            for item in cat.items where selection.contains(item.id) { b += item.bytes }
        }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if j.categories.isEmpty && !j.scanning {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(j.categories) { cat in
                            categoryCard(cat)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { j.startIfNeeded() }
        .alert("Clean \(selection.count) item\(selection.count == 1 ? "" : "s")?",
               isPresented: $showConfirm) {
            Button("Move to Trash", role: .destructive) {
                _ = j.clean(selection)
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(formatBytes(totalSelected)) will be reclaimed.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Junk").font(.system(size: 22, weight: .bold))
                if j.scanning {
                    Text(j.phase).font(.system(size: 12)).foregroundStyle(Tokens.text3)
                } else {
                    Text("\(j.categories.count) categories · \(formatBytes(j.totalBytes)) total")
                        .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                }
            }
            Spacer()
            if j.scanning {
                ProgressView().controlSize(.small)
                Btn(label: "Cancel", icon: "xmark", style: .ghost) { j.cancel() }
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { j.scan() }
            }
            if !selection.isEmpty {
                Btn(label: "Clean \(selection.count) (\(formatBytes(totalSelected)))",
                    icon: "trash", style: .danger) { showConfirm = true }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    @ViewBuilder
    private func categoryCard(_ cat: JunkCategory) -> some View {
        let isOpen = expanded.contains(cat.id)
        VStack(alignment: .leading, spacing: 0) {
            Button { toggleSection(cat.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: cat.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(state.accent.value)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Tokens.bgPanel2))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(cat.title).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Tokens.text)
                            riskPill(cat.risk)
                        }
                        Text(cat.summary).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(cat.items.count) · \(formatBytes(cat.totalBytes))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.text2)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                }
                .padding(14)
            }.buttonStyle(.plain)

            if isOpen {
                Divider()
                ForEach(cat.items) { item in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { selection.contains(item.id) },
                            set: { on in
                                if on { selection.insert(item.id) }
                                else  { selection.remove(item.id) }
                            }
                        )) { EmptyView() }.toggleStyle(.checkbox).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Tokens.text)
                            Text(item.detail).font(.system(size: 10.5)).foregroundStyle(Tokens.text3)
                        }
                        Spacer()
                        Text(item.bytes > 0 ? formatBytes(item.bytes) : "—")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func riskPill(_ r: JunkRisk) -> some View {
        let (label, color): (String, Color) = {
            switch r {
            case .safe:    return ("safe",    Tokens.good)
            case .caution: return ("caution", Tokens.warn)
            case .risky:   return ("risky",   Tokens.danger)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func toggleSection(_ id: JunkKind) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 32))
                .foregroundStyle(Tokens.good)
            Text("Nothing to clean").font(.system(size: 13, weight: .semibold))
            Text("Click Re-scan to look again.").font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
