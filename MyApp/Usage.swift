import Foundation

/// What is left of each data source's request allowance (see the backend's API_CONTRACT.md).
struct Usage: Decodable, Equatable {
    struct AdsbLol: Decodable, Equatable {
        /// Requests made to ADSB.lol in the last 24 hours.
        let used: Int
        let dailyBudget: Int
        let remaining: Int
        /// When the server began counting its requests, so earlier ones are not in the number.
        let countedSince: Date
        /// When the oldest counted request turns 24 hours old and stops counting, so the number goes down by one.
        /// Absent when nothing is counted.
        let nextFreeAt: Date?

        var fractionUsed: Double { min(1, Double(used) / Double(max(dailyBudget, 1))) }
        /// More than 70 % used: the server then asks the app to refresh less often.
        var isRunningLow: Bool { fractionUsed > 0.7 }
    }

    struct OpenSky: Decodable, Equatable {
        let enabled: Bool
        let creditsRemaining: Int?
        let checkedAt: Date?
    }

    let adsbLol: AdsbLol
    let opensky: OpenSky
}
