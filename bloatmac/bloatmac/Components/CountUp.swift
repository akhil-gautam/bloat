import SwiftUI

struct CountUp: View {
    let value: Double
    var duration: Double = 0.7
    var decimals: Int = 1
    var suffix: String = ""

    @State private var displayed: Double = 0
    @State private var start: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60)) { context in
            let progress = progress(at: context.date)
            let eased = 1 - pow(1 - progress, 3)
            let v = value * eased
            Text(String(format: "%.\(decimals)f%@", v, suffix))
        }
        .onAppear { start = Date() }
        .onChange(of: value) { _, _ in start = Date() }
    }

    private func progress(at now: Date) -> Double {
        guard let start else { return 0 }
        let t = now.timeIntervalSince(start)
        return min(1, max(0, t / duration))
    }
}
