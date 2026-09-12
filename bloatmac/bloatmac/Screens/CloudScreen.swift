import SwiftUI

struct CloudScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var c = LiveCloud.shared
    @State private var selection: Set<String> = []
    @State private var activeProvider: String? = nil
    @State private var showConfirm = false

    private var visibleInventory: CloudInventory? {
        if let p = activeProvider, let match = c.inventories.first(where: { $0.id == p }) { return match }
        return c.inventories.first
    }

    private var totalSelected: Int64 {
        var b: Int64 = 0
        for inv in c.inventories {
            for item in inv.items where selection.contains(item.id) { b += item.bytes }
        }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if c.scanning && c.inventories.isEmpty {
                loadingState
            } else if !c.hasCompletedScan {
                cancelledState
            } else if c.inventories.isEmpty {
                emptyState
            } else {
                if let error = c.lastError { ActionError(message: error) }
                providerTabs
                Divider()
                if let inv = visibleInventory {
                    if inv.items.isEmpty { noCandidatesState(inv) }
                    else { table(for: inv) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { c.startIfNeeded() }
        .alert("Evict \(selection.count) item\(selection.count == 1 ? "" : "s") from local disk?",
               isPresented: $showConfirm) {
            Button("Evict", role: .destructive) {
                _ = c.evict(selection); selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(formatBytes(totalSelected)) reclaimable. Files stay in iCloud and re-download on demand.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cloud").font(.system(size: 22, weight: .bold))
                if c.scanning {
                    Text(c.phase).font(.system(size: 12)).foregroundStyle(Tokens.text3)
                } else {
                    Text("\(c.inventories.count) provider\(c.inventories.count == 1 ? "" : "s") · \(formatBytes(c.totalDownloadedBytes)) in local review candidates")
                        .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                }
            }
            Spacer()
            if c.scanning {
                ProgressView().controlSize(.small)
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { selection = []; c.scan() }
            }
            if !selection.isEmpty {
                Btn(label: "Evict \(selection.count) (\(formatBytes(totalSelected)))",
                    icon: "icloud.slash", style: .danger) { showConfirm = true }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var providerTabs: some View {
        HStack(spacing: 0) {
            ForEach(c.inventories) { inv in
                let isActive = (activeProvider ?? c.inventories.first?.id) == inv.id
                Button {
                    activeProvider = inv.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: inv.provider.icon).font(.system(size: 12))
                        Text(providerLabel(inv)).font(.system(size: 12, weight: .semibold))
                        Text("· \(formatBytes(inv.downloadedBytes))").font(.system(size: 11)).foregroundStyle(Tokens.text3)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(isActive ? state.accent.value : Tokens.text2)
                    .background(isActive ? Tokens.bgPanel2 : .clear)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(isActive ? state.accent.value : .clear).frame(height: 2)
                    }
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func table(for inv: CloudInventory) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                tableHeader
                Divider()
                ForEach(inv.items) { item in
                    CloudRow(item: item,
                             selected: selection.contains(item.id),
                             canEvict: inv.provider.supportsEviction && item.state == .downloaded,
                             accent: state.accent.value,
                             onToggle: { toggle(item.id) },
                             onReveal: { c.revealInFinder(item.url) })
                    Divider().opacity(0.4)
                }
            }
            if inv.isTruncated {
                Text("Showing the largest \(inv.items.count) of \(inv.totalItemCount) candidates. The total includes all scanned candidates.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                    .padding(.horizontal, 24).padding(.vertical, 8)
            }
        }
        if !inv.provider.supportsEviction {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(Tokens.warn)
                Text("\(inv.provider.displayName) doesn't expose a CLI eviction API. Use the provider's own Finder integration to mark items as online-only.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text2)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(Tokens.warn.opacity(0.08))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 22)
            Text("File").frame(maxWidth: .infinity, alignment: .leading)
            Text("State").frame(width: 100, alignment: .leading)
            Text("Modified").frame(width: 130, alignment: .leading)
            Text("Size").frame(width: 90, alignment: .trailing)
            Color.clear.frame(width: 50)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Tokens.text3)
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Tokens.bgPanel2)
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud").font(.system(size: 32)).foregroundStyle(Tokens.text3)
            Text("No cloud providers detected").font(.system(size: 13, weight: .semibold))
            Text("iCloud Drive, Google Drive, Dropbox, OneDrive, and Box are scanned automatically.")
                .font(.system(size: 12)).foregroundStyle(Tokens.text3).multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Detecting cloud providers and local copies…")
                .font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cancelledState: some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud").font(.system(size: 30)).foregroundStyle(Tokens.text3)
            Text("Cloud scan not completed").font(.system(size: 13, weight: .semibold))
            Text("Re-scan to detect providers and local-copy candidates.")
                .font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noCandidatesState(_ inventory: CloudInventory) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud.and.arrow.down").font(.system(size: 30)).foregroundStyle(Tokens.text3)
            Text("No local copies to review").font(.system(size: 13, weight: .semibold))
            Text("\(providerLabel(inventory)) was detected, but no files of 5 MB or larger are stored locally.")
                .font(.system(size: 12)).foregroundStyle(Tokens.text3).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private func providerLabel(_ inventory: CloudInventory) -> String {
        let sameProvider = c.inventories.filter { $0.provider == inventory.provider }.count
        return sameProvider > 1 ? "\(inventory.provider.displayName) · \(inventory.root.lastPathComponent)" : inventory.provider.displayName
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

private struct CloudRow: View {
    let item: CloudItem
    let selected: Bool
    let canEvict: Bool
    let accent: Color
    let onToggle: () -> Void
    let onReveal: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { selected }, set: { _ in onToggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .frame(width: 22)
                .disabled(!canEvict)
                .accessibilityLabel("Evict local copy of \(item.displayName)")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.text)
                Text(item.url.path).font(.system(size: 10.5))
                    .foregroundStyle(Tokens.text3).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statePill.frame(width: 100, alignment: .leading)
            Text(formatDate(item.modifiedAt)).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                .frame(width: 130, alignment: .leading)
            Text(formatBytes(item.bytes)).font(.system(size: 12, weight: .semibold))
                .frame(width: 90, alignment: .trailing).foregroundStyle(Tokens.text)
            Button { onReveal() } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 13))
            }.buttonStyle(.plain).frame(width: 50).opacity(hovered ? 1 : 0.5)
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(selected ? accent.opacity(0.10) : (hovered ? Tokens.bgPanel2 : .clear))
        .onHover { hovered = $0 }
    }

    private var statePill: some View {
        let (label, color): (String, Color) = {
            switch item.state {
            case .downloaded: return ("downloaded", Tokens.warn)
            case .cloudOnly:  return ("cloud-only", Tokens.text3)
            case .partial:    return ("partial",    Tokens.indigo)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func formatDate(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
