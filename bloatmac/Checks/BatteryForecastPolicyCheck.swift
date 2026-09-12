import Foundation

@main
enum BatteryForecastPolicyCheck {
    static func main() {
        let base = 1_789_229_000.0

        let flatTimes = (0..<180).map { base + Double($0 * 5) }
        let flatLevels = Array(repeating: 0.18, count: flatTimes.count)
        precondition(BatteryForecastPolicy.forecast(timestamps: flatTimes, percents: flatLevels) == nil)

        let nearFlatLevels = flatTimes.indices.map { 0.18 - Double($0) * 1e-14 }
        precondition(BatteryForecastPolicy.forecast(timestamps: flatTimes, percents: nearFlatLevels) == nil)

        precondition(BatteryForecastPolicy.forecast(
            timestamps: [base, base + 300, .infinity, base + 900],
            percents: [0.50, 0.49, 0.48, 0.47]
        ) == nil)
        precondition(BatteryForecastPolicy.forecast(
            timestamps: [base, base + 300, base + 600, base + 900],
            percents: [0.50, .nan, 0.48, 0.47]
        ) == nil)

        let forecast = BatteryForecastPolicy.forecast(
            timestamps: [base, base + 300, base + 600, base + 900],
            percents: [0.50, 0.49, 0.48, 0.47]
        )
        precondition(forecast?.remainingMinutes == 235)
        precondition(abs((forecast?.drainPercentPerHour ?? 0) - 12) < 0.000_001)

        print("BatteryForecastPolicyCheck passed")
    }
}
