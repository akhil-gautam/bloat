import SwiftUI

struct NotifPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveDashboard.shared
    private var recommendations: [DashRecommendation] { live.recommendations.filter { $0.priority > 0 } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recommendations").font(.system(size: 13, weight: .bold))
                Spacer()
                Button("Close") { state.notifOpen = false }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Tokens.text3)
            }.padding(14)
            Divider()
            if recommendations.isEmpty {
              VStack(spacing: 10) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Tokens.text3)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Tokens.bgPanel2))
                Text("No recommendations right now").font(.system(size: 13, weight: .bold))
                Text("Open Dashboard to refresh your Mac's current health and scan suggestions.")
                    .font(.system(size: 11.5)).foregroundStyle(Tokens.text3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("From your latest health snapshot")
                            .font(.system(size: 11)).foregroundStyle(Tokens.text3)
                        ForEach(recommendations) { recommendation in
                            Button { state.goto(recommendation.target) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: recommendation.icon).foregroundStyle(recommendation.tone.color)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recommendation.title).font(.system(size: 12, weight: .semibold))
                                        Text(recommendation.body).font(.system(size: 11)).foregroundStyle(Tokens.text3)
                                        Text(recommendation.actionLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(state.accent.value)
                                    }
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }.padding(14)
                }
            }
        }
        .frame(width: 340, height: 320)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 32, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 36).padding(.trailing, 36)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
    }
}

struct NotifRow: View {
    let notif: AppNotification
    var bg: Color {
        switch notif.kind {
        case "danger": return Tokens.danger
        case "warn":   return Tokens.warn
        case "good":   return Tokens.good
        default:       return Color(hex: 0x0A84FF)
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(bg)
                Text(notif.icon).foregroundStyle(.white).font(.system(size: 13, weight: .bold))
            }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(notif.title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Tokens.text)
                Text(notif.body).font(.system(size: 11.5)).foregroundStyle(Tokens.text3).lineLimit(2)
                HStack(spacing: 8) {
                    Text(notif.time).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tokens.text3)
                    if notif.actionable {
                        Button("Resolve") {}
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.bgPanel2))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tokens.border))
                    }
                }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MenuBarWidgetPopover: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var live = LiveStorage.shared
    var body: some View {
        let pct = live.totalGB > 0 ? live.usedGB / live.totalGB : 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandMark()
                Text("BloatMac").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Tokens.text)
                Spacer()
                Button("Open app ›") { state.widgetOpen = false }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(Tokens.text2)
            }
            HStack(spacing: 12) {
                Ring(value: pct, size: 56, stroke: 6,
                     color: pct > 0.85 ? Tokens.danger : pct > 0.7 ? Tokens.warn : Tokens.good,
                     label: "\(Int((pct * 100).rounded()))%")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storage")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                    Text("\(Int(live.usedGB.rounded())) GB used")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Tokens.text)
                    Text("\(Int(live.freeGB.rounded())) GB free")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.text3)
                }
                Spacer()
            }.padding(.top, 12)
            Btn(label: "Open Storage", icon: "internaldrive", style: .primary) {
                state.widgetOpen = false
                state.goto(.storage)
            }
            .padding(.top, 12)
        }
        .padding(14)
        .frame(width: 280)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.30), radius: 28, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 64).padding(.trailing, 60)
    }
}

struct PermissionsGate: View {
    @EnvironmentObject var state: AppState

    private var fdaURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { /* swallow — modal */ }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(state.accent.value)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grant Full Disk Access").font(.system(size: 17, weight: .bold))
                        Text("BloatMac needs it to scan caches, mail, browser history, and other system-protected locations.")
                            .font(.system(size: 12)).foregroundStyle(Tokens.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    StepRow(num: 1, text: "Click **Open System Settings** below.")
                    StepRow(num: 2, text: "Find **BloatMac** in the list and toggle it on.")
                    StepRow(num: 3, text: "Return here — the gate will close automatically.")
                }
                .font(.system(size: 12)).foregroundStyle(Tokens.text2)

                HStack(spacing: 10) {
                    Btn(label: "Open System Settings", icon: "gearshape", style: .primary) {
                        NSWorkspace.shared.open(fdaURL)
                    }
                    Btn(label: "Re-check now", icon: "arrow.clockwise", style: .ghost) {
                        state.refreshPermissions()
                    }
                    Spacer()
                    Button("Skip for now") { state.dismissPermissionsGate() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                }
            }
            .padding(22)
            .frame(width: 480)
            .background(Tokens.bgPanel)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tokens.border))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 32, y: 12)
        }
    }
}

private struct StepRow: View {
    let num: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Tokens.bgPanel2))
                .overlay(Circle().stroke(Tokens.border))
            Text(.init(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Onboarding: View {
    @EnvironmentObject var state: AppState
    @State private var progress: Double = 0
    @State private var phase: String = "Review storage and large files"
    private let phases = [
        "Review storage and large files",
        "Find caches and duplicate candidates",
        "Check memory, battery, and network",
        "Choose what to keep before moving anything to Trash",
        "Ready — choose a screen to start scanning",
    ]
    var body: some View {
        ZStack {
            Tokens.bgWindow.ignoresSafeArea()
            VStack(spacing: 24) {
                BrandMark().scaleEffect(2.4).padding(.bottom, 8)
                Text("Welcome to BloatMac").font(.system(size: 22, weight: .bold))
                Text(phase).font(.system(size: 13)).foregroundStyle(Tokens.text3)
                Text("A quick tour. No files are changed.").font(.system(size: 11)).foregroundStyle(Tokens.text3)
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 280).tint(state.accent.value)
                Button("Skip") { state.dismissOnboarding() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
        }
        .task { await runScan() }
    }
    private func runScan() async {
        for (i, p) in phases.enumerated() {
            if Task.isCancelled { return }
            phase = p
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeOut(duration: 0.6)) {
                progress = Double(i + 1) / Double(phases.count)
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        state.dismissOnboarding()
    }
}
