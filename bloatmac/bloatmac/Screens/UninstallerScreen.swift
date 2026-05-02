import SwiftUI

struct UninstallerScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var u = LiveUninstaller.shared
    @State private var selection: Set<URL> = []
    @State private var showConfirm = false

    private var totalSelected: Int64 {
        u.apps.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.totalBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if u.apps.isEmpty && !u.scanning {
                emptyState
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { u.startIfNeeded() }
        .alert("Uninstall \(selection.count) app\(selection.count == 1 ? "" : "s")?",
               isPresented: $showConfirm) {
            Button("Move to Trash", role: .destructive) {
                u.uninstall(selection)
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(formatBytes(totalSelected)) will be reclaimed (app bundle plus all leftover support data, caches, and preferences).")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Uninstaller").font(.system(size: 22, weight: .bold))
                if u.scanning {
                    Text(u.phase).font(.system(size: 12)).foregroundStyle(Tokens.text3)
                } else {
                    Text("\(u.apps.count) apps · \(formatBytes(u.totalBytes)) total")
                        .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                }
            }
            Spacer()
            if u.scanning {
                ProgressView(value: u.progress).frame(width: 160).tint(state.accent.value)
                Btn(label: "Cancel", icon: "xmark", style: .ghost) { u.cancel() }
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { u.scan() }
            }
            if !selection.isEmpty {
                Btn(label: "Uninstall \(selection.count) (\(formatBytes(totalSelected)))",
                    icon: "trash", style: .danger) {
                    showConfirm = true
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    // MARK: - Table

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                tableHeader
                Divider()
                ForEach(u.apps) { row in
                    UninstallerRow(app: row,
                                   selected: selection.contains(row.id),
                                   accent: state.accent.value,
                                   onToggle: { toggle(row.id) },
                                   onReveal: { u.revealInFinder(row.id) })
                    Divider()
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { !u.apps.isEmpty && selection.count == u.apps.count },
                set: { all in selection = all ? Set(u.apps.map { $0.id }) : [] }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .frame(width: 22)
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Bundle ID").frame(width: 200, alignment: .leading)
            Text("Version").frame(width: 80, alignment: .leading)
            Text("App size").frame(width: 90, alignment: .trailing)
            Text("Leftovers").frame(width: 90, alignment: .trailing)
            Text("Total").frame(width: 90, alignment: .trailing)
            Color.clear.frame(width: 80)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Tokens.text3)
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Tokens.bgPanel2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 32)).foregroundStyle(Tokens.text3)
            Text("No apps detected").font(.system(size: 13, weight: .semibold))
            Text("Click Re-scan to inspect /Applications.").font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ id: URL) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

private struct UninstallerRow: View {
    let app: InstalledApp
    let selected: Bool
    let accent: Color
    let onToggle: () -> Void
    let onReveal: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { selected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .frame(width: 22)
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.id.path))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.displayName).font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                        if app.isSandboxed {
                            Text("sandboxed")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.bgPanel2))
                                .foregroundStyle(Tokens.text3)
                        }
                    }
                    Text(app.id.path).font(.system(size: 10)).foregroundStyle(Tokens.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(app.bundleID).font(.system(size: 11)).foregroundStyle(Tokens.text2)
                .frame(width: 200, alignment: .leading).lineLimit(1)
            Text(app.version).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                .frame(width: 80, alignment: .leading)
            Text(formatBytes(app.appBytes)).font(.system(size: 11, weight: .medium))
                .frame(width: 90, alignment: .trailing).foregroundStyle(Tokens.text2)
            Text(formatBytes(app.leftoverBytes)).font(.system(size: 11, weight: .medium))
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(app.leftoverBytes > 100_000_000 ? Tokens.warn : Tokens.text2)
            Text(formatBytes(app.totalBytes)).font(.system(size: 12, weight: .bold))
                .frame(width: 90, alignment: .trailing).foregroundStyle(Tokens.text)
            Button {
                onReveal()
            } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .frame(width: 80)
            .opacity(hovered ? 1 : 0.5)
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(selected ? accent.opacity(0.10) : (hovered ? Tokens.bgPanel2 : .clear))
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
