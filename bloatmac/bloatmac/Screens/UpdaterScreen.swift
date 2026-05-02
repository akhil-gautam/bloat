import SwiftUI

struct UpdaterScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var u = LiveUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sourceBanner
            if u.candidates.isEmpty && !u.scanning {
                emptyState
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
        .task { u.startIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Updater").font(.system(size: 22, weight: .bold))
                if u.scanning {
                    Text(u.phase).font(.system(size: 12)).foregroundStyle(Tokens.text3)
                } else {
                    Text("\(u.candidates.count) update\(u.candidates.count == 1 ? "" : "s") available")
                        .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                }
            }
            Spacer()
            if u.scanning {
                ProgressView(value: u.progress).frame(width: 160).tint(state.accent.value)
                Btn(label: "Cancel", icon: "xmark", style: .ghost) { u.cancel() }
            } else {
                Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) { u.scan() }
                if u.candidates.contains(where: { $0.source == .brew }) {
                    Btn(label: "Upgrade all (brew)", icon: "arrow.up.circle", style: .primary) {
                        u.upgradeAllBrew()
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    @ViewBuilder
    private var sourceBanner: some View {
        let labels: [(String, Bool)] = [
            ("Homebrew", u.brewAvailable),
            ("Mac App Store (mas-cli)", u.masAvailable),
            ("Sparkle feeds", true),
        ]
        HStack(spacing: 14) {
            ForEach(labels, id: \.0) { label, ok in
                HStack(spacing: 6) {
                    Circle()
                        .fill(ok ? Tokens.good : Tokens.text4)
                        .frame(width: 8, height: 8)
                    Text(label).font(.system(size: 11)).foregroundStyle(Tokens.text2)
                }
            }
            if !u.brewAvailable {
                Text("Install Homebrew to detect cask updates.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            if !u.masAvailable {
                Text("Install mas-cli (`brew install mas`) for Mac App Store updates.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Tokens.bgPanel2)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                tableHeader
                Divider()
                ForEach(u.candidates) { row in
                    UpdateRow(c: row, accent: state.accent.value) { u.upgrade(row) }
                    Divider()
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("Source").frame(width: 90, alignment: .leading)
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Installed").frame(width: 110, alignment: .leading)
            Text("Latest").frame(width: 110, alignment: .leading)
            Color.clear.frame(width: 100)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Tokens.text3)
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Tokens.bgPanel2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Tokens.good)
            Text("Everything is up to date").font(.system(size: 13, weight: .semibold))
            Text("Click Re-scan to check again.").font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UpdateRow: View {
    let c: UpdateCandidate
    let accent: Color
    let onUpgrade: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            sourcePill
                .frame(width: 90, alignment: .leading)
            HStack(spacing: 8) {
                if let appURL = c.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: c.source == .brew ? "shippingbox" : "bag")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Tokens.text3)
                }
                Text(c.name).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(c.installed).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                .frame(width: 110, alignment: .leading)
            Text(c.latest).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 110, alignment: .leading)
            Btn(label: "Update", icon: "arrow.up.circle", style: .ghost, action: onUpgrade)
                .frame(width: 100)
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(hovered ? Tokens.bgPanel2 : .clear)
        .onHover { hovered = $0 }
    }

    private var sourcePill: some View {
        let (label, color): (String, Color) = {
            switch c.source {
            case .brew:    return ("brew",    Tokens.warn)
            case .mas:     return ("MAS",     Tokens.good)
            case .sparkle: return ("Sparkle", Tokens.indigo)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
