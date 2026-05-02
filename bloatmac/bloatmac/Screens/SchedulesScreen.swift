import SwiftUI

struct SchedulesScreen: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var sched = LiveSchedule.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                cadenceCard
                notificationCard
                statusCard
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.bgWindow)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Schedules").font(.system(size: 22, weight: .bold))
            Text("Run Smart Care automatically and get a notification when reclaimable bytes cross a threshold.")
                .font(.system(size: 12)).foregroundStyle(Tokens.text3)
        }
    }

    private var cadenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How often").font(.system(size: 13, weight: .bold))
            HStack(spacing: 8) {
                ForEach(ScheduleCadence.allCases) { c in
                    Button {
                        sched.cadence = c
                    } label: {
                        Text(c.label)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(c == sched.cadence
                                        ? state.accent.value.opacity(0.18)
                                        : Tokens.bgPanel2)
                            .foregroundStyle(c == sched.cadence
                                             ? state.accent.value
                                             : Tokens.text2)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            HStack {
                Toggle("Dry-run only (don't trash anything)", isOn: $sched.dryRun)
                    .toggleStyle(.switch)
                Spacer()
            }
            .font(.system(size: 12))
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications").font(.system(size: 13, weight: .bold))
                Spacer()
                if sched.notificationsAuthorized {
                    Text("authorized").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Tokens.good)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.good.opacity(0.15)))
                } else {
                    Btn(label: "Request access", icon: "bell.badge", style: .ghost) {
                        Task { await sched.requestAuthorization() }
                    }
                }
            }
            HStack {
                Toggle("Notify when reclaimable crosses threshold", isOn: $sched.notifyOnFinding)
                    .toggleStyle(.switch)
                Spacer()
            }
            .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text("Threshold")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.text3)
                HStack(spacing: 8) {
                    ForEach([Int64(500_000_000), Int64(1_073_741_824), Int64(5_368_709_120)], id: \.self) { v in
                        Button {
                            sched.notifyThresholdBytes = v
                        } label: {
                            Text(formatBytes(v))
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(sched.notifyThresholdBytes == v
                                            ? state.accent.value.opacity(0.15)
                                            : Tokens.bgPanel2)
                                .foregroundStyle(sched.notifyThresholdBytes == v
                                                 ? state.accent.value
                                                 : Tokens.text3)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status").font(.system(size: 13, weight: .bold))
            HStack {
                statusRow("Last run", sched.lastRunAt.map { fmt($0) } ?? "Never")
                Spacer()
                statusRow("Next run", sched.nextRunAt.map { fmt($0) } ?? "—")
            }
            HStack {
                Btn(label: "Run now", icon: "play.fill", style: .primary) { sched.runNow() }
                Spacer()
            }
        }
        .padding(16)
        .background(Tokens.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.text3)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text)
        }
    }

    private func fmt(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
