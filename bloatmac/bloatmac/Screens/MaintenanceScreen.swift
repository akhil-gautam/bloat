import SwiftUI

struct MaintenanceScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var m = LiveMaintenance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            helperBanner
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(m.actions) { action in
                        actionCard(action)
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bgWindow)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Maintenance").font(.system(size: 22, weight: .bold))
                Text("System routines that keep macOS sharp.")
                    .font(.system(size: 12)).foregroundStyle(Tokens.text3)
            }
            Spacer()
            Btn(label: "Run all available", icon: "play.fill", style: .primary) { m.runAll() }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var helperBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(Tokens.text3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Root actions prompt for your admin password")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text)
                Text("RAM purge, DNS flush, mdutil reindex, and periodic scripts pop a single TouchID/password prompt per click and run as root.")
                    .font(.system(size: 11)).foregroundStyle(Tokens.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Tokens.bgPanel2)
    }

    @ViewBuilder
    private func actionCard(_ a: MaintenanceAction) -> some View {
        let disabled = false   // historic: was `a.requiresHelper && !m.helperAvailable`
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                statusDot(a.status, disabled: disabled)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(a.title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(disabled ? Tokens.text3 : Tokens.text)
                        if a.requiresHelper { rootPill }
                    }
                    Text(a.detail).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        .lineLimit(2)
                    if let last = a.lastRunAt {
                        Text("Last run: \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10.5)).foregroundStyle(Tokens.text3)
                    }
                }
                Spacer()
                if a.status == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Btn(label: "Run", icon: "play", style: .ghost) { m.run(a.id) }
                        .disabled(disabled)
                        .opacity(disabled ? 0.5 : 1)
                }
            }
            .padding(14)
            if !a.output.isEmpty {
                Divider()
                ScrollView {
                    Text(a.output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Tokens.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 120)
                .background(Tokens.bgPanel2)
            }
        }
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusDot(_ s: MaintenanceStatus, disabled: Bool) -> some View {
        let color: Color = {
            if disabled { return Tokens.text3 }
            switch s {
            case .idle:    return Tokens.text3
            case .running: return state.accent.value
            case .success: return Tokens.good
            case .failed:  return Tokens.danger
            }
        }()
        return Circle().fill(color).frame(width: 9, height: 9)
    }

    private var rootPill: some View {
        Text("root")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.danger.opacity(0.15)))
            .foregroundStyle(Tokens.danger)
    }
}
