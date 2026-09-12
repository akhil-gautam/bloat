import Foundation

nonisolated struct BatteryForecast: Equatable {
    let remainingMinutes: Int
    let drainPercentPerHour: Double
}

nonisolated enum BatteryForecastPolicy {
    /// Returns nil when the samples do not contain a reliable downward trend.
    static func forecast(timestamps: [Double], percents: [Double]) -> BatteryForecast? {
        guard timestamps.count == percents.count,
              timestamps.count >= 2,
              timestamps.allSatisfy(\.isFinite),
              percents.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let firstTime = timestamps.first,
              let firstPercent = percents.first,
              let currentPercent = percents.last else { return nil }

        // Translate Unix timestamps and charge levels before averaging. This
        // makes a flat series exactly flat instead of creating a microscopic
        // negative slope through cancellation of large absolute values.
        let xs = timestamps.map { $0 - firstTime }
        let ys = percents.map { $0 - firstPercent }
        let count = Double(xs.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        var numerator = 0.0
        var denominator = 0.0
        for index in xs.indices {
            let dx = xs[index] - meanX
            numerator += dx * (ys[index] - meanY)
            denominator += dx * dx
        }

        guard denominator.isFinite, denominator > 0, numerator.isFinite else { return nil }
        let slope = numerator / denominator
        guard slope.isFinite, slope < 0,
              let minTime = xs.min(), let maxTime = xs.max() else { return nil }

        // A trend smaller than one hundredth of a percentage point over the
        // observed interval is below the useful resolution of these readings.
        let modeledChange = -slope * (maxTime - minTime)
        guard modeledChange.isFinite, modeledChange >= 0.0001 else { return nil }

        let drainPercentPerHour = -slope * 3600 * 100
        let remainingMinutes = currentPercent / -slope / 60
        guard drainPercentPerHour.isFinite,
              remainingMinutes.isFinite,
              remainingMinutes >= 0,
              remainingMinutes < Double(Int.max) else { return nil }

        return BatteryForecast(
            remainingMinutes: Int(remainingMinutes.rounded()),
            drainPercentPerHour: drainPercentPerHour
        )
    }
}
