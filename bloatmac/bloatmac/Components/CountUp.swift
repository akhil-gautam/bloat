import SwiftUI

struct CountUp: View {
    let value: Double
    var duration: Double = 0.7
    var decimals: Int = 1
    var suffix: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false
    @State private var start: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60, paused: !animating || reduceMotion)) { context in
            let progress = reduceMotion || !animating ? 1 : progress(at: context.date)
            let eased = 1 - pow(1 - progress, 3)
            let v = value * eased
            Text(String(format: "%.\(decimals)f%@", v, suffix))
        }
        .task(id: value) {
            guard !reduceMotion, duration > 0 else { animating = false; return }
            start = Date()
            animating = true
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            animating = false
        }
    }

    private func progress(at now: Date) -> Double {
        guard let start else { return 0 }
        let t = now.timeIntervalSince(start)
        return min(1, max(0, t / duration))
    }
}
