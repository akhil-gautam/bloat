import SwiftUI

struct DiskHealthScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var d = LiveDiskHealth.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if d.volumes.isEmpty && !d.scanning { emptyState }
                    summaryCard
                    ForEach(d.volumes) { volume in
                        volumeCard(volume)
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { d.startIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Disk Health").font(.system(size: 22, weight: .bold))
                Text("\(d.volumes.count) volumes · \(d.localSnapshotCount) local APFS snapshots")
                    .font(.system(size: 12)).foregroundStyle(Tokens.text3)
            }
            Spacer()
            if d.scanning {
                ProgressView().controlSize(.small)
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { d.scan() }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var summaryCard: some View {
        let allHealthy = d.volumes.allSatisfy { $0.smartStatus == "Verified" || $0.smartStatus == "Not Supported" }
        return HStack(spacing: 14) {
            Image(systemName: allHealthy ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 26))
                .foregroundStyle(allHealthy ? Tokens.good : Tokens.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(allHealthy ? "All volumes report healthy" : "Volume needs attention")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text)
                Text("SMART verified across reporting volumes. Local APFS snapshots: \(d.localSnapshotCount).")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            Spacer()
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func volumeCard(_ v: DiskVolume) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: v.isInternal ? "internaldrive" : "externaldrive")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.accent.value)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tokens.bgPanel2))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(v.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.text)
                        if v.isSystem { systemPill }
                        if v.isEncrypted { encryptedPill }
                    }
                    Text("\(v.id) · \(v.format) \(v.mountPoint.isEmpty ? "(unmounted)" : "· \(v.mountPoint)")")
                        .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                }
                Spacer()
                smartPill(v.smartStatus)
            }

            // Capacity bar
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Tokens.bgPanel2)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(v.usedPct > 0.85 ? Tokens.danger : v.usedPct > 0.70 ? Tokens.warn : state.accent.value)
                            .frame(width: geo.size.width * CGFloat(v.usedPct))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("\(formatBytes(v.usedBytes)) of \(formatBytes(v.totalBytes)) used")
                        .font(.system(size: 11)).foregroundStyle(Tokens.text2)
                    Spacer()
                    Text("\(formatBytes(v.freeBytes)) free")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text)
                }
            }
        }
        .padding(14)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var systemPill: some View {
        Text("system")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(state.accent.value.opacity(0.18)))
            .foregroundStyle(state.accent.value)
    }

    private var encryptedPill: some View {
        Text("encrypted")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.good.opacity(0.18)))
            .foregroundStyle(Tokens.good)
    }

    private func smartPill(_ status: String) -> some View {
        let color: Color = (status == "Verified") ? Tokens.good
                         : (status == "Not Supported") ? Tokens.text3
                         : Tokens.danger
        return Text(status)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "internaldrive").font(.system(size: 32)).foregroundStyle(Tokens.text3)
            Text("No volumes detected").font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
