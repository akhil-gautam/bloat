import Foundation
import Combine
import UserNotifications
import SwiftUI

/// In-process scheduler for periodic Smart Care runs. Wakes a Timer at the
/// configured cadence, kicks off `LiveSmartCare.run()`, and (optionally)
/// posts a user notification when the result candidate total crosses
/// `notifyThresholdBytes`.
///
/// This is the "while the app is open" version. A true background daemon
/// that runs even when bloatmac isn't launched needs an `SMAppService`
/// agent target — that lands once Developer ID signing is configured (the
/// agent must be signed with the same team identity).
enum ScheduleCadence: String, CaseIterable, Identifiable {
    case off, hourly, daily, weekly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:    return "Off"
        case .hourly: return "Every hour"
        case .daily:  return "Once a day"
        case .weekly: return "Once a week"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .off:    return nil
        case .hourly: return 3600
        case .daily:  return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        }
    }
}

@MainActor
final class LiveSchedule: ObservableObject {
    static let shared = LiveSchedule()

    // Backed by UserDefaults manually because @AppStorage only works inside
    // SwiftUI Views — accessing it from an ObservableObject silently fails
    // to publish.
    @Published var cadence: ScheduleCadence {
        didSet {
            defaults.set(cadence.rawValue, forKey: "scheduleCadence")
            configureTimer()
        }
    }
    @Published var notifyOnFinding: Bool {
        didSet { defaults.set(notifyOnFinding, forKey: "scheduleNotify") }
    }
    @Published var notifyThresholdBytes: Int64 {
        didSet { defaults.set(notifyThresholdBytes, forKey: "scheduleThresholdBytes") }
    }
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var nextRunAt: Date?
    @Published private(set) var notificationsAuthorized: Bool = false
    @Published private(set) var isRunning: Bool = false

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var started = false

    private init() {
        let cadenceRaw = defaults.string(forKey: "scheduleCadence") ?? ScheduleCadence.off.rawValue
        cadence = ScheduleCadence(rawValue: cadenceRaw) ?? .off
        // Smart Care schedules are scan-only. No cleanup setting is needed.
        if defaults.object(forKey: "scheduleNotify") == nil { defaults.set(true, forKey: "scheduleNotify") }
        if defaults.object(forKey: "scheduleThresholdBytes") == nil {
            defaults.set(Int64(1_000_000_000), forKey: "scheduleThresholdBytes")
        }
        notifyOnFinding = defaults.bool(forKey: "scheduleNotify")
        notifyThresholdBytes = SystemStatusPolicy.normalizedScheduleThreshold(
            Int64(defaults.integer(forKey: "scheduleThresholdBytes"))
        )
        defaults.set(notifyThresholdBytes, forKey: "scheduleThresholdBytes")
        let lastInterval = defaults.double(forKey: "scheduleLastRun")
        lastRunAt = lastInterval > 0 ? Date(timeIntervalSince1970: lastInterval) : nil
        nextRunAt = nil

        Task { await refreshAuthorization() }
    }

    /// Starts the in-process timer. Call once during app launch; schedules do
    /// not run while BloatMac is closed.
    func start() {
        guard !started else { return }
        started = true
        configureTimer()
    }

    func runNow() {
        guard !isRunning else { return }
        Task {
            await runSmartCareAndNotify()
            configureTimer()
        }
    }

    // MARK: - Timer

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        nextRunAt = nil
        guard started, let interval = cadence.interval else { return }
        let lastRun = lastRunAt ?? Date()
        let dueIn = max(60, interval - Date().timeIntervalSince(lastRun))
        nextRunAt = Date().addingTimeInterval(dueIn)
        timer = Timer.scheduledTimer(withTimeInterval: dueIn, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.runSmartCareAndNotify()
                self.configureTimer()
            }
        }
    }

    private func runSmartCareAndNotify() async {
        guard !isRunning, !LiveSmartCare.shared.running else { return }
        isRunning = true
        defer { isRunning = false }
        let previousResultDate = LiveSmartCare.shared.result?.runAt
        await LiveSmartCare.shared.run()
        guard let result = LiveSmartCare.shared.result,
              result.runAt != previousResultDate else { return }
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: "scheduleLastRun")
        lastRunAt = now
        guard notifyOnFinding,
              result.cleanableBytes >= notifyThresholdBytes else { return }
        await postNotification(result: result)
    }

    // MARK: - Notifications

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationsAuthorized = granted
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAuthorized = (settings.authorizationStatus == .authorized
                                || settings.authorizationStatus == .provisional)
    }

    private func postNotification(result: LiveSmartCare.Result) async {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "BloatMac · Smart Care"
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useGB, .useMB]
        bcf.countStyle = .file
        content.body = "\(bcf.string(fromByteCount: result.cleanableBytes)) in review candidates. Tap to review."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "smartCare-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
