import Foundation
import Combine
import UserNotifications
import SwiftUI

/// In-process scheduler for periodic Smart Care runs. Wakes a Timer at the
/// configured cadence, kicks off `LiveSmartCare.run()`, and (optionally)
/// posts a user notification when the result reclaimable total crosses
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
    @Published var dryRun: Bool {
        didSet { defaults.set(dryRun, forKey: "scheduleDryRun") }
    }
    @Published var notifyOnFinding: Bool {
        didSet { defaults.set(notifyOnFinding, forKey: "scheduleNotify") }
    }
    @Published var notifyThresholdBytes: Int64 {
        didSet { defaults.set(notifyThresholdBytes, forKey: "scheduleThresholdBytes") }
    }
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var notificationsAuthorized: Bool = false

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    private init() {
        let cadenceRaw = defaults.string(forKey: "scheduleCadence") ?? ScheduleCadence.off.rawValue
        cadence = ScheduleCadence(rawValue: cadenceRaw) ?? .off
        // First-run defaults: dryRun on, notify on, 1 GB threshold.
        if defaults.object(forKey: "scheduleDryRun") == nil { defaults.set(true, forKey: "scheduleDryRun") }
        if defaults.object(forKey: "scheduleNotify") == nil { defaults.set(true, forKey: "scheduleNotify") }
        if defaults.object(forKey: "scheduleThresholdBytes") == nil {
            defaults.set(Int64(1_073_741_824), forKey: "scheduleThresholdBytes")
        }
        dryRun = defaults.bool(forKey: "scheduleDryRun")
        notifyOnFinding = defaults.bool(forKey: "scheduleNotify")
        notifyThresholdBytes = Int64(defaults.integer(forKey: "scheduleThresholdBytes"))
        let lastInterval = defaults.double(forKey: "scheduleLastRun")
        lastRunAt = lastInterval > 0 ? Date(timeIntervalSince1970: lastInterval) : nil

        configureTimer()
        Task { await refreshAuthorization() }
    }

    var nextRunAt: Date? {
        guard let interval = cadence.interval else { return nil }
        let base = lastRunAt ?? Date()
        return base.addingTimeInterval(interval)
    }

    func runNow() {
        Task { await runSmartCareAndNotify() }
    }

    // MARK: - Timer

    private func configureTimer() {
        timer?.invalidate()
        guard let interval = cadence.interval else { return }
        let lastRun = lastRunAt ?? .distantPast
        let dueIn = max(60, interval - Date().timeIntervalSince(lastRun))
        timer = Timer.scheduledTimer(withTimeInterval: dueIn, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.runSmartCareAndNotify()
                self.configureTimer()
            }
        }
    }

    private func runSmartCareAndNotify() async {
        await LiveSmartCare.shared.run()
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: "scheduleLastRun")
        lastRunAt = now
        guard notifyOnFinding,
              let result = LiveSmartCare.shared.result,
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
        content.body = "\(bcf.string(fromByteCount: result.cleanableBytes)) reclaimable. Tap to review."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "smartCare-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
