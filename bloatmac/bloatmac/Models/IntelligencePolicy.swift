import Foundation

#if canImport(FoundationModels) && !INTELLIGENCE_POLICY_CHECK
import FoundationModels
#endif

struct GroundedFact: Equatable, Sendable {
    let id: String
    let text: String
}

struct ObservationCoverage: Equatable, Sendable {
    let count: Int
    let first: TimeInterval?
    let last: TimeInterval?

    init(timestamps: [TimeInterval]) {
        let ordered = timestamps.sorted()
        count = ordered.count
        first = ordered.first
        last = ordered.last
    }

    var duration: TimeInterval {
        guard let first, let last else { return 0 }
        return max(0, last - first)
    }

    var canPlot: Bool { count >= 2 && duration > 0 }

    var summary: String {
        guard count > 0 else { return "no samples" }
        guard duration > 0 else { return count == 1 ? "1 sample" : "\(count) samples at one point in time" }
        if duration < 60 { return "\(count) samples over less than a minute" }
        if duration < 3600 { return "\(count) samples over \(Int(duration / 60)) min" }
        if duration < 86400 { return "\(count) samples over \(String(format: "%.1f", duration / 3600)) hr" }
        return "\(count) samples over \(String(format: "%.1f", duration / 86400)) days"
    }

    static func canCompare(previous: [TimeInterval], current: [TimeInterval]) -> Bool {
        let previousCoverage = ObservationCoverage(timestamps: previous)
        let currentCoverage = ObservationCoverage(timestamps: current)
        return previousCoverage.count >= 3 && previousCoverage.duration >= 300
            && currentCoverage.count >= 3 && currentCoverage.duration >= 300
    }
}

enum IntelligenceStatus: Equatable, Sendable {
    case rules
    case generating
    case generated
    case unavailable(String)
    case failed(String)

    var label: String {
        switch self {
        case .rules: "On-device rules"
        case .generating: "Apple Intelligence…"
        case .generated: "Apple Intelligence"
        case .unavailable: "On-device rules"
        case .failed: "On-device rules"
        }
    }

    var detail: String {
        switch self {
        case .rules: "A deterministic summary of current measurements."
        case .generating: "Apple Intelligence is ranking measured facts on this Mac."
        case .generated: "Apple Intelligence ranked measured facts; BloatMac rendered the wording and numbers."
        case .unavailable(let reason): reason
        case .failed(let reason): reason
        }
    }
}

struct IntelligenceReadiness: Equatable, Sendable {
    let available: Bool
    let label: String
    let detail: String
}

enum IntelligencePolicy {
    static func fingerprint(for facts: [GroundedFact]) -> String {
        facts.map { "\($0.id)\u{1f}\($0.text)" }.joined(separator: "\u{1e}")
    }

    static func rankingFingerprint(for facts: [GroundedFact]) -> String {
        facts.map(\.id).joined(separator: "\u{1e}")
    }

    static func groundedText(
        selectedIDs: [String],
        facts: [GroundedFact],
        limit: Int = 3,
        fallback: String
    ) -> String {
        let byID = Dictionary(facts.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let selected = acceptedIDs(selectedIDs, facts: facts, limit: limit)
            .compactMap { byID[$0] }
        let text = selected.joined(separator: " ")
        return text.isEmpty ? fallback : text
    }

    static func acceptedIDs(_ selectedIDs: [String], facts: [GroundedFact], limit: Int = 3) -> [String] {
        let knownIDs = Set(facts.map(\.id))
        var seen = Set<String>()
        return Array(selectedIDs.filter { knownIDs.contains($0) && seen.insert($0).inserted }
            .prefix(max(0, limit)))
    }

    static func accepts(
        generation: Int,
        currentGeneration: Int,
        fingerprint: String,
        currentFingerprint: String
    ) -> Bool {
        generation == currentGeneration && fingerprint == currentFingerprint
    }

    static func shouldStart(
        fingerprint: String,
        activeFingerprint: String?,
        completedFingerprint: String?,
        lastAttempt: Date?,
        now: Date = Date(),
        cooldown: TimeInterval = 20
    ) -> Bool {
        guard !fingerprint.isEmpty,
              activeFingerprint != fingerprint,
              completedFingerprint != fingerprint else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= cooldown
    }
}

#if canImport(FoundationModels) && !INTELLIGENCE_POLICY_CHECK
@available(macOS 26.0, *)
extension IntelligencePolicy {
    static func rankingSchema(for facts: [GroundedFact]) throws -> GenerationSchema {
        let factID = DynamicGenerationSchema(
            name: "FactID",
            description: "The ID of a supplied measured fact.",
            anyOf: facts.map(\.id)
        )
        let root = DynamicGenerationSchema(
            name: "IntelligenceRanking",
            description: "The most important supplied measured facts.",
            properties: [
                .init(
                    name: "factIDs",
                    description: "Supplied fact IDs in descending order of importance.",
                    schema: DynamicGenerationSchema(
                        arrayOf: factID,
                        minimumElements: 0,
                        maximumElements: 3
                    )
                )
            ]
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    static func readiness(for model: SystemLanguageModel, locale: Locale = .current) -> IntelligenceReadiness {
        if let reason = unavailableReason(for: model, locale: locale) {
            return .init(available: false, label: "Unavailable", detail: reason)
        }
        return .init(
            available: true,
            label: "Available",
            detail: "Apple Intelligence is ready to rank measured BloatMac facts on this Mac."
        )
    }

    static func unavailableReason(for model: SystemLanguageModel, locale: Locale = .current) -> String? {
        switch model.availability {
        case .available:
            guard model.supportsLocale(locale) else {
                return "Apple Intelligence does not support the current language. BloatMac is showing measured rules."
            }
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac does not support Apple Intelligence. BloatMac is showing measured rules."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. BloatMac is showing measured rules."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing its on-device model. BloatMac is showing measured rules."
        @unknown default:
            return "Apple Intelligence is unavailable. BloatMac is showing measured rules."
        }
    }
}

#endif
