import SwiftUI

struct PrivacyScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var p = LivePrivacy.shared
    @State private var selection: Set<String> = []
    @State private var showConfirm = false

    private var totalSelected: Int64 {
        var b: Int64 = 0
        for t in p.targets {
            for item in t.items where selection.contains(item.id) { b += item.bytes }
        }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if p.targets.isEmpty && !p.scanning {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(p.targets) { t in
                            targetCard(t)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { p.startIfNeeded() }
        .alert("Clear \(selection.count) item\(selection.count == 1 ? "" : "s")?",
               isPresented: $showConfirm) {
            Button("Move to Trash", role: .destructive) {
                _ = p.clean(selection); selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(formatBytes(totalSelected)) reclaimable. The host app will recreate empty databases on next launch.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Privacy").font(.system(size: 22, weight: .bold))
                if p.scanning {
                    Text(p.phase).font(.system(size: 12)).foregroundStyle(Tokens.text3)
                } else {
                    Text("\(p.targets.count) apps · \(formatBytes(p.totalBytes)) total")
                        .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                }
            }
            Spacer()
            if p.scanning {
                ProgressView().controlSize(.small)
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { p.scan() }
            }
            if !selection.isEmpty {
                Btn(label: "Clear \(selection.count) (\(formatBytes(totalSelected)))",
                    icon: "trash", style: .danger) { showConfirm = true }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    @ViewBuilder
    private func targetCard(_ t: PrivacyTarget) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let url = t.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 32, height: 32)
                } else {
                    Image(systemName: t.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(state.accent.value)
                        .background(Circle().fill(Tokens.bgPanel2))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text)
                        if t.isRunning { runningPill }
                    }
                    Text(t.bundleID).font(.system(size: 10.5)).foregroundStyle(Tokens.text3)
                }
                Spacer()
                Text(formatBytes(t.totalBytes))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
            }
            .padding(14)

            if !t.items.isEmpty {
                Divider()
                ForEach(t.items) { item in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { selection.contains(item.id) },
                            set: { on in
                                guard !t.isRunning else { return }
                                if on { selection.insert(item.id) } else { selection.remove(item.id) }
                            }
                        )) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .frame(width: 22)
                        .disabled(t.isRunning)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.kind.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.text)
                            Text(item.path.path).font(.system(size: 10.5))
                                .foregroundStyle(Tokens.text3).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(formatBytes(item.bytes))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    Divider().opacity(0.4)
                }
            }
            if t.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(Tokens.warn)
                    Text("Quit \(t.displayName) before cleaning to avoid corrupting open databases.")
                        .font(.system(size: 11)).foregroundStyle(Tokens.text2)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Tokens.warn.opacity(0.08))
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var runningPill: some View {
        Text("running")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.warn.opacity(0.18)))
            .foregroundStyle(Tokens.warn)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").font(.system(size: 32)).foregroundStyle(Tokens.good)
            Text("No browser or chat data found").font(.system(size: 13, weight: .semibold))
            Text("Click Re-scan to look again.").font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
