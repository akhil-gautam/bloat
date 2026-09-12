import SwiftUI

struct UpdaterScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var u = LiveUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sourceBanner
            if let error = u.lastError { ActionError(message: error) }
            if u.scanning && u.candidates.isEmpty {
                loadingState
            } else if u.candidates.isEmpty {
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
        let labels: [(String, UpdateSourceState)] = [
            ("Homebrew", u.brewState),
            ("Mac App Store (mas-cli)", u.masState),
            ("Sparkle feeds", u.sparkleState),
        ]
        HStack(spacing: 14) {
            ForEach(labels, id: \.0) { label, sourceState in
                HStack(spacing: 6) {
                    Circle()
                        .fill(sourceColor(sourceState))
                        .frame(width: 8, height: 8)
                    Text("\(label) · \(sourceLabel(sourceState))").font(.system(size: 11)).foregroundStyle(Tokens.text2)
                }
            }
            if u.brewState == .unavailable {
                Text("Install Homebrew to detect cask updates.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            if u.masState == .unavailable {
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
        let checked = [u.brewState, u.masState, u.sparkleState].contains(.available)
        return VStack(spacing: 8) {
            Image(systemName: checked ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(checked ? Tokens.good : Tokens.text3)
            Text(checked ? "No updates found" : "No update source completed")
                .font(.system(size: 13, weight: .semibold))
            Text(checked ? "Checked available sources. Re-scan to check again." : "Review the source status above, then try again.")
                .font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Checking installed update sources…").font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceLabel(_ sourceState: UpdateSourceState) -> String {
        switch sourceState {
        case .checking: return "checking"
        case .available: return "checked"
        case .unavailable: return "not installed"
        case .failed: return "failed"
        }
    }

    private func sourceColor(_ sourceState: UpdateSourceState) -> Color {
        switch sourceState {
        case .checking: return state.accent.value
        case .available: return Tokens.good
        case .unavailable: return Tokens.text4
        case .failed: return Tokens.danger
        }
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
