import Foundation

@main
struct IntelligencePolicyCheck {
    static func main() {
        let facts = [
            GroundedFact(id: "memory", text: "Memory pressure is normal."),
            GroundedFact(id: "storage", text: "Storage is 80% used."),
        ]

        precondition(
            IntelligencePolicy.groundedText(
                selectedIDs: ["invented", "storage", "storage", "memory"],
                facts: facts,
                limit: 2,
                fallback: "Fallback"
            ) == "Storage is 80% used. Memory pressure is normal."
        )
        precondition(
            IntelligencePolicy.groundedText(
                selectedIDs: ["invented"],
                facts: facts,
                fallback: "Fallback"
            ) == "Fallback"
        )
        precondition(IntelligencePolicy.acceptedIDs(["invented"], facts: facts).isEmpty)
        precondition(IntelligencePolicy.acceptedIDs(["storage", "storage", "memory"], facts: facts) == ["storage", "memory"])
        precondition(
            IntelligencePolicy.rankingFingerprint(for: facts)
                == IntelligencePolicy.rankingFingerprint(for: facts.map { .init(id: $0.id, text: "changed") })
        )

        let singleton = ObservationCoverage(timestamps: [100])
        precondition(!singleton.canPlot)
        precondition(singleton.summary == "1 sample")

        precondition(!ObservationCoverage.canCompare(previous: [], current: [100, 400, 700]))
        precondition(!ObservationCoverage.canCompare(previous: [0], current: [100, 400, 700]))
        precondition(!ObservationCoverage.canCompare(previous: [0, 100, 200], current: [300, 600, 900]))
        precondition(ObservationCoverage.canCompare(previous: [0, 300, 600], current: [700, 1_000, 1_300]))

        precondition(
            !IntelligencePolicy.accepts(
                generation: 1,
                currentGeneration: 2,
                fingerprint: "old",
                currentFingerprint: "new"
            )
        )
        precondition(
            IntelligencePolicy.accepts(
                generation: 2,
                currentGeneration: 2,
                fingerprint: "new",
                currentFingerprint: "new"
            )
        )

        let now = Date(timeIntervalSince1970: 100)
        precondition(
            !IntelligencePolicy.shouldStart(
                fingerprint: "same",
                activeFingerprint: nil,
                completedFingerprint: "same",
                lastAttempt: nil,
                now: now
            )
        )
        precondition(
            !IntelligencePolicy.shouldStart(
                fingerprint: "new",
                activeFingerprint: nil,
                completedFingerprint: nil,
                lastAttempt: Date(timeIntervalSince1970: 90),
                now: now,
                cooldown: 30
            )
        )
        precondition(
            IntelligencePolicy.shouldStart(
                fingerprint: "new",
                activeFingerprint: nil,
                completedFingerprint: nil,
                lastAttempt: Date(timeIntervalSince1970: 60),
                now: now,
                cooldown: 30
            )
        )

        print("IntelligencePolicyCheck passed")
    }
}
