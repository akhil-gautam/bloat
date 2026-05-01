import SwiftUI

struct SmartCareScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var care = LiveSmartCare.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if care.running { progressPanel }
                if let r = care.result, !care.running { resultPanel(r) }
                if care.result == nil && !care.running { idlePanel }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.bgWindow)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Smart Care").font(.system(size: 26, weight: .bold))
                Text("One scan covers storage, caches, duplicates, startup items, and memory. Apply individual recommendations or trigger a full clean.")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.text3)
                    .frame(maxWidth: 540, alignment: .leading)
                HStack(spacing: 10) {
                    Btn(label: care.running ? "Scanning…" : "Run Smart Care",
                        icon: care.running ? "hourglass" : "sparkles",
                        style: .primary) {
                        if !care.running {
                            Task { await care.run() }
                        }
                    }
                    if care.running {
                        Btn(label: "Cancel", icon: "xmark", style: .ghost) {
                            care.cancel()
                        }
                    } else if care.result != nil {
                        Btn(label: "Re-scan", icon: "arrow.clockwise", style: .ghost) {
                            Task { await care.run() }
                        }
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Progress

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(care.step.label).font(.system(size: 14, weight: .semibold))
            ProgressView(value: care.progress).progressViewStyle(.linear).tint(state.accent.value)
            Text("\(Int(care.progress * 100))%")
                .font(.system(size: 11)).foregroundStyle(Tokens.text3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Result

    @ViewBuilder
    private func resultPanel(_ r: LiveSmartCare.Result) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Big number — total reclaimable
            VStack(alignment: .leading, spacing: 6) {
                Text("Reclaimable")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                Text(formatGB(r.cleanableBytes))
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(state.accent.value)
                Text(r.runAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            .padding(20)
            .frame(width: 240, alignment: .leading)
            .background(Tokens.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Quick stats
            VStack(spacing: 0) {
                statRow("Caches",     formatGB(r.cacheBytes),     icon: "tray.full")
                Divider()
                statRow("Downloads",  formatGB(r.downloadBytes),  icon: "arrow.down.circle")
                Divider()
                statRow("Duplicates", formatGB(r.duplicateBytes), icon: "doc.on.doc")
                Divider()
                statRow("Startup risk", "\(r.flaggedStartup) flagged", icon: "powerplug")
                Divider()
                statRow("Memory", pressureText(r.memoryPressure), icon: "memorychip")
                Divider()
                statRow("Storage", "\(Int((r.storagePct * 100).rounded()))% used", icon: "internaldrive")
            }
            .frame(maxWidth: .infinity)
            .background(Tokens.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if !r.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recommendations")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tokens.text)
                ForEach(r.recommendations) { rec in
                    recommendationRow(rec)
                }
            }
            .padding(.top, 6)
        } else {
            Text("Nothing actionable right now — your Mac is in good shape.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.text3)
                .padding(.top, 6)
        }
    }

    private func statRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.text3)
                .frame(width: 18)
            Text(label).font(.system(size: 12)).foregroundStyle(Tokens.text2)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func recommendationRow(_ r: LiveSmartCare.Recommendation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: r.module))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state.accent.value)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Tokens.bgPanel2))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.text)
                Text(r.detail).font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
            }
            Spacer()
            Btn(label: r.actionLabel, icon: "arrow.right", style: .ghost) {
                state.goto(screenFor(r.module))
            }
        }
        .padding(12)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Idle

    private var idlePanel: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(state.accent.value)
            VStack(alignment: .leading, spacing: 4) {
                Text("Run a scan to see what's reclaimable").font(.system(size: 14, weight: .semibold))
                Text("Takes about a minute on most Macs.").font(.system(size: 12)).foregroundStyle(Tokens.text3)
            }
            Spacer()
        }
        .padding(18)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Format helpers

    private func formatGB(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func pressureText(_ p: MemoryPressure) -> String {
        switch p {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    private func icon(for m: LiveSmartCare.RecModule) -> String {
        switch m {
        case .caches:     return "tray.full"
        case .downloads:  return "arrow.down.circle"
        case .duplicates: return "doc.on.doc"
        case .startup:    return "powerplug"
        case .memory:     return "memorychip"
        case .storage:    return "internaldrive"
        }
    }

    private func screenFor(_ m: LiveSmartCare.RecModule) -> Screen {
        switch m {
        case .caches, .downloads: return .downloads
        case .duplicates:         return .duplicates
        case .startup:            return .startup
        case .memory:             return .memory
        case .storage:            return .storage
        }
    }
}
